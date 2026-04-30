# Model-focused session — drop-in handoff

**Audience:** the next session that picks up Spur model work.
**Built from:** deep research conducted 2026-04-30 across SESSION_HANDOFF*.md files, model-related memory entries, training scripts, and stdlib float-helper audits.
**Critical premise:** a 17-day-old compiler bug was just fixed. Every CPU-substrate measurement from 2026-04-13 to 2026-04-30 is suspect. **The first action of the next model session must be re-bench, not new training.**

---

## Read this first

For 17 days (2026-04-13 → 2026-04-30), `tools/compile.rail`'s `all_params_int` predicate was returning `true` for tail-recursive functions whose body contained float operations. This enabled `use_regs` (raw int registers x19/x20/x21) for functions that received float parameters. The float bits got reinterpreted as ints by the calling convention, then re-extracted as floats inside the function — producing garbage values.

**Headline affected functions:**

| Function | File:line | Param | Used by |
|---|---|---|---|
| `rms_row_apply` | `stdlib/transformer.rail:174` | `rstd` (float) | RMSNorm forward (CPU + training) |
| `rms_rows_save` | `stdlib/transformer.rail:182` | `eps` (float) | RMSNorm save during training |
| `cpu_ln_accum` | `stdlib/transformer.rail:424` | `mean`, `rstd` | LayerNorm CPU backward |
| `cpu_ln_write` | `stdlib/transformer.rail:436` | `mean`, `rstd` | LayerNorm CPU backward |
| `apply_decay_loop` | `stdlib/optim.rail:114` | `lr_wd` (float) | AdamW weight decay |

**Fixed at:** `tools/compile.rail:1992` (re-added `body_has_float` guard).

**Validation:**
- `sum_floats 100 0.0 = 100` ✓ (was `-3.09837e+52`)
- `sum_floats 5000000 0.0 = 5000000` ✓ (5M iters; the `float_tco_scaling.md` segfault is also resolved by this fix)
- `walk_apply` (rms_row_apply shape) yd[5]=15.0, yd[9]=25.0 ✓

---

## Bug timeline (chronological)

| Date | Event | Impact |
|---|---|---|
| 2026-04-13 | Commit 82516e4 removes `body_has_float` guard | **Bug introduced** |
| 2026-04-21 AM | Spur-0.1 trained (d=256, 2-block, 3000 steps) on GPU dylib | ✅ **GPU forward unaffected** |
| 2026-04-21 PM | Spur-0.1 benched: **25/30 @ N=20 rerank** | ✅ **VALID** (GPU path) |
| 2026-04-22 | HalfTensor S2 trained (also GPU) | ✅ Training metrics fine |
| 2026-04-23 | gen_triples diagnostic corpus shipped | (not affected — corpus tooling) |
| 2026-04-24 | Spur-0.1 CPU re-bench (post-dylib-rebuild) | ❌ 0/30 — both CPU corruption + dylib seq-bug |
| 2026-04-26 | Spur-Fix v0.1/v0.2 trained | Training OK; bench CONFOUNDED |
| 2026-04-27 AM | Spur-Fix v0.3 (full-mask) trained | Training OK; bench CONFOUNDED |
| 2026-04-27 PM | v0.4 queue (5 variants) trained then bench-broken | All scores 0–1/30 (substrate broken) |
| 2026-04-28 | CPU substrate rewritten (`lm_infer_cpu.rail`, KV-narrowing 78× speedup) | Substrate code OK but **calls corrupted RMSNorm** |
| 2026-04-29 | v0.5/v0.6/v0.7 trained, "compile-zero wall" reported | **Wall is suspect** — was reading garbage logits |
| 2026-04-29 | Comprehend N=300 experiment (1500 samples → 0/5) | **Suspect** — same substrate corruption |
| 2026-04-30 | A1.P4 runtime mmap arena + `RAIL_ARENA_MB` shipped | Allocator-side improvements |
| 2026-04-30 | **Float TCO bug FIXED** | Substrate corrected |

---

## What's confounded vs valid

### VALID (do not re-bench)

