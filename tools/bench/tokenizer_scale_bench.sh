#!/bin/bash
# run_tokenizer_scale_bench.sh — exercise counted-loop build_vocab on
# 9.2 / 50 / 200 / full (~540 KB) slices of the stdlib corpus.
# Peak RSS is captured from /usr/bin/time -l (macOS).
set -u

CORPUS=training/rail_corpus_stdlib.txt
if [[ ! -f $CORPUS ]]; then
  echo "corpus missing: run ./rail_native run tools/train/build_corpus.rail first"
  exit 1
fi

FULL=$(wc -c < "$CORPUS" | tr -d ' ')
echo "full corpus: $FULL bytes"
echo

SIZES=(9250 51200 204800 "$FULL")
LABELS=("9.2KB" "50KB" "200KB" "full")

OUT=/tmp/rail_tokenizer_bench.log
: > "$OUT"

for i in 0 1 2 3; do
  n=${SIZES[$i]}
  label=${LABELS[$i]}
  slice=/tmp/rail_bench_corpus.txt
  head -c "$n" "$CORPUS" > "$slice"
  actual=$(wc -c < "$slice" | tr -d ' ')
  echo "=== $label (${actual} bytes) ===" | tee -a "$OUT"
  /usr/bin/time -l ./rail_native run tools/train/bench_tokenizer_scale.rail 2>&1 | tee -a "$OUT"
  echo | tee -a "$OUT"
done

echo "full log: $OUT"
