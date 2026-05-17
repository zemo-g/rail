#!/usr/bin/env bash
# tools/spurarm/train/multi_seed_fan.sh
#
# Fan training across 5 seeds, sequential (Studio panic discipline:
# don't stack heavy workloads -- see memory `studio_panic_pattern`).
# Per `feedback_blob_slice_fan_condense`.
#
# Usage:
#   bash tools/spurarm/train/multi_seed_fan.sh \
#     [--phase=pretrain|sft] \
#     [--seeds=42,77,100,200,314] \
#     [--steps=2000]
#
# Output structure:
#   training/checkpoints/spurarm-base-v0_seed<N>_<phase>_step<S>.{ckpt files}
#   training/checkpoints/spurarm-base-v0_seed<N>_<phase>_step<S>.meta
#   training/checkpoints/spurarm-base-v0_seed<N>_<phase>_step<S>.committed
#
# At end:
#   Summary line per seed: <seed>: val_loss=<X> bench_v0=<N>/20
#   Best seed across the fan symlinked at
#     training/checkpoints/spurarm-base-v0_best.ckpt

set -u

# Force CPU fallback + bigger arena (Studio Metal stack is currently
# broken; honored via the worktree-aware gpu_available fix landed
# 2026-05-16). See gpu_available_hardcoded_worktree_path memory.
export RAIL_GPU_OFF=1
export RAIL_ARENA_MB=4096

PHASE="pretrain"
SEEDS="42,77,100,200,314"
STEPS=""
EVAL_BENCH=1

for arg in "$@"; do
  case "$arg" in
    --phase=*) PHASE="${arg#--phase=}" ;;
    --seeds=*) SEEDS="${arg#--seeds=}" ;;
    --steps=*) STEPS="${arg#--steps=}" ;;
    --no-bench) EVAL_BENCH=0 ;;
    *) echo "unknown arg: $arg" ; exit 2 ;;
  esac
done

if [[ "$PHASE" != "pretrain" && "$PHASE" != "sft" ]]; then
  echo "ERR: --phase must be pretrain or sft, got $PHASE"
  exit 2
fi

echo "=== multi_seed_fan phase=$PHASE seeds=$SEEDS steps=${STEPS:-default} ==="

CKPT_ROOT="training/checkpoints"
mkdir -p "$CKPT_ROOT"

IFS=',' read -ra SEED_ARR <<< "$SEEDS"
RESULTS_FILE="$CKPT_ROOT/fan_${PHASE}_results.txt"
: > "$RESULTS_FILE"

best_seed=""
best_score=-1
best_val=999.0

for seed in "${SEED_ARR[@]}"; do
  echo "--- seed $seed ($PHASE) ---"
  start_ts=$(date +%s)

  steps_arg=""
  if [[ -n "$STEPS" ]]; then
    steps_arg="--steps $STEPS"
  fi

  # Train (writes a checkpoint at the configured cadence).
  ./rail_native run tools/spurarm/train/train_spurarm.rail \
    --phase "$PHASE" \
    --seed "$seed" \
    $steps_arg 2>&1 | tail -20

  end_ts=$(date +%s)
  wall=$((end_ts - start_ts))

  # Read final val_loss from the seed's final ckpt meta.
  prefix="$CKPT_ROOT/spurarm-base-v0_seed${seed}_${PHASE}_final"
  if [[ ! -f "${prefix}.committed" ]]; then
    echo "WARN: seed $seed did not produce a committed ckpt at $prefix"
    echo "seed=$seed phase=$PHASE val_loss=NA bench_v0=NA wall_s=$wall" >> "$RESULTS_FILE"
    continue
  fi

  val_loss=$(grep best_val_loss "${prefix}.meta" 2>/dev/null | head -1 | cut -d= -f2)
  : "${val_loss:=NA}"

  bench_score=0
  if [[ "$EVAL_BENCH" == "1" ]]; then
    # Clear stale generator binary so cached stub doesn't pollute.
    rm -f /tmp/spurarm_gen_bin /tmp/spurarm_gen_bin.tag
    ./rail_native run tools/spurarm/train/bench_eval.rail \
      --prefix "$prefix" \
      --max-gen 60 \
      --out /tmp/bench_eval_${seed}_${PHASE}.txt 2>&1 \
      | tee /tmp/bench_eval_${seed}_${PHASE}.log \
      | tail -10
    # Parse the bench result sentinel.
    bench_line=$(grep -A1 BENCH_EVAL_RESULT /tmp/bench_eval_${seed}_${PHASE}.log | tail -1)
    bench_score=$(echo "$bench_line" | sed -E 's/.*"passes": ([0-9]+).*/\1/' || echo 0)
    [[ -z "$bench_score" || ! "$bench_score" =~ ^[0-9]+$ ]] && bench_score=0
  fi

  echo "seed=$seed phase=$PHASE val_loss=$val_loss bench_v0=$bench_score/20 wall_s=$wall" >> "$RESULTS_FILE"

  if [[ "$bench_score" -gt "$best_score" ]]; then
    best_score=$bench_score
    best_seed=$seed
    best_val=$val_loss
  fi

  echo "  done. val_loss=$val_loss bench=$bench_score/20 wall=${wall}s"
done

echo ""
echo "=== fan summary ==="
cat "$RESULTS_FILE"

if [[ -n "$best_seed" && "$PHASE" == "sft" ]]; then
  best_prefix="$CKPT_ROOT/spurarm-base-v0_seed${best_seed}_sft_final"
  ln -sf "$(basename ${best_prefix}.committed)" "$CKPT_ROOT/spurarm-base-v0_best.committed"
  echo "best seed = $best_seed (bench=$best_score val_loss=$best_val)"
  echo "$best_prefix" > "$CKPT_ROOT/spurarm-base-v0_best.ckpt"
fi

echo "done."
