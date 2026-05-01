# Phase 5c — sampling experiment (Session 5)

**Date:** 2026-04-22 morning.
**Branch:** `next`. Changes: top-k weighted-multinomial sampling added to `tools/train/lm_infer_v3_half.rail`.

## Headline

Sampling infrastructure shipped and works correctly — but **sampling alone cannot rescue the current model**. The d=256 × 4-block × HalfTensor checkpoint's output distribution collapses to whitespace at every position past the first, regardless of the sampling temperature or top-k width. This is a model-quality finding, not a sampling bug.

## What shipped

`tools/train/lm_infer_v3_half.rail` gained:
- `copy_row_loop`, `amax_avail_loop`, `topk_fill_loop`, `sum_ws_loop`, `rng_next`, `sample_walk_loop`, `topk_sample` helpers.
- `samp` param on `gen_loop` (11 params total — 1 over the usual ≤10 soft limit; works because gen_loop's recursion depth is ≤128 so loss of TCO is cost-neutral).
- `--k > 1` switches from argmax to weighted-multinomial sampling over top-k chars by softmax probability.
- `--seed` wired into an LCG rng bundled into `samp[1]`.
- `--temp` still accepted but ignored (no `pow()` in Rail stdlib; can be revisited later).

## The experimental finding

On the d=256 × 4-block × 3000-step checkpoint, using the bench's first Fundamentals-band prompt pattern:

| config | output after prompt "main = " | |
|---|---|---|
| --k 1 (argmax) | `\n\n\n\n\n…` | pure whitespace |
| --k 5 --seed 42 | `l\n\n\n…` | one `l` then newlines |
| --k 5 --seed 1 | `s\n\n\n…` | one `s` then newlines |
| --k 20 --seed 100 | `e\n\n\n…` | one `e` then newlines |
| --k 130 --seed 42 (full-V sampling) | `2\n\n\n…` | one `2` then newlines |

**Every sampling configuration produces exactly one non-whitespace char and collapses to newlines for the remaining 59+ generation steps.**

This is diagnostic: the model's softmax distribution at position 1+ after any non-whitespace content has mass ≈1.0 on `\n`. Even full-V weighted sampling cannot escape the attractor. The whitespace fixed point isn't just the argmax — it's 99%+ of the entire distribution mass.

## Why sampling doesn't help here

At eval mean 3.39 the character-level perplexity is ~30, which in principle implies broad distributional uncertainty (~30 plausible next chars). But the **actual** distribution is bimodal: sharp on whitespace (especially `\n`) as the next-char prediction after content, nearly flat on everything else. Sampling can explore the flat shoulder for one draw, but doesn't change the concentrated mass, so the very next prediction returns to whitespace.

The compile-pass cliff that S5 needed to cross requires not just any chars, but **sequentially coherent** chars forming a valid Rail expression. A single non-whitespace char in a stream of newlines doesn't help the oracle compile — the output just breaks the prompt's would-be complete-program structure (which was the mechanism for the 1/30 Fund pass in S3/S4).

## Bench attempt

Started `./rail_native run flywheel-local/bench_railnative.rail --prefix …/d256_4block_half_step3000 --max 128 --k 5 --temp 1.0`. Killed at task 4/30 after 7 min wall: the sampling path runs ~15× slower per token (~500ms/step CPU in topk_sample vs ~30ms/step argmax). Total bench ETA extrapolated to ~50 min vs ~2 min for argmax. Didn't finish; the sampling smoke already showed the output won't help the bench, so continuing was negative-EV.

The slowdown likely comes from `copy_row_loop` + `topk_fill_loop`'s 5 argmax passes over V=130 on every forward step — `128 × 30 = 3840 total calls × ~200ms overhead` = ~12 min total overhead in the bench's parallel-oracle path. Fixable (use heap-select in one pass; allocate scratch outside the hot loop) but not the bottleneck for the deadline.

## Implications for 2026-04-27

The "just add sampling" lever doesn't move the bench number. Session 5's 2-hour bet returned zero bench delta. The path to ≥5/30 now looks like:

**Rank 1 — Longer training.** Same d=256 × 4-block config, 6000 steps instead of 3000. 170 min wall. Expected eval target ~3.0 (possibly below), which may cross the compile-cliff on a few more Fund tasks. **Highest-leverage bet left.**

**Rank 2 — Bigger corpus.** Pull harvested Rail programs from `rail-training` private repo (if available) and concatenate with stdlib. Re-train d=256 × 4-block on the enlarged corpus. ~200 min total. Second-best bet.

**Rank 3 — Different LR schedule.** Warmup longer (500 steps vs 100), smaller base_lr (0.01 vs 0.02), longer cosine tail. Uncertain leverage.

Rank 4 — Curriculum. Teach simpler programs first. High setup cost, speculative returns.

Between rank 1 and rank 2: rank 1 is the cheaper test — if 6000 steps at current config crosses below eval 2.5, the corpus isn't the bottleneck. If it plateaus around 3.0, corpus is the bottleneck and rank 2 becomes the path.

## Deadline status update

With 5 working days left:
- Sampling lever: spent ✗
- Longer training lever: unspent (~3h cost)
- Bigger corpus lever: unspent (~3h cost including plumbing)
- LR tuning: unspent (~1h setup per variant, ~3h per trial)

Realistic: rank-1 today → rank-2 tomorrow → model card + ship on 2026-04-27 with whichever numbers land. If neither crosses 5/30, the model card honestly reports "≤5/30 on bench_railnative; self-hosting completeness + compile-verified training demonstrated as primary claim." That's still a shippable milestone; the bench number is contributory, not gating.

## Files changed

- `tools/train/lm_infer_v3_half.rail` — added ~70 lines of sampling helpers + `samp` threading. `--k 1` path unchanged (argmax fast-path preserved).
- `docs/plans/PHASE_5C_SAMPLING_RESULT.md` — this doc.

Not committed: `/tmp/bench_d256_4block_k5.log` (incomplete bench, killed at task 4).
