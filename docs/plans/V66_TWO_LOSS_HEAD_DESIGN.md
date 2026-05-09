# Spur-v66 design — true two-loss-head trainer

## Context

v62 (25% step-interleave) → 1/30 strip-bench (regression vs v54's 10/30)
v63 (10% step-interleave) → TBD (in flight at time of writing)

Step-interleave's fundamental problem: each step's gradient is FULL on either A or B, so Adam's moment estimates mix contributions from both — a comp gradient applied via Adam-scaled update points partially in compile.rail's preferred direction (the dominant moments). Plus, at LR=0.01 every comp step is a major perturbation to a model that's mid-way to forming compile.rail's sharp basin.

The architecturally correct alternative: **combined gradient before Adam**.

## Architecture

Per training step:
1. Sample chunk_a from compile.rail BQ
2. Sample chunk_b from comp v3/v4
3. forward(x_a, w) → probs_a, cache_a
4. forward(x_b, w) → probs_b, cache_b
5. grad_logits_a = α × ∂CE(probs_a, labels_a) / ∂logits_a
6. grad_logits_b = (1-α) × ∂CE(probs_b, labels_b) / ∂logits_b
7. backward(grad_logits_a, cache_a) → weight_grads_a (list of N tensors)
8. backward(grad_logits_b, cache_b) → weight_grads_b (list of N tensors)
9. For each weight i: combined_grad[i] = weight_grads_a[i] + weight_grads_b[i]
   (already pre-scaled by α and (1-α) at step 5/6)
10. Adam update: weights[i] ← Adam(weights[i], combined_grad[i], adam_state[i], lr)

α tunable hyperparameter, default 0.75 (matches v62's 25% comp ratio in expectation).

## Refactor required

Current `m_train_step` (in `lm_v54_BQ2_s77.rail` and clones) does forward → backward → Adam update **inline** (Adam called as soon as each grad is computed). To separate grad computation from Adam application, refactor to:

### `m_compute_grads x labels mask_chunk blocks w_e gf seq V d dlog_buf scale`
Same forward + backward as `m_train_step`, but instead of calling `half_adam_update`, returns a list `cons d_we (cons d_gf (cons block0_grads (cons block1_grads [])))` where each `blockN_grads` is a 9-element list (d_wq, d_wk, d_wv, d_wo, d_wgate, d_wup, d_wdown, d_g1, d_g2).

The `scale` parameter pre-multiplies the gradient at `m_ce_grad_masked_loop` so all returned grads are pre-scaled.

### `m_accum_grads grads_a grads_b grads_out`
Element-wise tensor add: for each weight i, `grads_out[i] = grads_a[i] + grads_b[i]`. Mutates grads_out's float_arrs in place.

### `m_apply_adam weights grads adam_states lr`
Walks weights/grads/states in parallel. For each weight i, calls `half_adam_update`. Returns 0.

### `m_two_head_step ctx_a ctx_b weights states alpha lr`
Composes the above:
1. `let grads_a = m_compute_grads x_a labels_a mask_a ... alpha`
2. `let grads_b = m_compute_grads x_b labels_b mask_b ... (1.0 - alpha)`
3. `m_accum_grads grads_a grads_b grads_buf` (writes to grads_buf, a pre-allocated grad-shaped buffer)
4. `m_apply_adam weights grads_buf states lr`

`grads_buf` is allocated ONCE at trainer startup (same shape as weights_flat).

## Memory cost

- Two forward caches per step (~2x activation memory)
- Two backward grad lists per step (~2x weight-shape memory) — temporarily, until accumulated to grads_buf
- grads_buf permanent (~1x weight-shape memory)

Total: ~3-4x weight memory vs v54 baseline. v54 uses ~3GB peak; v66 ~10-12GB. Should fit in 64GB Studio RAM.

## Compute cost

Per step: 2 forwards + 2 backwards + 1 Adam = ~2x v54's compute. Wall time: 90 min × 2 = 180 min for 3000 steps.

## Hyperparameters

- α (compile-vs-comp weight): 0.75 default. Sweep: 0.5, 0.75, 0.9.
- LR: 0.01 cosine (matches v54). May need lower since combined gradient has higher "effective" magnitude.
- Steps: 3000 (matches v54).
- Comp corpus: v3 (86KB, lambda-form) or v4 (79KB more diverse).

## Risks

- Refactor breaks self-loop optimization in m_train_step → Rail's TCO might not optimize the new helpers as tightly.
- Float-array gradient buffers compound the heap — may trigger GC pressure or arena fragmentation.
- Adam moments still mixed (no per-loss-head moments); two-loss-head solves the GRADIENT mixing but not the MOMENT mixing. Cleanest fix: separate Adam states per head, but that's 2x state memory and harder to reason about.

## Decision criteria

Run v66 only if v63 (10% interleave) fails to crack Comp. If v63 hits Comp >= 1/5 with total >= 11/30, v66 is unnecessary refinement.

If v66 also doesn't crack Comp (≥ 1/5), the lever isn't gradient handling — it's corpus quality (true hand-curated 200+ semantic shapes) or model capacity.
