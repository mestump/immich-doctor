#!/usr/bin/env python3
"""Tests for docs/migrate.py — run via: uv run --python 3.12 --with textual python t/test_migrate.py"""
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).parent
REPO = HERE.parent
TMP = Path(tempfile.mkdtemp(prefix="migrate-test-"))
os.environ["MIGRATE_HOME"] = str(TMP / "home")
os.environ.pop("SPARK_API_KEY", None)
os.environ.pop("SPARK_BASE_URL", None)
os.environ.pop("SPARK_MODEL", None)

import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location("migrate", REPO / "docs" / "migrate.py")
M = importlib.util.module_from_spec(_spec)
sys.modules["migrate"] = M
_spec.loader.exec_module(M)

M.CONFIG_PATH = TMP / "home" / "migrate.json"
M.DONE_LIST = TMP / "home" / "imported.tsv"


def make_takeout_zip(path: Path, parts: dict) -> None:
    """parts: relpath -> bytes; adds sidecars for jpgs."""
    with zipfile.ZipFile(path, "w") as z:
        for rel, data in parts.items():
            z.writestr(rel, data)
            if rel.lower().endswith(".jpg"):
                z.writestr(rel + ".json", json.dumps({
                    "title": Path(rel).name,
                    "photoTakenTime": {"timestamp": "1580000000"},
                    "geoData": {"latitude": 1.5, "longitude": -2.5},
                }))


def photo(i: int) -> bytes:
    return b"\xff\xd8\xff\xe0" + bytes(str(i), "ascii") + b"x" * 2000


def std_takeout_parts(year: str, n: int = 3, album: str | None = None) -> dict:
    parts = {}
    for i in range(n):
        name = f"{year}_P{i:02d}.jpg"
        parts[f"Photos/{year}/{name}"] = photo(i)
    if album:
        for i in range(2):
            parts[f"Photos/{year}/{album}/A{i:02d}.jpg"] = photo(100 + i)
    return parts


