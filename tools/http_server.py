#!/usr/bin/env python3
"""Rail HTTP server driver — accepts TCP connections, dispatches to Rail handler binary.

Usage:
    # First compile the handler:
    ./rail_native tools/http_demo.rail && cp /tmp/rail_out /tmp/rail_http_handler

    # Then run the server:
    python3 tools/http_server.py [port] [handler_binary]

Body cap: 32 KB. Larger bodies are 413'd before invoking the Rail handler.
"""

import socket
import subprocess
import sys
import time

# Hard cap on total request bytes accepted from a single connection. Matches
# sanitize.rail's sanitize_max_bytes (32768) and the Worker's body cap so the
# whole pipeline shares one number. A 32 KB Rail source plus the JSON wrapper
# plus typical HTTP headers fits comfortably under this; anything larger is
# either accidental or hostile.
MAX_BODY_BYTES = 32 * 1024
MAX_TOTAL_BYTES = MAX_BODY_BYTES + 8 * 1024  # body + headroom for headers
RECV_CHUNK = 8192
RECV_TIMEOUT_SEC = 5.0


def parse_content_length(header_blob):
    """Find Content-Length in the header blob (case-insensitive). Returns
    None if not present, an int otherwise. Returns -1 on a malformed value."""
    for line in header_blob.split(b"\r\n"):
        if b":" not in line:
            continue
        name, _, value = line.partition(b":")
        if name.strip().lower() == b"content-length":
            try:
                return int(value.strip())
            except (ValueError, TypeError):
                return -1
    return None


def recv_request(c):
    """Read a complete HTTP request: headers (until CRLFCRLF) plus the body
    indicated by Content-Length. Returns the raw bytes or None on error.

    Replaces the previous single ``c.recv(8192)`` which silently truncated
    POST bodies larger than 8 KB (e.g. 20 KB Rail sources from the
    playground). Caps total bytes at MAX_TOTAL_BYTES; oversize -> 413
    response is the caller's job."""
    c.settimeout(RECV_TIMEOUT_SEC)
    buf = bytearray()
    headers_end = -1
    # 1) read until end-of-headers
    while headers_end < 0:
        chunk = c.recv(RECV_CHUNK)
        if not chunk:
            return bytes(buf) if buf else None
        buf.extend(chunk)
        if len(buf) > MAX_TOTAL_BYTES:
            return bytes(buf[:MAX_TOTAL_BYTES])  # caller will detect oversize
        headers_end = buf.find(b"\r\n\r\n")
        if headers_end < 0:
            # Bare LF fallback for sloppy clients.
            lf = buf.find(b"\n\n")
            if lf >= 0:
                headers_end = lf  # treat as 2-byte sep
                # Normalize: rebuild buf with CRLFCRLF so downstream parsers
                # don't have to handle both. Cheap; happens once.
                head = bytes(buf[:lf])
                rest = bytes(buf[lf + 2 :])
                buf = bytearray(head + b"\r\n\r\n" + rest)
                headers_end = len(head)
                break
    # 2) determine body size
    header_blob = bytes(buf[:headers_end])
    cl = parse_content_length(header_blob)
    body_start = headers_end + 4  # past CRLFCRLF
    have = len(buf) - body_start
    if cl is None or cl < 0:
        # No Content-Length: assume no body (GET/OPTIONS/etc). Anything past
        # the headers we already have is dropped.
        return bytes(buf)
    if cl > MAX_BODY_BYTES:
        # Read the rest of the body up to a safe limit so we can still send a
        # clean 413, but DON'T balloon memory. We've already gathered some;
        # drain a small additional amount to keep the socket healthy then
        # return what we have for the caller to reject.
        return bytes(buf[: body_start + min(cl, MAX_BODY_BYTES + 1)])
    # 3) read until full body present
    while have < cl:
        need = cl - have
        chunk = c.recv(min(RECV_CHUNK, need))
        if not chunk:
            break  # EOF mid-body; return partial — handler will fail-clean
        buf.extend(chunk)
        have = len(buf) - body_start
        if len(buf) > MAX_TOTAL_BYTES:
            break
    return bytes(buf)


def oversize_response():
    body = b'{"ok":false,"error":"source too large (>32 KB)"}'
    return (
        b"HTTP/1.1 413 Payload Too Large\r\n"
        b"Content-Type: application/json\r\n"
        b"Content-Length: " + str(len(body)).encode() + b"\r\n"
        b"Access-Control-Allow-Origin: *\r\n"
        b"Connection: close\r\n\r\n" + body
    )


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
            data = recv_request(c)
            if not data:
                c.close()
                continue

            # Pre-handler oversize check: avoid even invoking Rail for huge
            # bodies. Keeps the (per-process flock-free) handler responsive.
            cl_header = parse_content_length(data.split(b"\r\n\r\n", 1)[0])
            if cl_header is not None and cl_header > MAX_BODY_BYTES:
                c.sendall(oversize_response())
                c.close()
                req_count += 1
                req_line = data.split(b"\r\n")[0].decode("utf-8", "replace")
                print(f"  [{req_count}] {req_line} (413 oversize cl={cl_header})")
                sys.stdout.flush()
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
            print(f"  [{req_count}] {req_line} ({dt_ms:.1f}ms, body={cl_header or 0}B)")
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
