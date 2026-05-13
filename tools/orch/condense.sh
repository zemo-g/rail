#!/bin/bash
# condense.sh — per-prompt max-pass ensemble across all benched arms.
#
# Parses each runs/<arm>/bench.log to recover per-prompt pass/fail, then
# OR-aggregates across arms for the honest project SOTA ("ensemble" or
# "condensed candidate" per the blob/slice/fan/condense methodology).
#
# bench_strip.rail emits, per task:
#   ── <Band> ──
#     → task [<idx-within-band>] <prompt>
#         OK | EXEC-MATCH | partial | fail   best-quality=...
#
# Bands are: Fundamentals, Practical IO, Real Tools, Compiler, Advanced, Comprehend.
# Global prompt index = band_idx * 5 + within-band-idx.
#
# OK and EXEC-MATCH count as pass; partial and fail do not.
#
# Output: ENSEMBLE.md with the condensed score, per-prompt vector, contributing arms.
#
# Usage: tools/orch/condense.sh [--include-historical]

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$REPO_ROOT"

OUT=ENSEMBLE.md
TMP=$(mktemp -d)

# ── Per-arm parse: produces 30-char string of 0/1, written to $TMP/<arm>.vec
parse_arm_log() {
  local arm=$1 log=$2
  local out=$TMP/$arm.vec
  awk -v out="$out" '
    BEGIN {
      band_map["Fundamentals"]=0; band_map["Practical IO"]=1
      band_map["Real Tools"]=2;   band_map["Compiler"]=3
      band_map["Advanced"]=4;     band_map["Comprehend"]=5
      for (i=0; i<30; i++) vec[i]="0"
      cur_band=-1; pending_idx=-1
    }
    /^── / {
      band_name=$0; sub(/^── */, "", band_name); sub(/ ──.*/, "", band_name)
      if (band_name in band_map) cur_band=band_map[band_name]
      else cur_band=-1
      pending_idx=-1
      next
    }
    /^  → task \[/ {
      match($0, /\[[0-9]+\]/)
      if (RSTART > 0) {
        s=substr($0, RSTART+1, RLENGTH-2)
        pending_idx=int(s)
      }
      next
    }
    /^    (OK|EXEC-MATCH|partial|fail) / {
      mark=$1
      if (cur_band >= 0 && pending_idx >= 0 && pending_idx < 5) {
        global_idx = cur_band * 5 + pending_idx
        if (mark == "OK" || mark == "EXEC-MATCH") vec[global_idx]="1"
      }
      pending_idx=-1
      next
    }
    END {
      s=""
      for (i=0; i<30; i++) s=s vec[i]
      print s > out
    }
  ' "$log"
}

# ── Collect all arms with bench.log
ARMS=()
for run_dir in runs/*/; do
  arm=$(basename "$run_dir")
  log=$run_dir/bench.log
  if [ -f "$log" ] && [ -s "$log" ]; then
    parse_arm_log "$arm" "$log"
    ARMS+=("$arm")
  fi
done

# ── OR-aggregate
ENSEMBLE=$(mktemp)
echo "000000000000000000000000000000" > "$ENSEMBLE"  # 30 zeros
for arm in "${ARMS[@]:-}"; do
  [ -n "$arm" ] || continue
  vec=$(cat "$TMP/$arm.vec")
  cur=$(cat "$ENSEMBLE")
  new=""
  for i in $(seq 0 29); do
    a=${cur:$i:1}; b=${vec:$i:1}
    if [ "$a" = "1" ] || [ "$b" = "1" ]; then new="${new}1"; else new="${new}0"; fi
  done
  echo "$new" > "$ENSEMBLE"
done
ENSEMBLE_VEC=$(cat "$ENSEMBLE")
ENSEMBLE_PASS=$(echo "$ENSEMBLE_VEC" | tr -cd '1' | wc -c | tr -d ' ')

# ── Per-band breakdown of ensemble
band_pass() {
  local start=$1
  local count=0
  for i in $(seq "$start" $((start + 4))); do
    [ "${ENSEMBLE_VEC:$i:1}" = "1" ] && count=$((count + 1))
  done
  echo "$count/5"
}

# ── Per-arm bench_pass for the table
arm_bench_pass() {
  local arm=$1
  local br=runs/$arm/bench_result.meta
  if [ -f "$br" ]; then
    grep "^bench_pass=" "$br" | head -1 | cut -d= -f2-
  else
    echo "-"
  fi
}

# ── Render ENSEMBLE.md
{
  echo "# ENSEMBLE.md"
  echo ""
  echo "Per-prompt max-pass ensemble across all benched orchestrator arms."
  echo "This is the **honest project SOTA** — single-best ckpts undercount because"
  echo "different recipes/seeds cover different bench prompts."
  echo ""
  echo "**Ensemble pass: $ENSEMBLE_PASS/30** across ${#ARMS[@]:-0} contributing arm(s)."
  echo ""
  echo "## Per-band breakdown"
  echo ""
  echo "| Band | Pass |"
  echo "|------|:----:|"
  echo "| Fundamentals | $(band_pass 0)  |"
  echo "| Practical IO | $(band_pass 5)  |"
  echo "| Real Tools   | $(band_pass 10) |"
  echo "| Compiler     | $(band_pass 15) |"
  echo "| Advanced     | $(band_pass 20) |"
  echo "| Comprehend   | $(band_pass 25) |"
  echo ""
  echo "## Per-prompt vector"
  echo ""
  echo "Indices 0-29 (rows of 5 = bands):"
  echo ""
  echo "\`\`\`"
  echo "Fundamentals: ${ENSEMBLE_VEC:0:5}"
  echo "Practical IO: ${ENSEMBLE_VEC:5:5}"
  echo "Real Tools:   ${ENSEMBLE_VEC:10:5}"
  echo "Compiler:     ${ENSEMBLE_VEC:15:5}"
  echo "Advanced:     ${ENSEMBLE_VEC:20:5}"
  echo "Comprehend:   ${ENSEMBLE_VEC:25:5}"
  echo "\`\`\`"
  echo ""
  echo "## Contributing arms"
  echo ""
  echo "| Arm | Single-best | Per-prompt vector |"
  echo "|-----|:-----------:|:-----------------:|"
  for arm in "${ARMS[@]:-}"; do
    [ -n "$arm" ] || continue
    vec=$(cat "$TMP/$arm.vec")
    bp=$(arm_bench_pass "$arm")
    echo "| \`$arm\` | $bp | \`$vec\` |"
  done
  echo ""
  echo "Generated $(date +%Y-%m-%dT%H:%M:%S%z) by tools/orch/condense.sh."
} > "$OUT"

rm -rf "$TMP" "$ENSEMBLE"

echo "wrote $OUT (ensemble=$ENSEMBLE_PASS/30 across ${#ARMS[@]:-0} arms)"
exit 0
