#!/bin/sh
# tools/robot/grade_all.sh
#
# Run the grader across all bench prompts using a directory of
# candidate completions. Defaults to the reference scripts at
# tools/robot/reference_scripts/ (one .rail file per id).
#
# Usage:
#   sh tools/robot/grade_all.sh [completion_dir]
#
# Emits one GRADE line per prompt to stdout, plus a TOTALS line at
# the end. Exit 0 always (grading is descriptive, not pass/fail).

set -u
DIR="${1:-tools/robot/reference_scripts}"

compile=0
parse=0
run=0
goal=0
total=0

for f in "$DIR"/b*.rail; do
  [ -f "$f" ] || continue
  id=$(basename "$f" .rail)
  line=$(./rail_native run tools/robot/grader.rail "$id" "$f" 2>/dev/null | grep -E "^GRADE " | head -1)
  echo "$line"
  total=$((total + 1))
  stage=$(echo "$line" | sed -n 's/.*stage=\([0-9]*\).*/\1/p')
  case "$stage" in
    1) compile=$((compile + 1)) ;;
    2) compile=$((compile + 1)); parse=$((parse + 1)) ;;
    3) compile=$((compile + 1)); parse=$((parse + 1)); run=$((run + 1)) ;;
    4) compile=$((compile + 1)); parse=$((parse + 1)); run=$((run + 1)); goal=$((goal + 1)) ;;
  esac
done

echo ""
echo "TOTALS: total=$total compile=$compile parse=$parse run=$run goal_reach=$goal"
