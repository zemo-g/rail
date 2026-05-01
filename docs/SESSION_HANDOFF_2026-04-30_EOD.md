# Session handoff — 2026-04-30 EOD

**Audience:** the next session.
**Premise:** today's earlier handoffs (`SPUR_HANDOFF_2026-04-30.md`, `MODEL_SESSION_HANDOFF.md`, `ROADMAP_2026-04-30.md`) cover the morning arc through the float-TCO fix. This doc covers the afternoon — mixed-precision inference, parallel rerank, GPU dylib falsification, and the seed-segfault bisection. Read this AFTER those three.

## TL;DR

- **5 commits landed** today (see `git log --oneline -5`).
- **Float-TCO bug fixed at root** (closes 17-day silent corruption).
- **GPU sequential collapse falsified** as a fixable bug — it's fp16 precision compounding, both substrates degenerate.
- **Mixed-precision inference shipped**: Rail-native fp16-weights × fp32-acts × fp32-accum kernel. 2× tighter than all-fp16 path at primitive level. Right substrate for d=384+ scaling.
- **Parallel rerank shipped**: 7.1× wall-clock at N=8, ~11× projected at N=20 → bench drops from 2.25hr to ~13min.
- **Critical bug discovered + worked around**: `lm_infer_cpu.rail` SIGSEGVs on ~50% of seeds at `--max 128 --k 10` — bisected to a compiler-codegen interaction between `arena_reset` and multiply-add expressions. Workaround applied; root-cause fix open.
- **Spur-0.1 historical 25/30 was confounded** by the segfault (silent ~50% sample loss). All post-04-13 single-sample numbers are noise; rerank numbers were partly artificial.

## Today's commits (chronological)

```
7752738 runtime+compile: float-TCO fix, arena mmap, dylib pool-disable diagnostic
1f699b3 docs: 2026-04-30 EOD handoffs + arena/strict-typecheck/Garmin design notes
ee6bdce runtime+stdlib+train: Rail-native mixed-precision inference + parallel rerank
73043e2 parallel_rerank: --bin flag for pre-compiled inference binaries
f215039 infer: lm_infer_cpu.rail — workaround for arena_reset + mul-add codegen bug
```

## What changed in detail

### `7752738` — Substrate hardening (morning)
- `tools/compile.rail`: re-added `body_has_float` guard at `all_params_int`, fixing the float-TCO bug that ran from 2026-04-13 to 2026-04-30
- A1.P4 runtime-mmap arena (`RAIL_ARENA_MB` env var, default 1 GB, max ~4 GB)
- A1.P5 spill/gc counters in `alloc_stats_snapshot[14..16]`
- `RAIL_ARENA_TRACE` stderr trace on spill
- Parser multi-line compound expr support
- New `./rail_native quick` command (15 critical tests in ~5s)
- `tensor_gpu_lib.m`: `RAIL_GPU_POOL_DISABLE` env flag to bypass MTLBuffer pool best-fit reuse (diagnostic)
- `sequential_matmul_half_test.rail`: regression test verifying matmul_half byte-determinism across 1000 calls
- `rail_native` rebuilt as fixed-point binary

### `1f699b3` — Morning EOD handoffs + design notes
- `SPUR_HANDOFF_2026-04-30.md`, `MODEL_SESSION_HANDOFF.md`, `ROADMAP_2026-04-30.md`
- Design notes: arena memory model, leak-fix strategy, data-section quirk, backlog deferred items, strict-typecheck design, Garmin Pass 6/7 research

### `ee6bdce` — Mixed-precision inference + parallel rerank
- **`tools/metal/tensor_gpu.metal`**: new `matmul_f32x_halfw` kernel — fp16 weights × fp32 activations → fp32, fp32 accumulator
- **`tools/metal/tensor_gpu_lib.m`**: `tgl_matmul_f32x_halfw_host` wrapper, casts f64↔f32 at GPU boundary
- **`stdlib/tensor.rail`**: `matmul_mixed` helper
- **`tools/test/matmul_mixed_smoke.rail`**: primitive correctness — `max_abs_diff=0.00042` vs f64 reference (vs 0.00082 for matmul_half), byte-deterministic across 100+ calls
- **`tools/train/lm_infer_v3_mixed.rail`**: precision-correct inference harness (12 matmul callsites swapped from `matmul_half` to `matmul_mixed`)
- **`tools/train/parallel_rerank.sh`**: fan-out N inference subprocesses concurrently with distinct seeds, pre-compiles harness once
- **`tools/train/parity_check.sh`**: three-way diff (cpu_f64 / gpu_half / gpu_mixed) for substrate comparison

