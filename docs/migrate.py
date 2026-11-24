#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["textual>=8,<9"]
# ///
"""Pop's Migrator — Google Photos Takeout -> Immich, with AI on call.

A TUI that wraps the immich-doctor pipeline: the same pinned immich-go
binary and the same safety rules as import.sh (wrapper-zip flattening,
bundle keying, done-list resume, checksum dedup inside immich-go), plus a
Spark-powered assistant that can inspect logs, interrogate the Immich
server, run read-only commands, and retry a failed bundle.

Run:      uv run migrate.py
Headless: uv run migrate.py scan /path/to/downloads

Provenance: orchestration rules ported from docs/import.sh (see
Infrastructure/Immich-Doctor-2026-09-19 for the lessons behind them).
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.request
import zipfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import cast

VERSION = "1.0.0"
IG_VERSION = "v0.32.0"
IG_RELEASE = "https://github.com/simulot/immich-go/releases/download/{tag}"
APP_DIR = Path(os.environ.get("MIGRATE_HOME", str(Path.home() / ".config/immich-doctor")))
CONFIG_PATH = APP_DIR / "migrate.json"
DONE_LIST = APP_DIR / "imported.tsv"
WORK_DIR_NAME = ".migrate-work"

DEFAULT_SPARK = {
    "url": os.environ.get("SPARK_BASE_URL", "https://llm.plexivision.tv/v1"),
    "key": os.environ.get("SPARK_API_KEY", ""),
    "model": os.environ.get("SPARK_MODEL", "spark-prod"),
}
DEFAULT_SPARK_KEY = "sk-spark-Nj6JJLxe5E0AGcTv6zpWR2U-iEIrMusR"  # baked distribution default; env SPARK_API_KEY / config win

# (path, min zip size MB) — mirrors import.sh scan roots. /root/Downloads is
# where a browser on the box puts things, so it is trusted with no floor.
SCAN_ROOTS = [
    ("/root/Downloads", 0),
    ("/root/download", 0),
    ("/mnt/user/downloads", 20),
    ("/mnt/user/Downloads", 20),
    ("/mnt/user/data", 20),
]

MEDIA_RE = re.compile(
    r"\.(jpg|jpeg|png|heic|heif|webp|gif|tiff|bmp|dng|mpo|mp4|mov|avi|wmv|"
    r"3gp|mts|m2ts|mkv|webm|mpg|mpeg|insv)$",
    re.I,
)
SIDECAR_RE = re.compile(r"\.(jpg|jpeg|png|heic|heif|webp|mp4|mov|avi|mkv|mts|m2ts)\.json$", re.I)
TAKEOUT_TOP_RE = re.compile(r"^(Takeout/|Photos/|Google Photos/|GooglePhotos\.json|history\.json)", re.I)
BUNDLE_TS_RE = re.compile(r"[0-9]{8}t[0-9]{6}z")


class UserError(Exception):
    """A problem worth telling a normal person about, in plain words."""


# --------------------------------------------------------------------- config


def load_config() -> dict:
    cfg = {
        "server": "",
        "key": "",
        "spark_url": DEFAULT_SPARK["url"],
        "spark_key": DEFAULT_SPARK_KEY,
        "spark_model": DEFAULT_SPARK["model"],
        "last_path": "",
        "auto_fix": True,
        "pause_jobs": True,
        "delete_downloads": False,
    }
    if CONFIG_PATH.exists():
        try:
            cfg.update(json.loads(CONFIG_PATH.read_text()))
        except Exception:
            pass
    for env, k in (("SPARK_API_KEY", "spark_key"), ("SPARK_BASE_URL", "spark_url"), ("SPARK_MODEL", "spark_model")):
        if os.environ.get(env):
            cfg[k] = os.environ[env]
    return cfg


def save_config(cfg: dict) -> None:
    APP_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CONFIG_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(cfg, indent=1))
    tmp.replace(CONFIG_PATH)
    try:
        CONFIG_PATH.chmod(0o600)
    except OSError:
        pass


def done_keys() -> set[str]:
    try:
        return {ln.split("\t", 1)[0] for ln in DONE_LIST.read_text().splitlines() if ln.strip()}
    except OSError:
        return set()


def record_done(key: str) -> None:
    DONE_LIST.parent.mkdir(parents=True, exist_ok=True)
    with DONE_LIST.open("a") as fh:
        fh.write(f"{key}\t{datetime.now(timezone.utc).strftime('%FT%TZ')}\n")


# ------------------------------------------------------- takeout orchestration


def _zip_names(path: Path) -> list[str]:
    try:
        with zipfile.ZipFile(path) as z:
            return z.namelist()
    except Exception:
        return []


def zip_kind(path: Path) -> str:
    """wrapper | takeout | junk — port of import.sh zip_kind via python zipfile."""
    names = _zip_names(path)
    if not names:
        return "junk"
    if any(n.lower().endswith(".zip") for n in names):
        return "wrapper"
    if any(TAKEOUT_TOP_RE.match(n) for n in names):
        return "takeout"
    if sum(1 for n in names if SIDECAR_RE.search(n)) >= 3:
        return "takeout"
    return "junk"


def dir_kind(path: Path) -> str:
    for sub in ("Takeout", "Photos", "Google Photos"):
        if (path / sub).exists():
            return "takeout"
    for marker in ("GooglePhotos.json", "history.json"):
        if (path / marker).is_file():
            return "takeout"
    return "junk"


def bundle_key(path: Path) -> str:
    m = BUNDLE_TS_RE.search(path.name.lower())
    return f"ts:{m.group(0)}" if m else f"file:{path.name.lower()}"


def count_media(names: list[str]) -> int:
    return sum(1 for n in names if MEDIA_RE.search(n))


@dataclass
class Bundle:
    key: str
    parts: list[str] = field(default_factory=list)  # 'kind:path'
    zip_bytes: int = 0
    est_assets: int = 0
    label: str = ""
    status: str = "pending"  # pending|running|ok|failed|skipped|cancelled
    rc: int | None = None
    log: str = ""

    def paths(self) -> list[str]:
        return [p.split(":", 1)[1] for p in self.parts if ":" in p]


def dir_size(path: Path) -> int:
    total = 0
    for p in Path(path).rglob("*"):
        try:
            if p.is_file():
                total += p.stat().st_size
        except OSError:
            pass
    return total


def scan_candidates(extra: str | None = None) -> list[tuple[str, str, int]]:
    """(path, kind, size): zips at depth 1-2 over the floor + takeout dirs."""
    roots: list[tuple[Path, int]] = [(Path(p), mb) for p, mb in SCAN_ROOTS]
    if extra:
        roots.append((Path(extra), 0))
    out: list[tuple[str, str, int]] = []
    seen: set[str] = set()
    for root, floor_mb in roots:
        try:
            if not root.is_dir():
                continue
            entries = sorted(root.iterdir())
            zips: list[Path] = []
            for e in entries:
                if e.name.startswith("."):
                    continue
                if e.is_file() and e.suffix.lower() == ".zip":
                    zips.append(e)
                elif e.is_dir():
                    try:
                        zips += [c for c in sorted(e.iterdir())
                                 if c.is_file() and c.suffix.lower() == ".zip" and not c.name.startswith(".")]
                    except OSError:
                        pass
            for z in zips:
                try:
                    size = z.stat().st_size
                except OSError:
                    continue
                if size >= floor_mb * 1024 * 1024 and str(z) not in seen:
                    kind = zip_kind(z)
                    if kind != "junk":
                        seen.add(str(z))
                        out.append((str(z), kind, size))
            for d in entries:
                if d.is_dir() and not d.name.startswith("."):
                    if dir_kind(d) == "takeout" and str(d) not in seen:
                        seen.add(str(d))
                        out.append((str(d), "dir", dir_size(d)))
        except OSError:
            continue
    return out


def build_bundles(extra: str | None, force: bool) -> list[Bundle]:
    groups: dict[str, Bundle] = {}
    for path, kind, size in scan_candidates(extra):
        key = bundle_key(Path(path))
        b = groups.setdefault(key, Bundle(key=key))
        b.parts.append(f"{kind}:{path}")
        b.zip_bytes += size
    done = done_keys()
    for key, b in groups.items():
        first = Path(b.parts[0].split(":", 1)[1])
        b.label = first.name + (f" (+{len(b.parts) - 1} more)" if len(b.parts) > 1 else "")
        est = 0
        for p in b.parts:
            kind, real = p.split(":", 1)
            if kind == "dir":
                est += count_media([str(f) for f in Path(real).rglob("*") if f.is_file()])
            else:
                est += count_media(_zip_names(Path(real)))
        b.est_assets = est
        if key in done and not force:
            b.status = "skipped"
    pending = [b for b in groups.values() if b.status != "skipped"]
    skipped = [b for b in groups.values() if b.status == "skipped"]
    return pending + skipped


def _recount(bundle: Bundle) -> None:
    est = 0
    for p in bundle.parts:
        kind, real = p.split(":", 1)
        if kind == "dir":
            est += count_media([str(f) for f in Path(real).rglob("*") if f.is_file()])
        else:
            est += count_media(_zip_names(Path(real)))
    bundle.est_assets = est


def prepare_bundles(bundles: list[Bundle], work: Path) -> list[str]:
    """Flatten Chrome-merged wrapper zips; returns notes. One level, per the v1 lesson."""
    notes: list[str] = []
    for b in bundles:
        if b.status != "pending":
            continue
        keep: list[str] = []
        for part in b.parts:
            kind, path = part.split(":", 1)
            if kind != "wrapper":
                keep.append(part)
                continue
            udir = work / ("unpacked-" + re.sub(r"[^a-z0-9]+", "-", b.key))
            udir.mkdir(parents=True, exist_ok=True)
            inner_ok = 0
            try:
                with zipfile.ZipFile(path) as z:
                    for name in [n for n in z.namelist() if n.lower().endswith(".zip")]:
                        tmp = udir / ("inner-" + re.sub(r"[^\w.-]+", "-", Path(name).name))
                        with z.open(name) as src, open(tmp, "wb") as dst:
                            shutil.copyfileobj(src, dst, 1 << 20)
                        if zip_kind(tmp) == "takeout":
                            keep.append(f"takeout:{tmp}")
                            inner_ok += 1
                        else:
                            notes.append(f"ignored non-takeout zip inside {Path(path).name}: {tmp.name}")
            except zipfile.BadZipFile:
                notes.append(f"could not read zip: {path}")
                continue
            if not inner_ok:
                notes.append(f"wrapper had no takeout parts: {path}")
        b.parts = keep
        _recount(b)
    return notes


def check_disk(bundles: list[Bundle], work: Path) -> str | None:
    need = sum(b.zip_bytes for b in bundles if any(p.startswith("wrapper:") for p in b.parts))
    if not need:
        return None
    try:
        free = shutil.disk_usage(work).free
    except OSError:
        return None
    if need > free:
        return (f"Unpacking the merged download needs {need // 1024 // 1024} MB free, and that "
                f"location has {free // 1024 // 1024} MB — free some space and try again.")
    return None


# ------------------------------------------------------------- immich client


class AuthError(UserError):
    pass


class Immich:
    def __init__(self, url: str, key: str, timeout: int = 15):
        self.url = url.rstrip("/")
        self.key = key
        self.timeout = timeout

    def req(self, method: str, path: str, body: dict | None = None) -> tuple[int, object]:
        data = json.dumps(body).encode() if body is not None else None
        full = self.url + (path if path.startswith("/api") else "/api" + path)
        r = urllib.request.Request(full, data=data, method=method,
                                   headers={"x-api-key": self.key, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(r, timeout=self.timeout) as resp:
                raw = resp.read()
                return resp.status, (json.loads(raw) if raw.strip() else {})
        except urllib.error.HTTPError as e:
            payload: object = {}
            try:
                payload = json.loads(e.read() or b"{}")
            except Exception:
                pass
            if e.code in (401, 403):
                raise AuthError("Immich rejected the API key (check the key in Immich > My Account > API Keys).") from e
            return e.code, payload
        except urllib.error.URLError as e:
            raise UserError(f"Cannot reach {self.url} ({e.reason}). Is Immich running?") from e

    def ping(self) -> bool:
        try:
            _, obj = self.req("GET", "/api/server/ping")
            return isinstance(obj, dict) and obj.get("res") == "pong"
        except UserError:
            return False

    def about(self) -> dict:
        return cast(dict, self.req("GET", "/api/server/about")[1])

    def me(self) -> dict:
        return cast(dict, self.req("GET", "/api/users/me")[1])

    def total_assets(self) -> int:
        try:
            obj = self.req("GET", "/api/assets/statistics")[1]
            return int(obj.get("total", 0))
        except Exception:
            return -1

    def album_count(self) -> int:
        try:
            obj = self.req("GET", "/api/albums")[1]
            return len(obj) if isinstance(obj, list) else -1
        except Exception:
            return -1

    @staticmethod
    def _probe(url: str) -> bool:
        try:
            with urllib.request.urlopen(url + "/", timeout=5) as r:
                return b"immich" in r.read(4096).lower()
        except Exception:
            return False

    @staticmethod
    def detect_local() -> str | None:
        if shutil.which("docker"):
            for exp in ("8080/tcp", "2283/tcp"):
                try:
                    out = subprocess.run(["docker", "port", "immich", exp],
                                         capture_output=True, text=True, timeout=10).stdout
                    first = out.strip().splitlines()[0] if out.strip() else ""
                    m = re.search(r"(\d+)$", first)
                    if m and Immich._probe(f"http://127.0.0.1:{m.group(1)}"):
                        return f"http://127.0.0.1:{m.group(1)}"
                except Exception:
                    pass
        for port in ("2283", "8082"):
            if Immich._probe(f"http://127.0.0.1:{port}"):
                return f"http://127.0.0.1:{port}"
        return None


# ------------------------------------------------------------------ immich-go


def _download(url: str, dest: Path, tries: int = 3) -> None:
    last: Exception | None = None
    for i in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=180) as r, open(dest, "wb") as f:
                shutil.copyfileobj(r, f, 1 << 20)
            return
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(2 * (i + 1))
    raise UserError(f"Download failed: {url} ({last})")


class Runner:
    def __init__(self, bindir: Path):
        self.bindir = Path(bindir)

    def bin(self) -> Path:
        b = self.bindir / "immich-go"
        ver = self.bindir / ".ig-version"
        if b.exists() and ver.exists() and ver.read_text().strip() == IG_VERSION:
            return b
        self.bindir.mkdir(parents=True, exist_ok=True)
        machine = os.uname().machine
        arch = {"x86_64": "x86_64", "aarch64": "arm64"}.get(machine, "")
        if not arch:
            raise UserError(f"No immich-go build for CPU type {machine}.")
        base = IG_RELEASE.format(tag=IG_VERSION)
        tgz = f"immich-go_Linux_{arch}.tar.gz"
        with tempfile.TemporaryDirectory() as td:
            tdp = Path(td)
            _download(f"{base}/{tgz}", tdp / tgz)
            _download(f"{base}/checksums.txt", tdp / "checksums.txt")
            want = ""
            for ln in (tdp / "checksums.txt").read_text().splitlines():
                parts = ln.split()
                if len(parts) == 2 and parts[1] == tgz:
                    want = parts[0]
            if not want:
                raise UserError(f"{tgz} is not in release {IG_VERSION}.")
            got = hashlib.sha256((tdp / tgz).read_bytes()).hexdigest()
            if want != got:
                raise UserError("immich-go download failed its checksum — refusing to run it.")
            with tarfile.open(tdp / tgz) as tf:
                member = next((m for m in tf.getmembers() if m.name == "immich-go"), None)
                if member is None:
                    member = next((m for m in tf.getmembers() if m.name.endswith("/immich-go")), None)
                src = tf.extractfile(member) if member else None
                if src is None:
                    raise UserError("could not unpack immich-go")
                data = src.read()
        b.write_bytes(data)
        b.chmod(0o755)
        ver.write_text(IG_VERSION)
        return b

    def run(self, parts: list[str], server: str, key: str, admin: bool, log_path: Path,
            on_line=None, proc_sink: dict | None = None) -> int:
        args = [
            str(self.bin()), "upload", "from-google-photos",
            "--server", server, "--api-key", key,
            "--log-file", str(log_path), "--log-level", "INFO",
            "--on-errors", "continue", "--no-ui",
        ]
        # pausing background jobs needs an admin key; without one, say so plainly
        args += ["--admin-api-key", key] if admin else ["--pause-immich-jobs=false"]
        args += parts
        log_path = Path(log_path)
        log_path.parent.mkdir(parents=True, exist_ok=True)
        rc = -1
        with log_path.open("w") as logf:
            proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, errors="replace")
            if proc_sink is not None:
                proc_sink["proc"] = proc
            assert proc.stdout is not None
            for line in proc.stdout:
                logf.write(line)
                if on_line:
                    try:
                        on_line(line.rstrip())
                    except Exception:
                        pass
            rc = proc.wait()
        if proc_sink is not None:
            proc_sink.pop("proc", None)
        return rc


# ---------------------------------------------------------------------- spark


class Spark:
    def __init__(self, url: str, key: str, model: str, timeout: int = 180):
        self.url = url.rstrip("/")
        self.key = key
        self.model = model
        self.timeout = timeout

    def chat(self, messages: list[dict], tools: list[dict] | None = None) -> dict:
        body: dict = {"model": self.model, "messages": messages, "temperature": 0.2}
        if tools:
            body["tools"] = tools
            body["tool_choice"] = "auto"
        data = json.dumps(body).encode()
        last: Exception | None = None
        for attempt in range(3):
            try:
                r = urllib.request.Request(
                    self.url + "/chat/completions", data=data,
                    headers={"Authorization": f"Bearer {self.key}", "Content-Type": "application/json"},
                )
                with urllib.request.urlopen(r, timeout=self.timeout) as resp:
                    obj = json.loads(resp.read())
                return obj["choices"][0]["message"]
            except Exception as e:  # noqa: BLE001
                last = e
                time.sleep(2 * (attempt + 1))
        raise UserError(f"Could not reach the AI helper at {self.url} ({last}).")

    @staticmethod
    def configured(cfg: dict) -> bool:
        return bool(cfg.get("spark_key") and cfg.get("spark_url"))


TOOL_SPECS = [
    {"type": "function", "function": {"name": "server_status", "description": "Immich reachability, version, asset and album counts.", "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {"name": "bundle_status", "description": "Migration bundles and their states.", "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {"name": "log_tail", "description": "Recent lines of the most recent immich-go log.", "parameters": {"type": "object", "properties": {"lines": {"type": "integer"}, "grep": {"type": "string"}}}}},
    {"type": "function", "function": {"name": "read_file", "description": "Read the first lines of a text file on this machine.", "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "lines": {"type": "integer"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "run_command", "description": "Run a shell command (90s timeout). Prefer read-only; no sudo/reboot.", "parameters": {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}}},
    {"type": "function", "function": {"name": "immich_api", "description": "Call the Immich API: method GET/POST/PUT/DELETE, path like /assets, optional body.", "parameters": {"type": "object", "properties": {"method": {"type": "string"}, "path": {"type": "string"}, "body": {"type": "object"}}, "required": ["method", "path"]}}},
    {"type": "function", "function": {"name": "retry_bundle", "description": "Re-queue one failed takeout bundle.", "parameters": {"type": "object", "properties": {"key": {"type": "string"}}, "required": ["key"]}}},
]

TOOL_PROMPT = """You are the helper inside Pop's Migrator, importing the user's Google Photos
Takeout into Immich. The user is not technical: answer in short, plain
sentences, say what you found and what happens next. You have tools; check
facts with them before answering. Rules: prefer read-only checks; never
delete photos (on the server or the downloads) without saying so in your
reply first; if a bundle failed you may call retry_bundle ONCE, then report.
When you know enough, stop calling tools and write the answer."""


class Toolbox:
    def state_snapshot(self) -> dict:  # pragma: no cover - interface
        return {}

    def tool(self, name: str, args: dict) -> object:  # pragma: no cover - interface
        raise KeyError(name)

    def mark_auto(self) -> None:
        pass


class Assistant:
    """Spark-backed agent loop. `host` supplies the tool implementations."""

    def __init__(self, spark, host, keep: int = 12):
        self.spark = spark
        self.host = host
        self.keep = keep
        self.history: list[dict] = []
        self.busy = False

    def _system(self) -> str:
        return TOOL_PROMPT + "\n\nCurrent state:\n" + json.dumps(self.host.state_snapshot(), default=str)[:4000]

    def ask(self, user: str, on_note=None) -> str:
        if self.busy:
            return "One moment - I am still working on the previous question."
        self.busy = True
        try:
            msgs: list[dict] = [{"role": "system", "content": self._system()}]
            msgs += self.history[-self.keep:]
            msgs.append({"role": "user", "content": user})
            reply = ""
            for _round in range(6):
                msg = self.spark.chat(msgs, tools=TOOL_SPECS)
                calls = msg.get("tool_calls") or []
                reply = (msg.get("content") or "").strip()
                if not calls:
                    break
                msgs.append(msg)
                for tc in calls:
                    name = tc["function"]["name"]
                    try:
                        args = json.loads(tc["function"]["arguments"] or "{}")
                    except Exception:
                        args = {}
                    if on_note:
                        on_note(f"checked: {name}")
                    try:
                        result = self.host.tool(name, args)
                    except Exception as e:  # noqa: BLE001
                        result = f"error: {e}"
                    msgs.append({"role": "tool", "tool_call_id": tc.get("id", name), "content": str(result)[:4000]})
                reply = ""
            else:
                reply = reply or "I ran out of steps - ask me again for the specifics."
            if not reply:
                reply = "(no answer)"
            self.history.append({"role": "user", "content": user})
            self.history.append({"role": "assistant", "content": reply})
            return reply
        finally:
            self.busy = False

    def investigate(self, bundle_key: str, rc, on_note=None) -> str:
        self.host.mark_auto()
        return self.ask(
            f"The takeout part '{bundle_key}' just failed (exit code {rc}). Investigate the "
            "cause with your tools, fix what is safe, and retry it ONCE via retry_bundle if "
            "that looks right. Then tell me plainly what happened and what I should do next.",
            on_note=on_note,
        )


# --------------------------------------------------------------------- report


def build_report(state: dict) -> str:
    now = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M")
    ok = sum(1 for b in state["bundles"] if b["status"] == "ok")
    fail = [b for b in state["bundles"] if b["status"] in ("failed", "cancelled")]
    lines = [
        "# Migration report",
        "",
        f"Finished: {now}  |  Server: {state.get('server', '?')}",
        "",
        "## Result",
        "",
        f"- Bundles imported OK: **{ok}**",
        f"- Bundles with problems: **{len(fail)}**",
        f"- Assets on the server before: **{state.get('total_start', '?')}**"
        f"  after: **{state.get('total_end', '?')}**",
        "",
        "## Bundles",
        "",
        "| Takeout part | Assets (est.) | Result |",
        "|---|---|---|",
    ]
    for b in state["bundles"]:
        suffix = f" (exit {b['rc']})" if b.get("rc") not in (None, 0) else ""
        lines.append(f"| {b['label']} | {b['est']} | {b['status']}{suffix} |")
    if state.get("albums") is not None and state["albums"] >= 0:
        lines += ["", f"Albums on the server now: **{state['albums']}**"]
    if state.get("notes"):
        lines += ["", "## Notes", ""] + [f"- {n}" for n in state["notes"]]
    if fail:
        lines += ["", "## Things to look at", ""]
        for b in fail:
            lines.append(f"- {b['label']}: {b['status']} — log: {b.get('log', '')}")
    lines += [
        "",
        "## Next steps",
        "",
        "- Check a few dates and albums in Immich (the timeline is ordered by date taken).",
        "- Anything failed can be retried: run the migrator again, finished parts are skipped.",
        "- Ask the AI helper about any line above.",
        "",
        "_Report written by Pop's Migrator. Nothing was deleted without asking._",
    ]
    return "\n".join(lines)


# ----------------------------------------------------------------------- UI
try:
    from textual import work
    from textual.app import App, ComposeResult
    from textual.containers import Horizontal, Vertical, VerticalScroll
    from textual.screen import Screen
    from textual.widgets import Button, DataTable, Input, Label, Markdown, ProgressBar, RichLog, Static, Switch
except ImportError as e:  # pragma: no cover
    sys.exit(
        "The TUI needs the 'textual' package.\n"
        "Run me with:  uv run migrate.py     (recommended)\n"
        "or:           bash migrate.sh\n"
        f"(import error: {e})"
    )


class ChatPanel(Vertical):
    """Bottom panel: transcript + one-line input to the assistant."""

    def compose(self) -> ComposeResult:
        yield RichLog(id="chat-log", wrap=True, max_lines=300)
        with Horizontal(id="chat-bar"):
            yield Input(placeholder="Ask the AI helper about the migration...", id="chat-in")
            yield Button("Send", id="chat-send", variant="primary")

    def on_mount(self) -> None:
        self.query_one("#chat-log", RichLog).write("AI helper ready - ask anything, e.g. 'what failed?'")

    def note(self, text: str) -> None:
        self.query_one("#chat-log", RichLog).write(text)

    def reply(self, text: str) -> None:
        self.query_one("#chat-log", RichLog).write("AI: " + text)

    def busy(self, on: bool) -> None:
        try:
            self.query_one("#chat-in", Input).disabled = on
            btn = self.query_one("#chat-send", Button)
            btn.disabled = on
            btn.label = "..." if on else "Send"
        except Exception:
            pass

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "chat-send":
            self.send()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        if event.input.id == "chat-in":
            self.send()

    def send(self) -> None:
        inp = self.query_one("#chat-in", Input)
        text = inp.value.strip()
        if not text:
            return
        inp.value = ""
        app = self.app
        assert isinstance(app, MigrateApp)
        self.note("You: " + text)
        if not app.assistant:
            self.note("AI helper is not configured - add a key in Settings (press 's').")
            return
        self.busy(True)

        def work() -> None:
            try:
                answer = app.assistant.ask(text, on_note=lambda n: app.call_from_thread(self.note, "  " + n))
            except Exception as e:  # noqa: BLE001
                answer = f"(helper error: {e})"
            app.call_from_thread(self.busy, False)
            app.call_from_thread(self.reply, answer)

        threading.Thread(target=work, daemon=True).start()


def chat_panel() -> ChatPanel:
    return ChatPanel(id="chat")


class ConfirmScreen(Screen):
    def __init__(self, question: str) -> None:
        self.question = question
        super().__init__()

    def compose(self) -> ComposeResult:
        yield Vertical(
            Static(self.question, id="confirm-q"),
            Horizontal(Button("Yes", id="yes", variant="primary"), Button("No", id="no")),
            id="confirm-box",
        )

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "yes")


class ConnectScreen(Screen):  # type: ignore[misc]
    def compose(self) -> ComposeResult:
        app = self.app
        assert isinstance(app, MigrateApp)
        with Vertical(classes="root"):
            yield Static("Pop's Migrator - Google Photos Takeout into Immich", id="title")
            yield Static("Immich server address (like http://192.168.1.10:2283; leave blank to auto-find)")
            yield Input(value=app.cfg.get("server", ""), placeholder="http://...", id="server")
            yield Static("Immich API key  (Immich > your picture, top right > My Account > API Keys > New Key)")
            yield Input(value=app.cfg.get("key", ""), password=True, id="key")
            yield Static("Folder with the downloaded Takeout zips (blank = search the usual places)")
            yield Input(value=app.cfg.get("last_path", ""), placeholder="/mnt/user/downloads", id="cpath")
            with Horizontal(classes="btnrow"):
                yield Button("Connect and scan", id="connect", variant="success")
                yield Button("Settings", id="settings")
            yield Static("TAB = next box  ·  ENTER = connect", classes="dim", id="hint")
            yield Static("", id="status")

    def on_mount(self) -> None:
        self.query_one("#server", Input).focus()

    def _keep_focus(self) -> None:
        # Clicking blank space clears focus in some terminals; put it back.
        if self.focused is None:
            try:
                self.query_one("#server", Input).focus()
            except Exception:
                pass

    def on_click(self) -> None:
        self._keep_focus()

    def on_screen_resume(self) -> None:
        self._keep_focus()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        order = ["#server", "#key", "#cpath"]
        try:
            idx = order.index(f"#{event.input.id}")
        except ValueError:
            return
        if idx + 1 < len(order):
            self.query_one(order[idx + 1], Input).focus()
        else:
            self.query_one("#connect", Button).press()

    def set_status(self, text: str) -> None:
        try:
            self.query_one("#status", Static).update(text)
        except Exception:
            pass

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "settings":
            self.app.push_screen(SettingsScreen())
        elif event.button.id == "connect":
            self.set_status("Checking...")
            app = self.app
            assert isinstance(app, MigrateApp)
            app.start_connect(
                server=self.query_one("#server", Input).value.strip(),
                key=self.query_one("#key", Input).value.strip(),
                path=self.query_one("#cpath", Input).value.strip(),
            )


class SettingsScreen(Screen):  # type: ignore[misc]
    def compose(self) -> ComposeResult:
        app = self.app
        assert isinstance(app, MigrateApp)
        with Vertical(classes="root"):
            yield Static("AI helper (Spark) - answers questions and investigates failures")
            yield Static("Server URL")
            yield Input(value=app.cfg.get("spark_url", ""), id="sp-url")
            yield Static("API key")
            yield Input(value=app.cfg.get("spark_key", ""), password=True, id="sp-key")
            yield Static("Model")
            yield Input(value=app.cfg.get("spark_model", ""), id="sp-model")
            yield Static("(Leave the key blank to run without the AI helper.)", classes="dim")
            with Horizontal(classes="btnrow"):
                yield Button("Test", id="sp-test")
                yield Button("Save", id="save", variant="primary")
                yield Button("Back", id="back")
            yield Static("", id="sp-status")

    def read_inputs(self) -> None:
        app = self.app
        assert isinstance(app, MigrateApp)
        app.cfg["spark_url"] = self.query_one("#sp-url", Input).value.strip()
        app.cfg["spark_key"] = self.query_one("#sp-key", Input).value.strip()
        app.cfg["spark_model"] = self.query_one("#sp-model", Input).value.strip() or "spark-prod"

    def _keep_focus(self) -> None:
        if self.focused is None:
            try:
                self.query_one("#sp-url", Input).focus()
            except Exception:
                pass

    def on_click(self) -> None:
        self._keep_focus()

    def on_screen_resume(self) -> None:
        self._keep_focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        app = self.app
        assert isinstance(app, MigrateApp)
        self.read_inputs()
        if event.button.id == "sp-test":
            self.query_one("#sp-status", Static).update("Testing...")
            app.test_spark()
        elif event.button.id == "save":
            app.save_cfg()
            app.reconnect_assistant()
            app.pop_screen()
        elif event.button.id == "back":
            app.pop_screen()


class ReviewScreen(Screen):  # type: ignore[misc]
    def compose(self) -> ComposeResult:
        app = self.app
        assert isinstance(app, MigrateApp)
        with Vertical(classes="root"):
            yield Static("Ready to import", id="review-title")
            yield Static("", id="review-summary")
            table = DataTable(id="bundles")
            table.cursor_type = "none"
            table.add_columns("Takeout part", "Assets (est.)", "Size", "Status")
            yield table
            with Horizontal(classes="opts"):
                yield Label("Retry finished parts")
                yield Switch(value=app.force, id="opt-force")
                yield Label("Let AI fix failures")
                yield Switch(value=bool(app.cfg.get("auto_fix", True)), id="auto-fix")
                yield Label("Delete downloads after (asks again)")
                yield Switch(value=bool(app.cfg.get("delete_downloads", False)), id="del-after")
            with Horizontal(classes="btnrow"):
                yield Button("Start import", id="start", variant="success")
                yield Button("Back", id="back")
            yield chat_panel()

    def on_mount(self) -> None:
        self.refresh_table()

    def visible_bundles(self) -> list:
        app = self.app
        assert isinstance(app, MigrateApp)
        return [b for b in app.bundles if b.status != "skipped" or app.force]

    def refresh_table(self) -> None:
        table = self.query_one("#bundles", DataTable)
        table.clear()
        for b in self.visible_bundles():
            table.add_row(b.label, str(b.est_assets) if b.est_assets else "?",
                          f"{b.zip_bytes // 1024 // 1024} MB", b.status)
        assets = sum(b.est_assets for b in self.visible_bundles())
        size = sum(b.zip_bytes for b in self.visible_bundles()) // 1024 // 1024
        note = ""
        app = self.app
        assert isinstance(app, MigrateApp)
        if getattr(app, "wiped_server", False):
            note = "  The server looks empty although earlier runs are recorded - importing everything again."
        self.query_one("#review-summary", Static).update(
            f"{len(self.visible_bundles())} takeout part(s): about {assets} photos/videos, {size} MB.{note}")

    def on_switch_changed(self, event) -> None:  # noqa: ANN001
        app = self.app
        assert isinstance(app, MigrateApp)
        app.force = self.query_one("#opt-force", Switch).value
        app.cfg["auto_fix"] = self.query_one("#auto-fix", Switch).value
        app.cfg["delete_downloads"] = self.query_one("#del-after", Switch).value
        self.refresh_table()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        app = self.app
        assert isinstance(app, MigrateApp)
        if event.button.id == "back":
            app.pop_screen()
        elif event.button.id == "start":
            self.on_switch_changed(event)
            app.start_run()


class RunScreen(Screen):  # type: ignore[misc]
    def compose(self) -> ComposeResult:
        with Vertical(classes="root"):
            yield Static("Importing... (re-running later skips finished parts)", id="run-title")
            yield ProgressBar(total=100, show_eta=False, id="prog")
            yield Static("", id="run-line")
            with VerticalScroll(id="states-wrap"):
                yield Static("", id="bundle-states")
            with Horizontal(classes="btnrow"):
                yield Button("Cancel import", id="cancel")
                yield Button("Hide chat", id="chat-toggle")
            yield chat_panel()

    def refresh_states(self) -> None:
        app = self.app
        assert isinstance(app, MigrateApp)
        self.query_one("#bundle-states", Static).update(
            "\n".join(f"{b.status:>9}  {b.label}" for b in app.bundles))

    def set_line(self, text: str) -> None:
        try:
            self.query_one("#run-line", Static).update(text[:200])
        except Exception:
            pass

    def on_button_pressed(self, event: Button.Pressed) -> None:
        app = self.app
        assert isinstance(app, MigrateApp)
        if event.button.id == "cancel":
            app.push_screen(ConfirmScreen("Stop the import? Finished parts are kept; the rest waits for the next run."),
                            lambda ok: app.cancel_run() if ok else None)
        elif event.button.id == "chat-toggle":
            app.chat_toggle()


class ReportScreen(Screen):  # type: ignore[misc]
    def __init__(self, md: str, path: str) -> None:
        self.md = md
        self.path = path
        super().__init__()

    def compose(self) -> ComposeResult:
        with Vertical(classes="root"):
            yield Static("Done - report", id="rep-title")
            with VerticalScroll():
                yield Markdown(self.md, id="rep-md")
            yield Static(f"Saved to: {self.path}", id="rep-path")
            with Horizontal(classes="btnrow"):
                yield Button("Close", id="close", variant="primary")
            yield chat_panel()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "close":
            self.app.exit()


class MigrateApp(App):  # type: ignore[misc]
    TITLE = "Pop's Migrator"
    CSS = """
    .root { width: 1fr; height: 1fr; padding: 1 2; }
    #title, #review-title, #run-title, #rep-title { text-style: bold; margin-bottom: 1; }
    .btnrow { height: auto; margin-top: 1; }
    .btnrow Button { margin-right: 2; }
    .opts { height: auto; margin-top: 1; }
    .opts Label { margin: 0 2 0 0; width: auto; }
    .opts Switch { margin-right: 3; }
    #bundles { height: 1fr; }
    #states-wrap { height: 1fr; }
    #chat { height: 12; border-top: solid $accent; padding: 0 1; }
    #chat-bar { height: 3; }
    #chat-bar Input { width: 1fr; }
    #confirm-box { width: 70; height: auto; border: solid $accent; padding: 1 2; background: $surface;
                   margin: 1 4; }
    #run-line { height: 1; }
    .dim { text-style: dim; }
    """
    BINDINGS = [("ctrl+q", "quit", "Quit"), ("s", "settings", "Settings")]

    def __init__(self, cfg: dict | None = None) -> None:
        super().__init__()
        self.cfg = cfg if cfg is not None else load_config()
        self.bundles: list = []
        self.force = False
        self.wiped_server = False
        self.workdir = Path("/tmp") / "migrate-work"
        self.runner = None
        self.immich = None
        self.assistant = None
        self.admin = False
        self.cancel = False
        self.total_start = -1
        self.total_end = -1
        self._prog_done = 0
        self.run_notes: list[str] = []
        self._proc_sink: dict = {}

    def on_mount(self) -> None:
        self.push_screen(ConnectScreen())

    # -- chat helpers -----------------------------------------------------

    def chat(self) -> ChatPanel | None:
        try:
            return self.screen.query_one("#chat", ChatPanel)
        except Exception:
            return None

    def chat_note(self, text: str) -> None:
        c = self.chat()
        if c:
            c.note(text)

    def chat_reply(self, text: str) -> None:
        c = self.chat()
        if c:
            c.reply(text)

    def chat_toggle(self) -> None:
        try:
            panel = self.screen.query_one("#chat", ChatPanel)
            panel.display = not panel.display
        except Exception:
            pass

    def action_settings(self) -> None:
        if not isinstance(self.screen, SettingsScreen) and not isinstance(self.screen, ConfirmScreen):
            self.push_screen(SettingsScreen())

    def save_cfg(self) -> None:
        save_config(self.cfg)

    def reconnect_assistant(self) -> None:
        spark = self._make_spark()
        self.assistant = Assistant(spark, HostAdapter(self)) if spark else None
        self.chat_note("AI helper " + ("connected." if spark else "disabled (no key)."))

    def _make_spark(self):
        if not Spark.configured(self.cfg):
            return None
        return Spark(self.cfg["spark_url"], self.cfg["spark_key"], self.cfg.get("spark_model", "spark-prod"))

    # -- connect ----------------------------------------------------------

    @work(thread=True, group="connect", exclusive=True)
    def start_connect(self, server: str, key: str, path: str) -> None:
        def status(t: str) -> None:
            self.call_from_thread(self._connect_status, t)

        try:
            if not server:
                status("Looking for Immich on this box ...")
                found = Immich.detect_local()
                if not found:
                    raise UserError("Could not find Immich here - type its address, e.g. http://192.168.1.10:2283")
                server = found
                self.call_from_thread(self._prefill_server, server)
            status(f"Checking {server} ...")
            imm = Immich(server, key)
            if not imm.ping():
                raise UserError(f"Nothing that looks like Immich answered at {server} - start it, then try again.")
            me = imm.me()
            total = imm.total_assets()
            admin = bool(me.get("isAdmin")) if isinstance(me, dict) else False
            status("Scanning for takeouts ...")
            bundles = build_bundles(path or None, force=False)
            if not bundles:
                raise UserError("No Google Photos takeout found there or in the usual places. "
                                "Put the downloaded zip file(s) in a folder and try again.")
            if path:
                workdir = Path(path).expanduser().resolve() / WORK_DIR_NAME
            else:
                first = next((b for b in bundles if b.status != "skipped"), bundles[0])
                workdir = Path(first.parts[0].split(":", 1)[1]).expanduser().resolve().parent / WORK_DIR_NAME
            disk_note = check_disk(bundles, workdir.parent)
            wiped = bool(done_keys()) and total == 0
            self.call_from_thread(self._connect_done, server, key, bundles, admin, total, wiped, str(workdir), disk_note)
        except UserError as e:
            status(f"Problem: {e}")
        except Exception as e:  # noqa: BLE001
            status(f"Unexpected problem: {e}")

    def _connect_status(self, t: str) -> None:
        scr = self.screen
        if isinstance(scr, ConnectScreen):
            scr.set_status(t)

    def _prefill_server(self, url: str) -> None:
        scr = self.screen
        if isinstance(scr, ConnectScreen):
            scr.query_one("#server", Input).value = url

    def _connect_done(self, server, key, bundles, admin, total, wiped, workdir, disk_note) -> None:
        self.cfg["server"], self.cfg["key"] = server, key
        self.save_cfg()
        self.immich = Immich(server, key)
        self.bundles = bundles
        self.admin = admin
        self.total_start = total
        self.force = wiped
        self.wiped_server = wiped
        self.workdir = Path(workdir)
        self.runner = Runner(Path(os.environ.get("MIGRATE_BIN", str(APP_DIR / "bin"))))
        spark = self._make_spark()
        self.assistant = Assistant(spark, HostAdapter(self)) if spark else None
        self.push_screen(ReviewScreen())
        if disk_note:
            self.notify(disk_note, timeout=8)

    @work(thread=True, group="sparktest", exclusive=True)
    def test_spark(self) -> None:
        self._read_settings()
        try:
            sp = self._make_spark()
            out = "No key set - the AI helper stays off." if not sp else None
            if sp:
                msg = sp.chat([{"role": "user", "content": "Reply with the single word: ready"}])
                out = "AI helper OK: " + (msg.get("content") or "").strip()[:60]
        except Exception as e:  # noqa: BLE001
            out = f"AI helper problem: {e}"
        self.call_from_thread(self._sparktest_done, out or "?")

    def _read_settings(self) -> None:
        scr = self.screen
        if isinstance(scr, SettingsScreen):
            scr.read_inputs()
            self.save_cfg()

    def _sparktest_done(self, out: str) -> None:
        scr = self.screen
        if isinstance(scr, SettingsScreen):
            try:
                scr.query_one("#sp-status", Static).update(out)
            except Exception:
                pass

    # -- run --------------------------------------------------------------

    @work(thread=True, group="run", exclusive=True)
    def start_run(self) -> None:
        assert self.runner is not None and self.immich is not None
        runner, imm = self.runner, self.immich
        self.cancel = False
        self._prog_done = 0
        self.run_notes = []
        self.call_from_thread(self._push_run_screen)
        logdir = self.workdir / "logs"
        try:
            self.run_notes += prepare_bundles([b for b in self.bundles if b.status == "pending"], self.workdir)
        except Exception as e:  # noqa: BLE001
            self.call_from_thread(self._finish_run, f"Could not prepare the archives: {e}")
            return
        est = max(1, sum(b.est_assets for b in self.bundles if b.status == "pending"))
        self.call_from_thread(self._set_prog_total, est)
        last_total = self.total_start

        for b in self.bundles:
            if b.status != "pending":
                continue
            if self.cancel:
                b.status = "cancelled"
                self.call_from_thread(self._refresh_run)
                continue
            b.status = "running"
            b.log = str(self.workdir / "logs" / (re.sub(r"[^a-z0-9.-]+", "-", b.key) + ".log"))
            self.call_from_thread(self._refresh_run)
            self.call_from_thread(self.chat_note, f"Importing {b.label} ...")
            sink: dict = {}
            self._proc_sink = sink

            def on_line(line: str) -> None:
                self.call_from_thread(self._run_line, line)

            try:
                rc = runner.run(b.paths(), self.cfg["server"], self.cfg["key"], self.admin,
                                Path(b.log), on_line=on_line, proc_sink=sink)
            except UserError as e:
                self.call_from_thread(self.chat_note, str(e))
                rc = -1
            except Exception as e:  # noqa: BLE001
                self.call_from_thread(self.chat_note, f"Importer crashed: {e}")
                rc = -1
            b.rc = rc
            if self.cancel:
                b.status = "cancelled"
            elif rc == 0:
                b.status = "ok"
                record_done(b.key)
            else:
                b.status = "failed"
            self.call_from_thread(self._refresh_run)
            self._proc_sink = {}

            try:
                total = imm.total_assets()
                if 0 <= last_total < 0 or total > last_total:
                    pass
                if total >= 0 and self.total_start >= 0 and total > last_total:
                    self.call_from_thread(self._advance_prog, total - self.total_start)
                    last_total = total
            except Exception:
                pass

            if b.status == "failed" and self.cfg.get("auto_fix") and self.assistant and not self.cancel:
                def a_note(n: str) -> None:
                    self.call_from_thread(self.chat_note, "  " + n)

                try:
                    reply = self.assistant.investigate(b.key, rc, on_note=a_note)
                    self.call_from_thread(self.chat_reply, "AI (auto-check): " + reply)
                except Exception as e:  # noqa: BLE001
                    self.call_from_thread(self.chat_note, f"(auto-fix unavailable: {e})")

        try:
            self.total_end = imm.total_assets()
        except Exception:
            self.total_end = -1
        self.call_from_thread(self._finish_run, None)

    def _push_run_screen(self) -> None:
        try:
            self.pop_screen()
        except Exception:
            pass
        self.push_screen(RunScreen())

    def _refresh_run(self) -> None:
        scr = self.screen
        if isinstance(scr, RunScreen):
            scr.refresh_states()

    def _run_line(self, line: str) -> None:
        scr = self.screen
        if isinstance(scr, RunScreen):
            scr.set_line(line)
        low = line.lower()
        if any(w in low for w in ("error", "fail", "warn", "duplicate", "skip")):
            self.chat_note("  " + line[:180])

    def _set_prog_total(self, est: int) -> None:
        scr = self.screen
        if isinstance(scr, RunScreen):
            scr.query_one("#prog", ProgressBar).update(total=max(est, 1))

    def _advance_prog(self, done_abs: int) -> None:
        scr = self.screen
        if isinstance(scr, RunScreen):
            bar = scr.query_one("#prog", ProgressBar)
            delta = max(0, done_abs - self._prog_done)
            self._prog_done = done_abs
            bar.advance(delta)

    def cancel_run(self) -> None:
        self.cancel = True
        proc = self._proc_sink.get("proc")
        if proc is not None:
            try:
                proc.terminate()
            except Exception:
                pass
        self.chat_note("Stopping - this file finishes; the rest waits for the next run.")

    def _finish_run(self, error: str | None) -> None:
        if error:
            self.chat_note("Problem: " + error)
        state = self.report_state()
        md = build_report(state)
        out = Path.home() / f"immich-migration-{datetime.now().strftime('%Y%m%d-%H%M%S')}.md"
        try:
            out.write_text(md)
        except OSError:
            out = Path("/tmp") / out.name
            out.write_text(md)
        try:
            self.pop_screen()
        except Exception:
            pass
        self.push_screen(ReportScreen(md, str(out)))

    def report_state(self) -> dict:
        return {
            "server": self.cfg.get("server"),
            "bundles": [{"label": b.label, "status": b.status, "rc": b.rc,
                         "est": b.est_assets, "log": b.log} for b in self.bundles],
            "total_start": self.total_start,
            "total_end": self.total_end,
            "albums": self.immich.album_count() if self.immich else -1,
            "notes": self.run_notes,
        }


class HostAdapter:
    """Exposes app state/actions to the assistant as tools."""

    def __init__(self, app: MigrateApp) -> None:
        self.app = app

    def mark_auto(self) -> None:
        pass

    def state_snapshot(self) -> dict:
        a = self.app
        return {
            "phase": "running" if a._proc_sink else "idle",
            "server": a.cfg.get("server"),
            "admin": a.admin,
            "assets_on_server": a.immich.total_assets() if a.immich else None,
            "assets_at_start": a.total_start,
            "bundles": [{"key": b.key, "label": b.label, "status": b.status, "rc": b.rc} for b in a.bundles],
            "workdir": str(a.workdir),
        }

    def tool(self, name: str, args: dict) -> object:
        a = self.app
        if name == "server_status":
            if a.immich is None:
                return "not connected"
            try:
                return {"ping": a.immich.ping(), "version": a.immich.about().get("version", "?"),
                        "assets": a.immich.total_assets(), "albums": a.immich.album_count()}
            except UserError as e:
                return str(e)
        if name == "bundle_status":
            return [{"key": b.key, "label": b.label, "status": b.status, "rc": b.rc} for b in a.bundles]
        if name == "log_tail":
            logs = [Path(b.log) for b in a.bundles if b.log]
            if not logs:
                return "no logs yet"
            path = max(logs, key=lambda p: p.stat().st_mtime if p.exists() else 0)
            try:
                lines = path.read_text(errors="replace").splitlines()
            except OSError:
                return "log unreadable"
            n = int(args.get("lines", 40) or 40)
            grep = args.get("grep")
            if grep:
                rx = re.compile(str(grep), re.I)
                lines = [ln for ln in lines if rx.search(ln)]
            return "\n".join(lines[-n:]) or "(empty)"
        if name == "read_file":
            p = Path(str(args.get("path", "")))
            try:
                n = int(args.get("lines", 60) or 60)
                return "\n".join(p.read_text(errors="replace").splitlines()[:n]) or "(empty)"
            except OSError as e:
                return f"cannot read {p}: {e}"
        if name == "run_command":
            cmd = str(args.get("command", "")).strip()
            if not cmd:
                return "empty command"
            if re.search(r"\bsudo\b|\breboot\b|\bshutdown\b|\bmkfs\b|>\s*/dev/sd", cmd):
                return "plain user commands only (no sudo/reboot/mkfs)"
            try:
                out = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=90,
                                     cwd=str(a.workdir) if a.workdir.exists() else None)
                return f"rc={out.returncode}\n{(out.stdout + out.stderr)[-6000:]}"
            except subprocess.TimeoutExpired:
                return "timeout after 90s"
            except OSError as e:
                return f"error: {e}"
        if name == "immich_api":
            if a.immich is None:
                return "not connected"
            code, obj = a.immich.req(str(args.get("method", "GET")).upper(), str(args.get("path", "/api")),
                                     args.get("body") or None)
            return json.dumps({"status": code, "body": obj}, default=str)[:4000]
        if name == "retry_bundle":
            key = str(args.get("key", ""))
            for b in a.bundles:
                if b.key == key and b.status in ("failed", "cancelled"):
                    b.status = "pending"
                    b.rc = None
                    return f"requeued {b.label}; the importer picks it up on its next pass"
            return f"no failed bundle keyed '{key}' (see bundle_status)"
        raise KeyError(name)


def headless_scan(path: str | None) -> int:
    bundles = build_bundles(path, force=False)
    for b in bundles:
        print(json.dumps({"key": b.key, "label": b.label, "parts": len(b.parts),
                          "est_assets": b.est_assets, "zip_bytes": b.zip_bytes, "status": b.status}))
    print(f"bundles={len(bundles)} skipped={sum(1 for b in bundles if b.status == 'skipped')}", file=sys.stderr)
    return 0


def main(argv: list[str]) -> int:
    if len(argv) > 1 and argv[1] in ("--version", "version"):
        print(f"Pop's Migrator {VERSION} (immich-go {IG_VERSION})")
        return 0
    if len(argv) > 1 and argv[1] == "scan":
        return headless_scan(argv[2] if len(argv) > 2 else None)
    MigrateApp(cfg=load_config()).run()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
