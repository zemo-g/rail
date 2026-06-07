#!/usr/bin/env bash
# ============================================================================
# RUNG 33 - k-of-n Threshold-Signed Utterance (FROST-Ed25519) :: VALIDATE
#
# Runs the 2-of-3 FROST-Ed25519 threshold-signing Rail demo over a pulse-anchored
# utterance link, then re-verifies the persisted threshold signature from a
# DIFFERENT language (Python big-integer Ed25519, the SAME RFC-8032 verifier that
# accepts the single-key utterance). Both must PASS.
#
# Compute note: this rung is the threshold-crypto LAYER only -- NO transformer
# training. It does NOT re-run lm10 (that pipeline is validated by its own rung).
# It compiles fast and uses the DEFAULT arena (the FROST ceremony is point/scalar
# arithmetic over a 32-byte message; the scalar inversion is ~380 sc_mul calls).
#
# Serial, single-compile. Run from the repo root:  bash rungs/r33/validate.sh
# GREEN GATE: BOTH the Rail run prints "PASS" (exit 0, all falsifiers reject)
# AND the foreign verifier prints "FOREIGN PASS" (exit 0). Either failing fails.
# ============================================================================
set -u
cd "$(dirname "$0")/../.." || exit 2
ROOT="$(pwd)"
mkdir -p out

RAIL="${RAIL_NATIVE:-./rail_native}"
SRC="rungs/r33/frost_main.rail"
LEDGER="rungs/r33/frost_ledger.txt"

[ -x "$RAIL" ] || { echo "RUNG33 FAIL: rail_native not found/executable at $RAIL"; exit 2; }

echo "=== [1/3] compile $SRC (isolated out-prefix, default arena) ==="
rm -f out/r33_bin out/r33_bin_out /tmp/r33_out
"$RAIL" --out-prefix out/r33_bin "$SRC" 2> /tmp/r33_compile.err
rc=$?
# Locate the produced binary across rail_native out conventions.
BIN=""
for cand in out/r33_bin out/r33_bin_out /tmp/rail_out; do
  [ -x "$cand" ] && BIN="$cand" && break
done
if [ -z "$BIN" ]; then
  echo "RUNG33 FAIL: compile produced no executable (rc=$rc). Compiler stderr:"
  cat /tmp/r33_compile.err
  exit 1
fi
echo "   compiled -> $BIN"

echo "=== [2/3] run the 2-of-3 FROST ceremony (Rail self-witness) ==="
"$BIN"
rc=$?
if [ $rc -ne 0 ]; then echo "RUNG33 FAIL: Rail FROST run returned $rc (a gate or falsifier failed)"; exit 1; fi
if [ ! -f "$LEDGER" ]; then echo "RUNG33 FAIL: $LEDGER was not written"; exit 1; fi

echo "=== [3/3] foreign cross-language re-verification (Python big-int Ed25519) ==="
python3 rungs/r33/frost_foreign_check.py "$LEDGER"
rc=$?
if [ $rc -ne 0 ]; then echo "RUNG33 FAIL: foreign verifier returned $rc"; exit 1; fi

echo ""
echo "RUNG33 PASS: a 2-of-3 FROST-Ed25519 threshold over the pulse-anchored utterance"
echo "             link produced a single 64-byte sig the UNMODIFIED ed25519_verify"
echo "             accepts under one group pubkey; any 2-of-3 reconstructs the same"
echo "             group sig; no minority forged it; re-run is byte-identical; and an"
echo "             independent language re-verified the sig AND reproduced it"
echo "             byte-for-bit from the shares with no group secret at sign time."
exit 0
