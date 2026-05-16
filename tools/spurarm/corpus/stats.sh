#!/bin/sh
# tools/spurarm/corpus/stats.sh
#
# Emit spurarm_v0_stats.json with the counters listed in
# AGENT_A_corpus.md and CHAIN_SKELETON_AGENT_A.md.
#
# Usage:
#   sh tools/spurarm/corpus/stats.sh <corpora_dir> <out_json>

set -u
DIR="${1:?usage: stats.sh <corpora_dir> <out_json>}"
OUT="${2:?usage: stats.sh <corpora_dir> <out_json>}"

if [ ! -f "$DIR/spurarm_v0.jsonl" ]; then
  echo "ERROR: $DIR/spurarm_v0.jsonl missing" >&2
  exit 2
fi

MAIN="$DIR/spurarm_v0.jsonl"
PRE="$DIR/spurarm_v0_pretrain.jsonl"
SFT="$DIR/spurarm_v0_sft.jsonl"
EVAL="$DIR/spurarm_v0_eval.jsonl"

total=$(wc -l < "$MAIN" | tr -d ' ')
n_pre=0;  [ -f "$PRE" ] && n_pre=$(wc -l < "$PRE" | tr -d ' ')
n_sft=0;  [ -f "$SFT" ] && n_sft=$(wc -l < "$SFT" | tr -d ' ')
n_eval=0; [ -f "$EVAL" ] && n_eval=$(wc -l < "$EVAL" | tr -d ' ')

# By source.
src_counts=$(awk '
  match($0, /"source":"[a-z]+"/) {
    s = substr($0, RSTART + 10, RLENGTH - 11);
    cnt[s]++;
  }
  END {
    for (s in cnt) printf("%s\t%d\n", s, cnt[s]);
  }
' "$MAIN")

# Stages distribution.
stage_counts=$(awk '
  match($0, /"stages_passed":[0-9]+/) {
    st = substr($0, RSTART + 16, RLENGTH - 16);
    cnt[st]++;
  }
  END {
    for (st in cnt) printf("%s\t%d\n", st, cnt[st]);
  }
' "$MAIN")

# Script-length distribution (chars).
script_len_dist=$(awk '
  function bin(n) {
    if (n < 50) return "<50";
    if (n < 100) return "50-99";
    if (n < 200) return "100-199";
    if (n < 400) return "200-399";
    if (n < 800) return "400-799";
    return ">=800";
  }
  match($0, /"script":"[^"]*"/) {
    sc = substr($0, RSTART + 10, RLENGTH - 11);
    cnt[bin(length(sc))]++;
  }
  END {
    for (b in cnt) printf("%s\t%d\n", b, cnt[b]);
  }
' "$MAIN")

# NL-length distribution.
nl_len_dist=$(awk '
  function bin(n) {
    if (n < 20) return "<20";
    if (n < 40) return "20-39";
    if (n < 80) return "40-79";
    if (n < 160) return "80-159";
    return ">=160";
  }
  match($0, /"nl":"[^"]*"/) {
    nl = substr($0, RSTART + 6, RLENGTH - 7);
    cnt[bin(length(nl))]++;
  }
  END {
    for (b in cnt) printf("%s\t%d\n", b, cnt[b]);
  }
' "$MAIN")

# Unique canonical scripts.
unique_scripts=$(awk '
  function canon(s,    t) {
    t = s; gsub(/[ \t\r\n]+/, " ", t); sub(/^ /, "", t); sub(/ $/, "", t);
    return t;
  }
  match($0, /"script":"[^"]*"/) {
    sc = canon(substr($0, RSTART + 10, RLENGTH - 11));
    seen[sc] = 1;
  }
  END { print length(seen) }
' "$MAIN")

# eval/bench overlap count.
TMP_BENCH=/tmp/spurarm_stats_bench.txt
grep -v -E '^#|^$' tools/robot/bench_v0.txt | cut -d'|' -f2 | \
  awk '{s=tolower($0); gsub(/[^a-z0-9 ]/, " ", s); gsub(/  +/," ",s); sub(/^ /,"",s); sub(/ $/,"",s); print s}' > "$TMP_BENCH"

overlap=$(awk -v bench="$TMP_BENCH" '
  function norm(s,    t) {
    t = tolower(s);
    gsub(/[^a-z0-9 ]/, " ", t);
    gsub(/  +/, " ", t);
    sub(/^ /, "", t); sub(/ $/, "", t);
    return t;
  }
  function shingle(s, set,    n, w, i) {
    n = split(s, w, " ");
    delete set;
    for (i = 1; i <= n - 2; i++) set[w[i] " " w[i+1] " " w[i+2]] = 1;
    if (n < 3) for (i = 1; i <= n; i++) set[w[i]] = 1;
  }
  function jac(a, b,    inter, uni, k) {
    inter = 0; uni = 0;
    for (k in a) { uni++; if (k in b) inter++; }
    for (k in b) if (!(k in a)) uni++;
    return uni == 0 ? 0 : inter / uni;
  }
  BEGIN { while ((getline line < bench) > 0) bench_lines[++bench_n] = line; }
  {
    if (match($0, /"nl":"[^"]*"/)) {
      nl = norm(substr($0, RSTART + 6, RLENGTH - 7));
      shingle(nl, ms);
      for (i = 1; i <= bench_n; i++) {
        shingle(bench_lines[i], bs);
        if (jac(ms, bs) > 0.5) { ov++; break; }
      }
    }
  }
  END { print ov + 0 }
' "$EVAL")

# By-source max share.
max_share_pct=$(printf '%s\n' "$src_counts" | awk -v tot="$total" '
  { if (tot > 0) p = ($2 * 100) / tot; if (p > best) best = p }
  END { printf("%.0f", best) }
')

# Build JSON via jq for safety.
src_json=$(printf '%s\n' "$src_counts" | jq -Rs '
  split("\n") | map(select(length > 0) | split("\t") | {(.[0]): (.[1] | tonumber)}) | add // {}
')
stages_json=$(printf '%s\n' "$stage_counts" | jq -Rs '
  split("\n") | map(select(length > 0) | split("\t") | {(.[0]): (.[1] | tonumber)}) | add // {}
')
script_len_json=$(printf '%s\n' "$script_len_dist" | jq -Rs '
  split("\n") | map(select(length > 0) | split("\t") | {(.[0]): (.[1] | tonumber)}) | add // {}
')
nl_len_json=$(printf '%s\n' "$nl_len_dist" | jq -Rs '
  split("\n") | map(select(length > 0) | split("\t") | {(.[0]): (.[1] | tonumber)}) | add // {}
')

jq -n \
  --argjson total "$total" \
  --argjson pretrain "$n_pre" \
  --argjson sft "$n_sft" \
  --argjson eval "$n_eval" \
  --argjson src "$src_json" \
  --argjson stages "$stages_json" \
  --argjson scriptlen "$script_len_json" \
  --argjson nllen "$nl_len_json" \
  --argjson uniq "$unique_scripts" \
  --argjson overlap "${overlap:-0}" \
  --argjson max_share "${max_share_pct:-0}" \
  '{
    total_pairs: $total,
    pretrain_pairs: $pretrain,
    sft_pairs: $sft,
    eval_pairs: $eval,
    by_source: $src,
    by_stages_passed: $stages,
    script_length_distribution: $scriptlen,
    nl_length_distribution: $nllen,
    unique_canonical_scripts: $uniq,
    eval_bench_overlap_count: $overlap,
    by_source_max_share_pct: $max_share
  }' > "$OUT"

printf 'stats written -> %s\n' "$OUT"
cat "$OUT"
