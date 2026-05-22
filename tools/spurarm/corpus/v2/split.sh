#!/bin/sh
# tools/spurarm/corpus/v2/split.sh
#
# v2 split. 4-bucket priority assignment per AGENT_A_corpus.md, with:
#   * Tighter Jaccard leakage cut on eval: < 0.3 (vs v1's 0.5) per
#     Agent A's open follow-up + SPEC §7's "Tighter than v1".
#   * Targets: SFT_TARGET=20000 (vs v1's 5000), EVAL_TARGET=200.
#   * Files named spurarm_v2_{pretrain,sft,eval}.jsonl.
#
# Eligibility:
#   eval (200):
#     - leakage check: NL Jaccard < 0.3 against tools/robot/bench_v0.txt
#     - source != "seed" (those came FROM bench prompts)
#     - stages_passed >= 3
#   sft (>= 20000):
#     - source in {substrate, seed, proc_v2}, stages_passed >= 3
#   pretrain (remainder):
#     - everything else (vh + alfred + leaky-or-low-stage)
#
# Usage:
#   sh tools/spurarm/corpus/v2/split.sh <in_jsonl> <out_dir> [eval_target]

set -u
IN="${1:?usage: split.sh <in_jsonl> <out_dir> [eval_target]}"
OUTDIR="${2:?usage: split.sh <in_jsonl> <out_dir> [eval_target]}"
EVAL_TARGET="${3:-200}"
SFT_TARGET="${SFT_TARGET:-20000}"
BENCH_FILE="${BENCH_FILE:-tools/robot/bench_v0.txt}"
LEAKAGE_THRESHOLD="${LEAKAGE_THRESHOLD:-0.3}"

mkdir -p "$OUTDIR"
PRETRAIN="$OUTDIR/spurarm_v2_pretrain.jsonl"
SFT="$OUTDIR/spurarm_v2_sft.jsonl"
EVAL="$OUTDIR/spurarm_v2_eval.jsonl"
LEAK_REPORT="$OUTDIR/eval_leakage_report.txt"

: > "$PRETRAIN"; : > "$SFT"; : > "$EVAL"; : > "$LEAK_REPORT"

# Normalized bench NL prompts (one per line).
TMP_BENCH=/tmp/spurarm_v2_bench_norm.txt
grep -v -E '^#|^$' "$BENCH_FILE" | cut -d'|' -f2 | \
  awk '{s=tolower($0); gsub(/[^a-z0-9 ]/, " ", s); gsub(/  +/," ",s); sub(/^ /,"",s); sub(/ $/,"",s); print s}' > "$TMP_BENCH"

# Bucket assignment.
TMP_BUCKET=/tmp/spurarm_v2_split_bucket.tsv
: > "$TMP_BUCKET"

awk -v bench="$TMP_BENCH" -v thresh="$LEAKAGE_THRESHOLD" '
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
  match(line, /"source":"[a-z0-9_]+"/);
  src = substr(line, RSTART + 10, RLENGTH - 11);
  match(line, /"stages_passed":[0-9]+/);
  st = substr(line, RSTART + 16, RLENGTH - 16);

  nl_norm = norm_nl(nl);

  shingle(nl_norm, my_shingle);
  max_j = 0;
  for (i = 1; i <= bench_n; i++) {
    shingle(bench_lines[i], bench_shingle);
    j = jaccard(my_shingle, bench_shingle);
    if (j > max_j) max_j = j;
  }
  leaky = (max_j >= thresh + 0 || src == "seed") ? 1 : 0;

  is_sft_eligible = ((src == "substrate" || src == "seed" || src == "proc_v2") && st + 0 >= 3) ? 1 : 0;
  is_eval_eligible = (!leaky && st + 0 >= 3) ? 1 : 0;

  h = id_hash(id);
  if (is_eval_eligible && is_sft_eligible) bucket = 0;
  else if (is_eval_eligible) bucket = 1;
  else if (is_sft_eligible) bucket = 2;
  else bucket = 3;
  printf("%d\t%d\t%d\t%d\t%s\n", NR, bucket, h, leaky, id) >> "/tmp/spurarm_v2_split_bucket.tsv";
}
' "$IN"

sort -t$'\t' -k2,2n -k3,3n /tmp/spurarm_v2_split_bucket.tsv > /tmp/spurarm_v2_split_sorted.tsv

awk -v eval_n="$EVAL_TARGET" -v sft_n="$SFT_TARGET" '
BEGIN { eval_taken = 0; sft_taken = 0; }
$2 == 0 && eval_taken < eval_n { eval_lines[$1] = 1; eval_taken++; next }
$2 == 0 && sft_taken < sft_n { sft_lines[$1] = 1; sft_taken++; next }
$2 == 0 { pretrain_lines[$1] = 1; next }
$2 == 1 && eval_taken < eval_n { eval_lines[$1] = 1; eval_taken++; next }
$2 == 1 { pretrain_lines[$1] = 1; next }
$2 == 2 && sft_taken < sft_n { sft_lines[$1] = 1; sft_taken++; next }
$2 == 2 { pretrain_lines[$1] = 1; next }
{ pretrain_lines[$1] = 1 }
END {
  for (k in eval_lines) print "EVAL\t" k;
  for (k in sft_lines) print "SFT\t" k;
  for (k in pretrain_lines) print "PRETRAIN\t" k;
}
' /tmp/spurarm_v2_split_sorted.tsv > /tmp/spurarm_v2_split_assign.tsv

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
' /tmp/spurarm_v2_split_assign.tsv > /tmp/spurarm_v2_split_keep.txt

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
' /tmp/spurarm_v2_split_keep.txt "$IN"

n_eval=$(wc -l < "$EVAL" | tr -d ' ')
n_sft=$(wc -l < "$SFT" | tr -d ' ')
n_pre=$(wc -l < "$PRETRAIN" | tr -d ' ')
total=$((n_eval + n_sft + n_pre))
printf 'split (v2): pretrain=%d sft=%d eval=%d total=%d (leakage thresh=%s)\n' \
  "$n_pre" "$n_sft" "$n_eval" "$total" "$LEAKAGE_THRESHOLD"

# Final leakage report: lines in EVAL whose normalized NL has Jaccard >= threshold to bench.
awk -v bench="$TMP_BENCH" -v thresh="$LEAKAGE_THRESHOLD" '
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
    if (jaccard(my_s, bench_s) >= thresh + 0) {
      print "LEAK\t" nl > "'"$LEAK_REPORT"'";
      ov++;
      break;
    }
  }
}
END { print "EVAL_BENCH_OVERLAP_COUNT=" (ov+0); }
' "$EVAL"
