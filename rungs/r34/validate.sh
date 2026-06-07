#!/usr/bin/env bash
# ============================================================================
# RUNG 34 validate - Economic Stake over the Succinct Length-Proof
#
# Serial, single-compile (NO self-host, NO 8GB training run). Run from repo root:
#   bash rungs/r34/validate.sh
#
# What it does (and the GREEN GATE it enforces):
#   1. Compile the Rail prover+verifier+slasher (one compile, no self-host).
#   2. Run it once. It:
#        - runs the PROVEN rung-30 per-step transition over K=512 steps, builds the
#          per-step Merkle DAG, derives Fiat-Shamir spot-checks from the signed
#          chain head, and verifies the K-step length-proof by recomputing only
#          k=46 challenged steps (<25% of K, sublinear);
#        - BONDS a stake (1000 credits) drawn from a real SDK credit balance
#          (5000) against the signed length-claim, chained + signed;
#        - on a FORGED chain (one poisoned/inconsistent step), a third party
#          constructs a single-step fraud-proof; an independent O(log N) checker
#          confirms the inconsistency and SLASHES the bond (balance debited);
#        - proves FALSE-SLASH RESISTANCE: an opened honest step recomputes
#          consistently -> NO slash -> stake released (honest bond never slashable);
#        - runs 4 more falsifiers (honest step of forged chain, fabricated
#          evidence, over-stake, unsigned root).
#      Emits rungs/r34/out/r34_gate.txt + rungs/r34/out/r34_fraudproof.txt.
#   3. Independently re-verify with the foreign Python checker: it re-runs the
#      WHOLE K-step trajectory from scratch in pure big-integers, rebuilds the
#      Merkle DAG, verifies the signed length-claim, CONFIRMS the single-step
#      fraud-proof slashes the bond, and CONFIRMS an honest chain is never
#      slashable -- reproducing every verdict in a DIFFERENT language.
#
# GREEN GATE: ALL of:
#   (a) the Rail run prints "PASS:" and exits 0;
#   (b) rungs/r34/out/r34_gate.txt has "ALL 1";
#   (c) the foreign verifier prints "R34-CHECK PASS" and exits 0.
# Any one failing fails the rung.
# ============================================================================
set -u
cd "$(dirname "$0")/../.." || exit 2
ROOT="$(pwd)"
RAIL="$ROOT/rail_native"
SRC="rungs/r34/r34_economic_stake.rail"
GATE="rungs/r34/out/r34_gate.txt"
FRAUD="rungs/r34/out/r34_fraudproof.txt"

echo "== RUNG 34 validate =="
[ -x "$RAIL" ] || { echo "FAIL: rail_native not found/executable at $RAIL"; exit 2; }
mkdir -p rungs/r34/out

echo "-- [1/3] compile $SRC --"
rm -f /tmp/r34_out rungs/r34/out/r34
RAIL_ARENA_MB=2048 "$RAIL" --out-prefix rungs/r34/out/r34 "$SRC" 2> /tmp/r34_compile.err
BIN=""
for cand in rungs/r34/out/r34 rungs/r34/out/r34_out /tmp/r34 /tmp/r34_out /tmp/rail_out; do
  [ -x "$cand" ] && BIN="$cand" && break
done
if [ -z "$BIN" ]; then
  echo "FAIL: compile produced no executable. Compiler stderr:"; cat /tmp/r34_compile.err; exit 1
fi
echo "   compiled -> $BIN"

echo "-- [2/3] run the prover + spot-check verifier + slasher --"
RAIL_ARENA_MB=2048 "$BIN"
RC=$?
echo "   rail exit=$RC"
if [ $RC -ne 0 ]; then echo "FAIL: Rail run nonzero exit (a gate failed)"; [ -f "$GATE" ] && cat "$GATE"; exit 1; fi
if ! grep -q "^ALL 1$" "$GATE" 2>/dev/null; then
  echo "FAIL: $GATE missing 'ALL 1'"; [ -f "$GATE" ] && cat "$GATE"; exit 1
fi
echo "   Rail gate: ALL 1"

echo "-- [3/3] foreign cross-language re-verification --"
[ -f "$FRAUD" ] || { echo "FAIL: $FRAUD not emitted by the Rail run"; exit 1; }
python3 rungs/r34/r34_foreign_check.py "$FRAUD"
FRC=$?
if [ $FRC -ne 0 ]; then echo "FAIL: foreign verifier rejected"; exit 1; fi

echo ""
echo "== RUNG 34 GREEN: Rail economic-stake PASS (ALL 1) + foreign verifier R34-CHECK PASS =="
exit 0
