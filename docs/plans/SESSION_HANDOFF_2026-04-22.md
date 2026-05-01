# Next session handoff — 2026-04-22

**Purpose:** drop-in context for the next working session. Read this file + `MEMORY.md` + `docs/plans/HALFTENSOR_SESSION1_RESULT.md` (for B's infrastructure) and you have everything to pick up without re-reading 2026-04-21's full session prompt.

**HEAD at handoff time:** `e2211cb` on `next` (Session 2 merge). Both lanes converged.

**Status update 2026-04-22 (late):** HalfTensor Session 2 is DONE. Both lanes merged. See `docs/plans/HALFTENSOR_SESSION2_RESULT.md` for the consolidated numbers and `docs/plans/PROMPT_HALFTENSOR_S3.md` for the Phase 5 composed run (now the active next step). Skip to §"The next big thing" below for the updated block order.

---

## The mission (unchanged)

Rail-on-Rail in Rail. A Rail-native transformer that writes Rail, compiler-verified. `bench_railnative` ≥ 5/30 and one closed flywheel round by **2026-04-27** (~5 working days out).

---

## What's landed as of 2026-04-21 end-of-day

Two concurrent sessions across three rounds shipped 14 commits. Headline:

**Capacity:** d=128 × 2-block and d=128 × 4-block both train cleanly at 3000 steps. Eval mean ≈ 2.87 either way — depth alone doesn't help at this d. Width (d=256) is the next dial.

**Precision/speed:** fp16 matmul path is wired end-to-end. Four foreign decls, four host dispatchers, fwd-only training variant converges. HalfTensor ADT + zero-cast dispatcher land at **4.77× matmul speedup at 1024²** (5.20× at 512², 1.86× at 128²). Accuracy byte-identical to the cast path.

**Memory:** `_free` no-op stub in `compile.rail:2855` fixed with a small-block free list — 38% peak RSS reduction. Residual 2 MB/step proven to be macOS VA accounting, not a real leak. `alloc_stats_snapshot` builtin available for future profiling. 4-block × 3000-step peak stayed flat at 515 MB for 2.6 h.

### Commits (chronological, all on `next`)

```
0b35676  docs: Session A Phase 2b result — 4-block × d=128 × 3000 steps
855064e  docs: HalfTensor Session 1 analysis — 5× cast-elimination + S2 scope
876e90e  test: matmul_half numerical equivalence + cast-overhead microbench
abdc2f0  metal: tgl_matmul_half_host — zero-cast fp16 matmul dispatcher
e366f4a  stdlib: HalfTensor ADT + host-side fp16 pack/unpack
d28e1e2  docs: Session B Round 3 prompt — HalfTensor reframing
5646871  docs: handoff appendix (Phase 4b)
5b4a726  bench: wall-time + convergence doc (Phase 4b)
6779569  train: lm_v3_chunked_fp16 (forward-only fp16)
35e96d4  stdlib: matmul_f16 + bias-fused variants (Tensor wrappers)
6019786  train: lm_v3_chunked_4block — 4-block Llama-style transformer
7d7f5b7  compile: allocator diagnostic counters + alloc_stats_snapshot builtin
77765c0  docs: 1d.4 fix result — 33% RSS reduction, residual 2 MB/step analysis
2cf68f6  compile: small-block free list fixes the chained_malloc leak
1d37a11  bench: fp16 forward swap — 10-step lm_v3_chunked wall-time
8d8bcdd  test: fp16 matmul smoke — 128×128 numerical equivalence
2680e20  metal: fp16 matmul host dispatchers (Phase 4a wiring)
aa1ecb9  stdlib: fp16 matmul foreign decls (Phase 4a wiring)
```

### Benchmarks that matter

| metric | value | context |
|---|---|---|
| eval mean @ 3000 (d=128, 2-block, f64) | **2.87 ± 0.18** | the bar to beat |
| eval mean @ 2900 (d=128, 4-block, f64) | 2.88 ± 0.23 | tied — depth didn't help |
| min single-chunk (4-block) | 0.965 | deeper memorizes better |
| matmul_half vs f16-with-cast, 1024² | **4.77×** | B's Session 1 |
| matmul_half vs f16-with-cast, 512² | 5.20× | peak of curve |
| matmul_half vs f16-with-cast, 128² | 1.86× | dispatch latency floor |
| fwd-only fp16 training wall | 1.07× | Phase 4b, cast-limited |
| peak RSS (4-block × 3000 steps) | 515 MB flat | leak fix holds |

---

## The next big thing: Phase 5 composed experiment

Today's two independent wins compose into one experiment that could be the flywheel's training-side flagship result.

**Hypothesis:** d=256 × 2-block × HalfTensor × 3000 steps drops eval mean below 2.7, at roughly the same RSS as today's d=128 × 2-block × f64 baseline.

**Why it might work:**
- d=128 × 4-block proved depth isn't the bottleneck at this width.
- Width doubles per-token mixing rank; depth just repeats it.
- HalfTensor halves weight memory, so d=256 × 2-block at ~same RSS as d=128 × 2-block × f64 is plausible.
- B's Session 2 (the half training pipeline) is the only prerequisite.

**Why it might not:**
- d=256 may need different init scaling; Kaiming's `sqrt(2/fan_in)` is correct but absolute magnitude changes.
- Larger hidden may trigger the γ bounce in different locations even with `lr_mult=0.3`.
- Softmax in fp16 can overflow (exp of large scores), as B flagged in `HALFTENSOR_SESSION1_RESULT.md`. Log-sum-exp reformulation needed in Session 2.

### The three work blocks in order

**Block 1 — HalfTensor Session 2. ✅ DONE (2026-04-22).**
Consolidated result: `docs/plans/HALFTENSOR_SESSION2_RESULT.md`.
- ✅ 4 new half kernels (add/scale/transpose/softmax) ship, max-abs-diff <1e-3 vs f64. Softmax log-sum-exp overflow-safe.
- ✅ `tools/train/lm_v3_chunked_half.rail` trains 500 steps, eval within 0.28 of f64 baseline (within noise).
- ⚠️ Wall-time speedup at d=128 is 1.10× (below ≥1.6× target). Expected: matmul fraction is small at d=128; win lives at d=256.
- ⚠️ RSS at d=128 is parity (512 vs 508 MB). Weight-memory halving is reclaimed by cast temps at d=128.
- ⚠️ Mini's `./rail_native test` hung during S2 — unrelated to S2 changes per Mini's analysis, but needs re-confirmation on Mini before Session 3 launches.

**Block 2 — Phase 5 composed run. 🔜 ACTIVE NEXT (Studio, 2-3 h).**
Prompt: `docs/plans/PROMPT_HALFTENSOR_S3.md`. Single-machine this time (Studio); Mini idle unless a kernel fix is needed.
- Clone `lm_v3_chunked_half.rail` → `lm_v3_chunked_d256_half.rail`. Set `d = 256` (auto-derived `d_ff` follows).
- Stage 10 → 50 → 500 steps first. Check for NaN/Inf at the wider attention range.
- If stable: launch 3000-step run. ETA ~1.5-2 h wall.
- Parallel options during the run: (A) write `PHASE_4C_MODEL_CARD.md` skeleton; (B) Task #14 Phase 2d.E wiring; (C) `bench_railnative` on the current 4-block checkpoint.
- Success: eval mean < 2.7. Stretch: eval < 2.5.

**Block 3 (after Block 2) — Phase 4c model card (2 hours).**
After Block 2 lands with a number:
- New doc `docs/plans/PHASE_4C_MODEL_CARD.md`. Architecture, precision, training config, corpus, eval results, `bench_railnative` score, hardware/wall/energy cost, one-liner for web.
- The defensible claim: *"A transformer whose training matmuls, inference matmuls, weights, and activations are all fp16 — verified end-to-end by a Rail compiler written in Rail."*
- This is the flagship artifact for the 2026-04-27 deadline.

---

## Parallel work that could land in this session if time / interest

Ranked by leverage:

**Rank 1 — Task #14 Phase 2d.E retrain bench wiring (B or A, 2-3 h).**
Primitives exist in `tools/train/self_train.rail` (`harvest_snapshot`, `harvest_rollback`, `harvest_ab_gate`). Needs:
- Private repo sync: `scp -r ledaticempire@mini.tb:~/projects/rail-training/flywheel ./flywheel-local/` or equivalent.
- Wire `harvest_snapshot 0` + bench parse + `harvest_ab_gate` around the `retrain` call in `run_loop`.
- Force one-round self_train test with `--parallel 4` to validate the gate fires correctly.

Blocks: nothing (Mini should have the private repo). Unblocks: A/B discipline on self-training iterations, which is the flywheel's quality control.

**Rank 2 — Task #9 residual 2 MB/step clean-up (optional, B, 1-2 h).**
B's diagnostic doc verdicts the residual as macOS VA accounting. If we want to prove it with one more experiment: run 5000 steps, show RSS asymptote doesn't grow past ~2× of a 2000-step run. Low leverage (we already have the verdict) but closes the chapter for the model card appendix.

**Rank 3 — Code-JEPA milestone 1 (B or A, 2 h).**
From `docs/plans/CODE_JEPA_5_0b.md`. Pure data-munging, no dependency on training: extract `(source_ids, compile_ok_bool)` pairs from `harvest.jsonl` positives and `*_repairs.jsonl` negatives. Sets up the learned-oracle backbone for later. Not critical path for 2026-04-27.

---

## Machine roles + coordination rules

**Studio (user@home).**
- Primary training workhorse, M1 Ultra GPU.
- Can't push to GitHub directly — always via Mini proxy.
- `rail_native` here is Studio-local; never commit from Studio.
- Re-sign after any `cp rail_native X`: `codesign -s - --force X`.

**Mini (ledaticempire@mini.tb).**
- Canonical push point. Compiler development. M4 Pro GPU.
- Private repo `Ledatic-Empire/rail-training` lives here (scp to other machines).
- Self-compile fixed-point requires 2 unsigned passes (ad-hoc codesign bytes differ; cmp two unsigned outputs, not signed-vs-unsigned).

**Both machines.**
- `tools/metal/libtensor_gpu.dylib` is gitignored. After any `tools/metal/tensor_gpu_lib.m` change, rebuild on whichever machine needs to run the new dispatcher:
  ```
  cd tools/metal && clang -shared -fobjc-arc \
    -framework Metal -framework Foundation \
    -install_name /Users/$USER/projects/rail/tools/metal/libtensor_gpu.dylib \
    tensor_gpu_lib.m -o libtensor_gpu.dylib
  ```
- Don't commit the `-install_name` override — source stays `/Users/ledaticempire/...`.

**Session coordination.**
- Ownership: Studio = training / GPU experiments; Mini = compiler / stdlib / dylib work. Can be renegotiated per round.
- Before touching shared files: `ssh ledaticempire@mini.tb "cd ~/projects/rail && git status"`.
- `/tmp/rail_out` is a shared file per machine — concurrent compile-run on the same machine will collide. Use the other machine or wait.
- Commit granularity: one commit per logical unit (decls / dispatch / test / bench / docs). Prefix `stdlib:` / `metal:` / `train:` / `test:` / `bench:` / `docs:` / `compile:`.

---

## Gotchas worth remembering (most of these bit someone today)

1. **`/usr/bin/time` strips `DYLD_*` under SIP.** Use shell builtin `time` for benches that depend on the dylib.
2. **Helper arity ≤ 10 params.** Pack scalar accumulators into `float_arr_new 2`.
3. **Nullary `let x = float_arr_new ...` re-evaluates on every reference.** Thread arrays as parameters, don't cache them.
4. **Nested `match` on multi-ctor ADTs at depth ≥ 2 mis-parses.** Single-ctor ADTs (like `Tensor` and `HalfTensor`) are safe. Reproducer at `tools/test/match_nest_exhaustive_bug.rail`.
5. **Float `>=` codegen segfaults** on simple `a >= b` even when both are provably float. Route via `*1000 → float_to_int → int >=`.
6. **`str_replace` replaces ALL occurrences** — grep for uniqueness before doing find/replace patches.
7. **`foreign X -> float` with int args** untags the int as if it were tagged-float bits, returns garbage. Either make all args float, or use a shell-based alternative. (Root cause: `untag_float_args` in `tools/compile.rail:1252` assumes all args are float when return is.)
8. **`abs_f` is already in `stdlib/tensor.rail:1526`.** Don't redefine it in smokes.
9. **`gpu_map` test fails on Studio** (no `xcrun metal`). Stable Studio baseline is 136/137; Mini is 137/137. Don't chase this.
10. **`cp rail_native X` invalidates ad-hoc codesign.** Re-sign immediately after.
11. **Rail's `getenv` returns empty through the `/bin/sh -c` wrapper** in `rail_native run`. Use sentinel files for config, not env vars.
12. **macOS `date +%s%N`** works on Mini (GNU coreutils) but not Studio (BSD `date`). Use `python3 -c 'import time; print(int(time.time()*1e9))'` for portability.

---

## Concrete first 60-minute checklist for next session

```bash
# 0. State check
cd ~/projects/rail
git log --oneline -5                       # expect HEAD = 0b35676 or newer
git rev-parse HEAD origin/next              # should match
./rail_native test                          # expect 137/137 (Mini) or 136/137 (Studio)

# 1. Session 2 is DONE. Session 3 is active.
#    Read: docs/plans/HALFTENSOR_SESSION2_RESULT.md  (what landed)
#    Read: docs/plans/PROMPT_HALFTENSOR_S3.md        (what to do next)
#
#    If Mini's ./rail_native test was still hanging, rerun to confirm 137/137.
#    (Session 2 flagged this as unrelated to S2 changes but unverified.)

# 2. Rebuild dylib if tensor_gpu_lib.m changed since last time
test tools/metal/tensor_gpu_lib.m -nt tools/metal/libtensor_gpu.dylib && \
  (cd tools/metal && clang -shared -fobjc-arc -framework Metal -framework Foundation \
     -install_name "/Users/$USER/projects/rail/tools/metal/libtensor_gpu.dylib" \
     tensor_gpu_lib.m -o libtensor_gpu.dylib)

# 3. Quick smoke of the fp16 path (confirms dylib symbols resolved)
./rail_native run tools/test/fp16_matmul_smoke.rail      # expect "ok fp16"
./rail_native run tools/test/matmul_half_smoke.rail      # expect 4-5× speedup report
```

---

## What to NOT do

- Don't restart A's 4-block experiment — the 2.88 result is the answer, and there's nothing to chase by re-running. Move on to width.
- Don't pursue "fp16 in backward" — Phase 4b proved it diverges by a full nat at step 499. Backward is f64. Write this in the model card.
- Don't commit `rail_native` from Studio.
- Don't commit `libtensor_gpu.dylib` (it's gitignored).
- Don't commit the `-install_name /Users/user/...` patch to `tensor_gpu_lib.m`.
- Don't try to get below 0.5 MB/step residual — B's verdict (macOS VA, not a real leak) is the close. Further work there is negative EV.

---

## The 2026-04-27 deadline — where we are

| milestone | status |
|---|---|
| Training pipeline works | ✅ d=128 × 2-block, d=128 × 4-block both converge |
| Leak fix | ✅ 38% peak RSS reduction, residual identified as non-leak |
| fp16 infrastructure | ✅ kernels, dispatchers, HalfTensor ADT, zero-cast path |
| fp16 training variant | ⚠️ fwd-only landed (1.07×); HalfTensor Session 2 pending |
| d=256 capacity experiment | 🔜 blocked on HalfTensor Session 2 |
| Phase 4c model card | 🔜 blocked on d=256 result |
| `bench_railnative` ≥ 5/30 | 🔜 need to actually run the bench after each capacity bump |
| One closed flywheel round | 🔜 needs Task #14 (2d.E retrain wiring) + private repo |

Six remaining work items. Three of them (HalfTensor S2, d=256 run, model card) are sequential and estimated at 8-10 hours combined. Two are parallel and ~4 hours (Task #14 + bench_railnative runs). Comfortable for 5 working days.

---

Rail-on-Rail in Rail. The precision and the depth experiments converged today. Next session composes them.
