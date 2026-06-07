#!/usr/bin/env bash
# RUNG 36 VALIDATE -- the single EXACT command the orchestrator runs (serially).
#
#   bash /Users/ledaticempire/rail-reward/rungs/r36/validate.sh
#
# Bounded Recursive Self-Improvement under a frozen, future-pulse-seeded, non-self-relaxing gate.
# Composes rung 28 (future live-beacon pulse, unforeseeable-in-advance) + rung 30 (succinct
# Fiat-Shamir spot-check of a training trajectory) into an RSI admission rule.
#
# Steps:
#   1. fetch + pin the pulse sequence (commit < future < future2); offline -> recorded fixtures (logged)
#   2. compile r36_rsi_protocol.rail to an ISOLATED out-prefix (never /tmp/rail_out)
#   3. run it (RAIL_ARENA_MB=2048 -- LIGHT: exact-int Adam cells, N<=1024, seconds not minutes; this
#      is the r30-precedent protocol core, NOT the heavy 8GB lm10 transformer path -- see IMPL.md)
#      -> writes the signed RSI ledger + gate transcript; exits 0 only if every internal gate held
#   4. foreign re-verifier (different language) re-derives the WHOLE admission chain from the signed
#      ledger -- frozen gate sig, future-pulse margins, per-generation succinct spot-check, monotone
#      held-out improvement, bounded counter, all four signatures -> MUST PASS
#   5. ledger falsifiers (proxy-gaming, gate-relaxation, runaway, replay, sig-tamper) -> each MUST REJECT
#   6. exit 0 + print RUNG36 PASS only if all of the above hold
#
# Honesty: this script asserts real outcomes. No PASS is printed unless every step held.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO" || { echo "RUNG36 FAIL: cannot cd $REPO"; exit 1; }
mkdir -p rungs/r36/out

RAIL="$REPO/rail_native"
[ -x "$RAIL" ] || { echo "RUNG36 FAIL: rail_native not found/executable at $RAIL"; exit 1; }

echo "===== RUNG 36: Bounded Recursive Self-Improvement (frozen, future-pulse, non-self-relaxing gate) ====="

# ---- 1. fetch + pin the pulse sequence ----
echo "[1/6] fetch + pin pulse sequence (commit < future < future2)"
bash "$HERE/fetch_pulses.sh" || { echo "RUNG36 FAIL: pulse fetch/pin failed"; exit 1; }
for f in commit_pulse_id m0_pulse_hex future_pulse_id future_pulse_hex future_pulse_hex2; do
  [ -s "rungs/r36/out/$f.txt" ] || { echo "RUNG36 FAIL: pulse $f not pinned"; exit 1; }
done

# ---- 2. compile (isolated out-prefix) ----
echo "[2/6] compile r36_rsi_protocol.rail (isolated prefix)"
BIN="rungs/r36/out/r36"
"$RAIL" --out-prefix "$BIN" "$HERE/r36_rsi_protocol.rail" || { echo "RUNG36 FAIL: compile failed"; exit 1; }
[ -x "$BIN" ] || { echo "RUNG36 FAIL: binary $BIN not produced"; exit 1; }

# ---- 3. run the protocol (LIGHT) ----
echo "[3/6] run the RSI protocol (RAIL_ARENA_MB=2048) -- light, seconds"
RAIL_ARENA_MB=2048 "$BIN" || { echo "RUNG36 FAIL: protocol exited non-zero (an internal gate failed)"; exit 1; }
[ -s rungs/r36/out/r36_chain.txt ] || { echo "RUNG36 FAIL: no signed RSI ledger produced"; exit 1; }

# ---- 3b. the in-process gate transcript must report ALL 1 ----
echo "[3b] check in-process gate transcript"
grep -Eq '^ALL 1$' rungs/r36/out/r36_gate.txt || { echo "RUNG36 FAIL: in-process gate transcript not ALL 1"; exit 1; }
HDR="$(head -1 rungs/r36/out/r36_chain.txt)"
echo "$HDR" | grep -Eq 'future_pulse_id=[0-9]+' || { echo "RUNG36 FAIL: ledger header missing future_pulse_id"; exit 1; }
echo "$HDR" | grep -Eq 'commit_pulse_id=[0-9]+' || { echo "RUNG36 FAIL: ledger header missing commit_pulse_id"; exit 1; }

# ---- 4. foreign witness (different language) MUST PASS ----
echo "[4/6] foreign re-verifier (different language, from the signed ledger only)"
python3 "$HERE/r36_foreign_check.py" rungs/r36/out/r36_chain.txt || {
  echo "RUNG36 FAIL: foreign verifier rejected the honest RSI ledger"; exit 1; }

# ---- 5. ledger falsifiers MUST each REJECT ----
echo "[5/6] ledger falsifiers (proxy-gaming / gate-relaxation / runaway / replay / sig-tamper)"
python3 "$HERE/falsify_ledger.py" rungs/r36/out/r36_chain.txt || {
  echo "RUNG36 FAIL: a forged ledger was accepted (a protection is cosmetic)"; exit 1; }

# ---- 6. all held ----
echo "[6/6] all gates + foreign re-derivation + all falsifiers held"
echo "RUNG36 PASS: a 3-generation chain where each admitted successor carries a certificate -- recomputed"
echo "            bit-for-bit by a Rail self-witness AND an independent foreign verifier -- proving it"
echo "            (i) strictly beats its parent on a future-pulse-seeded held-out metric it could not"
echo "            foresee, (ii) under a frozen M0-committed bar it cannot relax, (iii) with a rung-30"
echo "            succinct (verify<<train) spot-check of its trajectory, (iv) a bounded monotone counter"
echo "            and chain-prev. Proxy-gaming, gate-relaxation, runaway, replay, and forged-trajectory"
echo "            successors are all rejected."
exit 0