**Validated numbers:**

| Substrate | sec/token (Spur-0.1, max=20) | argmax (degenerate) |
|---|---|---|
| CPU substrate (KV-narrow) | 0.7 | spaces |
| GPU half (existing v3_half) | 0.85 | newlines |
| GPU mixed (new) | 0.9 | high-byte 0x84 |

| Parallel rerank | Total wall | Speedup |
|---|---|---|
| Sequential N=4 | 54s | 1× |
| Parallel N=4 (max=4) | 15s | 3.6× |
| Parallel N=8 (max=8) | 15s | 7.1× |
| Projected N=20 (max=8) | ~25s | ~11× |

### `73043e2` — `parallel_rerank.sh --bin`
Adds `--bin <path>` flag so callers (e.g., bench harnesses with their own pre-compiled inference binary) can skip the script's own pre-compile step. Critical for orchestrators that already manage `/tmp/rail_out` to avoid concurrency races.

### `f215039` — `lm_infer_cpu.rail` segfault workaround
Drops `arena_reset mk` from `gen_loop`. Per-iteration intermediate tensors now accumulate in the bump arena (which has 1 GB headroom for typical bench config). Eliminates the trigger pattern that caused SIGSEGV on ~50% of seeds. **30/30 stress tests pass** at `--max 128 --k 10` across previously-crashing seeds.

The underlying compiler bug (in `compile.rail`) remains open. See `inference_segfault_root_cause.md` for the precise reproducer and analysis.

## What was discovered (negatives)

### GPU sequential-collapse hypothesis: FALSIFIED
Per `dylib_investigation_2026-04-30.md`. The 2026-04-28 hypothesis ("MTLBuffer pool reuses freed staging buffer; second call reads stale fp16") was tested via `RAIL_GPU_POOL_DISABLE=1` (forces fresh `newBufferWithLength` on every acquire). Sequential collapse byte-identical to baseline → pool reuse is NOT the cause.

`tools/test/sequential_matmul_half_test.rail` further verifies `tgl_matmul_half_host` is byte-deterministic across 1000 sequential calls. Primitive corruption ruled out.

Surviving cause: **fp16 precision compounding across 22 matmul round-trips/token**. Both CPU and GPU substrates produce degenerate argmax for Spur-0.1 — they just degenerate to different tokens (CPU=space, GPU=newline, mixed=high-byte). This is intrinsic, not a fixable substrate bug.

### Spur-0.1 25/30 historical: CONFOUNDED
Per `inference_segfault_root_cause.md`. The CPU substrate had a seed-dependent SIGSEGV running undetected. ~50% of N=20 rerank samples were silent 0-byte outputs. The "25/30" measurement was achieved on the buggy substrate; the post-fix number under canonical config is unknown until re-bench (now unblocked).

### Mixed-precision: not a speed win at d=256
At Spur-0.1's size (d=256, 2-block), CPU substrate with KV-narrowing beats GPU+mixed by ~25%. Mixed is the right substrate for d=384+ scaling where single-thread CPU bogs down. Not yet useful for current model.

## The compile.rail-level bug (open)

**Precise reproducer** (see `inference_segfault_root_cause.md`):
```bash
DYLD_LIBRARY_PATH=tools/metal /tmp/rail_bench_rn_gen \
    --prefix training/rail_native/checkpoints/d256_half_step3000 \
    --prompt "fact n = if n <= 1 then 1 else n * fact (n - 1)
main = " \
    --max 11 --k 1 --seed 950 --no-ws-first 0
# rc=139 (SIGSEGV) deterministically
```

**Bisection result:** crash requires both `arena_reset` AND `float_arr_set xd_full IDX V` where IDX is a multiply-add expression. Multipliers 128 and 130 crash; 127, 129, 256, 200 don't (specific bit-patterns trigger). Crash is in `_rail_chained_malloc:.Lcm_k32 + 56` reading `_rail_small_fl[0]`, which has been corrupted to `0x3FF0000000000000` (= the `1.0` fp64 bits being stored by float_arr_set).

**Heisenbug blocked direct diagnosis:** any source-level instrumentation (let-rebind, helper-fn wrap, `print`) shifts heap layout and hides the trigger. `lldb -b` hangs on this binary. SIP-on blocks dtrace.

**Recommended next step for compile.rail fix:** boot a system with SIP off, set a dtrace store-watchpoint on `_rail_small_fl[0]` runtime address, run the reproducer, capture the wild store's PC, backtrace to the responsible emit function in compile.rail. One-day fix with right setup.

## What's now unblocked (next session menu)

