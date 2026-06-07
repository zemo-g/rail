#!/usr/bin/env bash
# RUNG 23 VALIDATE: Segmented Arena Training with Transparent Resume.
#
# Runs SERIALLY (the orchestrator invokes this; do NOT run concurrently with other heavy builds).
# Compute note: the lm10 transformer needs RAIL_ARENA_MB=8192. One build + one run of the oracle
# config (d=8/hidden=64/ctx=8/epochs=19, 4 segments) is the GREEN GATE. The scaled config + the
# rail_trace RSS measurement are OPTIONAL extended checks (gated behind R23_SCALED=1) because they
# are heavier; the core transparency+falsifier claim is fully decided by the oracle run.
#
# GREEN GATE = all of:
#   (1) rungs/r23/out/r23_bin builds clean (ld: OK)
#   (2) the run prints "PASS:" (okRT * okProg * okSegN * okHead * okBody * okSigs * okFalsify == 1)
#   (3) the foreign Python verifier prints "R23-CHECK PASS" on the segmented ledger
#
# Exit 0 iff the green gate holds.

set -u
cd "$(dirname "$0")/../.." || exit 2
ROOT="$(pwd)"
RN="$ROOT/rail_native"
ARENA="${RAIL_ARENA_MB:-8192}"
mkdir -p rungs/r23/out

echo "=================== RUNG 23 VALIDATE (root: $ROOT) ==================="
echo "[1/3] compile oracle config -> rungs/r23/out/r23_bin"
if ! "$RN" --out-prefix rungs/r23/out/r23_bin rungs/r23/r23_segmented_train.rail 2>&1 | tee rungs/r23/out/build.log | tail -3; then
  echo "R23 FAIL: compile error"; exit 1
fi
if [ ! -x rungs/r23/out/r23_bin ]; then
  echo "R23 FAIL: binary not produced (see rungs/r23/out/build.log)"; exit 1
fi

echo "[2/3] run (RAIL_ARENA_MB=$ARENA) -> segmented + one-shot ledgers"
RAIL_ARENA_MB="$ARENA" ./rungs/r23/out/r23_bin | tee rungs/r23/out/run.log
RUN_RC=${PIPESTATUS[0]}
if [ "$RUN_RC" -ne 0 ]; then
  echo "R23 FAIL: run exited $RUN_RC (the in-Rail gate did not all-pass)"; exit 1
fi
if ! grep -q "^PASS:" rungs/r23/out/run.log; then
  echo "R23 FAIL: run did not print PASS"; exit 1
fi

echo "[3/3] foreign cross-language re-verification of the SEGMENTED ledger"
if ! python3 rungs/r23/r23_foreign_check.py rungs/r23/out/r23_segmented_chain.txt | tee rungs/r23/out/foreign.log; then
  echo "R23 FAIL: foreign verifier rejected the segmented ledger"; exit 1
fi
if ! grep -q "R23-CHECK PASS" rungs/r23/out/foreign.log; then
  echo "R23 FAIL: foreign verifier did not print R23-CHECK PASS"; exit 1
fi

# ---- OPTIONAL extended scaling check (heavier; set R23_SCALED=1 to run) ----
if [ "${R23_SCALED:-0}" = "1" ]; then
  echo "[scaled] generating scaled config (hidden=256, epochs=120, 6 segments) from oracle source"
  sed -e 's/let hidden = 64 in/let hidden = 256 in/' \
      -e 's/let epochs = 19 in/let epochs = 120 in/' \
      -e 's/let seg_epochs = 5 in/let seg_epochs = 20 in/' \
      -e 's#"tools/bitexact/lm10_corpus.txt"#"rungs/r23/lm10_corpus_big.txt"#' \
      rungs/r23/r23_segmented_train.rail > rungs/r23/out/r23_scaled_gen.rail
  echo "[scaled] measure per-segment peak RSS via rail_trace (segmented run stays bounded)"
  RAIL_ARENA_MB="$ARENA" "$RN" run tools/trace/rail_trace.rail rungs/r23/out/r23_scaled_gen.rail \
    2>&1 | tee rungs/r23/out/scaled_trace.log | grep -i "rss\|peak\|PASS\|FAIL" || true
  echo "[scaled] note: a one-shot run of this config under a TIGHT arena (RAIL_ARENA_MB=2048) is the"
  echo "[scaled] does-not-fit witness; the segmented path survives because it arena_resets per segment."
fi

echo "=================== RUNG 23: GREEN GATE PASS ==================="
exit 0
