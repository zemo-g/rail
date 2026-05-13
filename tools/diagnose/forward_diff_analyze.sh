#!/bin/bash
# forward_diff_analyze.sh — per-layer CPU↔GPU divergence table from existing
# /tmp/forward_dump_{cpu,gpu}/ dumps. Doesn't re-run the bins.
#
# Companion to forward_diff.sh (which runs both bins then analyses).
# Use this when you've already produced dumps and just want to recompute the
# table (different prompt, after retraining, etc.).
#
# Handles shape mismatch: CPU substrate is shape-narrowed to active=prompt_len
# whereas GPU substrate runs full [seq, d/V]. We compare CPU's full dump
# against GPU's first len(cpu) floats — the row-major prompt-position rows.
#
# Usage: tools/diagnose/forward_diff_analyze.sh

set -u
GPU_DUMP=/tmp/forward_dump_gpu
CPU_DUMP=/tmp/forward_dump_cpu

LAYERS=(
  x_embed
  block0_ln1 block0_attn_out block0_x_attn block0_ln2 block0_h_out block0_x_out
  block1_ln1 block1_attn_out block1_x_attn block1_ln2 block1_h_out block1_x_out
  x_final logits
)

printf '\n%-20s  %-14s  %-14s  %-14s  %-8s\n' \
  "Layer" "max_abs_delta" "mean_abs_delta" "rms_delta" "n"
printf -- '─%.0s' {1..80}; printf '\n'

for layer in "${LAYERS[@]}"; do
  cpu_f=$CPU_DUMP/$layer.txt
  gpu_f=$GPU_DUMP/$layer.txt
  if [ ! -s "$cpu_f" ] || [ ! -s "$gpu_f" ]; then
    printf '%-20s  %s\n' "$layer" "MISSING (cpu=$([ -s $cpu_f ] && echo OK || echo MISS) gpu=$([ -s $gpu_f ] && echo OK || echo MISS))"
    continue
  fi
  cpu_n=$(awk 'END{print NR}' "$cpu_f")
  paste -d ' ' "$cpu_f" <(head -n "$cpu_n" "$gpu_f") | awk -v lyr="$layer" '
    {
      a = $1 + 0; b = $2 + 0;
      d = a - b; if (d < 0) d = -d;
      if (d > max_d) max_d = d;
      sum_d += d; sum_d2 += d * d;
      n++;
    }
    END {
      printf "%-20s  %-14.6e  %-14.6e  %-14.6e  %-8d\n", lyr, max_d, sum_d/n, sqrt(sum_d2/n), n;
    }'
done

cat <<'EOF'

=== INTERPRETATION (from docs/plans/GPU_DIVERGENCE_MAP.md) ===
If max_abs_delta at any pre-RMSNorm layer is >1.0, the divergence is NOT
fp16 precision drift (which would be sub-ULP per op). It's a kernel
arithmetic difference OR a body-fp16-vs-body-f64 dynamic-range mismatch.

The 'logits' row is the most-load-bearing for bench top-k since logit
ranks decide sampling. If logits delta is small but x_final delta is
also small, RMSNorm at the head is rescuing the divergence — meaning
the substrate's argmax MAY be in the right ballpark while the body
representation is drifting wildly. (See memory v54_fp32logits_partial_lift.md.)
EOF
