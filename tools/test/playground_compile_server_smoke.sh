#!/usr/bin/env bash
# tools/test/playground_compile_server_smoke.sh — End-to-end smoke for
# the playground compile server. Spawns tools/http_server.py with the
# compiled handler binary, posts canned requests, asserts the JSON
# fields. Last line prints PASS/FAIL.
#
# Run from repo root:
#   bash tools/test/playground_compile_server_smoke.sh
#
# Note: chose a thin shell over a Rail smoke per the explicit allowance
# in the task spec — this exercises an external HTTP server which is
# more naturally driven by curl than by a self-spawned subprocess from
# Rail. Pure-Rail tests for sanitize logic live in
# tools/test/playground_sanitize_test.rail.

set -uo pipefail
cd "$(dirname "$0")/../.."

PORT="${PORT:-18080}"
HANDLER=/tmp/rail_pg_handler
SERVER_LOG=/tmp/rail_pg_server.log
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "=== playground compile-server smoke ==="

echo "  build handler..."
./rail_native tools/playground/compile_server.rail >/tmp/rail_pg_build.log 2>&1
if [ $? -ne 0 ]; then
  echo "FAIL build: see /tmp/rail_pg_build.log"
  tail -5 /tmp/rail_pg_build.log
  exit 1
fi
cp /tmp/rail_out "$HANDLER"
chmod +x "$HANDLER"

echo "  start server on :$PORT..."
python3 tools/http_server.py "$PORT" "$HANDLER" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
# Wait for the listener to bind. http_server.py prints a banner.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q "Rail HTTP" "$SERVER_LOG" 2>/dev/null; then break; fi
  sleep 0.2
done
if ! grep -q "Rail HTTP" "$SERVER_LOG"; then
  echo "FAIL server didn't start"
  cat "$SERVER_LOG"
  exit 1
fi

PASS_COUNT=0
FAIL_COUNT=0

# ---- positive: trivial program ----
RESP=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"src":"main = 42"}' "http://localhost:$PORT/api/playground/compile")
if echo "$RESP" | grep -q '"ok":true' && echo "$RESP" | grep -q '"wasm_b64":"AGFzbQ'; then
  echo "  pass  trivial main=42"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "  FAIL  trivial main=42 — got: ${RESP:0:200}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ---- negative: shell injection ----
RESP=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"src":"main = let _ = shell \"rm -rf /\" in 0"}' \
  "http://localhost:$PORT/api/playground/compile")
if echo "$RESP" | grep -q '"ok":false' && echo "$RESP" | grep -q 'sanitize'; then
  echo "  pass  shell injection rejected"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "  FAIL  shell injection NOT rejected — got: ${RESP:0:200}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ---- negative: import attempt ----
RESP=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"src":"import \"stdlib/list.rail\"\nmain = 0"}' \
  "http://localhost:$PORT/api/playground/compile")
if echo "$RESP" | grep -q '"ok":false' && echo "$RESP" | grep -q 'sanitize'; then
  echo "  pass  import rejected"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "  FAIL  import NOT rejected — got: ${RESP:0:200}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ---- positive: spec example 1 (echo + arith) ----
RESP=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"src":"main = let _ = print \"hi\"\n  let _ = print (show (3 + 4))\n  0"}' \
  "http://localhost:$PORT/api/playground/compile")
if echo "$RESP" | grep -q '"ok":true' && echo "$RESP" | grep -q '"wasm_b64":"AGFzbQ'; then
  echo "  pass  spec ex1 echo+arith"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "  FAIL  spec ex1 — got: ${RESP:0:200}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

echo "$PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "PASS"
  exit 0
else
  echo "FAIL"
  exit 1
fi
