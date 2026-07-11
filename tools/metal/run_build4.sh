#!/bin/bash
# Build 4 driver: sequential GPU arms (ONE Metal trainer at a time), chain-verify each,
# determinism cmp, then the pre-declared judge. No globs; no set -e (grep-status trap).
REPO="$HOME/projects/rail-mbstream"
TRIAL="$HOME/.ledatic/railml-trial"
CORPUS="$TRIAL/arith/arith_sum.bin"
BIN=/tmp/mbsig4
LOGD="$TRIAL/build4_logs"
mkdir -p "$LOGD"

run_arm () {
  arm="$1"; alr="$2"; sched="$3"; tag="$4"
  echo "=== ARM $tag start $(date '+%H:%M:%S') ==="
  if [ -n "$sched" ]; then
    MB_ARM="$arm" MB_ALR="$alr" MB_SCHED="$sched" MB_CORPUS="$CORPUS" MB_STEPS=74 RAIL_ARENA_MB=10500 "$BIN" > "$LOGD/$tag.log" 2>&1
  else
    MB_ARM="$arm" MB_ALR="$alr" MB_CORPUS="$CORPUS" MB_STEPS=74 RAIL_ARENA_MB=10500 "$BIN" > "$LOGD/$tag.log" 2>&1
  fi
  rc=$?
  if [ $rc -ne 0 ]; then echo "FATAL: arm $tag exit $rc"; tail -5 "$LOGD/$tag.log"; exit 1; fi
  if grep -q FATAL "$LOGD/$tag.log"; then echo "FATAL inside arm $tag"; tail -5 "$LOGD/$tag.log"; exit 1; fi
  python3 "$REPO/tools/metal/verify_segment_chain.py" "$TRIAL/attested_mbstream_${tag}_ledger.jsonl"
  if [ $? -ne 0 ]; then echo "FATAL: chain INVALID for $tag"; exit 1; fi
  grep "grand mean\|verdict" "$LOGD/$tag.log"
  echo "=== ARM $tag done $(date '+%H:%M:%S') ==="
}

run_arm B8 a0   ""    SIG75_B8_a0
run_arm B8 a1e4 wsd   SIG75_B8_a1e4_wsd
cp "$TRIAL/attested_mbstream_SIG75_B8_a1e4_wsd_ledger.jsonl" "$TRIAL/attested_mbstream_SIG75_B8_a1e4_wsd_ledger.run1.jsonl"
run_arm B8 a1e4 wsd   SIG75_B8_a1e4_wsd
if cmp -s "$TRIAL/attested_mbstream_SIG75_B8_a1e4_wsd_ledger.jsonl" "$TRIAL/attested_mbstream_SIG75_B8_a1e4_wsd_ledger.run1.jsonl"; then
  echo "GATE (d) DETERMINISM: byte-identical ledger PASS"
else
  echo "GATE (d) DETERMINISM: FAIL -- ledgers differ"
fi
run_arm B8 a1e4 ""    SIG75_B8_a1e4
run_arm B1 a1e4 ""    SIG75_B1_a1e4

echo "=== JUDGE ==="
python3 "$REPO/tools/metal/judge_build4.py" "$TRIAL" | tee "$TRIAL/build4_verdict.txt"
echo "=== BUILD4 DRIVER COMPLETE $(date '+%H:%M:%S') ==="
