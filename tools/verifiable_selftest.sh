#!/bin/bash
# tools/verifiable_selftest.sh — exercises the three Verifiable-Language pillars and the
# "computation that proves itself" composition. See notes/VERIFIABLE_LANGUAGE.md.
#
# P1 attestation ledger · P2 authenticated data structures · P3 source-to-source AD,
# then: a deterministic P3 computation recorded + signed + hash-chained by P1, and verified.
# Offline, local test key — no Pi / beacon / publish.
set -u
cd "$(dirname "$0")/.." || exit 1
RN=./rail_native
WORK=/tmp/vl
mkdir -p "$WORK"
export CHAIN_KEY="$WORK/seed.hex" CHAIN_FILE="$WORK/chain.jsonl"
printf '9d61b19deffe1c2f8b6a7c0db7c5f7e3a9e3c0a1b2c3d4e5f60718293a4b5c6d' > "$CHAIN_KEY"  # local test seed (NOT the Pi key)
rm -f "$CHAIN_FILE"
fail=0

echo "================ P1: attestation ledger (selfhost binding) ================"
"$RN" run tools/attest/attest_chain.rail selfhost > "$WORK/p1.txt" 2>&1 || fail=1
tail -3 "$WORK/p1.txt"

echo "================ P2: authenticated data structures (Merkle) ================"
"$RN" run tools/auth/authkit.rail > "$WORK/p2.txt" 2>&1 || fail=1
tail -4 "$WORK/p2.txt"

echo "================ P3: source-to-source AD (gradient is a program) ================"
"$RN" run tools/ad/diff.rail > "$WORK/p3.txt" 2>&1 || fail=1
tail -4 "$WORK/p3.txt"

echo "================ COMPOSE: a computation that proves itself ================"
echo "  recording the deterministic P3 computation into the attestation chain..."
"$RN" run tools/attest/attest_chain.rail append "$WORK/p3.txt" > "$WORK/c1.txt" 2>&1 || fail=1
tail -1 "$WORK/c1.txt"
echo "  verifying the chain (selfhost binding + the P3 computation, hash-linked)..."
"$RN" run tools/attest/attest_chain.rail verify > "$WORK/c2.txt" 2>&1 || fail=1
tail -4 "$WORK/c2.txt"

echo "================ SUMMARY ================"
if [ "$fail" -eq 0 ]; then
  echo "verifiable-language selftest: ALL GREEN"
else
  echo "verifiable-language selftest: FAILURES above"
fi
echo "(next composition step: P2-authenticate P3's inputs; live: Pi-sign + beacon-anchor + publish.)"
exit $fail
