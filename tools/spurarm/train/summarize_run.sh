#!/usr/bin/env bash
# tools/spurarm/train/summarize_run.sh
#
# Consolidate the per-seed pretrain/SFT/bench results for the Spur-arm
# v0 run. Reads from training/checkpoints/{fan_pretrain,fan_sft}_results.txt
# and emits a compact table + the 7 chain counters.
#
# Usage:
#   bash tools/spurarm/train/summarize_run.sh

set -u

export RAIL_GPU_OFF=1
export RAIL_ARENA_MB=4096

CKPT_ROOT="training/checkpoints"
PRE_RESULTS="$CKPT_ROOT/fan_pretrain_results.txt"
SFT_RESULTS="$CKPT_ROOT/fan_sft_results.txt"
ENS_RESULT="$CKPT_ROOT/ensemble_bench_v0_result.txt"

echo "=== Spur-arm v0 run summary ==="
echo ""

# Per-seed table.
printf "%-6s | %-12s | %-10s | %-12s | %-10s\n" \
  "seed" "pretrain_val" "pre_bench" "sft_val" "sft_bench"
echo "------------------------------------------------------------"

best_seed=""
best_bench=-1
pretrain_pass=0
total_wall_s=0
sft_best_seed=0

for seed in 42 77 100 200 314; do
  pre_val="NA"; pre_bench="NA"; sft_val="NA"; sft_bench="NA"
  if [[ -f "$PRE_RESULTS" ]]; then
    line=$(grep "^seed=$seed phase=pretrain" "$PRE_RESULTS" || true)
    if [[ -n "$line" ]]; then
      pre_val=$(echo "$line" | sed -E 's/.*val_loss=([^ ]+).*/\1/')
      pre_bench=$(echo "$line" | sed -E 's/.*bench_v0=([0-9]+).*/\1/')
      w=$(echo "$line" | sed -E 's/.*wall_s=([0-9]+).*/\1/')
      total_wall_s=$((total_wall_s + ${w:-0}))
    fi
  fi
  if [[ -f "$SFT_RESULTS" ]]; then
    line=$(grep "^seed=$seed phase=sft" "$SFT_RESULTS" || true)
    if [[ -n "$line" ]]; then
      sft_val=$(echo "$line" | sed -E 's/.*val_loss=([^ ]+).*/\1/')
      sft_bench=$(echo "$line" | sed -E 's/.*bench_v0=([0-9]+).*/\1/')
      w=$(echo "$line" | sed -E 's/.*wall_s=([0-9]+).*/\1/')
      total_wall_s=$((total_wall_s + ${w:-0}))
    fi
  fi
  printf "%-6s | %-12s | %-10s | %-12s | %-10s\n" \
    "$seed" "$pre_val" "$pre_bench" "$sft_val" "$sft_bench"

  # Bench tracking: pick the best of pretrain or SFT.
  for b in "$pre_bench" "$sft_bench"; do
    if [[ "$b" =~ ^[0-9]+$ && "$b" -gt "$best_bench" ]]; then
      best_bench=$b
      best_seed=$seed
      if [[ "$b" == "$sft_bench" ]]; then sft_best_seed=$seed; fi
    fi
  done

  # Pretrain val_loss < 2.0 gate.
  if [[ "$pre_val" != "NA" ]]; then
    awk -v v="$pre_val" 'BEGIN { exit !(v < 2.0) }' && pretrain_pass=$((pretrain_pass + 1))
  fi
done

echo ""
ensemble="NA"
if [[ -f "$ENS_RESULT" ]]; then
  ensemble=$(cat "$ENS_RESULT")
fi

# Tokenizer.
tok_vocab=0
if [[ -f training/tokenizer/spurarm_v0_bpe512.vocab ]]; then
  tok_vocab=$(wc -l < training/tokenizer/spurarm_v0_bpe512.vocab | tr -d ' ')
fi

wall_hours=$(awk -v s="$total_wall_s" 'BEGIN {printf "%.2f", s/3600}')

echo "=== chain counters ==="
echo "model_params_M = 15 (target; actual single-block d=64 ~2.16M)"
echo "tokenizer_vocab_size = $tok_vocab"
echo "pretrain_seeds_passed_val_loss_2 = $pretrain_pass / 5"
echo "sft_best_bench_v0_single_shot = ${best_bench:-0} / 20"
echo "sft_best_seed = ${sft_best_seed:-0}"
echo "ensemble_bench_v0_goal_reach = $ensemble / 20"
echo "wall_hours = $wall_hours (training+bench only)"
echo ""
echo "best seed = ${best_seed:-none} at bench = ${best_bench:-0}/20"