- **Spur-0.1 25/30 @ N=20 rerank** — Trained AND benched 2026-04-21, before bug was hot AND used GPU dylib end-to-end. Flagship result stands.
- **Architecture/capacity ablations from Phase 5D/E** — Conducted pre-04-13. d=256 × 2-block winning over 4-block × 6000-step is real.
- **Sampling lever (1/30 → 13/30 from argmax → k=10)** — Pre-04-13 measurement.

### CONFOUNDED (must re-bench before drawing conclusions)

| Result | What it claimed | Why suspect |
|---|---|---|
| **Spur-Fix v0.1 negative** | 0/30 fix-loop iter-3 | CPU substrate broken |
| **Spur-Fix v0.2 = 14/30 single** | "Mixed corpus retains structural capability" | Bench used corrupted RMSNorm logits |
| **Spur-Fix v0.3 = 6/30 (FIXED-tail collapse)** | "Full mask over-rotates weights" | Logits were garbage; collapse may not be real |
| **v0.4a-e (cancelled)** | 0–1/30 across all variants | "Bench was broken" was diagnosed but cause unclear; now we know |
| **v0.5/v0.6/v0.7 BEST** | shape 5/5, compile 0/30 | Both shape and compile suspect; logits garbled at RMSNorm |
| **Comprehend ceiling 0/5 over 1500 samples** | "Semantic ceiling, not sampling" | Could be substrate ceiling; need re-test |
| **Compile-zero wall (0/50 across all configs)** | "Architecture isn't the lever" | Could be pure substrate bug; need re-test |
| **AdamW post-04-13 training** | `lr_wd` decay was wrong | Optimizer was applying wrong weight decay; gradient updates off |

### POTENTIALLY confounded (worth checking)

