#!/usr/bin/env bash
# RUNG 24 — SEALED HOLDOUT (ATTESTED GENERALIZATION): the EXACT validate command.
#
# Runs SERIALLY (one slow shared compiler + one GPU + 24GB). Compiles the rung-24 trainer, runs it
# under a multi-GB arena (the lm10 transformer needs it), then cross-verifies in a foreign language.
#
# GREEN GATE = both of:
#   (1) the Rail trainer prints "PASS:" and exits 0  -> the model GENERALIZED to the sealed holdout
#       (held-out echo-accuracy >= the pre-registered floor T) AND the control bracket holds
#       (honest >= T > lookup) AND the SPLIT is signed/chained before checkpoint 0 AND the two
#       SHA-mismatch falsifiers fire AND the D0 self-witness reproduces the chain head.
#   (2) the foreign Python re-verifier prints "R24-CHECK PASS" and exits 0 -> an independent
#       implementation re-derived the weights, reproduced the SPLIT commitment, and confirmed the
#       SAME held-out generalization + bracket bit-for-bit.
#
# HONEST NOTE: gate (1) genuinely fails (exit 1 / "FAIL") if the tiny d=8/2-block model does NOT
# clear T on the held-out copy-rule positions. That is the open capacity question the ladder names
# at this rung ("weeks -- the capacity search is open"). The machinery, metric, controls, and
# falsifiers are all real and validate-ready; whether THIS model crosses T is decided by this run.
set -u
cd "$(dirname "$0")/../.." || exit 2          # repo root (rail-reward)
RAIL=./rail_native
TRAINER=rungs/r24/r24_attested_holdout.rail
BIN=rungs/r24/out/r24_bin
LEDGER=rungs/r24/out/r24_chain.txt
ARENA_MB=${RAIL_ARENA_MB:-8192}

mkdir -p rungs/r24/out
echo "== [1/3] compile rung-24 trainer (isolated out-prefix) =="
"$RAIL" --out-prefix "$BIN" "$TRAINER" || { echo "COMPILE FAILED"; exit 2; }

echo "== [2/3] run trainer (RAIL_ARENA_MB=$ARENA_MB; multi-GB arena required) =="
RAIL_ARENA_MB="$ARENA_MB" "./$BIN"
RAIL_RC=$?
echo "trainer exit code = $RAIL_RC"
if [ "$RAIL_RC" -ne 0 ]; then
  echo "RUNG 24 GATE: Rail trainer did NOT pass (exit $RAIL_RC). See printed gate breakdown above."
  echo "rungs/r24/out/r24_eval.txt:"; cat rungs/r24/out/r24_eval.txt 2>/dev/null
  exit 1
fi

echo "== [3/3] foreign cross-language re-verification of the SEALED HOLDOUT =="
python3 rungs/r24/r24_foreign_check.py "$LEDGER"
PY_RC=$?
if [ "$PY_RC" -ne 0 ]; then
  echo "RUNG 24 GATE: foreign re-verifier did NOT pass (exit $PY_RC)."
  exit 1
fi

echo "================================================================"
echo "RUNG 24 PASS: attested generalization under a sealed holdout."
echo " - signed SPLIT (train_sha + hold_sha) chained before checkpoint 0"
echo " - held-out echo-accuracy >= pre-registered floor T (honest > T > lookup bracket)"
echo " - train-on-holdout + post-hoc swap rejected by SHA mismatch"
echo " - independent foreign re-verifier reproduced it all bit-for-bit"
echo "================================================================"
exit 0
