# HalfTensor Session 2 — Studio lane (training pipeline)

**Machine:** Studio (`user@home`), M1 Ultra.
**Branch:** `half-s2-train` (off `a7a9bb9` on `next`).
**Paired with:** Mini lane, `PROMPT_B_HALFTENSOR_S2_MINI.md`. You two run concurrently; the main session reconvenes when both finish.
**Budget:** 3-4 h.

## Why this split exists

Session 2 as originally scoped (kernels + training pipeline + bench, all in one) was ~4-5 h sequential. We're parallelizing: Mini builds the non-matmul half kernels + stdlib wrappers, you build the fwd-fp16 training variant using temporary cast shims for the ops Mini hasn't shipped yet. When Mini's kernels land (pull periodically), swap shims for real calls. Final bench is yours.

**You own these files, exclusively this session:**
- `tools/train/lm_v3_chunked_half.rail` (new file, cloned from `tools/train/lm_v3_chunked.rail`)
- Any new `tools/test/lm_v3_chunked_half_*.rail` smokes
- `docs/plans/PHASE_5A_HALF_TRAIN_RESULT.md` (new, end-of-session)

**Do NOT touch:**
- `stdlib/tensor.rail` — Mini's territory this session. If you need a half op Mini hasn't shipped, use the cast shim (see below), not a stdlib edit.
- `tools/metal/tensor_gpu.metal`, `tools/metal/tensor_gpu_lib.m` — Mini's.
- `tools/train/lm_v3_chunked.rail`, `lm_v3_chunked_4block.rail`, `lm_v3_chunked_fp16.rail` — frozen references. Read only.

## What's already available (shipped in Session 1)

In `stdlib/tensor.rail`:
- `HalfTensor` ADT (line 27 and 477-525)
- `half_tensor_new`, `half_of_tensor`, `tensor_of_half`
- `matmul_half` — zero-cast fp16 matmul, 4.77× at 1024²

You have enough to build the pipeline today. The pieces Mini is shipping (`add_half`, `scale_half`, `transpose_half`, `softmax_half`) are performance wins, not correctness blockers — the cast shim below is numerically equivalent, just slower.

## The cast-shim pattern (temporary, swap out when Mini ships)

```rail
-- Temporary shim: f64 op wrapped to accept/return HalfTensor
softmax_half_shim h =
  let t = tensor_of_half h
  let r = tensor_softmax t
  half_of_tensor r

add_half_shim a b =
  let ta = tensor_of_half a
  let tb = tensor_of_half b
  half_of_tensor (tensor_add ta tb)

-- etc for scale, transpose
```

These sit at the top of `lm_v3_chunked_half.rail`. When Mini ships `softmax_half` for real, replace `softmax_half_shim` with direct `softmax_half` calls — one search/replace per op. Commit each swap as `train: swap <op>_half shim for real kernel`.

**This means your pipeline is correct from step 1 and gets faster as Mini's commits land.** Worst-case (Mini finishes late), you still have a correct fp16-weights + fp16-matmul training variant with cast shims on non-matmul ops. Best-case, the final 10-step wall-time bench runs on all-real-kernels.

## What you build

### Step 1 — Clone and retype (45 min)

`cp tools/train/lm_v3_chunked.rail tools/train/lm_v3_chunked_half.rail`, then:

- At `main`: right after weights are initialized (f64), cast each weight to HalfTensor via `half_of_tensor`. Weights live as HalfTensor for the rest of main.
- `m_block_fwd`: change signature to accept HalfTensor weights + HalfTensor activations. Replace `matmul` calls with `matmul_half`. Replace `tensor_softmax / tensor_scale / tensor_add / tensor_transpose` with shim versions (above). Keep `rmsnorm_save` and `rope_apply` in f64 with a local cast-around — per Session 1 doc, they're precision-sensitive and the savings are small.
- `m_block_bwd`: cast dx from HalfTensor → Tensor at entry. Compute all grads and Adam updates in f64 (unchanged). At the end of the adam step, cast the updated weight back to HalfTensor.
- `run_segments` / loss loop: no structural change. Just ensures the train loop calls the new half variants.

Scope discipline: helper arity ≤ 10, so if the fwd needs more weights threaded through, bundle via existing weight-struct pattern from `lm_v3_chunked.rail`.

Commit as: `train: lm_v3_chunked_half — fp16 weights + fwd with cast shims`.

### Step 2 — 10-step smoke (30 min)

Stage a tiny compile+run:
```bash
./rail_native run tools/train/lm_v3_chunked_half.rail   # max_steps=10 hardcoded
```

Acceptance:
- Compiles. No runtime segfault. No NaN/Inf in loss.
- Loss descends: step 10 loss < step 1 loss.
- Peak RSS via `time -l` (shell builtin on macOS; `/usr/bin/time` strips DYLD under SIP).

If this breaks, fix before staging up. Don't batch fixes with later commits.

Commit as: `train: lm_v3_chunked_half 10-step smoke` (may be a separate test file, or just a verified max_steps=10 run you document in commit body).

### Step 3 — Stage 50 → 500 (30 min)

