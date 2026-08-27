#!/bin/bash
# tools/infer/s0_gate.sh — the S0 serving-contract gate.
#
# Boots serve_kv.rail on a scratch port and tests the CONTRACT, not the
# prose: health answers; the same request twice returns byte-identical
# text and output_sha256 (the whole point); a different prompt hashes
# differently; the ledger chain self-verifies over exactly the requests
# made; a garbage request 400s without killing the server.
#
# Run from repo root: bash tools/infer/s0_gate.sh
# PASS convention: exit 0 + last line PASS.
set -u
cd "$(dirname "$0")/../.."
PORT=9581
LEDGER=/tmp/s0_gate_ledger.jsonl
OUT=/tmp/s0_gate_server
LOG=/tmp/s0_gate_server.log
fails=0

note() { echo "  $1"; }
fail() { echo "  FAIL: $1"; fails=$((fails+1)); }

# kill any orphan first: rail_native run execs the compiled binary as a
# child, so killing the launcher pid alone leaves the actual server alive
# and holding the port -- the next run then talks to STALE code. (Bit this
# gate once: every check failed against a server from a previous run.)
pkill -f "$OUT" 2>/dev/null
sleep 1

# compile + launch (own --out-prefix: concurrent rail runs race /tmp/rail_out)
./rail_native run tools/infer/serve_kv.rail --out-prefix "$OUT" \
  --port $PORT --ledger "$LEDGER" > "$LOG" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; pkill -f "$OUT" 2>/dev/null' EXIT

ready=""
for _ in $(seq 1 60); do
  if curl -sm 2 "http://127.0.0.1:$PORT/health" | grep -q '"ok":true'; then
    ready=yes; break
  fi
  kill -0 $SRV 2>/dev/null || break
  sleep 1
done
if [ -z "$ready" ]; then
  echo "server never became ready; log tail:"; tail -5 "$LOG"; echo "FAIL"; exit 1
fi
note "health: ok"

REQ='{"prompt": "the rail language", "max": 24}'
R1=$(curl -sm 60 -X POST "http://127.0.0.1:$PORT/generate" -d "$REQ")
R2=$(curl -sm 60 -X POST "http://127.0.0.1:$PORT/generate" -d "$REQ")
H1=$(echo "$R1" | sed -n 's/.*"output_sha256":"\([0-9a-f]*\)".*/\1/p')
H2=$(echo "$R2" | sed -n 's/.*"output_sha256":"\([0-9a-f]*\)".*/\1/p')
T1=$(echo "$R1" | sed -n 's/.*"text":"\(.*\)","isl".*/\1/p')
T2=$(echo "$R2" | sed -n 's/.*"text":"\(.*\)","isl".*/\1/p')

[ -n "$H1" ] || fail "first generate returned no output_sha256: $R1"
if [ "$H1" = "$H2" ] && [ "$T1" = "$T2" ]; then
  note "determinism: same request twice -> same bytes (sha $H1)"
else
  fail "same request produced different responses: $H1 vs $H2"
fi

R3=$(curl -sm 60 -X POST "http://127.0.0.1:$PORT/generate" \
  -d '{"prompt": "compiles itself", "max": 24}')
H3=$(echo "$R3" | sed -n 's/.*"output_sha256":"\([0-9a-f]*\)".*/\1/p')
if [ -n "$H3" ] && [ "$H3" != "$H1" ]; then
  note "different prompt -> different output hash"
else
  fail "different prompt did not change the output hash"
fi

# metrics fields present
echo "$R1" | grep -q '"ttft_ms"' && echo "$R1" | grep -q '"tps_x10"' \
  && note "metrics: ttft/tps/isl/osl reported" \
  || fail "metrics fields missing: $R1"

# chain links: R2.prev_hash == R1.record_hash, R3.prev == R2.record
RH1=$(echo "$R1" | sed -n 's/.*"record_hash":"\([0-9a-f]*\)".*/\1/p')
PH2=$(echo "$R2" | sed -n 's/.*"prev_hash":"\([0-9a-f]*\)".*/\1/p')
[ "$PH2" = "$RH1" ] && note "chain: response n+1 carries response n's record hash" \
  || fail "chain link mismatch in responses"

# ── S1: streaming ──
# the streamed raw bytes must hash to EXACTLY the output_sha256 that the
# JSON endpoint reported for the same request -- streaming changes the
# transport, never the bytes
S1=$(curl -sm 60 -N -X POST "http://127.0.0.1:$PORT/generate_stream" -d "$REQ")
SH=$(printf '%s' "$S1" | shasum -a 256 | cut -d' ' -f1)
if [ "$SH" = "$H1" ]; then
  note "stream: sha256(streamed bytes) == /generate's output_sha256"
else
  fail "stream hash $SH != generate hash $H1 (text: $S1)"
fi
S2=$(curl -sm 60 -N -X POST "http://127.0.0.1:$PORT/generate_stream" -d "$REQ")
[ "$S1" = "$S2" ] && note "stream determinism: same request twice -> same stream" \
  || fail "stream nondeterministic"
# tokens arrive before the response completes (long generation, timing split)
TW=$(curl -sm 120 -N -o /dev/null -w '%{time_starttransfer} %{time_total}' \
  -X POST "http://127.0.0.1:$PORT/generate_stream" \
  -d '{"prompt": "the rail language", "max": 200}')
TS=$(echo "$TW" | cut -d' ' -f1); TT=$(echo "$TW" | cut -d' ' -f2)
if awk -v a="$TS" -v b="$TT" 'BEGIN{exit !(a < b/2)}'; then
  note "stream is live: first byte at ${TS}s of ${TT}s total"
else
  fail "stream not incremental: first byte ${TS}s vs total ${TT}s"
fi

V=$(curl -sm 10 "http://127.0.0.1:$PORT/ledger/verify")
echo "$V" | grep -q '"ok":true' && echo "$V" | grep -q '"records":6' \
  && note "ledger self-verifies: 6 records (3 json + 3 streamed), chain intact" \
  || fail "ledger verify failed: $V"

# a tampered ledger must FAIL verification
sed -i '' 's/"isl":[0-9]*/"isl":999/' "$LEDGER"
V2=$(curl -sm 10 "http://127.0.0.1:$PORT/ledger/verify")
echo "$V2" | grep -q '"ok":false' \
  && note "tampered ledger is caught (record hash mismatch)" \
  || fail "tampered ledger passed verification: $V2"

# malformed request: 400, and the server survives
B=$(curl -sm 10 -X POST "http://127.0.0.1:$PORT/generate" -d 'not json')
echo "$B" | grep -q 'error' || fail "garbage request did not error: $B"
curl -sm 2 "http://127.0.0.1:$PORT/health" | grep -q '"ok":true' \
  && note "server survives a garbage request" \
  || fail "server died after garbage request"

kill $SRV 2>/dev/null; pkill -f "$OUT" 2>/dev/null
trap - EXIT
if [ "$fails" -eq 0 ]; then echo "PASS"; exit 0; else echo "FAIL ($fails)"; exit 1; fi
