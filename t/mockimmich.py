#!/usr/bin/env python3
"""Mock Immich API sufficient for immich-go upload from-google-photos."""
import http.server, json, sys, os, re, threading

STATE = {"uploads": 0, "albums": 0, "paths": [], "assets": []}
LOCK = threading.Lock()

def dto_assets_empty():
    return {"assets": {"total": 0, "count": 0, "items": [], "nextPage": "0"}}

def asset_items():
    return [dict(a) for a in STATE["assets"]]

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _j(self, o, code=200):
        b = json.dumps(o, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _body(self):
        if "chunked" in (self.headers.get("transfer-encoding", "").lower()):
            data = b""
            while True:
                line = self.rfile.readline().strip()
                try: n = int(line.split(b";")[0], 16)
                except ValueError: break
                if n == 0:
                    self.rfile.readline()   # trailing CRLF
                    break
                data += self.rfile.read(n)
                self.rfile.readline()       # CRLF after chunk
            return data
        ln = int(self.headers.get("content-length", 0) or 0)
        return self.rfile.read(ln) if ln else b""

    def do_GET(self):
        p = self.path.split("?")[0]
        if p == "/__stats":
            with LOCK:
                snap = {k: v for k, v in STATE.items()}
            return self._j(snap)
        if p == "/":
            b = b"<html><title>Immich</title></html>"
            self.send_response(200); self.send_header("Content-Type","text/html")
            self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
            return
        if p == "/api/server/ping":
            return self._j({"res": "pong", "version": "v1.137.0", "ready": True})
        if p == "/api/server/about":
            return self._j({"version": "v1.137.0", "versionNumeric": {"major": 1, "minor": 137, "patch": 0},
                            "edition": "ORIGINAL", "build": "x"})
        if p == "/api/server/media-types":
            return self._j({"image": [".jpg",".jpeg",".png",".heic",".webp",".gif",".tiff",".bmp",".dng",".cr2",".nef",".arw"],
                            "video": [".mp4",".mov",".avi",".mkv",".mts",".m2ts",".3gp",".wmv",".webm",".m4v",".insv"]})
        if p == "/api/users/me":
            if self.headers.get("x-api-key") != os.environ.get("MOCK_KEY", "test"):
                return self._j({"message": "Invalid key", "statusCode": 401, "error": "Unauthorized"}, 401)
            return self._j({"id": "u1", "email": "dad@example.com", "firstName": "Dad", "lastName": "X",
                            "isAdmin": True, "quotaUsageInBytes": 0, "quotaSizeInBytes": 10**13})
        if p == "/api/assets/statistics":
            with LOCK: n = len(STATE["assets"])
            return self._j({"images": n, "videos": 0, "total": n})
        if p == "/api/people":
            return self._j({"people": [], "total": 0, "hidden": 0})
        if p == "/api/tags":
            return self._j([])
        if p.startswith("/api/albums"):
            return self._j([])
        if p == "/api/jobs":
            return self._j([])
        return self._j([])

    def do_POST(self):
        p = self.path.split("?")[0]
        body = self._body()
        if p == "/api/search/metadata":
            try: q = json.loads(body or b"{}")
            except Exception: q = {}
            with LOCK: items = asset_items()
            cs = q.get("checksum")
            if cs:
                items = [a for a in items if a.get("checksum") == cs]
            if q.get("isNotInAlbum"):
                items = []
            # immich paginates; immich-go asks with "page"/"size" and reads nextPage (string)
            return self._j({"assets": {"total": len(items), "count": len(items),
                                       "items": items, "nextPage": "0"}})
        if p == "/api/albums":
            with LOCK: STATE["albums"] += 1
            name = ""
            try: name = json.loads(body).get("albumName", "")
            except Exception: pass
            return self._j({"id": f"alb{STATE['albums']}", "albumName": name, "assets": []})
        if re.match(r"^/api/albums/[^/]+/assets$", p):
            return self._j({"count": 1, "ignored": 0})
        if p == "/api/assets":
            with LOCK:
                STATE["uploads"] += 1
                n = STATE["uploads"]
                cs = self.headers.get("x-immich-checksum", "")
                STATE["assets"].append({"id": f"asset-{n}", "checksum": cs, "type": "image",
                                        "ownerId": "u1", "isTrashed": False, "isArchived": False,
                                        "status": "active", "libraryId": None,
                                        "originalFileName": f"uploaded-{n}.jpg",
                                        "deviceAssetId": f"dev{n}", "deviceId": "import",
                                        "exifInfo": {"fileSizeInByte": 5004, "dateTimeOriginal": "2020-01-01T00:00:00.000Z"}})
                STATE["paths"].append(cs)
            return self._j({"id": f"asset-{n}", "duplicate": False, "originalPath": f"/data/{n}.jpg"})
        if p == "/api/tags":
            # real Immich answers 201 with the created tags; immich-go indexes [0]
            try: names = json.loads(body)
            except Exception: names = []
            out = [{"id": f"tag{i}", "name": nme, "value": nme} for i, nme in enumerate(names if isinstance(names, list) else [])]
            return self._j(out if out else [{"id": "tag0", "name": "x", "value": "x"}])
        return self._j({})

    def do_PUT(self):
        p = self.path.split("?")[0]
        body = self._body()
        if p == "/api/tags":
            try: names = json.loads(body or b"[]")
            except Exception: names = []
            out = [{"id": f"tag{i}", "name": nme, "value": nme} for i, nme in enumerate(names if isinstance(names, list) else [])]
            return self._j(out if out else [{"id": "tag0", "name": "x", "value": "x"}])
        if p.startswith("/api/tags/") or p.startswith("/api/jobs"):
            return self._j({})
        return self._j({})

    def do_DELETE(self):
        self._body()
        return self._j({})

    def log_message(self, *a):
        pass

class Stats(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/__stats":
            with LOCK: snap = json.dumps(STATE)
            b = snap.encode()
            self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
        else:
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a): pass

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9123
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), H)
    srv.serve_forever()
