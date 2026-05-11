# Session prompt — 2026-05-12 — d=384 bench + batch=32 trainer fork

## Where we are (one paragraph)

Yesterday shipped **10 honest re-benches** of the Spur lineage post
compile.rail fix. v54 holds the lead at 13/30, bq_s200 is a NEW second-
best at 11/30, all V=130 stdlib ckpts collapsed to 1/30. Post-fix
ensemble ceiling is ~13–16/30 (down from buggy 24/30). d=512 NaN'd at
LR=0.01 step 43; fell back to d=384 × 4-block × V=130 stdlib × LR=0.005
× warmup=200 × 6000 steps, which ran overnight. Strategic directive
saved (`exhaust_studio_before_renting.md`): push Studio's untouched
levers — batch, d, blocks, seq, parallel-seeds — BEFORE renting.

**Today's mission:** bench the overnight d=384 ckpt for the first
honest d→d scaling-law data point, then begin the **batch=32 trainer
fork** — Studio's #1 untouched lever. d=256 batch=32 baseline is the
target; d=384 batch=32 is the follow-up if the recipe holds.

---

## ✅ Pre-flight checklist (do FIRST, in order)

1. `[ ]` `hostname` → `studio`. `cd ~/projects/rail`.
2. `[ ]` `git log --oneline -1` shows `ca6d48a` or later on `next`.
3. `[ ]` `git status -sb` clean.
4. `[ ]` `./rail_native test 2>&1 | tail -1` reports `137/137 tests passed`.
5. `[ ]` `./rail_native self && cmp rail_native /tmp/rail_self && echo OK`
   prints `OK` (cycle-2 byte-identical).
6. `[ ]` Check d=384 training PID 63461:
   - `ps -o pid,stat,etime,command -p 63461` — should be `S` (running) or
     gone (completed)
   - If running: `tail -5 /tmp/d384_train.log` — should be at step >5000
   - If gone: check `training/rail_native/checkpoints/d384_4block_half_step6000.meta`
     for final step + val_loss
7. `[ ]` `tail -3 flywheel/bench_log.txt` shows the 10 post-fix entries
   from 2026-05-10.
8. `[ ]` `grep -n 'default_corpus_path' tools/train/lm_infer_v3_mixed.rail`
   shows line 31 = `"training/rail_corpus_stdlib.txt"`.

---

## Required reading (in order, before any code change)

These memory entries explain WHY the experiment is shaped this way:

1. `~/.claude/projects/-Users-user/memory/exhaust_studio_before_renting.md`
   — the directive. Defines the rent-justification gate.
2. `~/.claude/projects/-Users-user/memory/honest_rebench_2026-05-10.md`
   — yesterday's 10-ckpt baseline + ensemble ceiling.
3. `~/.claude/projects/-Users-user/memory/cpu_substrate_conditional_trigger_2026-05-10.md`
   — the compile.rail fix. Required context for "honest" vs "pre-fix"
   numbers.
4. `~/.claude/projects/-Users-user/memory/val_loss_underread.md` — do
   NOT bench a model until eval mean has meaningfully moved.
5. `~/.claude/projects/-Users-user/memory/init_matters.md` — Kaiming
   init is load-bearing for d≥128.
6. `~/.claude/projects/-Users-user/memory/studio_panic_pattern.md` —
   don't stack heavy workloads (training × bench parallel risks panic).
7. `~/.claude/projects/-Users-user/memory/feedback_verify_removals.md`
   — when changing a guard/kernel, write the smoke test FIRST.
8. `~/.claude/projects/-Users-user/memory/feedback_diagnostics_first.md`
   — ship the counter before changing the thing.
9. `~/projects/rail/docs/plans/HANDOFF_NEXT_SESSION.md` — yesterday's
   handoff, includes the lever-priority ranking.

