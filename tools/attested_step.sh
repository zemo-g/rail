#!/bin/bash
# tools/attested_step.sh — "a computation that proves itself," end to end.
#
# Composes all three Verifiable-Language pillars into one beacon-anchored, signed, hash-chained
# ledger and verifies it:
#   (1) P1 selfhost  — binds sha256(compile.rail)+sha256(rail_native): the self-hosting toolchain.
#   (2) P3 revad     — a DETERMINISTIC reverse-mode AD gradient (bit-reproducible) -> recorded.
#   (3) P2 authdict  — authenticated inputs (a value carrying proof of its derivation) -> recorded.
#   (4) verify       — every signature + prev_hash link + beacon-pulse monotonicity.
# The result: a reproducible computation that arrives with a public, replayable, tamper-evident
# proof of how it was derived. Offline / local test key — no Pi, no beacon network, no publish.
set -u
cd "$(dirname "$0")/.." || exit 1
RN=./rail_native
B=tools/attest/attest_chain_beacon.rail
W=/tmp/astep
mkdir -p "$W"
printf '9d61b19deffe1c2f8b6a7c0db7c5f7e3a9e3c0a1b2c3d4e5f60718293a4b5c6d' > "$W/seed.hex"
export CHAIN_KEY="$W/seed.hex" CHAIN_FILE="$W/chain.jsonl"
rm -f "$CHAIN_FILE"
fail=0

echo "== 1. bind the self-hosting toolchain (P1 selfhost, pulse 1000) =="
PULSE_ID=1000 "$RN" run "$B" selfhost > "$W/1.txt" 2>&1 || fail=1
grep -E "sha256|appended" "$W/1.txt" | tail -3

echo "== 2. deterministic AD gradient (P3 revad) -> recorded (pulse 1001) =="
"$RN" run tools/ad/revad.rail > "$W/grad.txt" 2>&1 || fail=1
grep -E "RESULT" "$W/grad.txt"
PULSE_ID=1001 "$RN" run "$B" append "$W/grad.txt" > "$W/2.txt" 2>&1 || fail=1
grep "appended" "$W/2.txt"

echo "== 3. authenticated inputs (P2 authdict) -> recorded (pulse 1002) =="
"$RN" run tools/auth/authdict.rail > "$W/inputs.txt" 2>&1 || fail=1
grep -E "accept value" "$W/inputs.txt" | tail -1
PULSE_ID=1002 "$RN" run "$B" append "$W/inputs.txt" > "$W/3.txt" 2>&1 || fail=1
grep "appended" "$W/3.txt"

echo "== 4. verify the attested-step chain (sigs + prev_hash links + pulse monotonicity) =="
"$RN" run "$B" verify > "$W/v.txt" 2>&1 || fail=1
tail -5 "$W/v.txt"

echo "== SUMMARY =="
if [ "$fail" -eq 0 ]; then
  echo "ATTESTED STEP: GREEN — toolchain + deterministic gradient + authenticated inputs,"
  echo "  recorded, signed, beacon-anchored, hash-chained, and verified end to end."
else
  echo "ATTESTED STEP: FAILURES above"
fi
exit $fail
