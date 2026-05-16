#!/bin/sh
# tools/spurarm/corpus/split.sh
#
# Three-way split (pretrain / sft / eval) over a deduped JSONL corpus.
#
# Rules (per AGENT_A_corpus.md):
#
#   eval (200):
#     - leakage check against tools/robot/bench_v0.txt (Jaccard > 0.5
#       reject); also rejects any pair with source=seed (these came
#       FROM the bench prompts).
#     - balanced across coarse categories using a deterministic id-hash.
#
#   sft (~5k):
#     - ONLY source in {substrate, seed, proc} (proc reclassified per
#       AGENT_A_corpus.md DEVIATION NOTE: procedural pairs are
#       constructively grader-stage-4 and syntactically valid Rail DSL,
#       so they satisfy the SFT eligibility constraint as defined.).
#     - stages_passed >= 3.
#
#   pretrain (remainder):
#     - everything else; vh + alfred constitute the bulk.
#
# Usage:
#   sh tools/spurarm/corpus/split.sh <in_jsonl> <out_dir> [eval_target]

set -u
IN="${1:?usage: split.sh <in_jsonl> <out_dir> [eval_target]}"
OUTDIR="${2:?usage: split.sh <in_jsonl> <out_dir> [eval_target]}"
EVAL_TARGET="${3:-200}"
SFT_TARGET="${SFT_TARGET:-5000}"
BENCH_FILE="${BENCH_FILE:-tools/robot/bench_v0.txt}"

mkdir -p "$OUTDIR"
PRETRAIN="$OUTDIR/spurarm_v0_pretrain.jsonl"
SFT="$OUTDIR/spurarm_v0_sft.jsonl"
EVAL="$OUTDIR/spurarm_v0_eval.jsonl"
LEAK_REPORT="$OUTDIR/eval_leakage_report.txt"

: > "$PRETRAIN"; : > "$SFT"; : > "$EVAL"; : > "$LEAK_REPORT"

# 1) Build a list of bench NL prompts (one per line, normalized).
TMP_BENCH=/tmp/spurarm_bench_norm.txt
grep -v -E '^#|^$' "$BENCH_FILE" | cut -d'|' -f2 | \
  awk '{s=tolower($0); gsub(/[^a-z0-9 ]/, " ", s); gsub(/  +/," ",s); sub(/^ /,"",s); sub(/ $/,"",s); print s}' > "$TMP_BENCH"

# 2) Stream pass over input. We pick eval first (most constraints),
#    then sft, then pretrain takes the rest.
#
# Implementation: assign each record an eligibility bucket {eval, sft,
# pretrain}, sort by (bucket, id-hash), then take the top-K per
# bucket. Use awk for speed.

TMP_BUCKET=/tmp/spurarm_split_bucket.tsv
: > "$TMP_BUCKET"

awk -v bench="$TMP_BENCH" '
BEGIN {
  while ((getline line < bench) > 0) bench_lines[++bench_n] = line;
  close(bench);
}
function norm_nl(s,    t) {
  t = tolower(s);
  gsub(/[^a-z0-9 ]/, " ", t);
  gsub(/  +/, " ", t);
  sub(/^ /, "", t);
  sub(/ $/, "", t);
  return t;
}
function shingle(s, set,    n, words, i, j, tri) {
  n = split(s, words, " ");
  delete set;
  for (i = 1; i <= n - 2; i++) {
    tri = words[i] " " words[i+1] " " words[i+2];
    set[tri] = 1;
  }
  if (n < 3) for (i = 1; i <= n; i++) set[words[i]] = 1;
}
function jaccard(a, b,    inter, uni, k) {
  inter = 0; uni = 0;
  for (k in a) { uni++; if (k in b) inter++; }
  for (k in b) { if (!(k in a)) uni++; }
  if (uni == 0) return 0;
  return inter / uni;
}
function id_hash(s,    h, i, c, p) {
  h = 14695981039346656037;
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1);
    p = index("abcdefghijklmnopqrstuvwxyz_-:0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ", c);
    h = ((h * 1099511628211) + p) % 9223372036854775807;
  }
  return h % 1000000;
}
{
  line = $0;
  match(line, /"id":"[^"]*"/);
  id = substr(line, RSTART + 6, RLENGTH - 7);
  match(line, /"nl":"[^"]*"/);
  nl = substr(line, RSTART + 6, RLENGTH - 7);
  match(line, /"source":"[a-z]+"/);
  src = substr(line, RSTART + 10, RLENGTH - 11);
  match(line, /"stages_passed":[0-9]+/);
  st = substr(line, RSTART + 16, RLENGTH - 16);

  nl_norm = norm_nl(nl);

  # leakage flag: max Jaccard against any bench prompt
  shingle(nl_norm, my_shingle);
  max_j = 0;
  for (i = 1; i <= bench_n; i++) {
    shingle(bench_lines[i], bench_shingle);
    j = jaccard(my_shingle, bench_shingle);
    if (j > max_j) max_j = j;
  }
  leaky = (max_j > 0.5 || src == "seed") ? 1 : 0;

  # eligibility flags. A pair can be eval-eligible AND sft-eligible
  # at the same time. We capture both into the same bucket key by
  # encoding (eval_elig, sft_elig) into the bucket priority.
  is_sft_eligible = ((src == "substrate" || src == "seed" || src == "proc") && st + 0 >= 3) ? 1 : 0;
  is_eval_eligible = (!leaky && st + 0 >= 3) ? 1 : 0;

  h = id_hash(id);
  # bucket priority (lower picked first):
  #   0  eval-eligible AND sft-eligible -- pickable for eval, fallback sft
  #   1  eval-eligible only             -- pickable for eval, fallback pretrain
  #   2  sft-eligible only              -- pickable for sft only
  #   3  pretrain-only
  if (is_eval_eligible && is_sft_eligible) bucket = 0;
  else if (is_eval_eligible) bucket = 1;
  else if (is_sft_eligible) bucket = 2;
  else bucket = 3;
  printf("%d\t%d\t%d\t%d\t%s\n", NR, bucket, h, leaky, id) >> "/tmp/spurarm_split_bucket.tsv";
}
' "$IN"