Code references to skim (don't deep-read until needed):

- `tools/train/lm_v3_chunked_d256_4block_half_6k.rail` — the d=256 4-block
  baseline trainer. The fork starts from this. ~920 lines.
- `tools/train/lm_v3_chunked_d384_4block_half_6k.rail` — d=384 fork
  shipped yesterday. Identical structure modulo `d = 384`.
- `stdlib/tensor.rail` — `Tensor` and `HalfTensor` ADTs, shape helpers.
- `stdlib/transformer.rail` — the kernels (matmul, attention, softmax,
  rmsnorm). MUST audit each for batch=1 assumptions.

---

## Phase 1 — bench d=384 (1 hr)

Goal: first post-fix d→d scaling-law data point.

Gates:
- If d=384 training did NOT complete (still running or NaN'd) → wait
  for completion OR fall back to whatever last min-ckpt was saved.
- If d=384 final `best_val_loss > 4.5` → recipe didn't converge; flag
  and skip to Phase 2 with d=256 batch=32 instead.

Steps:
1. Read `training/rail_native/checkpoints/d384_4block_half_step6000.meta`
   — confirm final step + best_val_loss. Should be < 3.39 (v06 d=384
   2-block bar) to be a real scaling result; ideally < 3.0.
2. Bench with current default (stdlib V=130 corpus matches training):
   ```bash
   DYLD_LIBRARY_PATH=tools/metal /tmp/rail_bench_strip \
     --prefix training/rail_native/checkpoints/d384_4block_half_step6000 \
     --max 60 --k 10 --temp 0.8 \
     --tag d384_4block_post_fix \
     --gen-source tools/train/lm_infer_v3_mixed.rail \
     2>&1 | tee /tmp/bench_d384.log
   ```
   **CAVEAT:** `lm_infer_v3_mixed.rail:324` hardcodes `d=256` in the
   gen_loop call. The attention scale = `1/sqrt(d)` will be wrong for
   d=384 (uses sqrt(256) instead of sqrt(384)). The bench will still
   run but the result is slightly off — note this in the bench tag and
   append a fix to your todo. If you have time, the 1-line fix is:
   `let d_actual = match w_e_h | HalfTensor _ shape _ -> head (tail shape)`
   right before line 324.

3. Record result in `flywheel/bench_log.txt` (auto-appended by
   bench_strip). Expected ~45 min wall-clock.

4. Plot in your head: d=256 (v54) 13/30 → d=384 (??) X/30.
   - If X > 13: scaling is the lever, batch=32 will compound it.
   - If X ≈ 13: mixed signal, but batch=32 still tests a different axis.
   - If X < 8: d=384 didn't help; revisit before scaling further.

---

## Phase 2 — batch=32 trainer fork (4-8 hrs)

Goal: Studio's #1 untouched lever. d=256 batch=32 vs the proven batch=1
v54 recipe (or its 4-block variant). Same wall-clock comparison.

### Step 2a — Smoke test the existing kernels at batch>1 (1-2 hrs)

**This is the critical de-risk step.** Per
`feedback_verify_removals.md`, write the smoke test BEFORE touching
the trainer.

Audit each kernel in `stdlib/transformer.rail` for batch-dim handling.
The current trainer feeds `(seq × V)` shapes; batch=32 will feed
`(batch × seq × V)`. Kernels likely needing batch handling:

| Kernel | Current shape | Batch=32 shape | Risk |
|---|---|---|---|
| `matmul_mixed x w_e_h` | `(seq, V) × (V, d)` | `(B, seq, V) × (V, d)` | matmul should batch-broadcast |
| `rope_apply q` | `(seq, d)` in place | `(B, seq, d)` in place | Q/K position indexing |
| `apply_causal_mask` | `(seq, seq)` | `(B, seq, seq)` | per-batch mask repeat |
| `tensor_softmax scaled` | `(seq, seq)` | `(B, seq, seq)` | row-wise per-batch |
| `rmsnorm_save x g` | `(seq, d)` | `(B, seq, d)` | per-batch norm |
| `tensor_add x attn_out` | `(seq, d)` | `(B, seq, d)` | elementwise broadcast |

Write `tools/diagnose/batch32_kernel_smoke.rail`:
- Allocate fixed-value `(2, 4, 8)` tensor (B=2, seq=4, d=8)
- Run each kernel on it
- Print intermediate shapes + a sentinel value (e.g., element [0,1,3])
- Compare against running same kernel on `(4, 8)` slice at B=0 → must match

Any kernel that diverges OR errors → file the bug, patch the kernel,
re-smoke. **Do NOT modify the trainer until all 6 kernels pass the
smoke.**

### Step 2b — Fork the trainer (1-2 hrs)

Once kernels are batch-safe:

1. `cp tools/train/lm_v3_chunked_d256_4block_half_6k.rail tools/train/lm_v3_chunked_d256_4block_batch32.rail`
2. Add `batch_size = 32` near top.
3. Change `x_data` allocation to `(batch × seq × V)`.
4. Modify `sample_chunk` to fill 32 random offsets:
   - Either use 32 rng advances (sequential)
   - Or maintain 32 parallel rng states (initialize from base seed)
5. Verify `m_train_step` handles the batched forward+backward. The Adam
   update at the end is unchanged (Adam averages per-param naturally).
6. Reduce `max_steps` to 188 for the first run (32× fewer steps = same
   token throughput as batch=1 × 6000 steps). Or keep 6000 for "more
   total tokens seen".
7. Use proven LR/warmup: `base_lr = 0.01`, `warmup = 100` from the d=256
   batch=1 recipe.
8. Ckpt path: `training/rail_native/checkpoints/d256_4block_batch32_step3000`.

### Step 2c — Sanity train (1-2 hrs)

- Run 200 steps first. Compare val_loss curve to batch=1 same-step:
  - batch=1 d=256 at step 200: ~3.3 (extrapolated from v54)
  - batch=32 d=256 at step 200: ??
- If batch=32 step 200 < batch=1 step 200: gradient quality is the win.
  Continue to 3000 steps overnight.
- If batch=32 step 200 ≈ batch=1: more batching needed (try 64) or
  there's a hidden bug.
- If batch=32 step 200 worse: a kernel still has a batch bug — re-smoke.

### Step 2d — Overnight train + bench (next day)

- Run 3000 steps overnight (likely ~10-12 hr at d=256 batch=32 4-block).
- Bench result post-fix.
- Plot: v54 batch=1 13/30 → batch=32 X/30.
- If lift > 0: batch is a lever. Compose with d=384 next round.
- If lift = 0: batch wasn't the bottleneck; revisit structural levers.

---

## Floor (don't break)

- 137/137 green
- Byte-identical self-compile cycle ≥ 2
- `lm_infer_v3_mixed.rail:31` default_corpus_path = `training/rail_corpus_stdlib.txt`
- v_full bisect produces 0.020599 (compile fix regression test)
- Don't quote pre-fix numbers (24/30, 25/30, 7/30, 8/30) as targets;
  ONLY the post-fix tags
- Every bench claim ties to a `flywheel/bench_log.txt` post-fix line
- Don't bench a model whose val_loss hasn't moved past v54's 3.19 baseline

## STOP conditions (write a fresh handoff and halt)

1. Pre-flight check #4 (137/137) or #5 (byte-identical) fails — investigate
   compile.rail before any model work.
2. d=384 bench < 6/30 — recipe is broken, not a scaling issue.
3. Kernel smoke test reveals a batch-dim bug that can't be patched in
   <2 hours — file, defer batch=32, revert to d=256 batch=1 multi-seed
   parallel runs as Studio-exhaustion alternative.
4. Batch=32 d=256 step 200 val_loss > 5.0 — something is corrupt;
   re-smoke kernels.
5. Studio panic during concurrent bench + training — kill both, restart
   serial.

## Reusable commands

```bash
# Bench any ckpt (set default_corpus_path FIRST if non-stdlib)
DYLD_LIBRARY_PATH=tools/metal /tmp/rail_bench_strip \
  --prefix <CKPT_PREFIX> \
  --max 60 --k 10 --temp 0.8 \
  --tag <TAG>_post_fix \
  --gen-source tools/train/lm_infer_v3_mixed.rail

# Corpus matching:
#   V=93  → training/corpora/spur_compile_back_quarter.txt
#   V=96  → training/corpora/spur_compile_half_b.txt
#   V=130 → training/rail_corpus_stdlib.txt  (default)

# Kernel smoke (write this BEFORE the trainer fork)
./rail_native run tools/diagnose/batch32_kernel_smoke.rail

# Self-compile + cycle check
./rail_native self && cmp rail_native /tmp/rail_self && echo "byte-identical"

# Regression test for codegen fix
./rail_native run tools/diagnose/cpu_bisect_v_full.rail \
  -- --prefix runs/smoke_v54_repro/checkpoints/smoke_v54_repro_best \
     --corpus training/corpora/spur_compile_back_quarter.txt \
     --prompt "main = " --max 1 --k 1
# expect: BISECT x_embed[0]=0.020599365234375
```

## What success looks like for THIS session

A clean handoff with:
- d=384 honest bench result in `bench_log.txt` (post-fix tag)
- `tools/diagnose/batch32_kernel_smoke.rail` shipped, all 6 kernels pass
- `tools/train/lm_v3_chunked_d256_4block_batch32.rail` shipped
- 200-step sanity training run completed with logged val_loss curve
- Decision: continue to overnight batch=32 train, or pivot to
  parallel-seeds Studio-exhaustion alternative
- Memory entries updated with findings
- Pushed to `origin/next`

## What to NOT do

- Don't fork the trainer until kernel smoke passes for ALL 6 kernels.
- Don't bench a model whose val_loss hasn't moved past v54's 3.19.
- Don't rent compute (this directive is in effect — see
  `exhaust_studio_before_renting.md`).
- Don't run batch=32 train concurrent with another heavy workload (studio_panic_pattern).
- Don't quote pre-fix numbers as targets.
- Don't try d=512 again without LR engineering first.
