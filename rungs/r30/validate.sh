#!/bin/bash
# =====================================================================================
# RUNG 30 -- Succinct Spot-Check of Training (Fiat-Shamir transcript)  ::  VALIDATE GATE
# =====================================================================================
# Runs serially (the orchestrator invokes this). Compiles the protocol core ONCE, runs it (light:
# scalar + SHA, no GPU, no lm10 training), then cross-verifies the emitted transcripts with the
# FOREIGN (Python) re-verifier. Green gate requires ALL of:
#   (1) Rail self-gate ALL=1  (honest spot-check verifies; sublinearity; both falsifiers caught)
#   (2) FOREIGN honest transcript fully reproduces + spot-check finds 0 mismatch  (exit 0)
#   (3) FOREIGN forged transcript is REJECTED (poison caught by challenge or full audit)  (exit 0)
#   (4) FALSIFY-THE-VALIDATOR: an honest transcript with one STATE line tampered MUST be rejected
#       by the foreign verifier under full audit (a meta-falsifier: the gate itself can fail).
#
# Exit 0 == PASS (green). Any non-zero == the gate is red, with the reason printed.
# Usage: bash rungs/r30/validate.sh        (run from the repo root /Users/ledaticempire/rail-reward)
# =====================================================================================
set -u
ROOT="/Users/ledaticempire/rail-reward"
cd "$ROOT" || { echo "FAIL: cannot cd $ROOT"; exit 2; }
OUT="rungs/r30/out"
mkdir -p "$OUT"
RAIL=./rail_native
PROTO=rungs/r30/r30_protocol.rail
FCHK=rungs/r30/r30_foreign_check.py
BIN="$OUT/r30"

say(){ echo "[r30] $*"; }
fail(){ echo "[r30] GATE RED: $*"; exit 1; }

# --- 1. compile the protocol core (light single-file compile; NOT a self-host) ---
say "compiling $PROTO ..."
"$RAIL" --out-prefix "$BIN" "$PROTO" > "$OUT/compile.log" 2>&1
grep -q "ld: OK" "$OUT/compile.log" || { cat "$OUT/compile.log"; fail "protocol did not compile (ld != OK)"; }
say "compiled OK -> $BIN"

# --- 2. run the Rail self-gate (emits transcripts + the machine-readable gate file) ---
say "running protocol (light: scalar + SHA, bounded arena) ..."
RAIL_ARENA_MB=2048 "$BIN" > "$OUT/run.log" 2>&1
RUN_RC=$?
[ "$RUN_RC" -eq 0 ] || { tail -20 "$OUT/run.log"; fail "protocol run exited $RUN_RC (expected 0)"; }
ALL=$(awk '/^ALL /{print $2}' "$OUT/r30_gate.txt")
say "rail self-gate ALL=$ALL"
[ "$ALL" = "1" ] || { cat "$OUT/r30_gate.txt"; fail "rail self-gate ALL != 1"; }
# spell out the sub-gates for the record
grep -E "^(honest_n1|honest_n2|sublinear|budget1|budget2|falsify_sampled|falsify_full_audit|clip_falsify) " "$OUT/r30_gate.txt"

# --- 3. FOREIGN cross-language verify: honest transcript must fully reproduce ---
say "foreign-verify HONEST transcript ..."
python3 "$FCHK" "$OUT/r30_transcript.txt" > "$OUT/foreign_honest.log" 2>&1
FH_RC=$?
tail -4 "$OUT/foreign_honest.log"
[ "$FH_RC" -eq 0 ] || fail "foreign verifier REJECTED the honest transcript (exit $FH_RC)"

# --- 4. FOREIGN cross-language verify: forged transcript must be rejected ---
say "foreign-verify FORGED transcript (expect detection) ..."
python3 "$FCHK" "$OUT/r30_transcript_forged.txt" > "$OUT/foreign_forged.log" 2>&1
FF_RC=$?
tail -4 "$OUT/foreign_forged.log"
[ "$FF_RC" -eq 0 ] || fail "foreign verifier did NOT catch the forged transcript (exit $FF_RC)"

# --- 5. META-FALSIFIER: tamper ONE state line of the HONEST transcript -> must be rejected ---
say "meta-falsifier: tamper one STATE line of the honest transcript ..."
TAMP="$OUT/r30_transcript_tampered.txt"
# bump the v-moment (column 5) of STATE 200 by 1; if the honest transcript still passes, the gate lies
awk 'BEGIN{done=0} /^STATE 200 /{$5=$5+1; done=1} {print} END{if(!done) exit 3}' \
  "$OUT/r30_transcript.txt" > "$TAMP" || fail "could not locate STATE 200 to tamper"
python3 "$FCHK" "$TAMP" > "$OUT/foreign_tampered.log" 2>&1
MT_RC=$?
tail -3 "$OUT/foreign_tampered.log"
# the tampered (honest-tagged, poison_at=-1) transcript should FAIL the honest verdict (exit 1)
[ "$MT_RC" -ne 0 ] || fail "META-FALSIFIER BREACH: tampered honest transcript was ACCEPTED -- gate is unsound"
say "meta-falsifier: tampered transcript correctly rejected (exit $MT_RC)"

echo ""
echo "============================================================================"
echo "[r30] GATE GREEN: succinct spot-check verified."
echo "[r30]   - Rail self-gate ALL=1 (honest verify + sublinearity + 2 falsifiers)"
echo "[r30]   - FOREIGN honest transcript reproduced bit-for-bit; spot-check 0 mismatch"
echo "[r30]   - FOREIGN forged transcript REJECTED (cheaper-than-retrain forgery caught)"
echo "[r30]   - META-falsifier: tampering an honest transcript is rejected (gate can fail)"
echo "============================================================================"
exit 0
