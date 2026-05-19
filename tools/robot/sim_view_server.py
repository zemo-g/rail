#!/usr/bin/env python3
"""Tiny HTTP server for the robot-arm sim/real viewer.

Reads /tmp/robot_world.txt (state) and /tmp/arm_commands.log (cmd
history) and serves them as JSON. Also serves the static viewer HTML.

Run:
  python3 tools/robot/sim_view_server.py [port]
Default port 8091. Then open http://localhost:8091/ in a browser.
"""

import http.server
import json
import os
import socketserver
import sys
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
HTML_PATH = os.path.join(ROOT, "sim_view.html")
STATE_FILE = "/tmp/robot_world.txt"
CMD_LOG = "/tmp/arm_commands.log"
SIM_OUT = "/tmp/talk_arm_sim.out"


def read_state():
    state = {
        "ax": 0, "ay": 0, "az": 0,
        "grip": 0, "held": 0,
        "obx": 10, "oby": 0, "obz": 5, "present": 1,
        "ball_origin_x": 10, "ball_origin_y": 0, "ball_origin_z": 5,
        "last_object": "ball",
        "fault": 0,
        "steps": 0,
        "ts": time.time(),
    }
    try:
        with open(STATE_FILE) as f:
            for line in f:
                line = line.strip()
                if "=" not in line:
                    continue
                k, v = line.split("=", 1)
                if v.lstrip("-").isdigit():
                    state[k] = int(v)
                else:
                    state[k] = v
    except FileNotFoundError:
        pass
    return state


def read_cmds(n=20):
    try:
        with open(CMD_LOG) as f:
            lines = f.readlines()
        return [ln.rstrip() for ln in lines[-n:]]
    except FileNotFoundError:
        return []


def read_last_fault():
    try:
        with open(SIM_OUT) as f:
            for line in f:
                if line.startswith("SIM_RESULT"):
                    out = {}
                    for tok in line.split()[1:]:
                        if "=" in tok:
                            k, v = tok.split("=", 1)
                            if v.lstrip("-").isdigit():
                                out[k] = int(v)
                    return out
    except FileNotFoundError:
        pass
    return {}


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        # Quiet -- this prints to stderr per request otherwise.
        pass

    def do_GET(self):
        if self.path in ("/", "/index.html", "/sim_view.html"):
            return self._serve_file(HTML_PATH, "text/html; charset=utf-8")
        if self.path.startswith("/state.json"):
            return self._serve_json({
                "state": read_state(),
                "cmds": read_cmds(),
                "sim_result": read_last_fault(),
            })
        self.send_error(404, "not found")

    def _serve_file(self, path, ctype):
        try:
            with open(path, "rb") as f:
                data = f.read()
        except FileNotFoundError:
            return self.send_error(404, f"{path} missing")
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _serve_json(self, obj):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8091
    with socketserver.TCPServer(("127.0.0.1", port), Handler) as srv:
        print(f"sim_view_server: http://127.0.0.1:{port}/", flush=True)
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            print("shutdown")


if __name__ == "__main__":
    main()
