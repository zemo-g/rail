# Code-JEPA / Learned-Oracle Substitute (Phase 5.0b)

**Status:** design note. No implementation. Scoping for a 2-3 day prototype.
**Date:** 2026-04-20 PM.
**Inspiration:** LeWorldModel (arxiv 2603.19312) — stable end-to-end JEPA from pixels.
**Master plan pointer:** `WEEK_PLAN_2026-04-20.md` Phase 5.0b.

## One-line goal

Replace the Rail compiler in `self_train.rail`'s inner loop with a small
"will-this-compile?" head. The compiler becomes final validation; the
head makes the flywheel differentiable end-to-end.

## Why

Current self_train loop:

```
generate → oracle_compile → classify (pass/fail) → retry w/ error feedback → harvest
          ↑ the bottleneck
```

Each oracle call is a Rail compile: forks `as`, `ld`, potentially runs the
binary. At N=16 parallel this is ~5–10 s per round on Studio. That's the
inner cost the flywheel is paying 10–200× per round.

LeWM's insight: you don't need the real world model in the inner planning
loop. A small learned surrogate is fast enough to run 48× more planning
rollouts, and the surrogate's error is small enough that final-validation
with the real model catches the rare divergences.

Applied here: a small Rail-native classifier predicts "will this source
compile?" and optionally "will it pass `oracle_quality`?" The generator
steers toward predicted-pass completions during candidate generation. The
compiler validates only the best K candidates per round.

## Architecture sketch

Two heads sharing an encoder:

```
Rail source tokens
  → embed (reuse tokenizer.rail)
  → small transformer (d=32–64, 2–3 blocks)
  → [CLS]-equivalent token
  → compile_head  : predicts P(compiles)       ← binary classifier
  → quality_head  : predicts oracle_quality    ← regression to nw/uq/helper-decl
```

Training signal comes for free from the existing `harvest.jsonl` +
`repairs.jsonl` (compiler-verified pass/fail pairs). Data is already
there — Stream 3's `harvest_clean_v2.jsonl` is 3,405 survivors from 10,964
raw. Plus error-classified repair data in `syntax_repairs.jsonl` etc.

## Stability

LeWM's core contribution: the isotropic Gaussian regularizer on the
encoder's latent. Without this, JEPA-style encoder-predictor pairs
collapse (encoder outputs constant, predictor trivially correct).

For code: the same trick applies. Encourage the encoder's latent
distribution to be roughly N(0, I) over the training set. Single
regularizer term, plus the prediction cross-entropy. Two-loss total —
matches LeWM's "6 → 2" reduction and Rail's lean-design aesthetic.

## Where the idea lives in the loop

Phase 1: shadow-mode. The head runs alongside `oracle_compile_batch` and
logs its predictions. Measure precision/recall vs ground truth. Gate:
≥95% precision at ≥80% recall on a held-out set. Don't wire in until the
gate holds.

Phase 2: inner-loop substitution. Generator samples N candidates, runs
head on each, sends top-K to the compiler. K < N yields the speedup.
Remaining N-K: logged, never validated, used only as negative training
signal ("head said fail → probably did fail").

Phase 3: differentiable flywheel. Backprop from the head's loss into the
generator via policy gradient or direct fine-tuning. This is where the
real leverage is — the generator learns to avoid head-predicted-fail
regions, which compound-speeds up the outer loop further.

## Integration points

- **`stdlib/tokenizer.rail`** — already has BPE + char-level encoders.
  Reuse tokens.
- **`tools/train/lm_v3_chunked.rail`** — existing 2-block transformer
  architecture. Fork for the head (smaller d, additional CLS pooler).
- **`tools/train/self_train.rail`** — eventual integration point. The
  head gates candidate selection before `oracle_compile_batch`.
- **Training data** — `harvest.jsonl` positives, `*_repairs.jsonl`
  negatives with error-class labels. No new data collection needed for v0.

## Known risks / constraints

- **The head is another model to train.** Adds infrastructure
  complexity. Mitigation: reuse lm_v3_chunked machinery.
- **Shadow-mode is load-bearing.** Skipping it and wiring the head
  straight into the inner loop → cascading errors. The gate (≥95%
  precision) is non-negotiable.
- **Rail-on-Rail purity.** The head is trained by a Rail program on
  Rail-compiler-verified data, predicting Rail compilation outcomes —
  fully in-family with the mission.
- **Scale.** LeWM's 15M params for continuous physics. Rail's compile
  decision is strictly simpler. A 1–5M param head should saturate;
  going bigger is waste. Fits in a single-GPU-hours training budget.

## First-experiment sketch (when unblocked)

1. Extract `(source_ids, compile_ok_bool)` pairs from `harvest.jsonl`
   (all pass) + `*_repairs.jsonl` (class-labeled fails).
2. Train a binary classifier head on top of lm_v3_chunked's 2-block
   backbone, 2000 steps, multi-chunk eval (per Phase 1d pattern).
3. Hold out 10% as val set. Expect: first-try baseline 70–85% accuracy.
4. If ≥80%: add Gaussian latent reg, measure improvement. If ≥95%
   precision on held-out: proceed to shadow mode.
5. Shadow mode for 24h of self_train rounds. Log head predictions
   alongside real oracle. Compute P/R.
6. If gate holds: wire into inner loop. Measure round-wall reduction.

End-to-end wall estimate: 2-3 days engineering + 1 overnight train, plus
shadow-mode soak.

## References

- arxiv 2603.19312 — LeWorldModel.
- github.com/lucas-maes/le-wm — official code.
- In-tree: `stdlib/oracle.rail` (quality metric), `harvest_clean_v2.jsonl`
  (data), `tools/train/self_train.rail:run_batch_parallel` (integration
  point). The private `Ledatic-Empire/rail-training` repo has the
  flywheel runner that would call this.
