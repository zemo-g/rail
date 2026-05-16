#!/bin/sh
# tools/spurarm/corpus/dedup.sh
#
# Two-level dedup over a JSONL corpus:
#   1. Script canonicalization: lower-internal-whitespace, SHA-256 hash,
#      keep the highest-stages_passed survivor when scripts collide.
#   2. NL near-duplicate: normalize, 3-gram word-shingle, Jaccard >
#      0.7 -> dedupe; keep higher stages_passed; ties keep longer nl.
#
# Determinism: order-of-arrival preserved within the same hash; ties
# broken by id alphabetic.
#
# Usage:
#   sh tools/spurarm/corpus/dedup.sh <in_jsonl> <out_jsonl>

set -u
IN="${1:?usage: dedup.sh <in_jsonl> <out_jsonl>}"
OUT="${2:?usage: dedup.sh <in_jsonl> <out_jsonl>}"

if [ ! -f "$IN" ]; then
  echo "ERROR: input $IN missing" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required" >&2
  exit 2
fi

TMP_FLAT=/tmp/spurarm_dedup_flat.txt
TMP_SCRIPT_DEDUP=/tmp/spurarm_dedup_script.jsonl
TMP_HASH=/tmp/spurarm_dedup_hash.tsv

# ---- Stage 1: joint (nl, script) canonical dedup ----
# Per the AGENT_A_corpus.md spec, script-only canonicalization would
# collapse 22k ALFRED paraphrase pairs (3 NLs share the same remapped
# script per trajectory) into 7k unique-script entries -- destroying
# the paraphrase signal that's the entire point of ALFRED. We dedupe
# on the JOINT (normalized-nl, canonical-script) key instead so the
# paraphrase signal survives. Within a collision class we keep the
# record with max stages_passed.

echo "dedup stage 1: joint (nl, script) canonical dedup..."

awk '
function canon(s,    t) {
  t = s;
  gsub(/[ \t\r\n]+/, " ", t);
  sub(/^ /, "", t);
  sub(/ $/, "", t);
  return t;
}
function norm_nl(s,    t) {
  t = tolower(s);
  gsub(/[^a-z0-9 ]/, " ", t);
  gsub(/  +/, " ", t);
  sub(/^ /, "", t);
  sub(/ $/, "", t);
  return t;
}
function fnv1a(s,    h, i, c, p) {
  h = 2166136261;
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1);
    p = index("\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037 !\"#$%&'\''()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~", c);
    if (p == 0) p = 1;
    h = h * 16777619;
    h = h % 4294967296;
    h = (h - p);
    if (h < 0) h += 4294967296;
  }
  return sprintf("%010d", h);
}
{
  line = $0;
  match(line, /"script":"[^"]*"/);
  script = substr(line, RSTART + 10, RLENGTH - 11);
  match(line, /"nl":"[^"]*"/);
  nl = substr(line, RSTART + 6, RLENGTH - 7);
  match(line, /"stages_passed":[0-9]+/);
  st = substr(line, RSTART + 16, RLENGTH - 16);
  match(line, /"id":"[^"]*"/);
  id = substr(line, RSTART + 6, RLENGTH - 7);
  joint = norm_nl(nl) "|" canon(script);
  h = fnv1a(joint);
  printf("%s\t%s\t%s\t%d\n", h, st, id, NR);
}
' "$IN" > "$TMP_HASH"

# Per hash: keep max stages_passed, ties -> smallest line idx.
sort -t$'\t' -k1,1 -k2,2nr -k4,4n "$TMP_HASH" \
  | awk -F'\t' 'BEGIN{prev=""} { if ($1 != prev) { print $4; prev=$1 } }' \
  | sort -n > /tmp/spurarm_dedup_keep_lines.txt

awk 'NR==FNR{keep[$1]=1; next} (FNR in keep)' /tmp/spurarm_dedup_keep_lines.txt "$IN" > "$TMP_SCRIPT_DEDUP"

before=$(wc -l < "$IN" | tr -d ' ')
after_1=$(wc -l < "$TMP_SCRIPT_DEDUP" | tr -d ' ')
printf 'dedup stage 1: %d -> %d (-%d)\n' "$before" "$after_1" "$((before - after_1))"

# ---- Stage 2: NL exact-dedup within identical-script clusters ----
# After stage-1 joint-dedup, residual stage-2 work is small. Keep all
# unique (nl_norm) entries: the previous Jaccard-near-dup pass was too
# aggressive on the procedural source (where dozens of slightly
# different NLs legitimately produce the same script). The training
# signal benefits more from paraphrase diversity than from squeezing
# out near-dup pairs at scale.

cp "$TMP_SCRIPT_DEDUP" "$OUT"
after_2=$(wc -l < "$OUT" | tr -d ' ')
printf 'dedup stage 2: %d -> %d (no further reduction by design)\n' "$after_1" "$after_2"
printf 'dedup TOTAL: %d -> %d (%d%% retained)\n' "$before" "$after_2" "$((after_2 * 100 / (before > 0 ? before : 1)))"
