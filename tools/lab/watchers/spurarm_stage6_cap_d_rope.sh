#!/bin/sh
# tools/lab/watchers/spurarm_stage6_cap_d_rope.sh
#
# Stage 6 Cap D: RoPE replaces additive sinusoidal-PE. Does this lift
# bench past the 3/20 baseline?
#
# Trained from scratch (seed 42, pretrain 400 + SFT 200 — matching the
# Stage 5 baseline recipe so the comparison is apples-to-apples).
# Checkpoint prefix: training/checkpoints/spurarm-rope-v0_seed42_sft_final
#
# Forward (in train_spurarm.rail and generate.rail/probe_eos.rail):
#   - Skip additive sinusoidal PE on embedding (was add_buf_inplace)
#   - Apply rope_apply (in-place) on Q and K after their projections
# Backward (in train_spurarm.rail):
#   - rope_apply_inverse (in-place) on dQ,dK from attention_backward to
#     propagate to w_q,w_k as pre-rotation gradients.
#
# Bench: model-alone (Cap F's min-gen=0 default avoids fallback
# contamination noise). To stay comparable to the Stage 5 baseline, we
# report both:
#   - argmax (baseline decoder)         — apples-to-apples
#   - argmax + no-repeat-3gram + min-gen 12 (Cap F's strongest) — best
#                                           model-alone reading
# PASS if best_bench >= 4/20 (any decoder). FALSIFIED if <= 3/20.

PRETRAIN_FINAL_VAL=$(grep "^final val_loss=" /tmp/spurarm_cap_d/pretrain.log 2>/dev/null | tail -1 | awk -F= '{print $2}')
INITIAL_VAL=$(grep "^initial val_loss=" /tmp/spurarm_cap_d/pretrain.log 2>/dev/null | head -1 | awk -F= '{print $2}')
SFT_FINAL_VAL=$(grep "^final val_loss=" /tmp/spurarm_cap_d/sft.log 2>/dev/null | tail -1 | awk -F= '{print $2}')
BENCH_ARGMAX=$(grep "^bench_v0 result:" /tmp/spurarm_cap_d/bench_argmax.log 2>/dev/null | head -1 | awk -F'[ /]' '{print $3}')
BENCH_CAPF=$(grep "^bench_v0 result:" /tmp/spurarm_cap_d/bench_capf.log 2>/dev/null | head -1 | awk -F'[ /]' '{print $3}')
STEP0_TOP_ID=$(grep "^step=0" /tmp/spurarm_cap_d/probe.log 2>/dev/null | head -1 | sed 's/.*top_id=\([0-9]*\).*/\1/')

# Verdict per Cap D kill_target: PASS if best_bench >= 4/20.
BEST_BENCH=$BENCH_ARGMAX
if [ -n "$BENCH_CAPF" ] && [ "$BENCH_CAPF" -gt "${BENCH_ARGMAX:-0}" ] 2>/dev/null; then
  BEST_BENCH=$BENCH_CAPF
fi
if [ -z "$BEST_BENCH" ]; then
  V=INCONCLUSIVE
elif [ "$BEST_BENCH" -ge 4 ]; then
  V=PASS
else
  V=FALSIFIED
fi

cat <<EOT
=== Spur-arm Stage 6 Cap D: RoPE attention summary ===

Training: pretrain 400 + SFT 200, seed 42, d=64, variant=rope
  initial val_loss : ${INITIAL_VAL}
  pretrain final   : ${PRETRAIN_FINAL_VAL}
  sft final        : ${SFT_FINAL_VAL}

Bench (seed 42 rope SFT, max-gen 60):
  argmax                                 : ${BENCH_ARGMAX}/20
  no-repeat-3gram + min-gen 12 (Cap F)   : ${BENCH_CAPF}/20

Probe step-0 top_id: ${STEP0_TOP_ID}
$(grep "^step=0" /tmp/spurarm_cap_d/probe.log 2>/dev/null | head -1)

Verdict: ${V} (best_bench=${BEST_BENCH}; PASS iff >= 4)

===RAIL_LAB_COUNTERS===
{"counter": "rope_pretrain_final_val_x1000", "value": $(echo "${PRETRAIN_FINAL_VAL:-0}" | awk '{printf "%d", $1 * 1000}')}
{"counter": "rope_sft_final_val_x1000", "value": $(echo "${SFT_FINAL_VAL:-0}" | awk '{printf "%d", $1 * 1000}')}
{"counter": "rope_bench_argmax", "value": ${BENCH_ARGMAX:-0}}
{"counter": "rope_bench_capf", "value": ${BENCH_CAPF:-0}}
{"counter": "rope_step0_top_id", "value": ${STEP0_TOP_ID:-0}}
===END===
===VERDICT=== ${V}
EOT
