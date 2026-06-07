#!/usr/bin/env bash
# ============================================================================
# RUNG 31 validate - Freivalds-Succinct GEMM Through the Truncating Nonlinearity
#
# Serial, single-GPU, single-compile. Run from the repo root:
#   bash rungs/r31/validate.sh
#
# What it does (and the GREEN GATE it enforces):
#   1. Compile the Rail succinct verifier (one compile, no self-host).
#   2. Run it once on the GPU (RAIL_ARENA_MB so the two-limb lists don't thrash).
#      It runs the proven tgl_exact_matmul readout GEMM, exposes the EXACT
#      pre-truncation 2-limb accumulators, derives a Fiat-Shamir projection r
#      from H(A,v,S), checks r^T S == (r^T A).v in the two-limb superaccumulator,
#      range-checks every truncation remainder + GPU lo limb, and runs all five
#      falsifiers. Emits rungs/r31/r31_proof.txt + rungs/r31/r31_transcript.txt.
#   3. Independently re-verify with the foreign Python checker over the emitted
#      transcript (re-derives r, recomputes the identity in bignum, range-checks,
#      reproduces all five rejections).
#
# GREEN GATE: BOTH the Rail run prints "RUNG 31 PASS" (exit 0) AND the foreign
# verifier prints "PASS" (exit 0). Either failing fails the rung.
# ============================================================================
set -u
cd "$(dirname "$0")/../.." || exit 2
ROOT="$(pwd)"
RAIL="$ROOT/rail_native"
SRC="rungs/r31/r31_freivalds_gemm.rail"
PROOF="rungs/r31/r31_proof.txt"
TRANSCRIPT="rungs/r31/r31_transcript.txt"

echo "== RUNG 31 validate =="
[ -x "$RAIL" ] || { echo "FAIL: rail_native not found/executable at $RAIL"; exit 2; }

echo "-- [1/3] compile $SRC --"
rm -f /tmp/r31_out
RAIL_ARENA_MB=4096 "$RAIL" --out-prefix /tmp/r31 "$SRC" 2> /tmp/r31_compile.err
# Different rail_native builds use different out conventions; locate the binary.
BIN=""
for cand in /tmp/r31 /tmp/r31_out /tmp/rail_out; do
  [ -x "$cand" ] && BIN="$cand" && break
done
if [ -z "$BIN" ]; then
  echo "FAIL: compile produced no executable. Compiler stderr:"; cat /tmp/r31_compile.err; exit 1
fi
echo "   compiled -> $BIN"

echo "-- [2/3] run the succinct verifier (GPU readout GEMM + Freivalds + falsifiers) --"
RAIL_ARENA_MB=4096 "$BIN"
RC=$?
echo "   rail exit=$RC"
if [ $RC -ne 0 ]; then echo "FAIL: Rail run nonzero exit (a gate failed)"; exit 1; fi
if ! grep -q "RUNG 31 PASS" "$PROOF" 2>/dev/null; then
  echo "FAIL: $PROOF missing 'RUNG 31 PASS'"; [ -f "$PROOF" ] && cat "$PROOF"; exit 1
fi
echo "   Rail gate: RUNG 31 PASS"

echo "-- [3/3] foreign cross-language re-verification --"
[ -f "$TRANSCRIPT" ] || { echo "FAIL: $TRANSCRIPT not emitted by the Rail run"; exit 1; }
python3 rungs/r31/r31_foreign_check.py "$TRANSCRIPT"
FRC=$?
if [ $FRC -ne 0 ]; then echo "FAIL: foreign verifier rejected"; exit 1; fi

echo ""
echo "== RUNG 31 GREEN: Rail succinct verifier PASS + foreign verifier PASS =="
exit 0