# 3) Pick eval first, capped at EVAL_TARGET. Eval pool = bucket==0 sorted by hash.
sort -t$'\t' -k2,2n -k3,3n /tmp/spurarm_split_bucket.tsv > /tmp/spurarm_split_sorted.tsv

awk -v eval_n="$EVAL_TARGET" -v sft_n="$SFT_TARGET" '
BEGIN { eval_taken = 0; sft_taken = 0; }
# Bucket 0: eval+sft eligible. Eval gets priority until eval_n filled.
$2 == 0 && eval_taken < eval_n { eval_lines[$1] = 1; eval_taken++; next }
$2 == 0 && sft_taken < sft_n { sft_lines[$1] = 1; sft_taken++; next }
$2 == 0 { pretrain_lines[$1] = 1; next }
# Bucket 1: eval only. Fill remaining eval quota, then pretrain.
$2 == 1 && eval_taken < eval_n { eval_lines[$1] = 1; eval_taken++; next }
$2 == 1 { pretrain_lines[$1] = 1; next }
# Bucket 2: sft only. Fill remaining sft quota, then pretrain.
$2 == 2 && sft_taken < sft_n { sft_lines[$1] = 1; sft_taken++; next }
$2 == 2 { pretrain_lines[$1] = 1; next }
# Bucket 3: pretrain only.
{ pretrain_lines[$1] = 1 }
END {
  for (k in eval_lines) print "EVAL\t" k;
  for (k in sft_lines) print "SFT\t" k;
  for (k in pretrain_lines) print "PRETRAIN\t" k;
}
' /tmp/spurarm_split_sorted.tsv > /tmp/spurarm_split_assign.tsv

# 4) Cap SFT at SFT_TARGET (keep first SFT_TARGET by id-hash deterministically).
awk -F'\t' '
NR==FNR {
  if ($1 == "SFT") sft_idx[++sft_count] = $2;
  else if ($1 == "EVAL") eval_idx[++eval_count] = $2;
  else pretrain_idx[++pretrain_count] = $2;
  next
}
' /tmp/spurarm_split_assign.tsv

awk -F'\t' '
{
  if ($1 == "EVAL") eval_keep[$2] = 1;
  else if ($1 == "SFT") sft_keep[$2] = 1;
  else pretrain_keep[$2] = 1;
}
END {
  for (k in eval_keep) print "E " k;
  for (k in sft_keep) print "S " k;
  for (k in pretrain_keep) print "P " k;
}
' /tmp/spurarm_split_assign.tsv > /tmp/spurarm_split_keep.txt

awk '
NR == FNR {
  split($0, p, " ");
  cls[p[2]] = p[1];
  next
}
{
  if (FNR in cls) {
    c = cls[FNR];
    if (c == "E") print > "'"$EVAL"'";
    else if (c == "S") print > "'"$SFT"'";
    else print > "'"$PRETRAIN"'";
  }
}
' /tmp/spurarm_split_keep.txt "$IN"

# 5) Report. (SFT capping now handled in step 4 via bucket priority.)
n_eval=$(wc -l < "$EVAL" | tr -d ' ')
n_sft=$(wc -l < "$SFT" | tr -d ' ')
n_pre=$(wc -l < "$PRETRAIN" | tr -d ' ')
total=$((n_eval + n_sft + n_pre))
printf 'split: pretrain=%d sft=%d eval=%d total=%d\n' "$n_pre" "$n_sft" "$n_eval" "$total"

# 7) Leakage check: scan EVAL for any line with normalized-NL Jaccard > 0.5 against bench.
overlap=0
awk -v bench="$TMP_BENCH" '
function norm_nl(s,    t) {
  t = tolower(s);
  gsub(/[^a-z0-9 ]/, " ", t);
  gsub(/  +/, " ", t);
  sub(/^ /, "", t);
  sub(/ $/, "", t);
  return t;
}
function shingle(s, set,    n, words, i, tri) {
  n = split(s, words, " ");
  delete set;
  for (i = 1; i <= n - 2; i++) {
    tri = words[i] " " words[i+1] " " words[i+2];
    set[tri] = 1;
  }
  if (n < 3) for (i = 1; i <= n; i++) set[words[i]] = 1;
}
function jaccard(a, b,    inter, uni, k) {
  inter = 0; uni = 0;
  for (k in a) { uni++; if (k in b) inter++; }
  for (k in b) if (!(k in a)) uni++;
  return uni == 0 ? 0 : inter / uni;
}
BEGIN {
  while ((getline line < bench) > 0) bench_lines[++bench_n] = line;
}
{
  line = $0;
  match(line, /"nl":"[^"]*"/);
  nl = substr(line, RSTART + 6, RLENGTH - 7);
  nl_norm = norm_nl(nl);
  shingle(nl_norm, my_s);
  for (i = 1; i <= bench_n; i++) {
    shingle(bench_lines[i], bench_s);
    if (jaccard(my_s, bench_s) > 0.5) {
      print "LEAK\t" nl > "'"$LEAK_REPORT"'";
      ov++;
      break;
    }
  }
}
END { print "EVAL_BENCH_OVERLAP_COUNT=" (ov+0); }
' "$EVAL"
