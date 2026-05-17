#!/usr/bin/env bash
# tools/spurarm/train/ensemble_bench.sh
#
# Per-prompt max-pass routing across the 5 SFT seed checkpoints.
# Mirrors the structure of tools/train/ensemble_ceiling.sh: for each
# bench prompt, accept the prompt as "passed" if ANY seed's
# greedy-argmax decode passes the grader.
#
# Per memory `parallel_rerank_works`: parallel rerank achieved 7.1x
# wall-clock at N=8. We use the same shape (5 seeds in parallel where
# safe; per `studio_panic_pattern` we cap concurrency to 2 to avoid
# Jetsam-induced panics).
#
# Usage:
#   bash tools/spurarm/train/ensemble_bench.sh [--seeds=42,77,100,200,314]
#
# Outputs:
#   /tmp/spurarm_ensemble_bench.log
#   training/checkpoints/ensemble_bench_v0_result.txt   (single integer)

set -u

# Force CPU fallback (worktree-local) and bigger arena.
export RAIL_GPU_OFF=1
export RAIL_ARENA_MB=4096

SEEDS="42,77,100,200,314"
PARALLEL=1
PHASE="sft"

for arg in "$@"; do
  case "$arg" in
    --seeds=*) SEEDS="${arg#--seeds=}" ;;
    --parallel=*) PARALLEL="${arg#--parallel=}" ;;
    --phase=*) PHASE="${arg#--phase=}" ;;
    *) echo "unknown arg: $arg" ; exit 2 ;;
  esac
done

IFS=',' read -ra SEED_ARR <<< "$SEEDS"

LOG=/tmp/spurarm_ensemble_bench.log
: > "$LOG"

# Per-seed bench (sequential or N-at-a-time per Studio panic discipline).
run_one_seed() {
  local seed="$1"
  local prefix="training/checkpoints/spurarm-base-v0_seed${seed}_${PHASE}_final"
  local out="/tmp/spurarm_ensemble_${seed}.log"
  if [[ ! -f "${prefix}.committed" ]]; then
    echo "WARN: no ckpt for seed $seed (${prefix})" >&2
    : > "$out"
    return 0
  fi
  # Clear stale generator binary so cached stub doesn't pollute.
  rm -f /tmp/spurarm_gen_bin /tmp/spurarm_gen_bin.tag
  ./rail_native run tools/spurarm/train/bench_eval.rail \
    --prefix "$prefix" \
    --max-gen 60 \
    > "$out" 2>&1
}

# Run seeds in batches of $PARALLEL.
i=0
batch=()
for seed in "${SEED_ARR[@]}"; do
  run_one_seed "$seed" &
  batch+=($!)
  i=$((i + 1))
  if [[ "$i" -ge "$PARALLEL" ]]; then
    wait "${batch[@]}"
    batch=()
    i=0
  fi
done
[[ "${#batch[@]}" -gt 0 ]] && wait "${batch[@]}"

# Per-prompt OR: for each bench id, the prompt passes the ensemble if
# ANY seed's bench_eval reported goal_reach=1. We rely on the
# ===BENCH_EVAL_PER_PROMPT=== sentinel block emitted by bench_eval.rail.

# Build per-prompt pass map across all seeds in awk.
PROMPT_MAP=/tmp/spurarm_ensemble_prompt_map.txt
: > "$PROMPT_MAP"

max=0
for seed in "${SEED_ARR[@]}"; do
  out="/tmp/spurarm_ensemble_${seed}.log"
  [[ ! -s "$out" ]] && continue
  s=$(grep -A1 BENCH_EVAL_RESULT "$out" | tail -1 \
      | sed -E 's/.*"passes": ([0-9]+).*/\1/')
  [[ -z "$s" || ! "$s" =~ ^[0-9]+$ ]] && s=0
  echo "seed=$seed single_shot=$s/20" >> "$LOG"
  [[ "$s" -gt "$max" ]] && max=$s

  # Extract per-prompt JSON line and emit "id goal_reach" rows.
  pp=$(grep -A1 BENCH_EVAL_PER_PROMPT "$out" | tail -1)
  if [[ -n "$pp" ]]; then
    # Parse: [{"id":"b01","goal_reach":1},...]
    echo "$pp" | tr ',' '\n' | grep -oE '"id":"[^"]+","goal_reach":[01]' \
      | sed -E 's/.*"id":"([^"]+)","goal_reach":([01])/\1 \2/' >> "$PROMPT_MAP"
  fi
done

# OR per id.
ENSEMBLE_PASS=0
if [[ -s "$PROMPT_MAP" ]]; then
  ENSEMBLE_PASS=$(awk '{m[$1] = m[$1] || $2} END {for (k in m) if (m[k] == 1) c++; print c+0}' "$PROMPT_MAP")
fi

echo "single-shot max-across-seeds = $max/20" | tee -a "$LOG"
echo "ensemble (per-prompt OR) = $ENSEMBLE_PASS/20" | tee -a "$LOG"

mkdir -p training/checkpoints
echo "$ENSEMBLE_PASS" > training/checkpoints/ensemble_bench_v0_result.txt
echo "wrote training/checkpoints/ensemble_bench_v0_result.txt = $ENSEMBLE_PASS"