class MigrateTest(unittest.TestCase):
    def setUp(self) -> None:
        M.DONE_LIST.parent.mkdir(parents=True, exist_ok=True)
        M.DONE_LIST.write_text("")

    def test_zip_kinds(self) -> None:
        dl = Path(tempfile.mkdtemp(dir=TMP))
        takeout = dl / "takeout-20240115T101530Z-1 of 2.zip"
        make_takeout_zip(takeout, std_takeout_parts("2020"))
        self.assertEqual(M.zip_kind(takeout), "takeout")
        inner = dl / "inner.zip"
        make_takeout_zip(inner, std_takeout_parts("2021", 2))
        wrapper = dl / "Takeout-February.zip"
        with zipfile.ZipFile(wrapper, "w") as z:
            z.write(inner, "Takeout-February/takeout-20240220T080000Z-1 of 1.zip")
        self.assertEqual(M.zip_kind(wrapper), "wrapper")
        junk = dl / "addon.zip"
        with zipfile.ZipFile(junk, "w") as z:
            z.writestr("plugin/a.dat", b"x" * 100)
        self.assertEqual(M.zip_kind(junk), "junk")
        self.assertEqual(M.zip_kind(dl / "missing.zip"), "junk")

    def test_dir_kind(self) -> None:
        d = Path(tempfile.mkdtemp(dir=TMP))
        (d / "Takeout").mkdir()
        self.assertEqual(M.dir_kind(d), "takeout")
        d2 = Path(tempfile.mkdtemp(dir=TMP))
        self.assertEqual(M.dir_kind(d2), "junk")

    def test_bundle_grouping_and_done(self) -> None:
        dl = Path(tempfile.mkdtemp(dir=TMP))
        a1 = dl / "takeout-20240115T101530Z-1 of 2.zip"
        a2 = dl / "takeout-20240115T101530Z-2 of 2.zip"
        b1 = dl / "takeout-20240220T080000Z-1 of 1.zip"
        make_takeout_zip(a1, std_takeout_parts("2020", 3))
        make_takeout_zip(a2, std_takeout_parts("2021", 2))
        make_takeout_zip(b1, std_takeout_parts("2022", 2))
        with zipfile.ZipFile(dl / "unrelated-1.2.zip", "w") as z:
            z.writestr("x.dat", b"x" * 100)
        bundles = M.build_bundles(str(dl), force=False)
        keys = {b.key: b for b in bundles}
        self.assertEqual(len([b for b in bundles if b.status != "skipped"]), 2, keys)
        self.assertEqual(keys["ts:20240115t101530z"].est_assets, 5)
        # done-list skip
        M.record_done("ts:20240115t101530z")
        bundles2 = M.build_bundles(str(dl), force=False)
        live = [b for b in bundles2 if b.status == "pending"]
        self.assertEqual(len(live), 1)
        self.assertEqual(live[0].key, "ts:20240220t080000z")
        bundles3 = M.build_bundles(str(dl), force=True)
        self.assertEqual(len([b for b in bundles3 if b.status == "pending"]), 2)

    def test_prepare_flattens_wrapper(self) -> None:
        dl = Path(tempfile.mkdtemp(dir=TMP))
        inner = dl / "takeout-20240220T080000Z-1 of 1.zip"
        make_takeout_zip(inner, {"Photos/2022/a.jpg": photo(1), "Photos/2022/b.jpg": photo(2),
                                 "Photos/2022/c.jpg": photo(3)})
        wrapper = dl / "Takeout-February.zip"
        with zipfile.ZipFile(wrapper, "w") as z:
            z.write(inner, "Takeout-Feb/takeout-20240220T080000Z-1 of 1.zip")
        inner.unlink()
        bundles = M.build_bundles(str(dl), force=False)
        self.assertEqual(len(bundles), 1)
        work = Path(tempfile.mkdtemp(dir=TMP))
        notes = M.prepare_bundles(bundles, work)
        self.assertEqual(notes, [])
        b = bundles[0]
        self.assertEqual(len(b.parts), 1)
        self.assertTrue(b.parts[0].startswith("takeout:"))
        self.assertIn("inner-takeout-20240220T080000Z-1-of-1.zip", b.parts[0])
        self.assertEqual(b.est_assets, 3)

    def test_config_roundtrip(self) -> None:
        cfg = {"server": "http://x:2283", "key": "k", "spark_key": "s", "auto_fix": False}
        M.save_config(cfg)
        loaded = M.load_config()
        self.assertEqual(loaded["server"], "http://x:2283")
        self.assertFalse(loaded["auto_fix"])
        self.assertTrue(M.CONFIG_PATH.exists())

    def test_build_report(self) -> None:
        state = {
            "server": "http://x",
            "bundles": [{"label": "a.zip", "status": "ok", "rc": 0, "est": 3, "log": ""},
                        {"label": "b.zip", "status": "failed", "rc": 2, "est": 4, "log": "/tmp/b.log"}],
            "total_start": 10, "total_end": 17, "albums": 4, "notes": ["ignored junk"],
        }
        md = M.build_report(state)
        for needle in ("# Migration report", "Bundles imported OK: **1**", "| a.zip | 3 | ok |",
                       "b.zip | 4 | failed (exit 2)", "Albums on the server now: **4**", "ignored junk"):
            self.assertIn(needle, md)


class ServerTestMixin:
    def wait_port(self, port: int, timeout: float = 10.0) -> None:
        import socket
        end = time.time() + timeout
        while time.time() < end:
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                    return
            except OSError:
                time.sleep(0.05)
        raise RuntimeError(f"port {port} never opened")


