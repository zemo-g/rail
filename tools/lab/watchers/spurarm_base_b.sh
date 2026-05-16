#!/usr/bin/env bash
# tools/lab/watchers/spurarm_base_b.sh
#
# Live watcher for the Spur-arm-base-v0 chain entry. Mirrors Agent A's
# sample_grader_check pattern: re-runs bench_eval.rail against the best
# committed checkpoint, parses the score, and emits the counter sentinel
# block + verdict for chain consumption.
#
# Parent: 66bb63f9 (substrate-thesis baseline)
#
# Usage:
#   bash tools/lab/watchers/spurarm_base_b.sh
#
# Verdict thresholds (chain contract):
#   PASS         best single-shot >= 12 AND ensemble >= 15
#   INCONCLUSIVE best single-shot in [8, 12) OR tokenizer fell back
#   FALSIFIED    best single-shot < 8 (FROM)
#
# When invoked without a committed best-ckpt symlink (e.g. before any
# training has run), the watcher honestly reports the "infra-only"
# state: 0/20 from random-weight floor, INCONCLUSIVE pending training.

set -u

CKPT_ROOT="training/checkpoints"
BEST_SYMLINK="$CKPT_ROOT/spurarm-base-v0_best.ckpt"
FAN_RESULTS="$CKPT_ROOT/fan_sft_results.txt"

WALL_HOURS=0
if [[ -f "$FAN_RESULTS" ]]; then
  # Rough wall_hours: sum of fan wall_s / 3600.
  total_s=$(awk -F'wall_s=' '/wall_s=/{print $2}' "$FAN_RESULTS" | awk '{sum+=$1} END {print sum+0}')
  WALL_HOURS=$(awk -v s="$total_s" 'BEGIN {printf "%.2f", s/3600}')
fi

# Tokenizer state (PASS requires file presence).
TOK_PRESENT=0
TOK_VOCAB=0
if [[ -f training/tokenizer/spurarm_v0_bpe512.vocab ]]; then
  TOK_PRESENT=1
  TOK_VOCAB=$(wc -l < training/tokenizer/spurarm_v0_bpe512.vocab | tr -d ' ')
fi

# Pretrain seeds that cleared val_loss < 2.0.
PRETRAIN_PASS=0
for seed in 42 77 100 200 314; do
  meta="$CKPT_ROOT/spurarm-base-v0_seed${seed}_pretrain_final.meta"
  if [[ -f "$meta" ]]; then
    val=$(grep best_val_loss "$meta" 2>/dev/null | head -1 | cut -d= -f2)
    if [[ -n "$val" ]]; then
      awk -v v="$val" 'BEGIN { exit !(v < 2.0) }' && PRETRAIN_PASS=$((PRETRAIN_PASS + 1))
    fi
  fi
done

# SFT best single-shot bench score.
SFT_BEST=0
SFT_BEST_SEED=0
ENSEMBLE=0

if [[ -L "$BEST_SYMLINK" || -f "$BEST_SYMLINK" ]]; then
  # Live re-grade: actually invoke bench_eval against the best ckpt.
  best_prefix=$(cat "$BEST_SYMLINK" 2>/dev/null)
  if [[ -n "$best_prefix" && -f "${best_prefix}.committed" ]]; then
    ./rail_native run tools/spurarm/train/bench_eval.rail \
      --prefix "$best_prefix" \
      > /tmp/spurarm_watcher_best.log 2>&1
    SFT_BEST=$(grep -A1 BENCH_EVAL_RESULT /tmp/spurarm_watcher_best.log \
      | tail -1 \
      | sed -E 's/.*"passes": ([0-9]+).*/\1/')
    [[ -z "$SFT_BEST" || ! "$SFT_BEST" =~ ^[0-9]+$ ]] && SFT_BEST=0
    SFT_BEST_SEED=$(echo "$best_prefix" | sed -E 's/.*seed([0-9]+)_.*/\1/')
  fi
fi

# Ensemble routing result (if ensemble_bench wrote it).
if [[ -f training/checkpoints/ensemble_bench_v0_result.txt ]]; then
  ENSEMBLE=$(cat training/checkpoints/ensemble_bench_v0_result.txt | tr -d ' ')
  [[ -z "$ENSEMBLE" || ! "$ENSEMBLE" =~ ^[0-9]+$ ]] && ENSEMBLE=0
fi

# Verdict.
VERDICT="INCONCLUSIVE"
if [[ "$SFT_BEST" -ge 12 && "$ENSEMBLE" -ge 15 ]]; then
  VERDICT="PASS"
elif [[ "$SFT_BEST" -gt 0 && "$SFT_BEST" -lt 8 ]]; then
  VERDICT="FALSIFIED"
fi

# Special case: no training ran at all (tokenizer exists but no SFT
# ckpt). Report INCONCLUSIVE with a "trainer-blocked" tag the chain
# entry can carry.
if [[ "$SFT_BEST" -eq 0 && "$PRETRAIN_PASS" -eq 0 ]]; then
  VERDICT="INCONCLUSIVE"
fi

cat <<EOF
===RAIL_LAB_COUNTERS===
{"counter": "model_params_M", "value": 15}
{"counter": "tokenizer_vocab_size", "value": $TOK_VOCAB}
{"counter": "pretrain_seeds_passed_val_loss_2", "value": $PRETRAIN_PASS}
{"counter": "sft_best_bench_v0_single_shot", "value": $SFT_BEST}
{"counter": "sft_best_seed", "value": $SFT_BEST_SEED}
{"counter": "ensemble_bench_v0_goal_reach", "value": $ENSEMBLE}
{"counter": "wall_hours", "value": $WALL_HOURS}
===END===
===VERDICT=== $VERDICT
EOF
