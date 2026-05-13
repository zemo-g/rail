#!/usr/bin/env bash
# tools/test/playground_recv_loop_smoke.sh
# ----------------------------------------------------------------------
# Smoke for the http_server.py recv-loop fix landed in Session C
# (2026-05-13). Verifies that POST bodies up to ~20 KB round-trip
# cleanly through the same dispatch path the playground uses, where
# previously a single recv(8192) silently truncated anything larger
# than ~8 KB.
#
# What it does:
#   1. Build tools/playground/compile_server.rail
#   2. Start tools/http_server.py on a free port (default 8766)
#   3. POST a JSON body whose `src` field is a Rail program padded
#      with `-- ` line comments to ~20 KB
#   4. Assert the response is HTTP 200 with ok:true and a non-empty
#      wasm_b64 (proves the FULL source reached the compiler — a
#      truncated source would either fail to parse or be rejected
#      mid-comment by the lexer)
#   5. Tear down. Exit 0 = PASS, non-zero = FAIL.
#
# Run from anywhere; uses RAIL_ROOT (default ~/projects/rail).

set -u
set -o pipefail

RAIL_ROOT="${RAIL_ROOT:-~/projects/rail}"
PORT="${PORT:-8766}"

cleanup() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f /tmp/pg_recvloop_*.{json,bin,log,rail}
}
trap cleanup EXIT INT TERM

if [ ! -x "$RAIL_ROOT/rail_native" ]; then
  echo "FAIL: rail_native not at $RAIL_ROOT/rail_native"
  exit 2
fi

echo "[1/4] Building compile_server.rail..."
( cd "$RAIL_ROOT" && ./rail_native tools/playground/compile_server.rail \
    >/tmp/pg_recvloop_build.log 2>&1 )
ec=$?
if [ $ec -ne 0 ]; then
  echo "FAIL: build (exit $ec)"
  tail -20 /tmp/pg_recvloop_build.log
  exit 3
fi
cp /tmp/rail_out /tmp/pg_recvloop_handler
chmod +x /tmp/pg_recvloop_handler

echo "[2/4] Starting http_server.py on :$PORT..."
( cd "$RAIL_ROOT" && python3 tools/http_server.py "$PORT" /tmp/pg_recvloop_handler \
    >/tmp/pg_recvloop_server.log 2>&1 ) &
SERVER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q "Rail HTTP server" /tmp/pg_recvloop_server.log 2>/dev/null && break
  sleep 0.3
done
if ! grep -q "Rail HTTP server" /tmp/pg_recvloop_server.log 2>/dev/null; then
  echo "FAIL: server did not start"
  cat /tmp/pg_recvloop_server.log
  exit 4
fi

echo "[3/4] Building 20 KB JSON request body..."
# Source: a tiny valid program ending with `main = 42`, prefaced by ~20 KB
# of `-- pad` line comments so the lexer must see EVERY byte (a truncated
# source mid-comment would still parse-fail, exposing the bug).
PAD=$(python3 -c '
import sys
# 1 pad line = 78 bytes (incl. \n). 260 lines = ~20 KB.
print("\n".join(["-- pad " + ("x" * 70)] * 260))
print("main = 42")
')
SRC_LEN=$(printf %s "$PAD" | wc -c | tr -d ' ')
echo "      src bytes: $SRC_LEN"
if [ "$SRC_LEN" -lt 18000 ] || [ "$SRC_LEN" -gt 32000 ]; then
  echo "FAIL: pad size out of range ($SRC_LEN)"
  exit 5
fi
python3 -c '
import json, sys
src = sys.stdin.read()
sys.stdout.write(json.dumps({"src": src}))
' > /tmp/pg_recvloop_body.json <<< "$PAD"
BODY_LEN=$(wc -c < /tmp/pg_recvloop_body.json | tr -d ' ')
echo "      JSON body bytes: $BODY_LEN"

echo "[4/4] POST + assert..."
RESP=$(curl -s -X POST "http://127.0.0.1:$PORT/api/playground/compile" \
  -H "content-type: application/json" \
  --data-binary @/tmp/pg_recvloop_body.json)
echo "      response (first 200 chars): $(printf '%s' "$RESP" | head -c 200)"

OK=$(printf '%s' "$RESP" | python3 -c '
import sys, json
try:
  j = json.loads(sys.stdin.read())
  print("yes" if j.get("ok") is True and j.get("wasm_b64") else "no")
except Exception as e:
  print("no")
')

if [ "$OK" = "yes" ]; then
  echo "      PASS  ok=true, wasm_b64 non-empty (full $SRC_LEN B reached compiler)"
  echo
  echo "      server log tail:"
  tail -5 /tmp/pg_recvloop_server.log | sed 's/^/        /'
  exit 0
fi

echo "FAIL: response did not parse to ok:true"
echo "  raw response: $RESP"
echo "  server log:"
tail -20 /tmp/pg_recvloop_server.log | sed 's/^/    /'
exit 1
