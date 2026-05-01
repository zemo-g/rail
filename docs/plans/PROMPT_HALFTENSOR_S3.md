# HalfTensor Session 3 — Phase 5 composed run

**Machine:** Studio (M1 Ultra). Single-machine, single-session. Mini is idle this session unless something breaks that needs a kernel patch.
**Branch:** `half-s3-composed` (off `next`, post Session 2 merge).
**Predecessor:** `HALFTENSOR_SESSION2_RESULT.md` (both lanes merged); `PHASE_5A_HALF_TRAIN_RESULT.md` (Studio-lane detail).
**Budget:** 2-3 h wall (10→50→500 smoke stages + 3000-step launch + analysis). The 3000-step run itself is ~1.5-2 h under the active-kernel path; that time is overlapped with writeup.

## The hypothesis, restated

**d=256 × 2-block × HalfTensor × 3000 steps drops eval mean below 2.7, at peak RSS no worse than today's d=128 × 2-block × f64 baseline (~460 MB).**

Why it should work:
- d=128 × 4-block proved depth isn't the bottleneck at this width (2.88 vs 2.87, tied).
- HalfTensor halves stored weight memory; at d=256 weights dominate the peak rather than cast temps, so RSS stays flat or falls.
- Session 2 proved the half pipeline converges to within eval noise of the f64 baseline at d=128. No remaining correctness blockers.
- Session 2's 1.10× speedup at d=128 was flops-fraction-limited; at d=256 the matmul fraction grows (seq·d² scales 4×, non-matmul ops ~2×) and step-level speedup should push toward Session 1's 4-6× microbench regime.

Why it might not:
- **Init scale at d=256.** Kaiming's `sqrt(2/fan_in)` is correct in form but the absolute magnitude shifts. Watch step-0 loss — should still be ~13 (uniform-prediction floor for a vocab of ~130), not blowing up to 20+.
- **γ bounce from d=128 could recur in different layer indices at d=256.** `lr_mult=0.3` on γ in `lm_v3_chunked_half.rail` was tuned at d=128. Consider `lr_mult=0.2` for d=256 if step 100 eval jumps.
- **fp16 overflow in attention scores at wider d.** At d=256 the Q·Kᵀ product has a larger dynamic range before the 1/√d scale; the scaled attention scores still sit well below fp16's ~65k exp-input ceiling (theoretical max for random init: ~√d = 16), but check step-0 attention scores for any row near that limit.
- **Cache RSS.** `m_block_fwd` caches 12 HalfTensor activations per block. At d=256 each is 4× the d=128 size. Worst case on peak RSS is 4× the d=128 cache footprint (~50 MB → ~200 MB cache alone).

## Staged rollout — don't skip steps

Memory: "never launch long runs without staged short tests first. 10→20→50→500."

### Stage 1 — clone and retype (20 min)

```bash
cd ~/projects/rail
git checkout -b half-s3-composed
cp tools/train/lm_v3_chunked_half.rail tools/train/lm_v3_chunked_d256_half.rail
```

Edit `lm_v3_chunked_d256_half.rail`:
- Find the `d = 128` definition in `main` and set to `d = 256`.
- Find `d_ff` — if auto-derived, verify it's now 768 (3 × 256). If hardcoded, change.
- Leave `n_layers = 2`, `seq = 1024`, `eval_seed = 1337`, corpus path all unchanged.
- Keep `lr_mult=0.3` on γ for stage 1; revisit at stage 3 if eval bounces.
- `max_steps = 10` for this stage.

`str_replace` caveat: `str_replace "d = 128" "d = 256"` will also replace matches like `d_ff = 128`. Search-then-patch individually, or use distinct indentation in the replacement context.

Commit: `train: lm_v3_chunked_d256_half (10-step stage)`.

### Stage 2 — 10-step smoke (15 min)

```bash
./rail_native run tools/train/lm_v3_chunked_d256_half.rail
```

