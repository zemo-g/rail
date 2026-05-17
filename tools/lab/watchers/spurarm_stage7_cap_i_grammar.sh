#!/bin/sh
# tools/lab/watchers/spurarm_stage7_cap_i_grammar.sh
#
# Stage 7 Cap I: does a grammar-walked decoder lift the existing
# rope-v0 SFT checkpoint past 3/20 bench? No retraining.
#
# Implementation: stdlib/rail_grammar.rail provides a tolerant prefix
# validator for the Spur-arm DSL (script = [...] of Cmd constructors).
# tools/spurarm/train/generate.rail gains a `--grammar` flag that runs
# decode_step in two passes:
#   1. Strict: reject pure-whitespace tokens AND tokens whose
#      decoded text would create an invalid Rail-DSL prefix. Pick argmax
#      over the surviving distribution.
#   2. Relaxed: same but whitespace allowed (used only when strict
#      empties the candidate set).
#   3. If both passes empty, emit EOS to terminate cleanly (no
#      argmax-over-garbage fallback).
#
# Run 2026-05-17 against spurarm-rope-v0_seed42_sft_final (the Cap D
# checkpoint with val_loss 2.97).
#
# Headline numbers (post-cleanup grader, baf661b):
#   no-grammar argmax baseline        : 0/20   (model output is degenerate)
#   grammar-walked argmax             : 0/20   (compile-clean but wrong coords)
#   compile-clean count (grammar)     : 14/20  (up from 0/20 baseline)
#
# Interpretation: grammar walker fixes syntactic mode collapse (model
# now emits valid `script = [...]` shape for 14/20 prompts). But the
# model's coordinate-semantic knowledge is missing — it emits
# attractors like `MoveTo 100 100 100` (out of workspace, faults) or
# `MoveTo 10 10 5` (point B literal) regardless of prompt. The cap is
# upstream of decoding: at single-block 2M params on the v1 corpus,
# the model has no per-prompt grounding for which (x,y,z) to emit.
#
# Cap I FALSIFIED at kill_target (>= 4/20). Strong diagnostic: compile
# rate jumped from 0 to 14, so the model's residual capability is real
# but lives below the coordinate layer. Cap H (scale + substrate corpus)
# remains the next swing.

cat <<'EOT'
=== Spur-arm Stage 7 Cap I: grammar-walked decode summary ===

Checkpoint: training/checkpoints/spurarm-rope-v0_seed42_sft_final
            (val_loss 2.97, Cap D's RoPE-trained 2M params)

Bench v0 (post-cleanup grader, max-gen 60):
  --grammar 0 (baseline)              0/20   (raw argmax = degenerate)
  --grammar 1 (Cap I full pipeline)   0/20   (compile-clean, wrong coords)

Diagnostic counters:
  compile-clean candidates (stage >= 1)   : 14/20
  candidates with MoveTo as first Cmd     : ~17/20 (visual scan)
  modal coord attractor                   : (10, 10, 5) ≈ point B literal
  workspace-violating coord attractor     : (100, 100, 100), (100, 10, 10)

The grammar walker DOES escape syntactic mode collapse (compile rate
0/20 → 14/20). The remaining cap is coordinate-semantic: the model
has no per-prompt grounding for (x,y,z). At 2M params on the v1
corpus, this knowledge is genuinely absent — not a decoding issue.

Cap I FALSIFIED at the named kill_target. Strong diagnostic for
Cap H (substrate corpus + 14.7M scale + grammar): the compile-rate
lift suggests the model HAS some recoverable knowledge once syntax is
constrained — a larger model on a better corpus should land coords too.

===RAIL_LAB_COUNTERS===
{"counter": "bench_grammar", "value": 0}
{"counter": "baseline_argmax_bench", "value": 0}
{"counter": "compile_clean_count_grammar", "value": 14}
{"counter": "compile_clean_count_baseline", "value": 0}
{"counter": "max_stage_reached", "value": 3}
===END===
===VERDICT=== FALSIFIED
EOT
