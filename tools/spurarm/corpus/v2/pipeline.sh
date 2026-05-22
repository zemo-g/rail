#!/bin/sh
# tools/spurarm/corpus/v2/pipeline.sh
#
# End-to-end build for spurarm_v2. SPEC §10 reproducer.
#
# Pipeline stages:
#   0. preflight   -- verify rail_native + jq + Studio :8082 substrate
#   1. proc_v2     -- procedural synthesis (uniform front-hemisphere)
#   2. vh          -- VirtualHome verb-remap (broader walk)
#   3. alfred      -- ALFRED PDDL verb-remap (cap 20000)
#   4. seed        -- regrade prior reranks (+ optional post-Stage-7)
#   5. substrate   -- substrate paraphrase (target 12000)
#   6. concat -> dedup -> split -> stats -> acceptance
#
# Substrate availability is checked BEFORE any inference call. Pipeline
# aborts cleanly if the 122B isn't loaded (SPEC §9d co-resident swap).
#
# ALFRED + VH walks run as background jobs in parallel with proc_v2
# where possible (substrate is the long tail and stays serial).
#
# Knobs:
#   PROC_N=60000
#   ALFRED_CAP=20000
#   VH_DIR=/tmp/vh_extract/programs_processed_precond_nograb_morepreconds
#   ALFRED_DIR=/tmp/alfred_data/json_2.1.0
#   SEED_DIR=/tmp/robot_completions_rerank
#   SUBSTRATE_TARGET=12000
#   SFT_TARGET=20000
#   EVAL_TARGET=200
#   SKIP_SUBSTRATE=0     -- set to 1 to skip the substrate stage

set -u
PROC_N="${PROC_N:-60000}"
ALFRED_CAP="${ALFRED_CAP:-20000}"
VH_DIR="${VH_DIR:-/tmp/vh_extract/programs_processed_precond_nograb_morepreconds}"
ALFRED_DIR="${ALFRED_DIR:-/tmp/alfred_data/json_2.1.0}"
SEED_DIR="${SEED_DIR:-/tmp/robot_completions_rerank}"
COMP_DIR_POST="${COMP_DIR_POST:-/tmp/robot_completions_stage7_rerank}"
SUBSTRATE_TARGET="${SUBSTRATE_TARGET:-12000}"
SFT_TARGET="${SFT_TARGET:-20000}"
EVAL_TARGET="${EVAL_TARGET:-200}"
SKIP_SUBSTRATE="${SKIP_SUBSTRATE:-0}"
PORT="${PORT:-8082}"

OUTDIR="${OUTDIR:-training/corpora_v2}"
mkdir -p "$OUTDIR"
mkdir -p /tmp/spurarm_v2_pipeline

PROC_OUT=/tmp/spurarm_v2_pipeline/proc_v2.jsonl
VH_OUT=/tmp/spurarm_v2_pipeline/vh.jsonl
ALFRED_RAW=/tmp/spurarm_v2_pipeline/alfred_raw.jsonl
ALFRED_OUT=/tmp/spurarm_v2_pipeline/alfred.jsonl
SEED_OUT=/tmp/spurarm_v2_pipeline/seed.jsonl
SUB_OUT=/tmp/spurarm_v2_pipeline/substrate.jsonl
RAW_OUT="$OUTDIR/spurarm_v2_raw.jsonl"
DEDUP_OUT="$OUTDIR/spurarm_v2.jsonl"
STATS_OUT="$OUTDIR/spurarm_v2_stats.json"

echo "=== pipeline (v2): PROC_N=$PROC_N ALFRED_CAP=$ALFRED_CAP SUBSTRATE_TARGET=$SUBSTRATE_TARGET ==="
echo "=== SFT_TARGET=$SFT_TARGET EVAL_TARGET=$EVAL_TARGET OUTDIR=$OUTDIR ==="

# ---- 0. PREFLIGHT ----
echo ""
echo "--- 0) preflight ---"
if [ ! -x "./rail_native" ]; then
  echo "ERROR: ./rail_native not executable in $(pwd)" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required" >&2
  exit 2
fi
# Substrate probe: REQUIRED unless explicitly skipped.
if [ "$SKIP_SUBSTRATE" = "0" ]; then
  if ! curl -sS --max-time 3 "http://localhost:$PORT/v1/models" 2>/dev/null | grep -q '"id"'; then
    echo "ERROR: no substrate at localhost:$PORT. Set SKIP_SUBSTRATE=1 to bypass." >&2
    echo "  (Substrate is required for v2 unless skipping; SPEC §9d.)"
    exit 2
  fi
  model_id=$(curl -sS --max-time 3 "http://localhost:$PORT/v1/models" 2>/dev/null \
    | jq -r '.data[0].id // .data.id // "unknown"')
  echo "substrate up at :$PORT model=$model_id"
else
  echo "substrate stage will be SKIPPED (SKIP_SUBSTRATE=1)"
fi

# ---- 1. PROC_v2 ----
echo ""
echo "--- 1) proc_v2 ---"
./rail_native run tools/spurarm/corpus/v2/synthesize_procedural.rail "$PROC_N" "$PROC_OUT" || true
wc -l "$PROC_OUT" || true