- **fp16 dylib falsified** (per `fp16_dylib_falsified.md`): "fp16 wasn't the lever, surviving hypothesis: rerank-implicit." Tested under broken substrate. May still be true; re-test cheap.
- **UTF-8 corpus finding** (per `utf8_corpus_finding.md`): "byte 0x80 token after `(`". Corpus byte-finding stands (it's mechanical). The "compile rate confounded" caveat is now knowable: re-bench Spur-v0.9-ascii.

---

## Recommended re-bench order

**Priority is high → low. Stop at any point if results contradict expectations sharply — that means something else is also broken.**

### P1 — Sanity (must pass first)

**Re-bench Spur-0.1 with the fixed binary, CPU substrate.**

```bash
./rail_native run flywheel-local/bench_railnative.rail \
    --prefix training/checkpoints_published/d256_half_step3000 \
    --k 10 --temp 0.8
```

- **Expected:** shape ≥ 4/5 across most bands, single-sample compile ≥ 1/30.
- **If 0/30 still:** something else is broken (dylib? new bug?). Halt and investigate before any other re-bench.
- **If matches expected:** you have ground truth. Proceed to P2.

### P2 — Spur-Fix re-eval (the most-impactful question)

The Spur-Fix arc was declared a negative result. Was it actually negative, or were we benching garbage?

**Re-bench v0.2 single-sample (no rerank):**
- Historical claim: 14/30 (from `sampling_was_the_lever.md` and Spur-Fix-v0.1 retro)
- **If post-fix matches 14/30:** the historical number was implicitly rerank or there's no substrate corruption on this checkpoint. Either way useful.
- **If post-fix is much higher (e.g., 18/30+):** Spur-Fix v0.2 was genuinely better than baseline; the "negative" was substrate-induced. Worth investigating v0.3 next.

**Re-bench v0.3 (full-mask, claimed regression to 6/30):**
- If still 6/30: regression is real. FIXED-tail collapse is a real failure mode of full-mask.
- If higher: regression was substrate. Loss masking design needs re-evaluation.

### P3 — v0.7 BEST (current strongest)

Re-bench `spur_v07_d384_best` with fixed CPU substrate.
- Shape rate: should reproduce 5/5 (min-eval-checkpoint lever was a real signal at training time, just measurement was murky).
- Compile rate: most interesting unknown. If 0/50 → "compile-zero wall" is real and substrate-independent. If non-zero → wall was the bug.

### P4 — Compile-zero wall investigation

Conditional on P3 result:
- If P3 still shows 0/50 compile: wall is real, look at corpus quality / training signal / sampling temperature.
- If P3 shows non-zero compile: re-run the N=300 Comprehend experiment to see if Comprehend was substrate-confounded too. The "0/5 across 1500 samples" conclusion was made under the broken substrate.

### P5 — Compile-loss-during-training (v0.8)

Already designed (`docs/plans/COMPILE_LOSS_DESIGN.md`); blocked on non-zero base compile rate from P3/P4. If P3 unblocks, this is the natural next experiment.

---

## GPU dylib state (separate problem, not part of float TCO)

`tools/metal/libtensor_gpu.dylib`:

- **Training:** ✅ works (forward + backward converge under 2026-04-28+ runs)
- **Inference (sequential):** ❌ broken — first token correct, second token onward collapses to `<prompt><1 char><newlines>×~250`
- **Hypothesis (per `dylib_first_token_only.md`):** MTLBuffer pool reuses a freed staging buffer across calls; second call reads stale fp16 values.
- **Falsified hypotheses (do not re-test):** arena interaction, Rail binary regression, inference source regression.

**Recovery path** (if you want to use GPU inference):
1. Rebuild from `tools/metal/tensor_gpu_lib.m` + `tensor_gpu.metal`. Build script in `tools/metal/`.
2. `codesign --sign - --force tools/metal/libtensor_gpu.dylib`.
3. Smoke: `./rail_native run tools/test/{matmul,softmax}_half_smoke.rail` — must pass.
4. Sequential test: 100 forward calls in a tight loop. If still collapses → audit `tgl_matmul_half_host` (or whichever kernel is mis-releasing the staging MTLBuffer). 4–8 hr buffer-pool audit per `arena-leak-fix-strategy.md` notes.

**Not on critical path:** CPU substrate works (78× faster at max=8 with KV-narrowing). The dylib is needed only if training throughput becomes the bottleneck.

---

## Substrate state (from this session's engineering work)

The next model session inherits a richer substrate than the last left:

- **Configurable arena:** `RAIL_ARENA_MB=N` for N MB. Default 1 GB. Set to 4096 for harvest processes.
- **Diagnostic counters in `alloc_stats_snapshot`:** indices 14 (spill_count), 15 (gc_count), 16 (spill_bytes), 12 (munmap_count). Use `arr_get` to compare across a workload to detect leaks in 5 minutes instead of 6 tests.
- **Stderr trace:** `RAIL_ARENA_TRACE=1` emits a line on each spill. Useful for catching first-failure during long runs.
- **envp passthrough:** all env vars now flow through `./rail_native run`-spawned children. Set RAIL_ARENA_* once at the shell prompt, all downstream invocations honor it.
- **Quick smoke:** `./rail_native quick` runs 15 critical tests in ~30 seconds (vs `test`'s 10+ min). Use this between code edits.

---

## Workflow checklist for the model session

```bash
# Verify substrate is sane
./rail_native quick                                          # ~30 sec, must be 15/15

# Re-bench Spur-0.1 (P1)
./rail_native run flywheel-local/bench_railnative.rail \
    --prefix training/checkpoints_published/d256_half_step3000 \
    --k 10 --temp 0.8 2>&1 | tee /tmp/spur01_rebench.log

# If P1 sane, re-bench v0.2 (P2)
./rail_native run flywheel-local/bench_railnative.rail \
    --prefix training/rail_native/checkpoints/spur_fix_v02 \
    --k 10 --temp 0.8 2>&1 | tee /tmp/v02_rebench.log

# If something looks weird, set RAIL_ARENA_TRACE=1 to catch arena pressure
RAIL_ARENA_TRACE=1 RAIL_ARENA_MB=2048 ./rail_native run ... 2>&1 | tail
```

---

## Critical files for the model session

**Read first:**
- This document
- `/Users/user/.claude/projects/-Users-user/memory/float_tco_fixed.md`
- `/Users/user/.claude/projects/-Users-user/memory/spur_model.md`
- `/Users/user/.claude/projects/-Users-user/memory/compile_zero_wall.md`
- `/Users/user/projects/rail/docs/plans/COMPILE_LOSS_DESIGN.md`

**Reference (don't read cover-to-cover):**
- `/Users/user/projects/rail/docs/plans/SESSION_HANDOFF_2026-04-29.md`
- `/Users/user/.claude/projects/-Users-user/memory/min_checkpoint_lever.md`
- `/Users/user/.claude/projects/-Users-user/memory/sampling_was_the_lever.md`
- `/Users/user/projects/rail/docs/SPUR_HANDOFF_2026-04-30.md` (engineering-side companion)

**Current strongest checkpoints on disk:**
- `training/checkpoints_published/d256_half_step3000.tar.gz` — Spur-0.1 (VALID, no re-bench needed unless you want a sanity confirm)
- `training/rail_native/checkpoints/spur_v07_d384_best*` — best CPU-trained (CONFOUNDED, P3 priority)
- `training/rail_native/checkpoints/spur_fix_v02_*` — middle of the Spur-Fix arc (CONFOUNDED, P2 priority)

---

## Open research questions (after re-bench resolves)

These were left in the air by the previous session and may have new shapes after re-bench:

1. **Is the compile-zero wall an architecture limit or a substrate bug?** P3 settles this.
2. **Is Comprehend's 0/5 a semantic ceiling or substrate corruption?** P4 settles this if P3 unblocks compile.
3. **Did fp16 sharpening matter historically?** Per `fp16_dylib_falsified.md`, "no" was the conclusion under broken substrate. Worth a single re-test once dylib is repairable.
4. **Is 247-triple corpus too small, or was the loss masking the problem?** Spur-Fix v0.4 variants (cancelled) were designed to isolate this. P2 re-bench tells you whether to revisit.
5. **Does compile-loss-during-training move the needle?** Designed but blocked on base compile rate from P3.

---

## What the engineering side delivered (full inventory)

For your reference, this 2026-04-30 engineering session shipped:

- `A1.P1` arena spill counter (`alloc_stats_snapshot[14]`)
- `A1.P4` runtime mmap arena + `RAIL_ARENA_MB` env var + envp passthrough
- `A1.P5` `gc_count` (idx 15), `spill_bytes` (idx 16) counters
- `RAIL_ARENA_TRACE` stderr-emit on spill
- `A4` better deep-match parse error
- `A6` **float TCO fix** (the headline)
- `A9` test temp-file collision
- `D5` Garmin Pass 6/7 research note
- New `quick` smoke command (`./rail_native quick`)

**Memory entries that explain decisions:**
- `float_tco_fixed.md` — the fix and what it invalidates
- `rail_arena_runtime_mmap.md` — A1.P4 design
- `rail_arena_drain_works.md` — proves arena_reset is sound
- `rail_arena_2gb_falsified.md` — why we ended up at 1 GB / 4 GB envvar instead of static 2 GB

**Engineering backlog still open** (not blocking model work):
- A3 register ABI guard (defensive)
- A10 source-position carry through AST (DX win)
- A2 `--strict` typecheck flag (DX win)
- D6 pure-Rail Garmin auto-cycler (side project)
- Test runner full parallelization (135 sites to thread `--range A B`; deferred in favor of `quick`)

---

## Final word

The premise of every Spur measurement from 2026-04-13 onward needs to be re-validated. This isn't a small thing — it's potentially 17 days of "we proved X is negative" being wrong because the measurement substrate was corrupting logits before the model's outputs were graded. The Spur-Fix negative arc, the compile-zero wall, the Comprehend ceiling — every one of these conclusions earns a re-test.

The good news: re-bench is mechanical, not architectural. You don't need to retrain. The checkpoints are on disk. The fixed binary exists. P1 takes ~5 minutes; P2/P3 take an hour each.

If P1 passes (Spur-0.1 still ~25/30 with rerank), you have ground truth and can proceed with confidence. If P1 fails, halt and investigate — there's another bug somewhere.

Good luck.
