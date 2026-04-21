# Next-session prompt — back to Rail-on-Rail in Rail

**Purpose:** cold-start handoff for the next session. Drop into a fresh
Claude with this file + `MEMORY.md` and you can resume without me.

---

## What was done last night (2026-04-20 PM, ~20:15 → 23:00)

- **Phase 1d.1/1d.2 instrumentation** landed in `lm_v3_chunked.rail`:
  10-chunk held-out eval every 100 steps (the ranking signal; fixes
  T5's chunk-noise problem), RSS snapshot every 500 steps (the memory
  diagnostic).
- **Phase 1d.3 memory bisect** ran 2000 steps instrumented. Found
  **linear 3.15 MB/step leak**, perfectly steady. Peak 6.99 GB.
- **Phase 1d.4 root cause LOCALIZED** — `_free` is a literal `ret`
  no-op at `tools/compile.rail:2855`. Sub-64KB chunks in the malloc
  chain never get freed. Four fix paths documented in
  `docs/plans/1D4_MEMORY_LEAK.md`.
- **Phase 2a (d=64 → d=128, 2-block, 3000 steps)** completed. d=128
  wins: eval mean 2.87 vs d=64's 2.99; min single-chunk 1.31 vs 1.47.
  Real, statistically clear improvement.
- **fp16 probe** ran on Studio M1 Ultra: **1.70× @ N=1024, 1.92× @
  N=2048** — Option A decision gate cleared.
- **Phase 4a decision** — agent-driven (labrat) route chosen over
  hand-port. Reusable infra > one-shot labor.
- **Phase 5.0 labrat scaffold** built via two-agent swarm in ~5 min:
  `README.md`, `labrat.rail`, `researcher.rail`, `tasks/fp16_matmul.spec`,
  `test_researcher.rail`. Compiles + smokes clean.
- **Labrat first end-to-end win**: MLX agent produced a textbook
  matmul_f16 (half operands, fp32 accumulator, cast on store) on iter
  1, bench measured 1.8× speedup.
- **Stability sweep** (N=5): 4/5 KEPT, mean real speedup 1.80×, 22-min
  wall. Labrat is operationally cheap.
- **Phase 2d.E snapshot/rollback primitives** added to `self_train.rail`
  (harvest_snapshot, harvest_rollback, harvest_ab_gate). Not wired into
  retrain yet.
- **Phase 5.0b Code-JEPA design doc** landed at
  `docs/plans/CODE_JEPA_5_0b.md`.

## What was done this session (2026-04-21 AM, 00:00 → 08:30)

Session continued solo. Phase 4a production pipeline got a lot closer:

- **3 more fp16 kernels ported by labrat**, joining the original matmul:

  | Kernel | Speedup | Task-spec lesson |
  |---|---|---|
  | matmul_blocked        | 1.6× | baseline pattern |
  | matmul_bias_relu      | 1.8× | **fp32-bias hint** (keep bias buffer as float to avoid per-cell half conversion in hot path) |
  | matmul_bias_gelu      | 1.7× | fp32-bias + uniqueness hint |

