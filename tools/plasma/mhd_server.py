#!/usr/bin/env python3
"""
mhd_server.py — HTTP server for RAIL PLASMA live GPU streaming.

Serves:
  /                    → thruster_engine.html (or any static file)
  /frame               → latest GPU frame (binary, ~100KB)
  /control  (POST)     → write control JSON to /tmp/plasma_ctrl.json
  /live                → thruster_live.html (GPU-connected client)
  /verify              → verify.html (byte-exact chamber audit page)
  /attest              → JSON attestation for the latest frame: snapshot
                         the planes, render the chamber with the native
                         chamber_cli, publish sha256 of both
  /attest/planes32.bin?fid=N  → the attested planes bytes (393216 B)
  /attest/chamber.bin?fid=N   → the attested chamber render (49152 B)

The Metal host (mhd_live) writes frames to /tmp/plasma_live.bin.
This server reads that file and serves it to any connected browser.

Usage:
  python3 mhd_server.py                    # port 9200
  python3 mhd_server.py 9300               # custom port
"""

import hashlib
import http.server
import json
import os
import struct
import subprocess
import sys
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9200
FRAME_PATH = "/tmp/plasma_live.bin"
CTRL_PATH = "/tmp/plasma_ctrl.json"
STATIC_DIR = os.path.dirname(os.path.abspath(__file__))

# ── attest path (byte-exact chamber audit) ──────────────────────────
ATTEST_DIR = "/tmp/plasma_attest"
CHAMBER_CLI = os.path.join(STATIC_DIR, "chamber_cli")
WASM_PATH = os.path.join(STATIC_DIR, "chamber_verify.wasm")
PLANES_OFF = 48          # header 16 B + metrics 32 B
PLANES_LEN = 6 * 128 * 128 * 4   # 393216 — f32 LE, plane-major
CHAMBER_LEN = 128 * 128 * 3      # 49152 — RGB8

# Cache the last frame to avoid re-reading unchanged files
_frame_cache = (0, b"")  # (mtime, data)

# Last attestation: {frame_id: response_dict}.  One entry only — the
# byte files for that frame_id live in ATTEST_DIR.
_attest_cache = {}


def read_frame():
    global _frame_cache
    try:
        st = os.stat(FRAME_PATH)
        if st.st_mtime == _frame_cache[0]:
            return _frame_cache[1]
        with open(FRAME_PATH, "rb") as f:
            data = f.read()
        _frame_cache = (st.st_mtime, data)
        return data
    except FileNotFoundError:
        return b""


def make_attest():
    """Snapshot the live frame, render it with the native CLI, hash both.

    Returns (http_status, response_dict).  Idempotent per frame_id: the
    same frame_id always maps to the same planes bytes (they were
    snapshotted once), so the hashes are stable across repeated calls.
    """
    global _attest_cache
    data = read_frame()
    if len(data) < PLANES_OFF + PLANES_LEN:
        return 503, {"error": "no live frame (mhd_live not writing?)",
                     "have_bytes": len(data)}
    n1, n2, nfields, frame_id = struct.unpack_from("<4I", data, 0)
    if n1 != 128 or n2 != 128 or nfields != 6:
        return 503, {"error": f"unexpected frame header {n1}x{n2}x{nfields}"}
    if frame_id in _attest_cache:
        return 200, _attest_cache[frame_id]

    metrics = struct.unpack_from("<8f", data, 16)
    sim_time = metrics[5]
    planes = data[PLANES_OFF:PLANES_OFF + PLANES_LEN]

    os.makedirs(ATTEST_DIR, exist_ok=True)
    planes_path = os.path.join(ATTEST_DIR, f"planes32_{frame_id}.bin")
    chamber_path = os.path.join(ATTEST_DIR, f"chamber_{frame_id}.bin")
    with open(planes_path, "wb") as f:
        f.write(planes)

    try:
        r = subprocess.run([CHAMBER_CLI, planes_path, chamber_path],
                           capture_output=True, timeout=15)
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        return 500, {"error": f"chamber_cli failed: {e}"}
    if r.returncode != 0:
        return 500, {"error": "chamber_cli nonzero exit",
                     "stdout": r.stdout.decode(errors="replace")[:200]}
    with open(chamber_path, "rb") as f:
        chamber = f.read()
    if len(chamber) != CHAMBER_LEN:
        return 500, {"error": f"chamber render is {len(chamber)} B, want {CHAMBER_LEN}"}

    try:
        with open(WASM_PATH, "rb") as f:
            wasm_sha = hashlib.sha256(f.read()).hexdigest()
    except FileNotFoundError:
        wasm_sha = None

    resp = {
        "frame_id": frame_id,
        "sim_time": round(sim_time, 6),
        "planes_sha256": hashlib.sha256(planes).hexdigest(),
        "chamber_sha256": hashlib.sha256(chamber).hexdigest(),
        "n_bytes": CHAMBER_LEN,
        "planes_bytes": PLANES_LEN,
        "planes_url": f"/attest/planes32.bin?fid={frame_id}",
        "chamber_url": f"/attest/chamber.bin?fid={frame_id}",
        "wasm_url": "/chamber_verify.wasm",
        "wasm_sha256": wasm_sha,
        "widen_rule": "each f32 (LE, plane-major rho,vx,vy,p,Bx,By) widened to f64 — exact",
        "narrow_rule": "clamp [0.0, 255.0], truncate toward zero",
    }

    # Evict the previous attestation's byte files (keep /tmp tidy).
    for old_fid in list(_attest_cache):
        if old_fid != frame_id:
            for stem in (f"planes32_{old_fid}.bin", f"chamber_{old_fid}.bin"):
                try:
                    os.remove(os.path.join(ATTEST_DIR, stem))
                except FileNotFoundError:
                    pass
    _attest_cache = {frame_id: resp}
    return 200, resp


