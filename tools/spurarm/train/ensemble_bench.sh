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

SEEDS="42,77,100,200,314"
PARALLEL=2

for arg in "$@"; do
  case "$arg" in
    --seeds=*) SEEDS="${arg#--seeds=}" ;;
    --parallel=*) PARALLEL="${arg#--parallel=}" ;;
    *) echo "unknown arg: $arg" ; exit 2 ;;
  esac
done

IFS=',' read -ra SEED_ARR <<< "$SEEDS"

LOG=/tmp/spurarm_ensemble_bench.log
: > "$LOG"

# Per-seed bench (sequential or N-at-a-time per Studio panic discipline).
run_one_seed() {
  local seed="$1"
  local prefix="training/checkpoints/spurarm-base-v0_seed${seed}_sft_final"
  local out="/tmp/spurarm_ensemble_${seed}.log"
  if [[ ! -f "${prefix}.committed" ]]; then
    echo "WARN: no ckpt for seed $seed (${prefix})" >&2
    : > "$out"
    return 0
  fi
  ./rail_native run tools/spurarm/train/bench_eval.rail \
    --prefix "$prefix" \
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

# Now read each seed's per-prompt grade and OR them. We approximate by
# re-running the grader on each prompt for each seed; for the v0 script
# we just take the max across seeds, since bench_eval doesn't emit
# per-prompt detail in the current format. Improvement: emit per-prompt
# detail and OR.
#
# Until the per-prompt JSON is wired in, ensemble = max single-shot.

max=0
for seed in "${SEED_ARR[@]}"; do
  out="/tmp/spurarm_ensemble_${seed}.log"
  [[ ! -s "$out" ]] && continue
  s=$(grep -A1 BENCH_EVAL_RESULT "$out" | tail -1 \
      | sed -E 's/.*"passes": ([0-9]+).*/\1/')
  [[ -z "$s" || ! "$s" =~ ^[0-9]+$ ]] && s=0
  echo "seed=$seed bench=$s/20" >> "$LOG"
  if [[ "$s" -gt "$max" ]]; then
    max=$s
  fi
done

echo "ensemble (max-across-seeds, fallback) = $max/20" | tee -a "$LOG"

mkdir -p training/checkpoints
echo "$max" > training/checkpoints/ensemble_bench_v0_result.txt
echo "wrote training/checkpoints/ensemble_bench_v0_result.txt"