Same binary, bump `max_steps`. At 500:
- Eval mean within 0.2 of f64 baseline at checkpoint 100, 200, 300, 400, 500. (Baseline: the d=128 × 2-block × f64 eval trajectory is recorded in `SESSION_HANDOFF_2026-04-22.md` — 2.87 ± 0.18 @ 3000; earlier checkpoints are in `tools/train/lm_v3_chunked.rail` log output.)
- No NaN/Inf at any step.
- Peak RSS < f64 baseline's ~460 MB.

If eval diverges past 0.2: root-cause before running longer. Most likely suspect: softmax shim's f64↔fp16 round-trip is where precision loss can bite even in a "round-trip should be clean" setup. If Mini has shipped `softmax_half` by now, swap it in and re-stage.

### Step 4 — 10-step wall-time bench (30 min)

`seq=1024 d=128 2-block`, eval disabled, 10 steps:
- Record wall-time via shell `time`.
- Compare to f64 baseline on same machine (Studio — record a fresh f64 wall-time right before, don't trust numbers from a different run).
- **Target: ≥1.6× vs f64 if Mini's kernels are live. ≥1.3× if you're still on full cast shims.** Either is a keeper; the bench measures what you ran, not what you wished you ran.

Commit as: `bench: lm_v3_chunked_half 10-step wall-time vs f64`.

### Step 5 — Swap shims as Mini lands kernels (periodic)

Every 30-45 min, pull `half-s2-kernels` branch state:
```bash
git fetch origin half-s2-kernels
git log --oneline origin/half-s2-kernels ^half-s2-train | head
```

When a new `stdlib: X_half wrapper` commit appears:
1. Cherry-pick or merge that commit.
2. In `lm_v3_chunked_half.rail`, replace `X_half_shim` call with `X_half` direct call.
3. Rebuild dylib:
   ```bash
   cd tools/metal && clang -shared -fobjc-arc \
     -framework Metal -framework Foundation \
     -install_name ~/projects/rail/tools/metal/libtensor_gpu.dylib \
     tensor_gpu_lib.m -o libtensor_gpu.dylib
   ```
4. 10-step smoke to verify numerics still clean.
5. Commit: `train: swap <op>_half shim for real kernel`.

Order of swap (cheapest first, in case Mini ships out of order): add → scale → transpose → softmax.

### Step 6 — Writeup (30 min)

`docs/plans/PHASE_5A_HALF_TRAIN_RESULT.md`:
- Eval trajectory table vs f64 baseline.
- Wall-time table (cast-shim vs real-kernel version if you got both).
- Peak RSS comparison.
- What shipped; what the numbers say; what's open for Session 3.
- Commit: `docs: Phase 5a half training result`.

## Done criteria

- `lm_v3_chunked_half.rail` trains stably at max_steps=500 with eval within 0.2 of f64 at every checkpoint.
- Wall-time bench commits have concrete numbers (not promises).
- Branch `half-s2-train` pushed (via Mini proxy at the end if that's the push flow in use).

## Report back with

1. Eval trajectory at 100/200/300/400/500 vs f64 baseline (table).
2. 10-step wall-time ratio vs f64 on the same machine, with a note on which shims were live vs real-kernel at bench time.
3. Peak RSS vs f64.
4. Which Mini kernels you integrated in time for the bench.
5. Any numerical surprise — especially if the softmax shim round-trip introduced drift the real kernel would avoid.

If the pipeline doesn't converge at 500 steps, STOP and report. Don't push a broken training variant past 500 just to get a wall-time number — we'd rather know it's broken and fix in Session 3 than have a fast-but-wrong artifact.

## Do NOT

- Edit `stdlib/tensor.rail`. Mini owns it. Use shims.
- Edit any metal file. Mini owns them. Rebuild dylib when you pull Mini's commits.
- Touch `tools/train/lm_v3_chunked.rail`, `lm_v3_chunked_4block.rail`, `lm_v3_chunked_fp16.rail`.
- Commit `libtensor_gpu.dylib` (gitignored) or the `-install_name` override.
- Run anything on Mini. You're Studio-only this session.

## Gotchas (re-stated)

- `float >=` codegen segfault; route via ×1000 int compare if the training code has any.
- Helper arity ≤ 10. If you need more, bundle into a `float_arr 2` accumulator.
- Nullary `let x = float_arr_new ...` re-evaluates on every reference; thread as a parameter.
- `/usr/bin/time` strips DYLD — use shell builtin `time`.
- `date +%s%N` doesn't work on BSD date (Studio). Use `python3 -c 'import time; print(int(time.time()*1e9))'` if you need ns-precision timing.
- `cp rail_native X` invalidates codesign. You should NOT need to rebuild rail_native this session — the half ops are stdlib-level and don't touch the compiler. If you do, re-sign with `codesign -s - --force rail_native`.

## What happens next

When you and Mini both finish, the main session reconvenes, writes `HALFTENSOR_SESSION2_RESULT.md` (consolidating both lanes), and designs Session 3 — almost certainly the Phase 5 composed run at d=256 × 2-block × HalfTensor × 3000 steps.
