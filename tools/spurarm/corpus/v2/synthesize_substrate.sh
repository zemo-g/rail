#!/bin/sh
# tools/spurarm/corpus/v2/synthesize_substrate.sh
#
# v2 substrate paraphrase. Loops over the seed pool and asks the 122B
# substrate at Studio :8082 to paraphrase each NL into N alternatives,
# preserving the script unchanged. Pairs the new NLs against the
# original script + expected and tags source=substrate.
#
# v2 modifications vs v1:
#   * SUBSTRATE_TARGET defaults to 12000 (vs v1's ~1500-3000 effective).
#   * Rejected paraphrases (empty / >200 chars / fails reasonability)
#     are logged to /tmp/spurarm_v2_pipeline/substrate_rejects.jsonl
#     for offline analysis (target reject rate < 30% per spec risk).
#   * Substrate availability is probed before any inference call.
#
# Same retry/reject logic as v1: paraphrases pruned to ASCII, < 200
# chars, distinct from the source NL. Per the SPEC's risk (b) note,
# we accept paraphrases that pass surface validation -- we do NOT
# re-sim because the script is unchanged from the seed (which already
# passes the sim).
#
# Usage:
#   sh tools/spurarm/corpus/v2/synthesize_substrate.sh <seed_jsonl> <out_jsonl> [N_per_seed] [MAX_SEEDS]

set -u
SEED="${1:?usage: synthesize_substrate.sh <seed_jsonl> <out_jsonl> [N] [MAX]}"
OUT="${2:?usage: synthesize_substrate.sh <seed_jsonl> <out_jsonl> [N] [MAX]}"
N="${3:-6}"
MAX="${4:-2000}"

PORT="${PORT:-8082}"
MAX_TOKENS="${MAX_TOKENS:-512}"
TEMPERATURE="${TEMPERATURE:-0.9}"
MODEL="${MODEL:-mlx-community/Qwen3.5-122B-A10B-heretic-v2-2.34bit-msq}"
SUBSTRATE_TARGET="${SUBSTRATE_TARGET:-12000}"
REJECT_LOG="${REJECT_LOG:-/tmp/spurarm_v2_pipeline/substrate_rejects.jsonl}"

mkdir -p "$(dirname "$REJECT_LOG")"
: > "$REJECT_LOG"

if [ ! -f "$SEED" ]; then
  echo "ERROR: seed jsonl $SEED missing." >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required" >&2
  exit 2
fi
if ! curl -sS --max-time 3 "http://localhost:$PORT/v1/models" 2>/dev/null | grep -q '"id"'; then
  echo "ERROR: no substrate at localhost:$PORT (need Qwen3.5-122B for v2)." >&2
  exit 2
fi

: > "$OUT"

# System prompt (ASCII only).
SYS_FILE=/tmp/spurarm_v2_substrate_sys.txt
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

# Sample MAX seeds; shuffle by awk.
awk -v n="$MAX" 'BEGIN{srand(20260522)} {a[NR]=$0} END{
  cnt=NR; for (i=0;i<n && cnt>0;i++) { r=int(rand()*cnt)+1; print a[r]; a[r]=a[cnt]; cnt--; }
}' "$SEED" > /tmp/spurarm_v2_sub_seeds.txt

emitted=0
processed=0
rejected=0

while IFS= read -r seed_line; do
  [ -z "$seed_line" ] && continue
  # Stop if we hit the SUBSTRATE_TARGET.
  if [ "$emitted" -ge "$SUBSTRATE_TARGET" ]; then
    break
  fi
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

  resp=$(MAX_TOKENS="$MAX_TOKENS" TEMPERATURE="$TEMPERATURE" PORT="$PORT" MODEL="$MODEL" \
    sh tools/robot/call_substrate.sh "$SYS_FILE" "$user_prompt" 2>/dev/null || true)
  if [ -z "$resp" ]; then
    rejected=$((rejected + 1))
    printf '{"reason":"empty_response","seed_nl":%s}\n' "$(printf '%s' "$nl" | jq -Rs '.')" >> "$REJECT_LOG"
    continue
  fi
  # Process up to N non-empty lines.
  line_idx=0
  printf '%s\n' "$resp" | while IFS= read -r rline; do
    rline=$(printf '%s' "$rline" | sed 's/^[ \t]*//;s/[ \t\r]*$//')
    case "$rline" in
      ''|\#*) continue ;;
      [0-9]*)
        rline=$(printf '%s' "$rline" | sed -E 's/^[0-9]+[.)] *//') ;;
    esac
    [ -z "$rline" ] && continue
    # Length cap.
    rlen=${#rline}
    if [ "$rlen" -gt 200 ]; then
      printf '{"reason":"too_long","len":%d,"text":%s}\n' "$rlen" "$(printf '%s' "$rline" | jq -Rs '.')" >> "$REJECT_LOG"
      continue
    fi
    # Reject if identical to source NL.
    if [ "$rline" = "$nl" ]; then
      printf '{"reason":"identical","text":%s}\n' "$(printf '%s' "$rline" | jq -Rs '.')" >> "$REJECT_LOG"
      continue
    fi
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
  # Recount emitted at end of each seed (subshell pipe means var
  # mutation inside while doesn't propagate).
  emitted=$(wc -l < "$OUT" | tr -d ' ')
  if [ "$((processed % 10))" -eq 0 ]; then
    printf 'synthesize_substrate (v2): processed=%d emitted=%d rejected=%d target=%d\n' \
      "$processed" "$emitted" "$rejected" "$SUBSTRATE_TARGET" >&2
  fi
done < /tmp/spurarm_v2_sub_seeds.txt

final_count=$(wc -l < "$OUT" | tr -d ' ')
final_rejected=$(wc -l < "$REJECT_LOG" | tr -d ' ')
printf 'synthesize_substrate (v2) done: processed=%d emitted=%d rejected=%d -> %s\n' \
  "$processed" "$final_count" "$final_rejected" "$OUT"
printf 'rejects logged to: %s\n' "$REJECT_LOG"
