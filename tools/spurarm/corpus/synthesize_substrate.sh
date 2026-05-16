#!/bin/sh
# tools/spurarm/corpus/synthesize_substrate.sh
#
# Substrate-driven NL-paraphrase augmentation. Takes a SEED JSONL,
# samples records, asks the 122B substrate to rephrase each NL in N
# distinct ways, and emits new pairs (substrate-paraphrased NL,
# original script). The script is unchanged so it still passes the
# grader at its original stage.
#
# Why this and not full substrate-from-scratch synthesis: substrate
# inference is ~30 s/call; at BATCH=4 (Metal OOM cap, see memory entry
# robot_arm_flywheel_2026-05-16), generating 5k de-novo scripts would
# eat most of the 12 h budget. Paraphrasing existing seed scripts gives
# us substrate diversity on the NL side at a fraction of the cost --
# every emitted script is already a known-stage-3+ behavior.
#
# Output: JSONL records tagged source=substrate, stages_passed copied
# from the seed (>= 3).
#
# Usage:
#   sh tools/spurarm/corpus/synthesize_substrate.sh <seed_jsonl> <out_jsonl> [N_per_seed] [MAX_SEEDS]

set -u
SEED="${1:?usage: synthesize_substrate.sh <seed_jsonl> <out_jsonl> [N] [MAX]}"
OUT="${2:?usage: synthesize_substrate.sh <seed_jsonl> <out_jsonl> [N] [MAX]}"
N="${3:-4}"
MAX="${4:-100}"

PORT="${PORT:-8082}"
MAX_TOKENS="${MAX_TOKENS:-256}"
TEMPERATURE="${TEMPERATURE:-0.9}"

if [ ! -f "$SEED" ]; then
  echo "ERROR: seed jsonl $SEED missing." >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required" >&2
  exit 2
fi
if ! curl -sS --max-time 3 "http://localhost:$PORT/v1/models" 2>/dev/null | grep -q '"id"'; then
  echo "ERROR: no substrate at localhost:$PORT" >&2
  exit 2
fi

: > "$OUT"

# System prompt for paraphrase. ASCII only.
SYS_FILE=/tmp/spurarm_substrate_sys.txt
cat > "$SYS_FILE" <<'EOT'
You are a paraphrase generator for robot-arm commands.

Given a single natural-language instruction for a robot arm, rewrite it
in N distinct alternative phrasings. Each rephrasing must:

- Convey the EXACT same intent and outcome as the original.
- Use only plain ASCII characters. No em-dashes, no curly quotes.
- Stay under 200 characters.
- Differ from the original wording in noticeable ways (synonyms, word
  order, sentence structure).

Output exactly N lines, one paraphrase per line. No numbering, no
bullets, no preamble, no explanation. Just N lines of paraphrased text.
EOT

emitted=0
processed=0

# Sample MAX seeds; shuffle by awk.
awk -v n="$MAX" 'BEGIN{srand(31337)} {a[NR]=$0} END{
  cnt=NR; for (i=0;i<n && cnt>0;i++) { r=int(rand()*cnt)+1; print a[r]; a[r]=a[cnt]; cnt--; }
}' "$SEED" > /tmp/spurarm_sub_seeds.txt

while IFS= read -r seed_line; do
  [ -z "$seed_line" ] && continue
  processed=$((processed + 1))
  nl=$(printf '%s' "$seed_line" | jq -r '.nl')
  script=$(printf '%s' "$seed_line" | jq -r '.script')
  obx=$(printf '%s' "$seed_line" | jq -r '.world.obx')
  oby=$(printf '%s' "$seed_line" | jq -r '.world.oby')
  obz=$(printf '%s' "$seed_line" | jq -r '.world.obz')
  present=$(printf '%s' "$seed_line" | jq -r '.world.present')
  gex=$(printf '%s' "$seed_line" | jq -r '.expected.gex')
  gey=$(printf '%s' "$seed_line" | jq -r '.expected.gey')
  gez=$(printf '%s' "$seed_line" | jq -r '.expected.gez')
  ggrip=$(printf '%s' "$seed_line" | jq -r '.expected.ggrip')
  gheld=$(printf '%s' "$seed_line" | jq -r '.expected.gheld')
  st=$(printf '%s' "$seed_line" | jq -r '.stages_passed')

  user_prompt="Rephrase this instruction in $N distinct alternative phrasings:\n\n$nl"

  resp=$(MAX_TOKENS="$MAX_TOKENS" TEMPERATURE="$TEMPERATURE" PORT="$PORT" \
    sh tools/robot/call_substrate.sh "$SYS_FILE" "$user_prompt" 2>/dev/null || true)
  [ -z "$resp" ] && continue
  # Take up to N non-empty lines.
  line_idx=0
  printf '%s\n' "$resp" | while IFS= read -r rline; do
    rline=$(printf '%s' "$rline" | sed 's/^[ \t]*//;s/[ \t\r]*$//')
    case "$rline" in
      ''|\#*) continue ;;
      [0-9]*)
        rline=$(printf '%s' "$rline" | sed -E 's/^[0-9]+[.)] *//') ;;
    esac
    [ -z "$rline" ] && continue
    line_idx=$((line_idx + 1))
    if [ "$line_idx" -gt "$N" ]; then break; fi
    rec=$(jq -nc \
      --arg id "substrate:${processed}_${line_idx}" \
      --arg nl "$rline" \
      --arg script "$script" \
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
        source: "substrate", stages_passed: $st}')
    printf '%s\n' "$rec" >> "$OUT"
  done
  # Progress.
  if [ "$((processed % 10))" -eq 0 ]; then
    printf 'synthesize_substrate: processed=%d emitted_so_far=%d\n' "$processed" "$(wc -l < "$OUT" | tr -d ' ')" >&2
  fi
done < /tmp/spurarm_sub_seeds.txt

final_count=$(wc -l < "$OUT" | tr -d ' ')
printf 'synthesize_substrate done: processed=%d emitted=%d -> %s\n' "$processed" "$final_count" "$OUT"
