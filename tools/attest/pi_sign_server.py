#!/usr/bin/env python3
"""tools/attest/pi_sign_server.py — Pi-side HTTP signer for attestations.

Replaces the SSH dance in attest.rail / attest.sh with a localhost-tier
HTTP endpoint. Reuses sign_attestation.sh (the same shell signer the
SSH path called) so the wire format and key material are unchanged —
this is purely a transport swap, not a crypto change.

Endpoint:  POST /sign  Content-Type: application/json
Headers:   X-Sign-Token: <token from ~/.ledatic/witness/sign_token>
Body:      {"digest": "<hex>", "pulse_id": <int>, "value_hex": "<hex>"}
Response:  the raw JSON sign_attestation.sh prints on stdout (200)
           or {"error": "..."} (400/401/500)

Health:    GET /health -> {"ok": true, "name": "<hostname>"}

Bind:      0.0.0.0:9102 (override with PORT env var)
Auth:      mandatory X-Sign-Token header, compared to
           ~/.ledatic/witness/sign_token contents (chmod 600).
           Token mismatch -> 401.
"""

import json
import os
import re
import socket
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

WITNESS_DIR = os.environ.get("WITNESS_DIR", os.path.expanduser("~/.ledatic/witness"))
SIGNER = os.environ.get("SIGNER", os.path.join(WITNESS_DIR, "sign_attestation.sh"))
TOKEN_PATH = os.environ.get("SIGN_TOKEN_PATH", os.path.join(WITNESS_DIR, "sign_token"))
PORT = int(os.environ.get("PORT", "9102"))
HEX_RE = re.compile(r"^[0-9a-fA-F]+$")
PULSE_RE = re.compile(r"^[0-9]+$")


def _load_token() -> str:
    with open(TOKEN_PATH, "r") as f:
        return f.read().strip()


class Handler(BaseHTTPRequestHandler):
    def _reply(self, status: int, body: bytes, ctype: str = "application/json"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _err(self, status: int, msg: str):
        self._reply(status, json.dumps({"error": msg}).encode() + b"\n")

    def log_message(self, format, *args):
        # systemd journal already timestamps; cut the access-log noise.
        del format, args

    def do_GET(self):
        if self.path == "/health":
            self._reply(200, json.dumps({"ok": True, "name": socket.gethostname()}).encode() + b"\n")
        else:
            self._err(404, "not found")

    def do_POST(self):
        if self.path != "/sign":
            self._err(404, "not found")
            return
        try:
            want = _load_token()
        except OSError:
            self._err(500, "server token unavailable")
            return
        got = self.headers.get("X-Sign-Token", "")
        if not want or got != want:
            self._err(401, "bad or missing X-Sign-Token")
            return
        try:
            n = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(n).decode())
            digest = payload["digest"]
            pulse_id = payload["pulse_id"]
            value_hex = payload["value_hex"]
        except (ValueError, KeyError):
            self._err(400, "bad json: need digest, pulse_id, value_hex")
            return
        if not HEX_RE.match(digest) or not HEX_RE.match(value_hex):
            self._err(400, "digest/value_hex must be hex")
            return
        if not PULSE_RE.match(str(pulse_id)):
            self._err(400, "pulse_id must be int")
            return
        try:
            res = subprocess.run(
                [SIGNER, digest, str(pulse_id), value_hex],
                check=True,
                capture_output=True,
                timeout=10,
            )
        except subprocess.CalledProcessError as e:
            self._err(500, f"signer exit {e.returncode}: {e.stderr.decode()[:200]}")
            return
        except subprocess.TimeoutExpired:
            self._err(504, "signer timeout")
            return
        self._reply(200, res.stdout)


def main():
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
