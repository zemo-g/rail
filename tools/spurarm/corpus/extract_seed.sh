#!/bin/sh
# tools/spurarm/corpus/extract_seed.sh
#
# Harvest the 400 prior-session rerank completions at
# /tmp/robot_completions_rerank/b<id>_<n>.rail into a JSONL stream.
# Each (id, n) is graded; pairs with stages_passed >= 3 are emitted.
#
# NOTE: these are bench prompts -- the resulting pairs MUST be tagged
# source=seed and the eval-split logic must reject them via the
# leakage check.
#
# Usage:
#   sh tools/spurarm/corpus/extract_seed.sh <out_jsonl>

set -u
OUT="${1:?usage: extract_seed.sh <out_jsonl>}"
COMP_DIR="${COMP_DIR:-/tmp/robot_completions_rerank}"
BENCH_FILE="tools/robot/bench_v0.txt"

if [ ! -d "$COMP_DIR" ]; then
  echo "ERROR: no completion dir at $COMP_DIR (this is the 400 prior reranks). Skipping seed source." >&2
  : > "$OUT"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required" >&2
  exit 2
fi

: > "$OUT"

emitted=0
skipped=0
total=0
for f in "$COMP_DIR"/b*_*.rail; do
  [ -e "$f" ] || break
  total=$((total + 1))
  base=$(basename "$f" .rail)
  bid=$(printf '%s' "$base" | cut -d_ -f1)
  n=$(printf '%s' "$base" | cut -d_ -f2)
  # Look up bench row.
  row=$(grep -E "^${bid}\\|" "$BENCH_FILE" 2>/dev/null | head -1)
  if [ -z "$row" ]; then skipped=$((skipped + 1)); continue; fi
  nl=$(printf '%s' "$row" | cut -d'|' -f2)
  obx=$(printf '%s' "$row" | cut -d'|' -f3)
  oby=$(printf '%s' "$row" | cut -d'|' -f4)
  obz=$(printf '%s' "$row" | cut -d'|' -f5)
  gex=$(printf '%s' "$row" | cut -d'|' -f6)
  gey=$(printf '%s' "$row" | cut -d'|' -f7)
  gez=$(printf '%s' "$row" | cut -d'|' -f8)
  ggrip=$(printf '%s' "$row" | cut -d'|' -f9)
  gheld=$(printf '%s' "$row" | cut -d'|' -f10)
  rm -f /tmp/rail_out /tmp/robot_sim_out.txt 2>/dev/null
  grade=$(./rail_native run tools/robot/grader.rail "$bid" "$f" 2>/dev/null | grep '^GRADE ' | head -1)
  st=$(printf '%s' "$grade" | sed -n 's/.*stage=\([0-9]*\).*/\1/p')
  st=${st:-0}
  if [ "$st" -lt 3 ]; then
    skipped=$((skipped + 1))
    continue
  fi
  # Determine present from world.
  if [ "$obx" -lt 0 ] 2>/dev/null; then
    present=0
  else
    present=1
  fi
  script_text=$(cat "$f")
  # Strip optional markdown fences (same logic as grader's strip_fences,
  # but cheaper here).
  script_text=$(printf '%s' "$script_text" | awk '
    BEGIN{in_code=0}
    /^```/ {in_code = 1 - in_code; next}
    {print}
  ')
  # JSON-escape with jq.
  rec=$(jq -nc \
    --arg id "seed:${bid}_${n}" \
    --arg nl "$nl" \
    --arg script "$script_text" \
    --argjson obx "$obx" \
    --argjson oby "$oby" \
    --argjson obz "$obz" \
    --argjson present "$present" \
    --argjson gex "$gex" \
    --argjson gey "$gey" \
    --argjson gez "$gez" \
    --argjson ggrip "$ggrip" \
    --argjson gheld "$gheld" \
    --argjson st "$st" \
    '{id: $id, nl: $nl, script: $script,
      world: {obx: $obx, oby: $oby, obz: $obz, present: $present},
      expected: {gex: $gex, gey: $gey, gez: $gez, ggrip: $ggrip, gheld: $gheld},
      source: "seed", stages_passed: $st}')
  printf '%s\n' "$rec" >> "$OUT"
  emitted=$((emitted + 1))
done

printf 'extract_seed: total=%d emitted=%d skipped=%d\n' "$total" "$emitted" "$skipped"
