# M6 — Scale Gate Decision

Deferred from `FORK_B_PLAN.md`. To be revisited after M5 v0.2 ships
(samples + corpus pivot).

## Current ship point

`MODEL_CARD_v0.1.md` — d=64, d_ff=256, single-block, single-head,
Shakespeare (383 chars, full training set), loss 0.333 at step 1990.

## Three scale axes

Each can move independently. Pick one to focus on per session.

### Axis 1 — Depth (multi-block)

- Today: 1 block (attention + FFN + residual + LN)
- Next: 2-4 blocks stacked
- Cost: per-step runtime scales linearly with block count.
- Benefit: more expressive; needed for non-trivial language modeling.
- Risk: gradient flow issues at depth without LayerNorm tuning (γ/β
  currently fixed). Would likely need to make γ/β learnable first
  (deferred per model card).

### Axis 2 — Width (multi-head)

- Today: 1 head, d=64
- Next: 4 heads, d=64 (d_head=16) OR 4 heads d=128 (d_head=32)
- `v2.12` shipped multi-head code in stdlib/transformer.rail but
  `lm_transformer.rail` doesn't exercise it.
- Cost: ~same total FLOPs for split-head at same d. Small overhead
  from head concatenation.
- Benefit: attention heads can specialize. Standard transformer win.
- Risk: the Rail multi-head code path is untested under sustained
  training. Need a gradcheck run before wiring in.

### Axis 3 — Dimension (wider d / d_ff)

- Today: d=64, d_ff=256
- Next: d=128, d_ff=512 or d=256, d_ff=1024
- Cost: quadratic in d for most matmuls. Memory pressure.
- Benefit: more capacity. Also: puts matmuls solidly in Metal-wins
  territory (≥256×256 per `tensord_scale_bench`) even for attention
  projections.
- Risk: Mini's 22GB wired cap. At d=256, V=4096, the output
  projection alone is d × V = 1M params = 8MB. Still fits. For
  TinyStories-scale corpus and small model (≤10M params), stays
  under cap.

## Proposed order

Shipping criterion: each step should land a card-worthy result.

1. **Enable learnable γ/β** in LayerNorm (prereq for depth).
   Small change; measurable effect on convergence. Low risk.
2. **Multi-head attention** (axis 2). Exercise the v2.12 code path
   with gradcheck + sustained training. Most bang-for-buck: standard
   transformer win without dramatically more params.
3. **Multi-block** (axis 1). Stack 2 blocks. Measure loss improvement.
   If gradient flow is problematic, add residual scaling or revisit
   γ/β init.
4. **Width bump** (axis 3). After axes 1-2 are proven, widen to
   d=128 or d=256 for a real corpus run.

Each of the first three is ~1 session of work. Width bump follows
the corpus pivot (Rail stdlib, TinyStories, etc) since it's the
axis that benefits most from real-scale training data.

## What NOT to do yet

- **Don't chase 4B-scale.** Rail-native training is about owning the
  loop, not matching Qwen. Plan's original cap of ≤100M stands.
- **Don't pre-refactor for all three axes simultaneously.** That's
  the kind of speculative abstraction that wastes sessions.
- **Don't bump to CPU-only runs for quick iteration.** The point is
  Metal dispatch works now; use it.

## Decision after M5 v0.2 ships

1. Post-v0.2, review: does the trained model generalize to held-out
   corpus slice? If yes, we have a working ML stack and can focus on
   capacity. If no, the fix is in optimization/init/architecture
   rather than scale.
2. If generalization works at single-block / single-head:
   → execute axis 2 (multi-head) first.
3. If generalization fails:
   → debug before scaling. Scale doesn't fix wrong code.

## Pointers

- `stdlib/transformer.rail` — block + MHA + LN primitives
- `stdlib/autograd.rail` — tape-based reverse mode
- `stdlib/optim.rail` — Adam with fused GPU kernel
- `stdlib/tensor.rail` — matmul dispatch to Metal
- `tools/train/lm_transformer.rail` — current single-block driver
