# Rail-native transformer — Model Card v0.3b

**Run:** 2026-04-15
**Companion to:** v0.3a (architecture unchanged, same fill_onehot fix applied to xval harness)
**Purpose:** cross-file holdout eval — measure whether the architecture generalizes, or whether v0.3's 3.96 val/train ratio was another bug artifact.

## Headline

After applying the `head ids` fix to `tools/train/lm_xval.rail` (same surgery as commit a5f37a1 on `lm_transformer.rail`), the cross-file val/train ratio **dropped from 3.96 → 2.549**. The fill_onehot bug accounted for most of the observed gap, but not all of it — the architecture still overfits at d=64 on this data.

## Config

- Train corpus: `stdlib/tensor.rail[0:1500]`
- Val corpus:   `stdlib/json.rail[0:1500]`
- Vocab: union of both files
- Architecture: d=64, d_ff=256, single pre-norm block (identical to v0.3a)
- Optimizer: Adam, warmup=100, peak_lr=0.02
- Steps: **500** (capped below the unsolved seq≥1499 termination bug at step ~600)
- Logging: val eval every 50 steps

## The fix applied to lm_xval.rail

```diff
 fill_onehot dst ids V seq i =
   if i >= seq then 0
   else
-    let c = list_nth i ids
+    let c = head ids
     let _ = float_arr_set dst (i * V + c) 1.0
     fill_onehot dst (tail ids) V seq (i + 1)
```

Same pattern as lm_transformer.rail — `list_nth i ids` was dereferencing `original[2i]` while `ids` was already tailed i times. The val-side tensor was built from the same corrupted input, so v0.3's raw 3.96 ratio compared two corrupted distributions — it was measuring bug-overlap, not generalization.

## Curve

```
init    train=16.74  val=16.63  ratio=0.99   (both ≈ log V baseline)
step 50 train= 8.70  val=12.83  ratio=1.47
step100 train= 3.43  val= 8.29  ratio=2.42
step150 train= 2.96  val= 7.34  ratio=2.48
step200 train= 2.86  val= 7.17  ratio=2.51
step250 train= 2.82  val= 7.08  ratio=2.51
step300 train= 2.79  val= 7.05  ratio=2.52
step350 train= 2.78  val= 7.03  ratio=2.53
step400 train= 2.76  val= 7.02  ratio=2.54
step450 train= 2.75  val= 7.01  ratio=2.55
step500 train= 2.75  val= 7.00  ratio=2.549
```

best_val 7.00 at step 500.

## Decision (per prior plan)

Plan branches:
- `<1.5`  clean — scale corpus.
- `1.5–2.5` partial — add holdout axis, triangulate.
- `>2.5`  overfit — learnable γ/β first, do NOT scale.

**Branch taken: `>2.5` → overfit.**

2.549 is 0.049 past the threshold — close enough that I want to flag the borderline honestly. But the trajectory is unambiguous: val plateaus by step 200 at 7.0, train continues grinding down to 2.75. Classic overfit signature (val saturated, train memorizing).

## Interpretation

1. **The fill_onehot bug was most of the v0.3 ratio story.** 3.96 → 2.55 is a 1.4-point improvement with no architectural change. v0.3's "doesn't generalize" conclusion was overstated — the broken val pipeline was training on its own corrupted distribution and measuring drift against a different corruption.
2. **But a real gap remains.** 2.55 is still above 2.5 and val plateaus while train keeps dropping. On 1500 chars of Rail source with a 32-ish vocab and d=64, the model memorizes tensor.rail's distribution and fails to transfer it to json.rail. This is an architecture/capacity issue, not a bug.
3. **Do not scale corpus yet.** Scaling a non-generalizing architecture wastes compute. The prior plan's prescription stands: enable learnable γ/β in LayerNorm (M6 axis 1) before any scale-up.

## Next session — explicit

1. Make `ln_g` / `ln_b` receive gradient updates in `train_step`:
   - Accumulate dgamma / dbeta sums over rows from `layernorm_backward_f64`.
   - Add `st_ln_g`, `st_ln_b` AdamState entries, Adam-update per step.
2. Retrain v0.3a with learnable γ/β — measure if final loss drops below 0.409.
3. Rerun this xval with learnable γ/β — measure ratio again. Only if ratio drops below 2.0, proceed to corpus scale-up.
4. **Not in scope for next session:** the seq≥1499 cumulative termination bug at step ~600, and the 28-arg arity cap. Both are compiler sessions.

## Landmines still live

- Top-level `name = expr` re-evaluates per reference.
- `list_nth` on a forward-returning list requires destructure.
- Multi-line cons chains break the parser.
- stdout fully buffered under nohup — monitor via tail/Monitor.
- Arity cap 28 on non-self-loop calls — respect B's packed-list pattern.
- seq≥1499 cumulative termination at step ~600 — unsolved.

---

Commit: `rail: v0.3b — fixed xval, ratio 2.55, next=learnable γ/β`
