#!/usr/bin/env python3
"""Rail HTTP server driver — accepts TCP connections, dispatches to Rail handler binary.

Usage:
    # First compile the handler:
    ./rail_native tools/http_demo.rail && cp /tmp/rail_out /tmp/rail_http_handler

    # Then run the server:
    python3 tools/http_server.py [port] [handler_binary]
"""

import socket
import subprocess
import sys
import time

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    handler = sys.argv[2] if len(sys.argv) > 2 else "/tmp/rail_http_handler"

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", port))
    s.listen(16)
    print(f"Rail HTTP server on :{port} (handler: {handler})")
    sys.stdout.flush()

    req_count = 0
    while True:
        try:
            c, addr = s.accept()
            data = c.recv(8192)
            if not data:
                c.close()
                continue

            open("/tmp/rail_http_req.txt", "wb").write(data)

            t0 = time.perf_counter()
            r = subprocess.run([handler], capture_output=True, timeout=5)
            dt_ms = (time.perf_counter() - t0) * 1000

            # Response is in /tmp/rail_http_resp.txt (binary-safe)
            resp = open("/tmp/rail_http_resp.txt", "rb").read()
            c.sendall(resp)
            c.close()

            req_count += 1
            req_line = data.split(b"\r\n")[0].decode("utf-8", "replace")
            print(f"  [{req_count}] {req_line} ({dt_ms:.1f}ms)")
            sys.stdout.flush()

        except KeyboardInterrupt:
            print(f"\nShutdown after {req_count} requests")
            break
        except Exception as e:
            print(f"  Error: {e}")
            try:
                c.close()
            except:
                pass

    s.close()


if __name__ == "__main__":
    main()
