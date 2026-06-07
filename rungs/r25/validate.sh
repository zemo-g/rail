#!/usr/bin/env bash
# RUNG 25 -- ATTESTED SAMPLING -- validate to a green gate.
#
# Runs SERIALLY by the orchestrator (one slow shared compiler + one GPU + 24GB RAM). This is the
# ONLY heavy step; the builder did NOT run it (compute discipline).
#
# Two independent witnesses must both PASS:
#   1. Rail self-witness  (attested_sampling.rail): train -> SAMPLE (not greedy) -> attest ->
#      re-train + re-sample reproduces t_hex bit-for-bit; ndiff>0; F1/F2/F3/F4 all rejected.
#   2. Foreign Python verifier (sampling_foreign_check.py): a DIFFERENT language re-derives u_t,
#      redraws every token, reproduces t_hex, independently recomputes argmax to confirm ndiff>0,
#      verifies the sig, and rejects key-flip / boundary-swap / non-producing-key / forged-commitment.
#
# GREEN GATE: this script exits 0 iff the Rail run prints its PASS line AND the foreign verifier
# prints "SAMPLE-CHECK PASS". Any FAIL (or a missing PASS) exits non-zero.
set -u

cd "$(dirname "$0")/../.." || exit 2          # repo root (rail-reward)
REPO="$(pwd)"
OUT="$REPO/rungs/r25/out"
mkdir -p "$OUT"

echo "== [1/3] compile attested_sampling.rail (isolated out-prefix; serial) =="
# --out-prefix P puts the linked binary at exactly P (ld -o P). Mirror ATTESTED_UTTERANCE.md's
# `--out-prefix out/utter_bin` convention -> binary at out/r25_bin.
BIN="$OUT/r25_bin"
./rail_native --out-prefix "$BIN" rungs/r25/attested_sampling.rail
if [ ! -x "$BIN" ]; then
  echo "GATE FAIL: compile produced no binary at $BIN"
  exit 1
fi

echo "== [2/3] run the Rail self-witness (RAIL_ARENA_MB=8192 required; lm10 needs a multi-GB arena) =="
RAIL_ARENA_MB=8192 "$BIN" | tee "$OUT/rail_run.log"
RAIL_RC=${PIPESTATUS[0]}
if ! grep -q "^PASS: a Rail-native transformer trained itself, SPOKE a Rail program BY EXACT-INTEGER" "$OUT/rail_run.log"; then
  echo "GATE FAIL: Rail self-witness did not print its PASS line (rc=$RAIL_RC)"
  exit 1
fi
if [ "$RAIL_RC" -ne 0 ]; then
  echo "GATE FAIL: Rail self-witness exited non-zero (rc=$RAIL_RC)"
  exit 1
fi

echo "== [3/3] run the FOREIGN cross-language verifier (independent Python re-implementation) =="
python3 rungs/r25/sampling_foreign_check.py "$OUT/sampling_chain.txt" | tee "$OUT/foreign_run.log"
FOR_RC=${PIPESTATUS[0]}
if ! grep -q "^SAMPLE-CHECK PASS" "$OUT/foreign_run.log"; then
  echo "GATE FAIL: foreign verifier did not print SAMPLE-CHECK PASS (rc=$FOR_RC)"
  exit 1
fi
if [ "$FOR_RC" -ne 0 ]; then
  echo "GATE FAIL: foreign verifier exited non-zero (rc=$FOR_RC)"
  exit 1
fi

echo ""
echo "GATE PASS (rung 25 -- attested sampling): a Rail-native transformer SPOKE by exact-integer"
echo "categorical sampling (non-greedy, ndiff>0), bound the chain-seeded RNG key + temperature into"
echo "its Ed25519 hash-chain, and TWO independent implementations reproduced the sampled words"
echo "bit-for-bit. Key-flip, boundary-swap, non-producing-key, and forged-commitment all rejected."
exit 0
