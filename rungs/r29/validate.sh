#!/usr/bin/env bash
# RUNG 29 - Pi-Witness as Active Recency Oracle :: VALIDATE
#
# Runs the dual-signing Rail demo (separate trainer + witness keys, witness validates
# recency before countersigning, 2-of-2), then re-verifies the persisted record from a
# DIFFERENT language (Python big-integer Ed25519). Both must PASS.
#
# Compute note: this rung's demo is the dual-signature LAYER only (no transformer
# training), so it compiles fast and uses the DEFAULT arena. It does NOT re-run lm10.
# (The proven utterance pipeline that produces the ulink it binds is validated by its
#  own rung; this rung adds + verifies the second, separated-duty signature.)
#
# Usage:  bash rungs/r29/validate.sh
# Exit 0 = PASS (both witnesses agree, all falsifiers reject). Non-zero = FAIL.

set -u
cd "$(dirname "$0")/../.." || exit 2
ROOT="$(pwd)"
mkdir -p out

RAIL="${RAIL_NATIVE:-./rail_native}"
BIN="out/r29_bin"

echo "=== [1/3] compile rung29_dual_sign.rail (isolated out-prefix, default arena) ==="
"$RAIL" --out-prefix "$BIN" rungs/r29/rung29_dual_sign.rail
rc=$?
if [ $rc -ne 0 ]; then echo "RUNG29 FAIL: compile error (rc=$rc)"; exit 1; fi

echo "=== [2/3] run the dual-signer (Rail self-witness) ==="
"$BIN"
rc=$?
if [ $rc -ne 0 ]; then echo "RUNG29 FAIL: Rail dual-sign run returned $rc (a gate failed)"; exit 1; fi

if [ ! -f out/rung29_recency_chain.txt ]; then
  echo "RUNG29 FAIL: out/rung29_recency_chain.txt was not written"; exit 1
fi

echo "=== [3/3] foreign cross-language re-verification (Python big-int Ed25519) ==="
python3 rungs/r29/rung29_foreign_check.py out/rung29_recency_chain.txt
rc=$?
if [ $rc -ne 0 ]; then echo "RUNG29 FAIL: foreign verifier returned $rc"; exit 1; fi

echo ""
echo "RUNG29 PASS: utterance link carries a 2-of-2 dual signature from SEPARATE keys"
echo "             (trainer + Pi-witness); the witness independently validated recency"
echo "             before countersigning; self-co-sign, wrong-pulse, stale-refusal, and"
echo "             tampered-pulse all reject; an independent language re-verified it."
exit 0