Expect:
- Compile time ~6-8 s (slightly larger than d=128 due to constant propagation).
- Step 0 loss ~13 ± 0.5 (uniform-prediction floor).
- Step 10 loss < step 1 loss (some descent).
- **No NaN/Inf at any step.** If either appears: stop, investigate attention-score max (softmax input), weight init max.
- Peak RSS via shell `time -l` — record for the d=256 curve.

If the 10-step smoke blows up, stop and report. Do not escalate to 50 steps.

### Stage 3 — 50-step and 500-step stages (45 min)

Bump `max_steps` to 50, re-run. Verify:
- Loss trajectory descending (not flat, not diverging).
- Attention-score max stays < 10 at all layers (check via a debug print you can leave behind).

If 50 clean, bump to 500 — this is the convergence floor for the half pipeline, analogous to Studio's Session 2 gate. At step 500:
- Eval mean should track f64 d=256 baseline (we don't have one yet — the f64 d=128 baseline @ 500 was 3.26). Expect half d=256 @ 500 to land somewhere in the 2.8-3.2 range based on the d=128 × 4-block result (2.88) and the hypothesis that width helps more than depth.
- Peak RSS over the 500-step run via `time -l`.

If 500 converges: **stage 3 passed**, launch the 3000-step run. If eval bounces or flatlines, diagnose before launching: the 3000-step run is 1.5-2 h of wall time and we want to know it's on a good trajectory first.

Commit stages as:
```
train: d256_half 50-step smoke passed
train: d256_half 500-step convergence verified
```

(or fold into a single `train: d256_half staged up through 500 steps` if the diffs are just `max_steps` bumps.)

### Stage 4 — 3000-step launch (1.5-2 h wall)

```bash
# eval_interval=500 so we get 7 checkpoints (0, 500, 1000, ..., 3000)
/usr/bin/time -l ./rail_native run tools/train/lm_v3_chunked_d256_half.rail 2>&1 | tee ~/tmp/d256_half_3000.log &
```

Monitor during the run:
- Peak RSS every 15-30 min via `ps -o rss= -p <pid>` or just let `time -l` collect at the end.
- Any stderr NaN/Inf warnings.
- Eval checkpoints at 500, 1000, 1500, 2000, 2500, 3000 — if any show divergence (Δ to previous > +0.5), consider killing early.

Commit the final result-bearing file:
- `train: d256_half_3000 final config` (if any tuning happened during staging).

## During the 3000-step run — parallel work options

Since the run is ~1.5-2 h unattended, this is a good window for one of:

**Option A — Write `PHASE_4C_MODEL_CARD.md`.**
The model card for the 2026-04-27 deadline. Architecture, precision (fp16 everywhere except bwd/Adam), training config, corpus, the one-liner from the Session 2 result doc. Leave eval-result and `bench_railnative` cells empty; fill when the 3000-step run lands.

**Option B — Task #14 Phase 2d.E retrain bench wiring.**
Independent of Phase 5. 2-3 h. Needs private repo sync (`scp -r ledaticempire@mini.tb:~/projects/rail-training/flywheel ./flywheel-local/`). Wires `harvest_snapshot 0` + bench parse + `harvest_ab_gate` around the `retrain` call in `run_loop`. Unblocks closed-flywheel-round milestone.

**Option C — `bench_railnative` on the current d=128 × 4-block model.**
Studio's 4-block result (eval 2.88) hasn't been run through `bench_railnative` yet. If that number comes back ≥5/30 it meaningfully de-risks the deadline. 30 min.

Pick one. Don't start a second one on Studio — the GPU is busy with the 3000-step run.

## Acceptance criteria

**Primary (the flagship result):**
- Eval mean @ 3000 < **2.7** (stretch: < 2.5).
- No NaN/Inf across the full run.
- Peak RSS < 600 MB (i.e. within ~2× of the d=128 f64 baseline, not 4× which is the naive d² scaling).

**Secondary (the speedup thesis):**
- Step-level wall: d=256 half should run meaningfully faster per step than d=256 f64 *would have* (we don't have that baseline — extrapolate from `lm_v3_chunked.rail` by running 10 steps at d=256 f64 for a direct comparison if curious, ~30 min, optional).
- Matmul-fraction analysis: run a mid-run `samply` or Instruments trace at step 500-1000 to quantify matmul vs non-matmul wall if the speedup is still sub-1.3×.

**Tertiary (the model card's load-bearing number):**
- `bench_railnative` score on the checkpoint at step 3000. This is how we hit the 5/30 milestone.

## Pre-flight checklist (do these before Stage 1)

1. **`./rail_native test` clean on both machines.** Mini flagged a hang during Session 2; Studio's baseline is 136/137 (gpu_map failure, known). Confirm no NEW regressions.
2. **Studio's `libtensor_gpu.dylib` rebuilt** — Session 2 added four new dispatchers to `tensor_gpu_lib.m`. Studio's local dylib may not have them if it hasn't been rebuilt since the merge:
   ```bash
   cd tools/metal && clang -shared -fobjc-arc \
     -framework Metal -framework Foundation \
     -install_name /Users/user/projects/rail/tools/metal/libtensor_gpu.dylib \
     tensor_gpu_lib.m -o libtensor_gpu.dylib
   ```
3. **Corpus path** (`training/rail_corpus_stdlib.txt`, 544018 chars) present. Same corpus Session 2 used; no need to re-fetch.
4. **GPU free.** No concurrent Session 2-style runs in flight.

## Do-not

- Don't rerun Session 2 — the numbers are in, move on to d=256.
- Don't touch `stdlib/tensor.rail` or `tools/metal/` this session. All the primitives Session 3 needs shipped in Session 2. If something's actually missing, stop and think — don't patch.
- Don't run on Mini. The 4-kernel work landed; Mini is free for idle or a parallel task, but the Phase 5 run happens on Studio where the f64 baselines were collected (apples-to-apples comparison).
- Don't commit `libtensor_gpu.dylib` or the `-install_name` override.
- Don't skip the 10→50→500 staging. The 3000-step run is too long to gamble on an untested d=256 config.

## Report back with

1. Eval trajectory at 500, 1000, 1500, 2000, 2500, 3000.
2. Peak RSS over the 3000-step run.
3. Wall-time per step (3000-step wall / 3000).
4. `bench_railnative` score at the final checkpoint (if Option C was picked up).
5. Any fp16 overflow or numerical surprise during staging.
6. Which parallel option (A/B/C) was executed during the 3000-step run, and its outcome.

## Gotchas worth remembering

- `str_replace` is global; grep for uniqueness before patching constants like `d = 128`.
- `/usr/bin/time` strips DYLD under SIP — for the dylib to load, either use shell `time` OR rely on the `-install_name` absolute path (which is what `lm_v3_chunked_half.rail` uses; `time -l` has worked on Studio this session).
- Helper arity ≤ 10. If d=256 pushes any helper over because of added weight threading, bundle via existing `float_arr 2` accumulator pattern.
- `cp rail_native X` invalidates codesign. Shouldn't be needed this session — no compiler changes.

## If this fails

Two failure modes and their implications:

**Failure A — eval mean at 3000 > f64 d=128 baseline (> 2.87).**
That says width doesn't help OR fp16 is a bigger accuracy hit at larger d than Session 2 suggested. Next move: run d=256 f64 as a clean baseline (1-2 h) to disambiguate. If d=256 f64 also > 2.87, the model is capacity-bottlenecked somewhere other than width (likely FFN rank, depth-width balance, or LR schedule). If d=256 f64 < 2.7 but half-at-d=256 > 2.87, fp16 is biting harder at larger d — move residual ops to half kernels (the next-next optimization mentioned in Session 2's Phase 5a writeup).

**Failure B — OOM or NaN during staging.**
Stops Session 3. Root-cause, commit a fix, restart from the relevant stage. Don't power through.

**Success** upgrades the model card's one-liner to its defensible form for 2026-04-27. Deadline math stays comfortable.

---

Rail-on-Rail in Rail. Session 2 proved the precision substrate. Session 3 composes it with width.
