#!/usr/bin/env python3
"""
tensor_daemon.py — Persistent Metal tensor compute daemon.

Listens on localhost:9300 for text-mode tensor operations.
Keeps Metal device + compiled shaders in memory across calls.
Eliminates ~200ms init overhead per operation.

Protocol (text over TCP):
  Request:  "matmul M K N\n" + M*K floats + "\n" + K*N floats + "\n"
  Response: M*N floats + "\n"

  Request:  "relu N\n" + N floats + "\n"
  Response: N floats + "\n"

Usage:
  python3 tensor_daemon.py        # start on :9300
  python3 tensor_daemon.py 9301   # custom port

Rail calls via: shell "echo 'matmul 2 3 2\\n1 2 3 4 5 6\\n7 8 9 10 11 12' | nc localhost 9300"
"""

import socket
import subprocess
import sys
import os
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9300
GPU_BIN = os.path.expanduser("~/projects/rail/tools/metal/tensor_gpu")


def handle_client(conn):
    """Handle one request-response cycle."""
    data = b""
    while not data.endswith(b"\nEND\n"):
        chunk = conn.recv(4096)
        if not chunk:
            break
        data += chunk

    text = data.decode().strip()
    if not text:
        conn.close()
        return

    lines = text.replace("END", "").strip().split("\n")
    cmd = lines[0].strip().split()
    op = cmd[0]

    try:
        if op == "matmul":
            M, K, N = int(cmd[1]), int(cmd[2]), int(cmd[3])
            a_vals = lines[1].strip()
            b_vals = lines[2].strip()
            # Write temp files
            with open("/tmp/rail_tgd_a.txt", "w") as f:
                f.write(a_vals.replace(" ", "\n") + "\n")
            with open("/tmp/rail_tgd_b.txt", "w") as f:
                f.write(b_vals.replace(" ", "\n") + "\n")
            subprocess.run(
                [GPU_BIN, "matmul", str(M), str(K), str(N),
                 "/tmp/rail_tgd_a.txt", "/tmp/rail_tgd_b.txt", "/tmp/rail_tgd_c.txt"],
                capture_output=True, timeout=10
            )
            with open("/tmp/rail_tgd_c.txt") as f:
                result = " ".join(f.read().strip().split("\n"))
            conn.sendall((result + "\n").encode())

        elif op in ("relu", "tanh_fwd", "exp", "sigmoid"):
            n = int(cmd[1])
            a_vals = lines[1].strip()
            with open("/tmp/rail_tgd_a.txt", "w") as f:
                f.write(a_vals.replace(" ", "\n") + "\n")
            subprocess.run(
                [GPU_BIN, op, str(n), "/tmp/rail_tgd_a.txt", "/tmp/rail_tgd_c.txt"],
                capture_output=True, timeout=10
            )
            with open("/tmp/rail_tgd_c.txt") as f:
                result = " ".join(f.read().strip().split("\n"))
            conn.sendall((result + "\n").encode())

        elif op in ("add", "mul"):
            n = int(cmd[1])
            a_vals = lines[1].strip()
            b_vals = lines[2].strip()
            with open("/tmp/rail_tgd_a.txt", "w") as f:
                f.write(a_vals.replace(" ", "\n") + "\n")
            with open("/tmp/rail_tgd_b.txt", "w") as f:
                f.write(b_vals.replace(" ", "\n") + "\n")
            subprocess.run(
                [GPU_BIN, op, str(n), "/tmp/rail_tgd_a.txt", "/tmp/rail_tgd_b.txt", "/tmp/rail_tgd_c.txt"],
                capture_output=True, timeout=10
            )
            with open("/tmp/rail_tgd_c.txt") as f:
                result = " ".join(f.read().strip().split("\n"))
            conn.sendall((result + "\n").encode())

        elif op == "quit":
            conn.sendall(b"bye\n")
            conn.close()
            sys.exit(0)

        else:
            conn.sendall(b"ERROR unknown op\n")

    except Exception as e:
        conn.sendall(f"ERROR {e}\n".encode())
    finally:
        conn.close()
        # Cleanup
        for f in ["/tmp/rail_tgd_a.txt", "/tmp/rail_tgd_b.txt", "/tmp/rail_tgd_c.txt"]:
            try:
                os.unlink(f)
            except FileNotFoundError:
                pass


def main():
    # Pre-warm: compile Metal shader once
    subprocess.run(
        ["bash", "-c",
         f"test -f /tmp/tensor_gpu.metallib || {GPU_BIN} --benchmark 2>/dev/null"],
        capture_output=True
    )

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", PORT))
    sock.listen(4)
    print(f"tensor_daemon: listening on :{PORT}", file=sys.stderr)

    while True:
        conn, addr = sock.accept()
        handle_client(conn)


if __name__ == "__main__":
    main()
