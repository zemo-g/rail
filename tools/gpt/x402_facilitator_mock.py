#!/usr/bin/env python3
# TEST STUB — stands in for the external x402 facilitator (Coinbase/CF /settle).
# NOT the product. Confirms "settlement" from a registry file of settled nonces.
import http.server, json, os
REG = os.path.expanduser("~/.ledatic/railml-trial/x402_settled")
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('content-length', 0))
        body = json.loads(self.rfile.read(n) or b'{}')
        nonce = body.get('nonce', '')
        settled = os.path.exists(REG) and nonce in open(REG).read().split()
        resp = {"settled": settled}
        if settled: resp.update(txHash="0x"+"ab"*32, network="base", asset="USDC")
        self.send_response(200); self.send_header('content-type','application/json'); self.end_headers()
        self.wfile.write(json.dumps(resp, separators=(",",":")).encode())
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', 8474), H).serve_forever()
