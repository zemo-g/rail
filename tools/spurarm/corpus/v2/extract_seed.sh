#!/bin/sh
# tools/spurarm/corpus/v2/extract_seed.sh
#
# v2 seed extractor. Regrades historical rerank completions at the
# default COMP_DIR (/tmp/robot_completions_rerank). Per SPEC §6, the
# v2 mix also pulls in post-Stage-7 reranks if a second extraction
# pool is present at $COMP_DIR_POST (defaults to
# /tmp/robot_completions_stage7_rerank). Both pools are graded; only
# stages_passed >= 3 survives. Source tag: "seed".
#
# Usage:
#   sh tools/spurarm/corpus/v2/extract_seed.sh <out_jsonl>

set -u
OUT="${1:?usage: extract_seed.sh <out_jsonl>}"
COMP_DIR="${COMP_DIR:-/tmp/robot_completions_rerank}"
COMP_DIR_POST="${COMP_DIR_POST:-/tmp/robot_completions_stage7_rerank}"
BENCH_FILE="${BENCH_FILE:-tools/robot/bench_v0.txt}"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required" >&2
  exit 2
fi

: > "$OUT"

grade_dir() {
  local dir="$1"
  local tag="$2"
  if [ ! -d "$dir" ]; then
    echo "extract_seed: pool $dir absent; skipping ($tag)" >&2
    return 0
  fi
  for f in "$dir"/b*_*.rail; do
    [ -e "$f" ] || break
    base=$(basename "$f" .rail)
    bid=$(printf '%s' "$base" | cut -d_ -f1)
    n=$(printf '%s' "$base" | cut -d_ -f2)
    row=$(grep -E "^${bid}\\|" "$BENCH_FILE" 2>/dev/null | head -1)
    if [ -z "$row" ]; then
      continue
    fi
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
      continue
    fi
    if [ "$obx" -lt 0 ] 2>/dev/null; then
      present=0
    else
      present=1
    fi
    script_text=$(cat "$f")
    script_text=$(printf '%s' "$script_text" | awk '
      BEGIN{in_code=0}
      /^```/ {in_code = 1 - in_code; next}
      {print}
    ')
    rec=$(jq -nc \
      --arg id "seed_${tag}:${bid}_${n}" \
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
  done
}

# Grade the historical pool.
grade_dir "$COMP_DIR" "v0"

# Grade any post-Stage-7 reranks if present.
grade_dir "$COMP_DIR_POST" "post7"

emitted=$(wc -l < "$OUT" | tr -d ' ')
printf 'extract_seed (v2): emitted=%d\n' "$emitted"
