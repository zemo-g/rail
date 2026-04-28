#!/usr/bin/env python3
"""
mhd_server.py — HTTP server for RAIL PLASMA live GPU streaming.

Serves:
  /                    → thruster_engine.html (or any static file)
  /frame               → latest GPU frame (binary, ~100KB)
  /control  (POST)     → write control JSON to /tmp/plasma_ctrl.json
  /live                → thruster_live.html (GPU-connected client)

The Metal host (mhd_live) writes frames to /tmp/plasma_live.bin.
This server reads that file and serves it to any connected browser.

Usage:
  python3 mhd_server.py                    # port 9200
  python3 mhd_server.py 9300               # custom port
"""

import http.server
import json
import os
import struct
import sys
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9200
FRAME_PATH = "/tmp/plasma_live.bin"
CTRL_PATH = "/tmp/plasma_ctrl.json"
STATIC_DIR = os.path.dirname(os.path.abspath(__file__))

# Cache the last frame to avoid re-reading unchanged files
_frame_cache = (0, b"")  # (mtime, data)


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


class PlasmaHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=STATIC_DIR, **kwargs)

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
    print()
    server.serve_forever()
