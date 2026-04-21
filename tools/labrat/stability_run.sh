#!/usr/bin/env bash
# stability_run.sh — run labrat N times on the same fp16 task, log
# success rate. Each run starts from a fresh seed.metal copy.
#
# Usage: ./tools/labrat/stability_run.sh [N]   (default N=10)
#
# Outputs:
#   /tmp/labrat_stability.log       — full per-run output
#   /tmp/labrat_stability_summary   — one-line summary (success rate, mean speedup)

set -eu

N="${1:-10}"
LABRAT_BIN="${LABRAT_BIN:-/tmp/labrat_bin}"
SPEC="${SPEC:-/tmp/labrat_test/fp16_spec.json}"
SEED_ORIG="${SEED_ORIG:-/tmp/labrat_test/seed.metal.orig}"
SEED_LIVE="${SEED_LIVE:-/tmp/labrat_test/seed.metal}"
LOG="/tmp/labrat_stability.log"
SUMMARY="/tmp/labrat_stability_summary"

[ -x "$LABRAT_BIN" ] || { echo "missing $LABRAT_BIN"; exit 1; }
[ -f "$SPEC" ] || { echo "missing $SPEC"; exit 1; }
[ -f "$SEED_ORIG" ] || { echo "missing $SEED_ORIG"; exit 1; }

: > "$LOG"
echo "stability_run start: $(date)" | tee -a "$LOG"
echo "  N=$N  spec=$SPEC" | tee -a "$LOG"
echo "" | tee -a "$LOG"

KEPT=0
ROLLED=0
SPEEDUPS=""

for i in $(seq 1 "$N"); do
  cp "$SEED_ORIG" "$SEED_LIVE"
  echo "=== run $i / $N at $(date '+%H:%M:%S') ===" | tee -a "$LOG"
  OUT=$(LABRAT_SPEC="$SPEC" "$LABRAT_BIN" 2>&1)
  echo "$OUT" | tee -a "$LOG"

  if echo "$OUT" | grep -q "iter [0-9]*: KEEP"; then
    SPEEDUP=$(echo "$OUT" | grep -oE "speedup=[0-9.]+" | head -1 | cut -d= -f2)
    KEPT=$((KEPT + 1))
    SPEEDUPS="$SPEEDUPS $SPEEDUP"
    echo "  -> KEPT speedup=$SPEEDUP" | tee -a "$LOG"
  else
    ROLLED=$((ROLLED + 1))
    echo "  -> ROLLBACK (no successful iter)" | tee -a "$LOG"
  fi
  echo "" | tee -a "$LOG"
done

MEAN=$(echo "$SPEEDUPS" | awk '{
  s = 0; n = 0;
  for (i = 1; i <= NF; i++) { s += $i; n++; }
  if (n > 0) printf "%.2f", s/n; else printf "0.00";
}')

{
  echo "stability_run end: $(date)"
  echo "  N=$N  kept=$KEPT  rolled=$ROLLED  success_rate=$(awk -v k=$KEPT -v n=$N 'BEGIN{printf "%.0f%%", 100*k/n}')"
  echo "  mean_speedup_when_kept=$MEAN"
} | tee "$SUMMARY" | tee -a "$LOG"
