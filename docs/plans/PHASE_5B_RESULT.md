# Phase 5b — d=256 × 4-block × HalfTensor, Session 4 deeper variant

**Date:** 2026-04-21 overnight → 2026-04-22 early morning.
**Branch:** `next`. Commit: `7218806` (training file) + `03941ec` (generic infer harness).
**Mission:** test "deeper beats 2-block" at the same width + half precision.

## Headline

The deeper run shipped cleanly. Eval trajectory tracks ahead of 2-block at every checkpoint from step 400 onward. Peak RSS stays flat at 606 MB for 171 minutes. Checkpoint lands and loads. Bench score is **1/30** — identical to 2-block, because both models are undertrained enough that greedy decoding collapses to whitespace at char-level perplexity ~30.

## Numbers

### Training

| config | eval @ 2900 | final (fresh chunk) | min single-chunk | peak RSS | wall | s/step |
|---|---:|---:|---:|---:|---:|---:|
| d=256 × 2-block half (S3) | 3.49 ± 0.17 | 3.06 | 2.58 | 580 MB | 84 min | 1.68 |
| **d=256 × 4-block half (S4)** | **3.39 ± 0.19** | **3.03** | **2.57** | **606 MB** | 171 min | 3.43 |
| d=128 × 2-block f64 baseline | 2.87 ± 0.18 | 3.24 | 2.67 | — | — | — |

**4-block improvements over 2-block at same width:** Δ=−0.10 on eval mean, Δ=−0.03 on fresh-chunk final, Δ=−0.01 on min. Numerically small, within 1σ of eval noise. Both plateau — 4-block at ~3.39 from step 2500 onward, 2-block at ~3.44 in the same range. Neither clears the d=128 f64 baseline target.

**Wall-time:** 2.04× slower per step than 2-block (3.43 vs 1.68) for a 2× parameter count increase. Consistent with matmul flops scaling linearly with blocks and non-matmul overhead scaling ~1.5×.

**RSS:** +26 MB over 2-block (606 vs 580). The activation cache's per-block allocation doubled (12 half tensors × 4 blocks vs × 2 blocks) but was offset partially by arena reuse. Still well inside the 1 GB Session 4 budget.

### Bench (first honest 4-block measurement)

Run: `./rail_native run flywheel-local/bench_railnative.rail --prefix training/rail_native/checkpoints/d256_4block_half_step3000 --max 128 --k 1 --temp 1.0`

| band | 2-block d=256 | 4-block d=256 |
|---|---:|---:|
| Fundamentals | 1/5 (q=2991) | 1/5 (q=2991) |
| Practical IO | 0/5 (q=1620) | 0/5 (q=1620) |
| Real Tools | 0/5 (q=3529) | 0/5 (q=3529) |
| Compiler | 0/5 (q=4918) | 0/5 (q=4918) |
| Advanced | 0/5 (q=1912) | 0/5 (q=1912) |
| Comprehend | 0/5 (q=2736) | 0/5 (q=2736) |
| **total** | **1/30 (q=17706)** | **1/30 (q=17706)** |

**Scores are byte-identical** — not because 4-block is broken, but because:

1. **Both models generate mostly whitespace.** Diagnostic: `./rail_native run tools/train/lm_infer_v3_half.rail --prefix <ckpt> --prompt "fact n = " --max 20` produces the prompt followed by newlines/spaces from both 2-block and 4-block models. Greedy decoding on a ~30-perplexity char distribution finds whitespace as its argmax because whitespace is the most frequent char in Rail source and all non-whitespace chars look similarly unlikely.
2. **Quality is computed on prompt + completion concatenation.** When both models contribute the same whitespace completion, the resulting code is dominated by the prompt content — which is identical across both runs — so the oracle_quality scoring is identical.
3. **The 1 Fund pass is a prompt artifact, not a model artifact.** The first Fund task's prompt is already a complete compileable Rail program (`fact n = ... main = let _ = print (show (fact 5)) \n 0`). Any empty/whitespace continuation compiles the same way — pass. The model contributed zero useful bits to that pass.

Verified with direct comparison of captured completions: `diff /tmp/bench_d256_v2.log /tmp/bench_d256_4block.log` shows only the `checkpoint prefix` line and the compile binary size differing. All 30 task outputs byte-match.