class ImmichClientTest(ServerTestMixin, unittest.TestCase):
    def test_against_mock(self) -> None:
        self.port = 9151
        env = dict(os.environ, MOCK_KEY="testkey")
        proc = subprocess.Popen([sys.executable, str(HERE / "mockimmich.py"), str(self.port)],
                                env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(proc.terminate)
        self.wait_port(self.port)
        base = f"http://127.0.0.1:{self.port}"
        imm = M.Immich(base, "testkey")
        self.assertTrue(imm.ping())
        me = imm.me()
        self.assertEqual(me["email"], "dad@example.com")
        self.assertTrue(me["isAdmin"])
        self.assertEqual(imm.total_assets(), 0)
        self.assertEqual(imm.album_count(), 0)
        about = imm.about()
        self.assertIn("version", about)
        with self.assertRaises(M.AuthError):
            M.Immich(base, "wrong", timeout=5).me()


class FakeSpark:
    """Scriptable chat/completions server."""

    def __init__(self) -> None:
        self.responses: list[dict] = []
        self.requests: list[dict] = []
        self.lock = threading.Lock()
        outer = self

        class H(BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                n = int(self.headers.get("content-length", 0) or 0)
                body = json.loads(self.rfile.read(n) or b"{}")
                with outer.lock:
                    outer.requests.append(body)
                    idx = len(outer.requests) - 1
                msg = outer.responses[idx] if idx < len(outer.responses) else {"content": "fallback"}
                out = json.dumps({"choices": [{"message": msg}]}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(out)))
                self.end_headers()
                self.wfile.write(out)

            def log_message(self, *a) -> None:
                pass

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}/v1"

    def stop(self) -> None:
        self.srv.shutdown()


class AssistantTest(ServerTestMixin, unittest.TestCase):
    def test_tool_loop_then_answer(self) -> None:
        fs = FakeSpark()
        self.addCleanup(fs.stop)
        fs.responses = [
            {"tool_calls": [{"id": "c1", "function": {"name": "server_status", "arguments": "{}"}}]},
            {"content": "The server is fine: 12 assets."},
        ]

        class Box:
            calls: list = []

            def state_snapshot(self) -> dict:
                return {"x": 1}

            def tool(self, name: str, args: dict) -> object:
                Box.calls.append((name, args))
                return {"ping": True, "assets": 12}

            def mark_auto(self) -> None:
                pass

        spark = M.Spark(fs.url(), "k", "m", timeout=10)
        box = Box()
        assistant = M.Assistant(spark, box)
        out = assistant.ask("is it ok?")
        self.assertEqual(out, "The server is fine: 12 assets.")
        self.assertEqual([c[0] for c in box.calls], ["server_status"])
        self.assertEqual(len(assistant.history), 2)
        # the tool result was fed back to the model
        second = fs.requests[1]
        self.assertTrue(any(m.get("role") == "tool" for m in second["messages"]))

    def test_busy_guard(self) -> None:
        fs = FakeSpark()
        self.addCleanup(fs.stop)

        class Box:
            def state_snapshot(self) -> dict:
                return {}

            def tool(self, name, args) -> object:
                return {}

            def mark_auto(self) -> None:
                pass

        a = M.Assistant(M.Spark(fs.url(), "k", "m", timeout=10), Box())
        a.busy = True
        self.assertIn("moment", a.ask("hi"))


class HostAdapterTest(unittest.TestCase):
    def test_run_command_and_snapshot(self) -> None:
        app = M.MigrateApp(cfg={"server": "http://x", "key": "k"})
        host = M.HostAdapter(app)
        out = host.tool("run_command", {"command": "echo hi"})
        self.assertIn("rc=0", out)
        self.assertIn("hi", out)
        self.assertEqual(host.state_snapshot()["phase"], "idle")
        self.assertEqual(host.tool("bundle_status", {}), [])
        with self.assertRaises(KeyError):
            host.tool("nope", {})

    def test_sudo_guard(self) -> None:
        app = M.MigrateApp(cfg={})
        host = M.HostAdapter(app)
        out = host.tool("run_command", {"command": "sudo rm -rf /"})
        self.assertIn("plain user commands", out)


