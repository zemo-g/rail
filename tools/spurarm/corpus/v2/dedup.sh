#!/bin/sh
# tools/spurarm/corpus/v2/dedup.sh
#
# v2 dedup. JOINT FNV-1a hash on (normalized_nl, canonical_script).
# Per SPEC §7, we explicitly do NOT cut on Jaccard near-dup -- Agent
# A's lesson is that a 0.7 cutoff guts ~40% of paraphrase signal. The
# joint key handles exact (nl, script) collisions; distinct surface
# forms of the same script stay.
#
# Within a collision class we keep the record with max stages_passed;
# ties broken by line order (stable).
#
# Usage:
#   sh tools/spurarm/corpus/v2/dedup.sh <in_jsonl> <out_jsonl>

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

TMP_HASH=/tmp/spurarm_v2_dedup_hash.tsv

echo "dedup (v2): joint (nl, script) canonical dedup..."

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

# Per hash: keep max stages_passed; ties -> smallest line idx.
sort -t$'\t' -k1,1 -k2,2nr -k4,4n "$TMP_HASH" \
  | awk -F'\t' 'BEGIN{prev=""} { if ($1 != prev) { print $4; prev=$1 } }' \
  | sort -n > /tmp/spurarm_v2_dedup_keep_lines.txt

awk 'NR==FNR{keep[$1]=1; next} (FNR in keep)' /tmp/spurarm_v2_dedup_keep_lines.txt "$IN" > "$OUT"

before=$(wc -l < "$IN" | tr -d ' ')
after=$(wc -l < "$OUT" | tr -d ' ')
printf 'dedup (v2): %d -> %d (-%d, %d%% retained)\n' \
  "$before" "$after" "$((before - after))" "$((after * 100 / (before > 0 ? before : 1)))"
