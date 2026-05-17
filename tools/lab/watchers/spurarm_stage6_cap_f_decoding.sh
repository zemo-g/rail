#!/bin/sh
# tools/lab/watchers/spurarm_stage6_cap_f_decoding.sh
#
# Stage 6 Cap F: does decoding regularization (no-repeat-3gram +
# min-gen EOS suppression) lift bench past the 3/20 baseline?
#
# Run on Studio 2026-05-17 against seed42 SFT (best checkpoint per
# spurarm-base-v0_best -> seed42_sft_final).
#
# Pre-probe (Stage 6 readiness plan, also chained separately) found:
#   - seed314 pretrain: step-0 argmax = EOS (id=2, p=0.176)
#   - seed42 SFT:        step-0 argmax = "MoveTo" (id=155, p=0.135)
# Decoding regularization implemented in tools/spurarm/train/generate.rail:
#   - --no-repeat-n N: ban N-gram repetitions (default 0, off)
#   - --min-gen K:     force at least K generated tokens before EOS
#                      allowed (default 0, off)
#
# Results table (bench_v0, 20 prompts, on seed42 SFT, max-gen=60):
#
#   config                              passes   note
#   --no-repeat-n 0 --min-gen 0  (base)  2/20    b14,b19 via fallback
#   --no-repeat-n 3 --min-gen 0          2/20    no-repeat doesn't break cycles
#   --no-repeat-n 3 --min-gen 12         0/20    fallback lost, model alone = 0
#
# Key honest finding: the baseline "2/20" (and prior runs' "3/20") is
# PURE FALLBACK CONTAMINATION + a bench-grader flaw. The model emits
# step-0 EOS for some prompts (b14, b19), producing empty output that
# triggers the `script = [Home]` fallback in generate.rail. b14 and b19
# both have expected end state == initial state (arm at home, no ball
# held), so the no-op fallback accidentally passes.
#
# Cap F's min-gen variant forces real model output and exposes the
# honest 0/20 — the model itself produces zero compilable Rail at this
# scale.
#
# Cap F is therefore FALSIFIED: no decoding strategy escapes mode
# collapse when the underlying next-token distribution is degenerate.
# The cap is upstream of decoding -- architecture (Cap D) or scale.
#
# Bench-grader contamination flag: the v0 grader does not check ball
# end position separately from held state, and accepts empty/no-op
# scripts on prompts where expected end state == initial state.
# Filed for cleanup; does not change Cap F verdict.

cat <<'EOT'
=== Spur-arm Stage 6 Cap F: decoding regularization summary ===

Pre-probe on seed314 pretrain and seed42 SFT (chained separately):
  seed314 pretrain : step-0 argmax = EOS (p=0.176)
  seed42 SFT       : step-0 argmax = "MoveTo" (p=0.135)
  max p(EOS) over 12 steps: 0.176 (seed314), 0.048 (seed42 SFT)
  -- model HAS EOS supervision (Cap E falsified inline)

Cap F bench sweep on seed42 SFT, max-gen=60:

  --no-repeat-n 0 --min-gen 0          2/20   baseline (b14,b19 fallback)
  --no-repeat-n 3 --min-gen 0          2/20   no-repeat alone: no change
  --no-repeat-n 3 --min-gen 12         0/20   model alone: zero compilable

Decoding regularization does NOT escape mode collapse. The baseline
2/20 is fallback contamination: b14 and b19 expected end state
matches initial state (arm at home, no ball held), so the
`script = [Home]` fallback (triggered by step-0 EOS) accidentally
passes.

Model-alone bench (Cap F with min-gen forcing real output): 0/20.

The cap is upstream of decoding. Cap D (RoPE / architecture) is the
remaining named candidate.

===RAIL_LAB_COUNTERS===
{"counter": "baseline_argmax_bench", "value": 2}
{"counter": "no_repeat_only_bench", "value": 2}
{"counter": "cap_f_full_bench", "value": 0}
{"counter": "fallback_contamination_prompts", "value": 2}
{"counter": "model_alone_bench", "value": 0}
===END===
===VERDICT=== FALSIFIED
EOT