class FakeIgTest(ServerTestMixin, unittest.TestCase):
    def make_fake_ig(self, bindir: Path, rc: int = 0) -> Path:
        bindir.mkdir(parents=True, exist_ok=True)
        args_file = bindir / "args.txt"
        script = f"""#!/usr/bin/env bash
printf '%s\\n' "$@" > {args_file}
echo "fake-ig running"
echo "WARN: nothing real"
exit {rc}
"""
        bin_ = bindir / "immich-go"
        bin_.write_text(script)
        bin_.chmod(0o755)
        (bindir / ".ig-version").write_text(M.IG_VERSION)
        return bin_

    def test_runner_flags_and_log(self) -> None:
        bindir = Path(tempfile.mkdtemp(dir=TMP))
        self.make_fake_ig(bindir)
        r = M.Runner(bindir)
        log = bindir / "run.log"
        lines: list[str] = []
        sink: dict = {}
        rc = r.run(["/tmp/a.zip", "/tmp/b.zip"], "http://s:2283", "KEY", admin=False,
                   log_path=log, on_line=lines.append, proc_sink=sink)
        self.assertEqual(rc, 0)
        args = (bindir / "args.txt").read_text().splitlines()
        joined = " ".join(args)
        self.assertIn("upload from-google-photos", joined)
        self.assertIn("--server http://s:2283", joined)
        self.assertIn("--api-key KEY", joined)
        self.assertIn("--pause-immich-jobs=false", joined)
        self.assertIn("--no-ui", joined)
        self.assertIn("/tmp/a.zip", joined)
        self.assertTrue(len(lines) >= 2)
        self.assertIn("fake-ig running", log.read_text())
        self.assertEqual(sink, {})

    def test_runner_admin_flag(self) -> None:
        bindir = Path(tempfile.mkdtemp(dir=TMP))
        self.make_fake_ig(bindir)
        M.Runner(bindir).run(["/x"], "http://s", "K", admin=True,
                             log_path=bindir / "r2.log")
        self.assertIn("--admin-api-key", (bindir / "args.txt").read_text())

    def test_runner_rc(self) -> None:
        bindir = Path(tempfile.mkdtemp(dir=TMP))
        self.make_fake_ig(bindir, rc=3)
        rc = M.Runner(bindir).run(["/x"], "http://s", "K", admin=False, log_path=bindir / "r3.log")
        self.assertEqual(rc, 3)

    def test_bin_cached(self) -> None:
        bindir = Path(tempfile.mkdtemp(dir=TMP))
        want = self.make_fake_ig(bindir)
        self.assertEqual(M.Runner(bindir).bin(), want)


class HeadlessScanTest(unittest.TestCase):
    def test_scan_cli(self) -> None:
        dl = Path(tempfile.mkdtemp(dir=TMP))
        make_takeout_zip(dl / "takeout-20240115T101530Z-1 of 1.zip", std_takeout_parts("2020", 2))
        env = dict(os.environ, MIGRATE_HOME=str(TMP / "home2"))
        (TMP / "home2").mkdir(exist_ok=True)
        out = subprocess.run([sys.executable, str(REPO / "docs" / "migrate.py"), "scan", str(dl)],
                             capture_output=True, text=True, env=env, timeout=120)
        self.assertEqual(out.returncode, 0, out.stderr)
        rows = [json.loads(ln) for ln in out.stdout.strip().splitlines()]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["est_assets"], 2)
        self.assertIn("bundles=1", out.stderr)

    def test_version(self) -> None:
        out = subprocess.run([sys.executable, str(REPO / "docs" / "migrate.py"), "--version"],
                             capture_output=True, text=True, timeout=60)
        self.assertIn("Pop's Migrator", out.stdout)


