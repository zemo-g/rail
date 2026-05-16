#!/bin/sh
# tools/spurarm/corpus/pipeline.sh
#
# End-to-end corpus build for Spur-arm v0. See
# notes/railarm4agent/AGENT_A_corpus.md for the full design.
#
# Pipeline stages:
#   1. proc        -- procedural synthesis (constructively grader-stage-4)
#   2. vh          -- VirtualHome ActivityPrograms verb-remap
#   3. alfred      -- ALFRED high-level PDDL verb-remap (subsampled)
#   4. seed        -- prior-session 400 reranks regraded
#   5. substrate   -- substrate paraphrase of seeds (optional, time-bound)
#   6. concat -> dedup -> split -> stats -> acceptance
#
# All paths are absolute / repo-relative. Env knobs are listed below.
#
# Knobs:
#   PROC_N=15000   -- procedural pairs to generate
#   ALFRED_CAP=10000 -- subsample ALFRED to this many pairs
#   VH_DIR=/tmp/vh_extract/...  -- VirtualHome withoutconds dir (or '')
#   ALFRED_DIR=/tmp/alfred_data/json_2.1.0  -- ALFRED root (or '')
#   SEED_DIR=/tmp/robot_completions_rerank  -- prior reranks (or '')
#   SUBSTRATE_JSONL=/tmp/spurarm_substrate.jsonl  -- precomputed substrate pairs (or '')
#   EVAL_TARGET=200
#   SFT_TARGET=5000

set -u
PROC_N="${PROC_N:-15000}"
ALFRED_CAP="${ALFRED_CAP:-10000}"
VH_DIR="${VH_DIR:-/tmp/vh_extract/programs_processed_precond_nograb_morepreconds/withoutconds}"
ALFRED_DIR="${ALFRED_DIR:-/tmp/alfred_data/json_2.1.0}"
SEED_DIR="${SEED_DIR:-/tmp/robot_completions_rerank}"
SUBSTRATE_JSONL="${SUBSTRATE_JSONL:-/tmp/spurarm_substrate.jsonl}"
EVAL_TARGET="${EVAL_TARGET:-200}"
SFT_TARGET="${SFT_TARGET:-5000}"

OUTDIR="${OUTDIR:-training/corpora}"
mkdir -p "$OUTDIR"
mkdir -p /tmp/spurarm_pipeline

PROC_OUT=/tmp/spurarm_pipeline/proc.jsonl
VH_OUT=/tmp/spurarm_pipeline/vh.jsonl
ALFRED_OUT=/tmp/spurarm_pipeline/alfred_raw.jsonl
ALFRED_CAPPED=/tmp/spurarm_pipeline/alfred.jsonl
SEED_OUT=/tmp/spurarm_pipeline/seed.jsonl
SUB_OUT=/tmp/spurarm_pipeline/substrate.jsonl
RAW_OUT="$OUTDIR/spurarm_v0_raw.jsonl"
DEDUP_OUT="$OUTDIR/spurarm_v0.jsonl"
STATS_OUT="$OUTDIR/spurarm_v0_stats.json"

echo "=== pipeline: PROC_N=$PROC_N ALFRED_CAP=$ALFRED_CAP EVAL_TARGET=$EVAL_TARGET SFT_TARGET=$SFT_TARGET ==="

echo ""
echo "--- 1) proc ---"
./rail_native run tools/spurarm/corpus/synthesize_procedural.rail "$PROC_N" "$PROC_OUT" || true
wc -l "$PROC_OUT" || true

echo ""
echo "--- 2) virtualhome ---"
if [ -n "$VH_DIR" ] && [ -d "$VH_DIR" ]; then
  sh tools/spurarm/corpus/extract_virtualhome.sh "$VH_DIR" "$VH_OUT" 99999 || true
else
  echo "VH_DIR='$VH_DIR' not found; skipping."
  : > "$VH_OUT"
fi
wc -l "$VH_OUT" || true

echo ""
echo "--- 3) alfred ---"
if [ -n "$ALFRED_DIR" ] && [ -d "$ALFRED_DIR" ]; then
  sh tools/spurarm/corpus/extract_alfred.sh "$ALFRED_DIR" "$ALFRED_OUT" 99999 || true
  alfred_full=$(wc -l < "$ALFRED_OUT" | tr -d ' ')
  if [ "$alfred_full" -gt "$ALFRED_CAP" ]; then
    awk -v n="$ALFRED_CAP" 'BEGIN{srand(42)} {a[NR]=$0} END{
      cnt=NR; for (i=0;i<n && cnt>0;i++) { r=int(rand()*cnt)+1; print a[r]; a[r]=a[cnt]; cnt--; }
    }' "$ALFRED_OUT" > "$ALFRED_CAPPED"
    echo "alfred capped: $alfred_full -> $ALFRED_CAP"
  else
    cp "$ALFRED_OUT" "$ALFRED_CAPPED"
  fi
else
  echo "ALFRED_DIR='$ALFRED_DIR' not found; skipping."
  : > "$ALFRED_CAPPED"
fi
wc -l "$ALFRED_CAPPED" || true

echo ""
echo "--- 4) seed ---"
if [ -n "$SEED_DIR" ] && [ -d "$SEED_DIR" ]; then
  COMP_DIR="$SEED_DIR" sh tools/spurarm/corpus/extract_seed.sh "$SEED_OUT" || true
else
  echo "SEED_DIR='$SEED_DIR' not found; skipping."
  : > "$SEED_OUT"
fi
wc -l "$SEED_OUT" || true

echo ""
echo "--- 5) substrate (precomputed) ---"
if [ -f "$SUBSTRATE_JSONL" ]; then
  cp "$SUBSTRATE_JSONL" "$SUB_OUT"
else
  : > "$SUB_OUT"
fi
wc -l "$SUB_OUT" || true

echo ""
echo "--- 6) concat raw ---"
cat "$PROC_OUT" "$VH_OUT" "$ALFRED_CAPPED" "$SEED_OUT" "$SUB_OUT" > "$RAW_OUT"
wc -l "$RAW_OUT"

echo ""
echo "--- 7) dedup ---"
sh tools/spurarm/corpus/dedup.sh "$RAW_OUT" "$DEDUP_OUT"

echo ""
echo "--- 8) split ---"
sh tools/spurarm/corpus/split.sh "$DEDUP_OUT" "$OUTDIR" "$EVAL_TARGET"
# Reconstitute spurarm_v0.jsonl as pretrain + sft + eval (in order)
cat "$OUTDIR/spurarm_v0_pretrain.jsonl" "$OUTDIR/spurarm_v0_sft.jsonl" "$OUTDIR/spurarm_v0_eval.jsonl" > "$DEDUP_OUT"

echo ""
echo "--- 9) stats ---"
sh tools/spurarm/corpus/stats.sh "$OUTDIR" "$STATS_OUT"

echo ""
echo "--- 10) acceptance ---"
sh tools/spurarm/corpus/acceptance.sh "$OUTDIR"