class PlasmaHandler(http.server.SimpleHTTPRequestHandler):
    # .wasm must arrive as application/wasm or the browser refuses
    # WebAssembly.instantiateStreaming.
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
    }

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=STATIC_DIR, **kwargs)

    def send_bytes(self, status, body, ctype):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.end_headers()
        self.wfile.write(body)

    def serve_attest_file(self, stem):
        # /attest/<stem>.bin?fid=N → the snapshotted bytes for frame N.
        query = self.path.split("?", 1)[1] if "?" in self.path else ""
        fid = None
        for part in query.split("&"):
            if part.startswith("fid="):
                fid = part[4:]
        if fid is None or not fid.isdigit():
            self.send_bytes(400, b'{"error": "missing ?fid="}', "application/json")
            return
        path = os.path.join(ATTEST_DIR, f"{stem}_{int(fid)}.bin")
        try:
            with open(path, "rb") as f:
                body = f.read()
        except FileNotFoundError:
            self.send_bytes(404, b'{"error": "attestation expired; re-fetch /attest"}',
                            "application/json")
            return
        self.send_bytes(200, body, "application/octet-stream")

    def do_GET(self):
        if self.path == "/frame":
            data = read_frame()
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
            self.end_headers()
            self.wfile.write(data)
        elif self.path == "/" or self.path == "/viewer":
            # Full-page Rail-driven viewer (HUD, legend, conservation, etc.)
            self.path = "/live_viewer.html"
            super().do_GET()
        elif self.path == "/embed":
            # Minimal canvas-only build for embedding inside another page
            # (e.g., ledatic.org/plasma).  No chrome, transparent background.
            self.path = "/live_viewer_embed.html"
            super().do_GET()
        elif self.path == "/live":
            self.path = "/thruster_live.html"
            super().do_GET()
        elif self.path == "/verify":
            self.path = "/verify.html"
            super().do_GET()
        elif self.path == "/attest":
            status, resp = make_attest()
            self.send_bytes(status, json.dumps(resp).encode(), "application/json")
        elif self.path.startswith("/attest/planes32.bin"):
            self.serve_attest_file("planes32")
        elif self.path.startswith("/attest/chamber.bin"):
            self.serve_attest_file("chamber")
        elif self.path == "/status":
            # Check if mhd_live is running
            exists = os.path.exists(FRAME_PATH)
            age = time.time() - os.path.getmtime(FRAME_PATH) if exists else -1
            status = {
                "frame_exists": exists,
                "frame_age_ms": int(age * 1000) if exists else -1,
                "gpu_active": exists and age < 1.0,
            }
            body = json.dumps(status).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            super().do_GET()

    def do_POST(self):
        if self.path == "/control":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                ctrl = json.loads(body)
                with open(CTRL_PATH, "w") as f:
                    json.dump(ctrl, f)
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(b"ok")
            except Exception as e:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(str(e).encode())
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        # Quiet the /frame spam.  Python 3.14's BaseHTTPRequestHandler can
        # pass an HTTPStatus enum as args[0] for error logs (not a str), so
        # coerce before substring-checking — without this guard every error
        # response inside the request handler raises a TypeError that the
        # framework converts into a 502 to the client.
        if args and "/frame" not in str(args[0]):
            super().log_message(format, *args)


if __name__ == "__main__":
    BIND = os.environ.get("MHD_BIND", "127.0.0.1")
    server = http.server.HTTPServer((BIND, PORT), PlasmaHandler)
    print(f"RAIL PLASMA server on http://{BIND}:{PORT}")
    print(f"  Static files: {STATIC_DIR}")
    print(f"  GPU frames:   {FRAME_PATH}")
    print(f"  Control:      POST {CTRL_PATH}")
    print(f"  Live view:    http://localhost:{PORT}/live")
    print(f"  Audit:        http://localhost:{PORT}/verify")
    print()
    server.serve_forever()