class PilotTest(ServerTestMixin, unittest.IsolatedAsyncioTestCase):
    """Full UI flow: connect -> review -> run (fake ig, mock immich) -> report."""

    def setUp(self) -> None:
        # mock immich
        self.port = 9157
        self.mock = subprocess.Popen([sys.executable, str(HERE / "mockimmich.py"), str(self.port)],
                                     env=dict(os.environ, MOCK_KEY="testkey"),
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(self.mock.terminate)
        self.wait_port(self.port)
        # fixtures
        self.dl = Path(tempfile.mkdtemp(prefix="pilot-dl-", dir=TMP))
        inner = self.dl / "inner.zip"
        make_takeout_zip(inner, std_takeout_parts("2020", 3))
        with zipfile.ZipFile(self.dl / "Takeout-February.zip", "w") as z:
            z.write(inner, "Takeout-Feb/takeout-20240220T080000Z-1 of 1.zip")
        inner.unlink()  # only the wrapper remains, like a real download dir
        # fake ig
        self.bindir = Path(tempfile.mkdtemp(dir=TMP))
        script = f"""#!/usr/bin/env bash
printf '%s\\n' "$@" > {self.bindir}/args.txt
echo "fake-ig ok"
exit 0
"""
        (self.bindir / "immich-go").write_text(script)
        (self.bindir / "immich-go").chmod(0o755)
        (self.bindir / ".ig-version").write_text(M.IG_VERSION)
        # app
        self.cfg = {"server": f"http://127.0.0.1:{self.port}", "key": "testkey",
                    "spark_url": "", "spark_key": "", "auto_fix": False,
                    "delete_downloads": False}
        self.app = M.MigrateApp(cfg=dict(self.cfg))

    async def wait_for(self, pred, timeout: float = 30.0):
        end = time.time() + timeout
        while time.time() < end:
            try:
                if pred():
                    return True
            except Exception:
                pass
            await asyncio.sleep(0.05)
        return False

    async def test_full_flow(self) -> None:
        import asyncio
        app = self.app
        async with app.run_test(size=(140, 44)) as pilot:
            await self.wait_for(lambda: isinstance(app.screen, M.ConnectScreen))
            self.assertIsInstance(app.screen, M.ConnectScreen)
            app.screen.query_one("#server", M.Input).value = self.cfg["server"]
            app.screen.query_one("#key", M.Input).value = "testkey"
            app.screen.query_one("#cpath", M.Input).value = str(self.dl)
            await pilot.click("#connect")
            ok = await self.wait_for(lambda: isinstance(app.screen, M.ReviewScreen), timeout=30)
            self.assertTrue(ok, f"review never shown; screen={type(app.screen).__name__}")
            self.assertEqual(app.bundles[0].key, "file:takeout-february.zip")
            app.runner = M.Runner(self.bindir)  # swap in the fake immich-go
            await pilot.click("#start")
            ok = await self.wait_for(lambda: isinstance(app.screen, M.ReportScreen), timeout=60)
            self.assertTrue(ok, f"report never shown; screen={type(app.screen).__name__}")
            bundle = app.bundles[0]
            self.assertEqual(bundle.status, "ok")
            args = (self.bindir / "args.txt").read_text()
            self.assertIn("from-google-photos", args)
            self.assertIn("inner-takeout-20240220T080000Z-1-of-1.zip", args)  # wrapper was flattened
            # done-list recorded -> a second plan marks it skipped
            self.assertIn(bundle.key, M.done_keys())
            report_path = Path(app.screen.path)
            self.assertTrue(report_path.exists())
            body = report_path.read_text()
            self.assertIn("Migration report", body)
            self.assertIn("Takeout-February.zip", body)
            await self.wait_for(lambda: app.total_end >= 0, timeout=10)
            app.exit()


import asyncio  # noqa: E402  (after class defs is fine for IsolatedAsyncioTestCase? keep top-level)

if __name__ == "__main__":
    unittest.main(verbosity=2)
