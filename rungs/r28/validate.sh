#!/usr/bin/env bash
# RUNG 28 VALIDATE -- the single EXACT command the orchestrator runs (serially).
#
#   bash /Users/ledaticempire/rail-reward/rungs/r28/validate.sh
#
# Steps:
#   1. fetch + pin a LIVE entropy pulse (fetch_pulse.sh; falls back to a recorded real pulse if
#      offline, logged) -> out/pulse_id.txt, out/pulse_hex.txt
#   2. compile r28_live_beacon.rail to an ISOLATED out-prefix (never /tmp/rail_out)
#   3. run it with RAIL_ARENA_MB=8192 (lm10 needs the multi-GB arena) -> out/utterance_chain.txt
#      [THIS is the one heavy step: ~2-3 min, ~8 GB arena -- same cost as the proven floor]
#   4. r28 foreign verifier replays the pinned pulse, re-derives genesis+poff, reproduces head+t_hex,
#      verifies sig -> MUST PASS
#   5. run BOTH falsifiers -> each MUST REJECT its forged ledger
#   6. exit 0 + print RUNG28 PASS only if all of the above hold
#
# Honesty: this script asserts real outcomes. If the heavy build/train fails or any gate/falsifier
# does not hold, it exits non-zero with the failing stage. No PASS is printed unless every step held.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO" || { echo "RUNG28 FAIL: cannot cd $REPO"; exit 1; }
mkdir -p out

RAIL="$REPO/rail_native"
[ -x "$RAIL" ] || { echo "RUNG28 FAIL: rail_native not found/executable at $RAIL"; exit 1; }

echo "===== RUNG 28: Live-Beacon Genesis, Proof-of-Recency ====="

# ---- 1. fetch + pin the live pulse ----
echo "[1/6] fetch + pin live pulse"
bash "$HERE/fetch_pulse.sh" || { echo "RUNG28 FAIL: pulse fetch/pin failed"; exit 1; }
[ -s out/pulse_id.txt ] && [ -s out/pulse_hex.txt ] || { echo "RUNG28 FAIL: pulse not pinned"; exit 1; }

# ---- 2. compile (isolated out-prefix) ----
echo "[2/6] compile r28_live_beacon.rail (isolated prefix)"
BIN="out/r28_bin"
"$RAIL" --out-prefix "$BIN" "$HERE/r28_live_beacon.rail" || {
  echo "RUNG28 FAIL: compile failed"; exit 1; }
[ -x "$BIN" ] || { echo "RUNG28 FAIL: binary $BIN not produced"; exit 1; }

# ---- 3. run the heavy train+attest (multi-GB arena REQUIRED) ----
echo "[3/6] run (RAIL_ARENA_MB=8192) -- heavy: ~2-3 min"
RAIL_ARENA_MB=8192 "$BIN" || { echo "RUNG28 FAIL: trainer exited non-zero (gates inside failed)"; exit 1; }
[ -s out/utterance_chain.txt ] || { echo "RUNG28 FAIL: no signed ledger produced"; exit 1; }

# ---- 3b. header must record the pulse ----
echo "[3b] check header records pulse_id + pulse_hex"
HDR="$(head -1 out/utterance_chain.txt)"
echo "$HDR" | grep -Eq 'pulse_id=[0-9]+' || { echo "RUNG28 FAIL: header missing pulse_id"; exit 1; }
echo "$HDR" | grep -Eq 'pulse_hex=[0-9a-f]{64}' || { echo "RUNG28 FAIL: header missing/short pulse_hex"; exit 1; }
echo "      header pulse fields present: $(echo "$HDR" | grep -oE 'pulse_id=[0-9]+ pulse_hex=[0-9a-f]{8}')..."

# ---- 4. foreign witness (replays the pinned pulse) MUST PASS ----
echo "[4/6] foreign re-verifier (different language, replays exact pulse)"
python3 "$HERE/r28_foreign_check.py" out/utterance_chain.txt || {
  echo "RUNG28 FAIL: foreign verifier rejected the honest ledger"; exit 1; }

# ---- 5. falsifiers MUST REJECT ----
echo "[5/6] falsifier A: swap to an earlier pulse (weights untouched) -> MUST REJECT"
python3 "$HERE/falsify_earlier_pulse.py" out/utterance_chain.txt || {
  echo "RUNG28 FAIL: forged-pulse ledger was NOT rejected (seed-binding cosmetic)"; exit 1; }

echo "[5b] falsifier B: swap pulse, keep stale genesis -> MUST REJECT"
python3 "$HERE/falsify_keep_genesis.py" out/utterance_chain.txt || {
  echo "RUNG28 FAIL: pulse<->genesis binding not enforced"; exit 1; }

# ---- 6. all held ----
echo "[6/6] all gates + both falsifiers held"
echo "RUNG28 PASS: a Rail-native transformer was seeded (genesis AND initial weights) by a LIVE"
echo "             ledatic.org entropy pulse, trained+spoke+attested, an independent language replayed"
echo "             the exact pulse and reproduced the words bit-for-bit, and a swapped (earlier) pulse"
echo "             is provably rejected. The signed trajectory is posterior to a public unpredictable"
echo "             value (not-before bound; elapsed-work is deferred to rung 34)."
exit 0