# ---- 2/3. VH + ALFRED in parallel ----
echo ""
echo "--- 2/3) virtualhome + alfred (parallel) ---"

vh_pid=""
if [ -n "$VH_DIR" ] && [ -d "$VH_DIR" ]; then
  ( sh tools/spurarm/corpus/v2/extract_virtualhome.sh "$VH_DIR" "$VH_OUT" 99999 \
    > /tmp/spurarm_v2_pipeline/vh.log 2>&1 ) &
  vh_pid=$!
else
  echo "VH_DIR='$VH_DIR' not found; skipping."
  : > "$VH_OUT"
fi

alfred_pid=""
if [ -n "$ALFRED_DIR" ] && [ -d "$ALFRED_DIR" ]; then
  ( sh tools/spurarm/corpus/v2/extract_alfred.sh "$ALFRED_DIR" "$ALFRED_RAW" 99999 \
    > /tmp/spurarm_v2_pipeline/alfred.log 2>&1 ) &
  alfred_pid=$!
else
  echo "ALFRED_DIR='$ALFRED_DIR' not found; skipping."
  : > "$ALFRED_RAW"
fi

# Wait for parallel jobs.
[ -n "$vh_pid" ] && wait "$vh_pid"
[ -n "$alfred_pid" ] && wait "$alfred_pid"

if [ -n "$vh_pid" ]; then
  cat /tmp/spurarm_v2_pipeline/vh.log
fi
if [ -n "$alfred_pid" ]; then
  cat /tmp/spurarm_v2_pipeline/alfred.log
fi

# ALFRED subsample to ALFRED_CAP.
alfred_full=$(wc -l < "$ALFRED_RAW" | tr -d ' ')
if [ "$alfred_full" -gt "$ALFRED_CAP" ]; then
  awk -v n="$ALFRED_CAP" 'BEGIN{srand(42)} {a[NR]=$0} END{
    cnt=NR; for (i=0;i<n && cnt>0;i++) { r=int(rand()*cnt)+1; print a[r]; a[r]=a[cnt]; cnt--; }
  }' "$ALFRED_RAW" > "$ALFRED_OUT"
  echo "alfred capped: $alfred_full -> $ALFRED_CAP"
else
  cp "$ALFRED_RAW" "$ALFRED_OUT"
fi
wc -l "$VH_OUT" "$ALFRED_OUT" || true

# ---- 4. SEED ----
echo ""
echo "--- 4) seed ---"
COMP_DIR="$SEED_DIR" COMP_DIR_POST="$COMP_DIR_POST" \
  sh tools/spurarm/corpus/v2/extract_seed.sh "$SEED_OUT" || true
wc -l "$SEED_OUT" || true

# ---- 5. SUBSTRATE ----
echo ""
echo "--- 5) substrate ---"
if [ "$SKIP_SUBSTRATE" = "0" ]; then
  # Build the seed pool: seed jsonl + small proc sample for diversity.
  TMP_SEED_POOL=/tmp/spurarm_v2_pipeline/substrate_seed_pool.jsonl
  cat "$SEED_OUT" > "$TMP_SEED_POOL"
  # Add up to 2000 proc samples for variety.
  head -2000 "$PROC_OUT" >> "$TMP_SEED_POOL" || true
  SUBSTRATE_TARGET="$SUBSTRATE_TARGET" PORT="$PORT" \
    sh tools/spurarm/corpus/v2/synthesize_substrate.sh "$TMP_SEED_POOL" "$SUB_OUT" 6 2500 || true
else
  : > "$SUB_OUT"
  echo "substrate skipped (SKIP_SUBSTRATE=1)"
fi
wc -l "$SUB_OUT" || true

# ---- 6. CONCAT + DEDUP + SPLIT + STATS + ACCEPTANCE ----
echo ""
echo "--- 6) concat raw ---"
cat "$PROC_OUT" "$VH_OUT" "$ALFRED_OUT" "$SEED_OUT" "$SUB_OUT" > "$RAW_OUT"
wc -l "$RAW_OUT"

echo ""
echo "--- 7) dedup ---"
sh tools/spurarm/corpus/v2/dedup.sh "$RAW_OUT" "$DEDUP_OUT"

echo ""
echo "--- 8) split ---"
SFT_TARGET="$SFT_TARGET" \
  sh tools/spurarm/corpus/v2/split.sh "$DEDUP_OUT" "$OUTDIR" "$EVAL_TARGET"
cat "$OUTDIR/spurarm_v2_pretrain.jsonl" \
    "$OUTDIR/spurarm_v2_sft.jsonl" \
    "$OUTDIR/spurarm_v2_eval.jsonl" > "$DEDUP_OUT"

echo ""
echo "--- 9) stats ---"
sh tools/spurarm/corpus/v2/stats.sh "$OUTDIR" "$STATS_OUT"

echo ""
echo "--- 10) acceptance ---"
sh tools/spurarm/corpus/v2/acceptance.sh "$OUTDIR"