## Architecture detection verified

Generic N-block inference harness correctly detects both checkpoint shapes:
- 2-block checkpoint: `n_weights=20, n_blocks=2`
- 4-block checkpoint: `n_weights=38, n_blocks=4`

Formula `n_blocks = (n_weights - 2) / 9` works. `unpack_blocks` correctly materializes `blocks_h` as a 4-entry list of 9-weight lists. `infer_blocks_loop` iterates 4 times for the 4-block case. The inference path structurally executes the full 4-block forward — the argmax just settles on whitespace at every step due to perplexity.

## What this session taught

- **Deeper did help eval.** 2-block → 4-block closed 18% of the gap between 2-block half and the f64 baseline (0.10 of the 0.62 gap). But not enough to cross the compile-pass threshold.
- **The compile-pass cliff is steep.** At eval ~3.4 both 2-block and 4-block score the same because both sit on the wrong side of a nonlinear cliff. The 1 Fund pass is a free point from a complete-program prompt; real improvement over 1/30 requires eval < ~2.5 where non-whitespace chars dominate the greedy choice.
- **Architecture changes at same data/steps are cheaper than they are useful.** 2× compute for Δ=0.10 eval. Getting to the compile-pass cliff likely requires one of:
  - More training steps (6000+, linear returns still expected)
  - Bigger corpus (currently 544K chars; the stdlib teaches Rail's shape but not enough content)
  - Better init / LR / longer warmup (small, compounding)
  - Sampling instead of greedy at inference (top-k with low temp would break the whitespace fixed point even at current perplexity)

## Session 5 candidate direction — revised rank

`SESSION_4_RANKING.md`'s rank-1 was "bench plumbing + first bench" — done. The 1/30 score re-prioritizes:

**Rank 1 — Sampling at inference.** Add top-k + temperature to `lm_infer_v3_half.rail`. At k=5 temp=0.8, the whitespace fixed point breaks and the model produces varied continuations that may sometimes land on compile-pass Rail. **Zero retraining cost, ~2 h to implement.** Possibly the highest-leverage intervention before the 2026-04-27 deadline.

**Rank 2 — Longer training.** 6000 steps at current config. ~170 min wall. Pushes eval toward ~3.0. May or may not cross the compile-pass cliff on its own. Can stack with Rank 1.

**Rank 3 — Bigger corpus.** Pull harvested Rail programs from the private flywheel repo (if available), concatenate with stdlib corpus. ~1 h plumbing, re-run training. Teaches program-level Rail (not just stdlib idioms). Cost: the new run probably needs another 3000 steps to converge.

**Rank 4 — Wider (d=512).** Memory budget gets tight at 4-block × d=512. Probably would need to drop back to 2-block. Uncertain leverage.

## Files

- `tools/train/lm_v3_chunked_d256_4block_half.rail` — 4-block half training variant (shipped in commit `7218806`).
- `tools/train/lm_infer_v3_half.rail` — now generic over block count via `(n_weights-2)/9` (commit `03941ec`).
- `training/rail_native/checkpoints/d256_4block_half_step3000.*` — 64-file checkpoint artifact (not in git).
- `/tmp/d256_4block_3000.log` — full training log (3.4 MB).
- `/tmp/bench_d256_4block.log` — bench log (matches 2-block byte-for-byte modulo the prefix line).

## Deadline status update (2026-04-22)

Against `DEADLINE_2026-04-27_PUNCHLIST.md`:

- ✅ P0: bench plumbing working end-to-end. Two checkpoints, two bench runs.
- ⚠️ P1 "push to ≥5/30": first two attempts both scored 1/30, same across 2-block and 4-block at same data/steps.
- 4-5 working days remaining. The "deeper" lever delivered measurable-but-insufficient improvement; need one or more of the Session 5 rank-1/2/3 directions to cross.
- Realistic budget for Session 5: 1 day (today) for sampling + longer training + re-bench.
- Risk: high. The compile-pass cliff at perplexity ~5 is a sharper requirement than the handoff's initial framing suggested.

Ship the sampling fix first (smallest effort, largest expected delta).
