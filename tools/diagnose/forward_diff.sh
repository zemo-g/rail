#!/bin/bash
# forward_diff.sh — run both forward_dump substrates on the same ckpt + prompt,
# then emit a per-layer max-abs / mean-abs delta table.
#
# Usage: tools/diagnose/forward_diff.sh <ckpt_prefix> [prompt]
# Example:
#   tools/diagnose/forward_diff.sh \
#     training/rail_native/checkpoints/spur_v54_BQ2_s77_best "main = "

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$REPO_ROOT"

CKPT=${1:?usage: $0 <ckpt_prefix> [prompt]}
PROMPT=${2:-"main = "}

GPU_DUMP=/tmp/forward_dump_gpu
CPU_DUMP=/tmp/forward_dump_cpu
mkdir -p "$GPU_DUMP" "$CPU_DUMP"
rm -f "$GPU_DUMP"/*.txt "$CPU_DUMP"/*.txt

echo "=== STEP 1: GPU substrate (mixed precision) ==="
"$SCRIPT_DIR/forward_dump_gpu_bin" --prefix "$CKPT" --prompt "$PROMPT" 2>&1 | tail -10
echo ""
echo "=== STEP 2: CPU substrate (pure f64) ==="
"$SCRIPT_DIR/forward_dump_cpu_bin" --prefix "$CKPT" --prompt "$PROMPT" 2>&1 | tail -10

echo ""
echo "=== STEP 3: PER-LAYER DIVERGENCE TABLE ==="

# Tensors to compare in fixed order so the table reads top-to-bottom of the
# forward pass.
LAYERS=(x_embed block0_x_attn block0_x_out block1_x_attn block1_x_out x_final logits)

printf '\n%-20s  %-12s  %-12s  %-12s  %-8s\n' \
  "Layer" "max_abs_delta" "mean_abs_delta" "rms_delta" "n"
printf -- '─%.0s' {1..76}; printf '\n'

for layer in "${LAYERS[@]}"; do
  cpu_f=$CPU_DUMP/$layer.txt
  gpu_f=$GPU_DUMP/$layer.txt
  if [ ! -s "$cpu_f" ] || [ ! -s "$gpu_f" ]; then
    printf '%-20s  %s\n' "$layer" "MISSING (cpu=$([ -s $cpu_f ] && echo OK || echo MISS) gpu=$([ -s $gpu_f ] && echo OK || echo MISS))"
    continue
  fi
  awk_out=$(paste -d ' ' "$cpu_f" "$gpu_f" | awk '
    {
      a = $1; b = $2;
      d = a - b; if (d < 0) d = -d;
      if (d > max_d) max_d = d;
      sum_d += d; sum_d2 += d * d;
      n++;
    }
    END {
      printf "%.6e %.6e %.6e %d", max_d, sum_d/n, sqrt(sum_d2/n), n;
    }
  ')
  read -r max_d mean_d rms_d n_vals <<< "$awk_out"
  printf '%-20s  %-12s  %-12s  %-12s  %-8s\n' \
    "$layer" "$max_d" "$mean_d" "$rms_d" "$n_vals"
done

echo ""
echo "=== INTERPRETATION ==="
echo "If max_abs_delta grows monotonically through the forward pass, it's"
echo "compounded fp16 precision drift. If it spikes at one layer, that"
echo "layer's kernel is suspect. The 'logits' row is the most-load-bearing"
echo "for bench top-k since logit ranks decide sampling."
exit 0