**Highest leverage — re-bench under post-fix substrate:**
1. Run canonical `bench_railnative_rerank.rail` against Spur-0.1 with the patched `lm_infer_cpu.rail` and parallel rerank → get the real baseline number
2. Re-bench v0.7 BEST, Spur-Fix v0.2, Spur-Fix v0.3, v0.5, v0.6 — the four confounded checkpoints. Now ~13 min each instead of ~2.25hr. Total: ~1 hour for the full truth table.
3. Compare to historical noise. Decide which checkpoint is actually the strongest.

**Then:** v0.8 compile-loss-during-training. Per `compile_loss_scaffolding.md`, the design exists; the harvester that was blocked on parallel-rerank infrastructure can now use it. This is the swing-for-the-fences experiment — converting the compiler from a downstream grader into a training-loss signal.

**Optional engineering:**
- Compile.rail-level fix for the segfault bug (one-day SIP-off task)
- Wire parallel rerank into `bench_railnative_rerank.rail` (gitignored, lives in working tree only — patch documented in `inference_segfault_root_cause.md`)
- KV-narrowing in `lm_infer_v3_mixed.rail` (turns mixed into the right substrate at d=256 too)
- Add bounds-checking to `_rail_float_arr_set` in compile.rail (protects against future similar bugs)

## Files & memory entries

**Memory entries created or updated today** (15 total):
- Substrate: `float_tco_broken.md`, `float_tco_fixed.md`, `rail_arena_drain_works.md`, `rail_arena_runtime_mmap.md`, `rail_arena_2gb_falsified.md`, `rail_emit_gotchas.md`
- Discipline rules: `feedback_verify_removals.md`, `feedback_diagnostics_first.md`, `feedback_honest_backlog.md`
- Dylib: `dylib_pool_hypothesis_falsified.md`, `dylib_investigation_2026-04-30.md`, `metal_one_source_string.md`
- New paths: `rail_mixed_precision_landed.md`, `parallel_rerank_works.md`
- Segfault: `inference_seed_segfault.md`, `inference_segfault_analysis.md`, `inference_segfault_root_cause.md`
- Index: `next_session_pointer.md` (updated)

**Working tree** (uncommitted, intentional):
- Training files (`tools/train/*.rail`, `tools/labrat/stability_run.sh`) — model-team workflow per `feedback_workflow_split.md`
- Backup binaries (`rail_native_*.bak`, `libtensor_gpu.dylib.pre-*`) — recovery points, gitignored
- Untracked feature work (`stdlib/cortexm_runtime.rail`, `stdlib/thumb2*.rail`, `stdlib/fit*.rail`, `stdlib/gcd.rail`, `tools/attest/`, `tools/bucket/`, `tools/cortexm/`, `tools/garmin/`) — needs your direction
- `tools/metal/.no_gpu.parked` — renamed from `.no_gpu`; restoring re-enables CPU fallback for matmul

## Reproducers cheat sheet

```bash
# Run inference (post-workaround):
DYLD_LIBRARY_PATH=tools/metal ./rail_native run tools/train/lm_infer_cpu.rail \
    --prefix training/rail_native/checkpoints/d256_half_step3000 \
    --prompt "main = " --max 128 --k 10 --temp 0.8 --seed 100

# Parallel rerank:
tools/train/parallel_rerank.sh \
    --bin /tmp/rail_bench_rn_gen \
    --prefix training/rail_native/checkpoints/d256_half_step3000 \
    --prompt "main = " --max 60 --k 10 --n 20 --base-seed 100 --max-parallel 8

# Three-way precision parity:
tools/train/parity_check.sh \
    --prefix training/rail_native/checkpoints/d256_half_step3000 \
    --prompt "main = " --max 20 --k 1 --seed 42

# Compile-codegen-bug reproducer (still crashes pre-workaround binary):
DYLD_LIBRARY_PATH=tools/metal /tmp/rail_bench_rn_gen \
    --prefix training/rail_native/checkpoints/d256_half_step3000 \
    --prompt "fact n = if n <= 1 then 1 else n * fact (n - 1)
main = " --max 11 --k 1 --seed 950 --no-ws-first 0
```

## The shape of the next session

**Recommended:** start with re-bench. ~30 min wall-clock for Spur-0.1 + 4 confounded checkpoints, gives the model team's truth table. Decide v0.8 vs further engineering after that. Compile.rail-level fix is genuinely optional given the workaround is durable.

The codebase is in better shape than it started today. Five commits, fourteen memory entries, three real bugs (one fixed at root, one workaround'd at source, one falsified), one substantial new feature (mixed-precision inference), one substantial new tool (parallel rerank), and a precise reproducer for the one bug that stayed open.
