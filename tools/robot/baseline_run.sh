#!/bin/sh
# tools/robot/baseline_run.sh
#
# Substrate baseline run. Walks every non-comment row in
# tools/robot/bench_v0.txt, calls substrate via call_substrate.sh,
# writes each completion to /tmp/robot_completions/<id>.rail, grades
# via tools/robot/grader.rail, and emits per-prompt GRADE lines plus
# a TOTALS + lab-chain sentinel block at the end.
#
# This replaces tools/robot/substrate_driver.rail (which depended on
# stdlib/llm.rail's broken escape pipeline).
#
# Usage:
#   sh tools/robot/baseline_run.sh [bench_file]
# Env:
#   PORT (default 8082)
#   MAX_TOKENS (default 1024)
#   TEMPERATURE (default 0.3)
#   ENABLE_THINKING (default false)
#
# Output: per-prompt GRADE line + TOTALS line + chain-sentinel block.

set -u
BENCH="${1:-tools/robot/bench_v0.txt}"
SPEC="tools/robot/dsl_spec.txt"
COMP_DIR="/tmp/robot_completions"

export PORT="${PORT:-8082}"
export MAX_TOKENS="${MAX_TOKENS:-1024}"
export TEMPERATURE="${TEMPERATURE:-0.3}"
export ENABLE_THINKING="${ENABLE_THINKING:-false}"

mkdir -p "$COMP_DIR"

# Health-check the endpoint up front.
if ! curl -sS --max-time 3 "http://localhost:$PORT/v1/models" 2>/dev/null | grep -q '"id"'; then
  echo "ERROR: no substrate at localhost:$PORT" >&2
  exit 2
fi

total=0
compile=0
parse=0
run=0
goal=0

while IFS= read -r line; do
  # skip comments and blanks
  case "$line" in
    ''|'#'*) continue ;;
  esac

  id=$(printf '%s\n' "$line" | cut -d'|' -f1)
  prompt=$(printf '%s\n' "$line" | cut -d'|' -f2)

  comp_path="$COMP_DIR/$id.rail"
  sh tools/robot/call_substrate.sh "$SPEC" "$prompt" > "$comp_path"

  # Clear stale outputs and grade.
  rm -f /tmp/rail_out /tmp/robot_sim_out.txt
  grade_line=$(./rail_native run tools/robot/grader.rail "$id" "$comp_path" 2>/dev/null | grep '^GRADE ' | head -1)
  echo "$grade_line"

  total=$((total + 1))
  stage=$(printf '%s\n' "$grade_line" | sed -n 's/.*stage=\([0-9]*\).*/\1/p')
  case "$stage" in
    1) compile=$((compile + 1)) ;;
    2) compile=$((compile + 1)); parse=$((parse + 1)) ;;
    3) compile=$((compile + 1)); parse=$((parse + 1)); run=$((run + 1)) ;;
    4) compile=$((compile + 1)); parse=$((parse + 1)); run=$((run + 1)); goal=$((goal + 1)) ;;
  esac
done < "$BENCH"

echo ""
echo "TOTALS: total=$total compile=$compile parse=$parse run=$run goal_reach=$goal"
echo "===RAIL_LAB_COUNTERS==="
echo "{\"counter\": \"bench_size\", \"value\": $total}"
echo "{\"counter\": \"substrate_compile_count\", \"value\": $compile}"
echo "{\"counter\": \"substrate_parse_count\", \"value\": $parse}"
echo "{\"counter\": \"substrate_run_count\", \"value\": $run}"
echo "{\"counter\": \"substrate_goal_reach_count\", \"value\": $goal}"
echo "===END==="
verdict="FALSIFIED"
if [ "$goal" -ge 10 ]; then verdict="PASS"
elif [ "$goal" -ge 5 ]; then verdict="INCONCLUSIVE"
fi
echo "===VERDICT=== $verdict"
