#!/bin/sh
# tools/robot/baseline_rerank.sh
#
# N=20 rerank substrate baseline. For each bench prompt, fires N
# parallel substrate calls with varied seeds, grades each, takes the
# MAX stage as the prompt's score (per-prompt max-pass routing, same
# pattern as substrate_30_of_30_2026-05-09).
#
# Output shape matches baseline_run.sh: per-prompt MAXGRADE line +
# TOTALS + lab-chain sentinel block.
#
# Usage:
#   sh tools/robot/baseline_rerank.sh [bench_file]
# Env:
#   N (default 20)        — reranks per prompt
#   PORT (default 8082)
#   TEMPERATURE (default 0.7) — higher than single-shot, more diverse
#   ENABLE_THINKING (default false)

set -u
BENCH="${1:-tools/robot/bench_v0.txt}"
SPEC="tools/robot/dsl_spec.txt"
COMP_DIR="/tmp/robot_completions_rerank"

export PORT="${PORT:-8082}"
export N="${N:-20}"
export TEMPERATURE="${TEMPERATURE:-0.9}"
export MAX_TOKENS="${MAX_TOKENS:-1024}"
export ENABLE_THINKING="${ENABLE_THINKING:-false}"
# Concurrent calls per batch. N=20 simultaneously OOMs Metal on the
# 2.34-bit 122B model (Insufficient Memory in command buffer). 4 is
# the empirically-tested safe level.
BATCH="${BATCH:-4}"

mkdir -p "$COMP_DIR"

if ! curl -sS --max-time 3 "http://localhost:$PORT/v1/models" 2>/dev/null | grep -q '"id"'; then
  echo "ERROR: no substrate at localhost:$PORT" >&2
  exit 2
fi

total=0
compile=0
parse=0
run=0
goal=0

# Per-prompt: fire N substrate calls (parallel), grade each, take max stage.
process_prompt() {
  id="$1"
  prompt="$2"
  best_stage=0
  best_line=""

  # Fire N substrate calls in batches of BATCH (to avoid Metal OOM).
  i=1
  while [ "$i" -le "$N" ]; do
    end=$((i + BATCH - 1))
    [ "$end" -gt "$N" ] && end="$N"
    for j in $(seq "$i" "$end"); do
      out_path="$COMP_DIR/${id}_${j}.rail"
      (sh tools/robot/call_substrate.sh "$SPEC" "$prompt" > "$out_path") &
    done
    wait
    i=$((end + 1))
  done

  # Grade each (sequential — rail_native isn't parallel-safe on /tmp/rail_out)
  for i in $(seq 1 "$N"); do
    cp="$COMP_DIR/${id}_${i}.rail"
    [ -s "$cp" ] || continue
    rm -f /tmp/rail_out /tmp/robot_sim_out.txt
    gl=$(./rail_native run tools/robot/grader.rail "$id" "$cp" 2>/dev/null | grep '^GRADE ' | head -1)
    [ -z "$gl" ] && continue
    st=$(printf '%s\n' "$gl" | sed -n 's/.*stage=\([0-9]*\).*/\1/p')
    if [ "${st:-0}" -gt "$best_stage" ]; then
      best_stage=$st
      best_line=$gl
    fi
  done

  if [ -z "$best_line" ]; then
    best_line="MAXGRADE id=$id stage=0 goal_reach=0 fault=-2 sim_line=all_n_failed"
  else
    best_line=$(printf '%s\n' "$best_line" | sed 's/^GRADE /MAXGRADE /')
  fi
  echo "$best_line"

  total=$((total + 1))
  case "$best_stage" in
    1) compile=$((compile + 1)) ;;
    2) compile=$((compile + 1)); parse=$((parse + 1)) ;;
    3) compile=$((compile + 1)); parse=$((parse + 1)); run=$((run + 1)) ;;
    4) compile=$((compile + 1)); parse=$((parse + 1)); run=$((run + 1)); goal=$((goal + 1)) ;;
  esac
}

while IFS= read -r line; do
  case "$line" in
    ''|'#'*) continue ;;
  esac
  id=$(printf '%s\n' "$line" | cut -d'|' -f1)
  prompt=$(printf '%s\n' "$line" | cut -d'|' -f2)
  process_prompt "$id" "$prompt"
done < "$BENCH"

echo ""
echo "TOTALS: total=$total compile=$compile parse=$parse run=$run goal_reach=$goal n_rerank=$N"
echo "===RAIL_LAB_COUNTERS==="
echo "{\"counter\": \"bench_size\", \"value\": $total}"
echo "{\"counter\": \"substrate_compile_count\", \"value\": $compile}"
echo "{\"counter\": \"substrate_parse_count\", \"value\": $parse}"
echo "{\"counter\": \"substrate_run_count\", \"value\": $run}"
echo "{\"counter\": \"substrate_goal_reach_count\", \"value\": $goal}"
echo "{\"counter\": \"n_rerank\", \"value\": $N}"
echo "===END==="
verdict="FALSIFIED"
if [ "$goal" -ge 10 ]; then verdict="PASS"
elif [ "$goal" -ge 5 ]; then verdict="INCONCLUSIVE"
fi
echo "===VERDICT=== $verdict"