- **Labrat infra got robust** through four iterations:
  - **prompt v5** — dropped markdown fences around file body (v4's
    closing ``` leaked into FIND text, causing silent no-ops)
  - **ambiguity guard** — reject patches whose FIND matches >1 place
    (Rail's str_replace replaces ALL occurrences; single `}` as FIND
    was corrupting files every iter)
  - **fence-strip** in the patch parser — if the model wraps
    FIND/REPLACE content in ```...```, strip the fences
  - **prompt v6** — explicit uniqueness requirement + safe-choice
    pattern (use last 3–4 lines of a function including closing brace)

- **Unary-op limitation identified** — 1:1 fp16 port of simple
  launch-bound kernels (`tensor_relu`) plateaus at 1.1–1.2×, well below
  the 1.6× gate. Real wins for unary need half4/half8 vectorization —
  different task-spec class. Documented in
  `tools/metal/fp16_drafts/RESULTS.md`.

- **Production transplant (partial)**: 4 fp16 kernels appended to
  `tools/metal/tensor_gpu.metal`. `newLibraryWithSource` validation
  passes. **Not yet callable from Rail** — needs `tgl_*_f16` foreign
  decls + host dispatch + dylib rebuild.

- **21 commits total across both sessions** on `next`. HEAD = `789ac3e`.

---

## Rail-on-Rail in Rail — the actual mission

Everything above is substrate. The goal: **a Rail-native transformer
that writes Rail, compiler-verified.** `bench_railnative` ≥ 5/30 and
one closed flywheel round by 2026-04-27.

Right now we have:
- d=128 × 2-block working at eval mean 2.87 (still learning — d=64
  floor was ~2.99).
- Instrumented training (can trust the eval curve now).
- fp16 infra 50% landed (kernels in source, Rail-side wiring to come).
- Labrat agent ready to port the remaining ~20 kernels overnight once
  task specs are written.
- Leak diagnosed; workaround (≤3000-step runs fit in 10 GB) lets us
  keep moving.

## The five open tasks, scaffolded

### Task #19 — Phase 4a Rail-side wiring (1–2 hours, unblocks fp16 in training)

1. Open `stdlib/tensor.rail`. Find the `foreign tgl_matmul_gelu_f64`
   declaration and its neighbors (lines ~200–221 per
   `MIXED_PRECISION_SCOPE.md`).
2. Add mirrors with `_f16` suffix for each of the 4 transplanted
   kernels:
   ```rail
   foreign tgl_matmul_f16          : half_ptr -> half_ptr -> half_ptr -> int -> int -> int -> int
   foreign tgl_matmul_blocked_f16  : ...
   foreign tgl_matmul_bias_relu_f16: half_ptr -> half_ptr -> float_ptr -> half_ptr -> ...
   foreign tgl_matmul_bias_gelu_f16: ...
   ```
   Rail's native float type is f64 (double). No `half_ptr` type exists
   natively — either (a) pass as `float_arr` and let the dylib cast
   double→half at stage-in, or (b) add a narrow `half_arr` type.
   Simplest for Option A: reuse existing `float_arr` / `double *` on
   the Rail side, do the conversion in the dylib entry point.
3. Open `tools/metal/tensor_gpu_lib.m`. For each existing
   `tgl_*_f64` entry point, write the `_f16` sibling. Copy the
   `@autoreleasepool` structure. Instead of `f64 → float*` staging, do
   `f64 → uint16_t*` (write an `f64_to_half` helper — see the
   `f32_to_f16` one in `tools/metal/probes/fp16_probe.m` for the bit
   ops; adapt for double input).
4. Rebuild `libtensor_gpu.dylib` via whatever make/clang invocation
   currently builds it (look for `tools/metal/*.sh` or a Makefile; if
   absent, check how it was built historically and document).
5. Test: a tiny Rail smoke calling `tgl_matmul_f16` on small fixed
   input; compare to `tgl_matmul_f64` output; expect agreement within
   ~1e-3 max abs diff.
6. `./rail_native test` must still pass.

### Task #14 — Phase 2d.E wiring into retrain (2–3 hours, needs private repo)

Primitives (`harvest_snapshot`, `harvest_rollback`, `harvest_ab_gate`)
are committed in `self_train.rail`. Wiring steps:

1. Sync private repo: `scp -r ledaticempire@mini.tb:~/projects/rail-training/flywheel ./flywheel-local/`
   (or a clone). `flywheel/bench_railnative.rail` is what you need.
2. In `self_train.rail:run_loop`, before calling `retrain`: call
   `harvest_snapshot 0`. Capture the pre-retrain bench by running
   `flywheel/bench_railnative.rail` and parsing its score.
3. After `retrain`: run bench again, parse. Call
   `harvest_ab_gate before after` — it either prints "kept" or rolls
   back.
4. Test with a one-round forced self_train (`--parallel 4 --no-retrain`
   then manually trigger retrain).

### Task #12 — Phase 2b 4-block depth (60–90 min careful edit)

Precondition: have `lm_v3_3block.rail` open as reference — it has
`block2` + `block2_adams` wired; we need to extend to `block3`.

1. Clone `lm_v3_chunked.rail` → `lm_v3_chunked_4block.rail` so the
   2-block config stays as the baseline.
2. In `main`: add `block2 = mk_block d d_ff 300`, `block3 = mk_block
   d d_ff 400`, extend `blocks` list, add corresponding
   `block{2,3}_adams`, extend `adams_blocks`.
3. In `m_forward`: add `cache2 = m_block_fwd x_after_b1 b2_weights
   seq d` and `cache3 = ...`. Extend the return list from 6 → 8
   elements.
4. In `m_train_step`: the backward pass goes in reverse. Currently it
   pops `cache1` then `cache0`; now it must pop `cache3, cache2,
   cache1, cache0` and propagate gradients through each. The pattern
   for one block's backward is already in the file — replicate 2 more
   times. The adam-update block at the end also grows from 2 × 9 = 18
   calls to 4 × 9 = 36 calls.
5. Adopt `adam_lr_mult_gamma = 0.3` for the γ weights per the master
   plan (see `stdlib/optim.rail` docblock for the call-site pattern).
6. Stage 10 → 50 → 500 → 3000 steps.
7. Compare d=128×4block eval mean to d=128×2block's 2.87 baseline.

### Task #9 — Phase 1d.4 leak fix (1 day dedicated compiler work)

Pick **Option A** from `docs/plans/1D4_MEMORY_LEAK.md`: small-block
free list in `compile.rail`.

1. Add a `_rail_small_free_list` per power-of-two size class (e.g.
   16B, 32B, 64B, 128B, ..., 32KB, 64KB).
2. Rewrite `_free` (currently `"_free:\n    ret\n\n"` at
   `compile.rail:2855`) to:
   - read the chunk size from `[x0, -8]` (the 16-byte header written
     by `_rail_chained_malloc`)
   - if size > 64KB: `munmap` directly (darwin svc #73, as the drain
     already does)
   - else: round size up to nearest class, push chunk onto that
     class's free-list head
3. Rewrite `_malloc` (at `compile.rail:2854`) to check the appropriate
   free-list head first, pop if non-empty, fall through to bump alloc
   if empty.
4. Self-compile fixed point (`./rail_native self && cmp rail_native
   /tmp/rail_self`). Iterate 2–3 rounds if needed.
5. Re-run the bisect: `/tmp/t5_bisect_bin` equivalent at 2000 steps.
   Target: peak RSS < 2 GB at 2000 steps (vs current 6.99 GB).
6. Full T5 run at d=64 × 12000 should now peak well below 35 GB.

### Task #23 — Phase 5.0b Code-JEPA (2–3 day first prototype)

Full scope in `docs/plans/CODE_JEPA_5_0b.md`. First milestone:

1. Extract `(source_ids, compile_ok_bool)` pairs from
   `harvest.jsonl` (positives) and `*_repairs.jsonl` (negatives with
   error-class labels).
2. Add a CLS-style pooler token to `lm_v3_chunked.rail`. Train a small
   2-block backbone (reuse the existing machinery) with a binary head
   on top predicting compile-OK.
3. 2000 steps on a small held-out (10%) val set. Target ≥80% accuracy
   as a first-signal gate.
4. Add the isotropic-Gaussian latent regularizer (LeWM trick): a
   single additional loss term encouraging
   `E[z] ≈ 0, Var(z) ≈ I` over the pooled latent. Measure precision
   bump.
5. Gate to proceed: **≥95% precision at ≥80% recall** on val set.
6. If gate passes: shadow-mode deploy alongside
   `oracle_compile_batch`, log predictions vs ground truth for a
   full day.
7. If shadow mode agrees: swap into the inner loop of self_train
   (top-K filter before oracle_compile).

---

## Concrete first hour checklist

```bash
# 0. State check
cd ~/projects/rail
git log --oneline -5                       # expect HEAD = 789ac3e
./rail_native test                         # confirm 136/137 or better
/tmp/labrat_test/validate_metal tools/metal/tensor_gpu.metal  # expect OK

# 1. Pick a task. Suggested priority:
#    (a) Task #19 Rail-side fp16 wiring — unblocks actual training speedup
#    (b) Task #12 4-block depth — unblocks Phase 4b soak + 4c model card
#    (c) Task #14 2d.E bench wiring — unblocks flywheel A/B discipline
```

## What NOT to forget

- Rail quirks from the overnight sessions (added to
  `~/.claude/projects/-Users-user/memory/rail_quirks.md`):
  float `>=` codegen segfaults; nested-match on multi-ctor ADTs breaks
  at depth ≥2; `_free` is a no-op stub.
- Studio has **no `xcrun metal`** — use `/tmp/labrat_test/validate_metal`
  or write a one-off `newLibraryWithSource` harness.
- **Commit via Mini proxy** (Studio has no github push). Pattern is
  in `session_handoff.md` memory file.
- Don't commit `rail_native` from Studio (toolchain-local).
- Multi-chunk eval is the only trustable training-progress signal.
  Single-chunk loss bounces 1.4–4.0 per step and was drowning out
  real improvement in the T5 run.

---

## Full commit log this session block (both halves)

```
789ac3e metal: transplant 4 labrat-produced fp16 kernels into tensor_gpu.metal
d0a4cb8 docs: session handoff — final update with all 4 matmul kernels
85ef7d2 labrat: fence-strip in patch parser + tensor_relu findings
d324f95 labrat: prompt v6 (uniqueness hint) + ambiguity guard + bias_gelu port
ab1f106 fp16_drafts: matmul_bias_relu ported — 1.8x with fp32-bias hint
a7b8bcd docs: session handoff — late-night addendum + full commit log
88b2953 labrat: prompt v5 — drop file delimiters entirely
b79452b fp16_drafts: 2 labrat-produced kernels (matmul, matmul_blocked)
4209d8a labrat: chain runner for sequential kernel ports
6b5afae labrat: stability sweep result — 4/5 KEPT (80%), mean speedup 1.80x
ac40c10 docs: session handoff for 2026-04-21 AM — full cold-start context
e1bd472 docs: 1d.4 leak root cause LOCALIZED — _free is no-op stub at compile.rail:2855
4e8b8e2 labrat: prompt v4 (markdown fences) + no-op patch detection
f74ec2a labrat: first end-to-end win (1.8x fp16) + stability sweep runner
d6f37ea labrat: end-to-end working — prompt v3, float-compare workaround, validator path
9c87d2b labrat: autonomous kernel-optimizer agent scaffold (Phase 5.0)
888cafe test: nested-match parse bug reproducer (depth=2, multi-ctor ADTs)
9cc5838 metal: fp16 vs fp32 matmul probe — Option A decision gate
7403d57 docs: Phase 1d (eval discipline + memory bisect), Phase 2a revision, Phase 2d.E + 5.0/5.0b stretch
```

Rail-on-Rail in Rail. Every item above feeds a model that writes Rail,
verified by the Rail compiler. Don't lose the thread.
