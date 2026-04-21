# Phase 1d.4 — Memory leak diagnosis

**Date:** 2026-04-20 PM, post-bisect.
**Bisect run:** `/tmp/t5_bisect_bin`, 2000 steps instrumented with 1d.1/1d.2.
**Status:** diagnosis locked in; fix deferred to a dedicated compile.rail investigation.

## Data

Linear RSS growth at **3.1 MB/step** with four snapshot points:

| Step | RSS      | Δ vs prev | Rate        |
|-----:|----------|-----------|-------------|
|    0 | 319 MB   | —         | —           |
|  500 | 1.85 GB  | +1.53 GB  | 3.06 MB/step |
| 1000 | 3.48 GB  | +1.63 GB  | 3.26 MB/step |
| 1500 | 5.05 GB  | +1.57 GB  | 3.14 MB/step |

**Extrapolation:** 319 MB + 12000 × 3.14 MB = **37.9 GB** at step 12000.
T5's observed peak: **35.84 GB**. Match within ~5% — well within noise.

The eval instrumentation (10 forward passes every 100 steps) does NOT
add significant growth on top of what T5 showed — rates match. The
leak is in the training step itself, pre-existing.

Eval curve across the same run (monotone descent, std ~0.2 throughout):

| Step | mean | std  |
|-----:|-----:|-----:|
|    0 | 8.30 | 0.24 |
|  500 | 3.20 | 0.19 |
| 1000 | 3.10 | 0.20 |
| 1500 | ~3.0 | ~0.2 |

Model training correctly; leak does not prevent learning.

## What the shape tells us

**Steady-state linear** — each training step leaks a fixed ~3 MB that
neither `arena_reset` (bump-region reset) nor d24340c's added
`_rail_chained_malloc` munmap path is reclaiming.

If it were a trigger leak (e.g., activated by RNG hitting a specific
value or a counter crossing a threshold) we'd see a piecewise curve.
We don't — every 500-step interval grows by the same amount.

If it were Metal-device memory (mlx/libtensor_gpu.dylib buffer retains),
`ps -o rss=` would NOT capture it — RSS is host-side. So the leak is
host memory.

## Candidates

1. **Intermediate-size blocks** (e.g. 8–64 KB). d24340c's fix only
   munmaps chunks ≥ some threshold. Sub-threshold chunks accumulate
   in the malloc chain — `_free` is the no-op stub per CLAUDE.md
   ("GC is ARM64 assembly... triggered when 512MB arena bump-alloc
   fails"). If a step produces many medium-size intermediate tensors,
   each goes into the chain and never gets freed.

   seq=1024 × d=64 tensors = 65536 floats = 512 KB. Above 64KB
   threshold → should hit munmap path. Unless the threshold is
   higher, or the chunk_size header path is missing for some code
   path.

   seq=1024 × vocab=130 tensors = 133120 floats = ~1 MB. Same
   analysis.

2. **Small-block bump-region fragmentation.** Each step allocates
   small Rail ADT cells (cons, Tensor wrappers, etc.). Bump-region
   `arena_reset` is `ptr := start` — should be O(1) and complete.
   But if the bump region grew via `mmap` extensions that aren't
   unmapped on reset, the mapping persists. Plausible but would
   not produce exactly 3 MB/step — the bump region is pre-allocated
   512 MB and fills more slowly.

3. **Foreign call (tgl_*) return-value buffers.** `transformer.rail`
   calls `tgl_matmul_gelu_f64`, `tgl_layernorm_backward_f64`,
   `tgl_softmax_backward_f64`. Each Metal kernel returns a float_arr.
   If the dylib allocates via `malloc` (not `_rail_chained_malloc`)
   and the Rail side doesn't track it for free — classic C-Rail
   interop leak. `tools/metal/tensor_gpu_lib.m` has the answer.

4. **GC never runs.** CLAUDE.md says GC is "triggered when 512MB
   arena bump-alloc fails." If each step allocates heavy via the
   malloc chain rather than the bump region, the bump region never
   fills → GC never fires → nothing is reclaimed. This would match
   the shape.

**Ranked hypothesis (revised post-investigation):** Candidate 3
**downranked** — `tools/metal/tensor_gpu_lib.m` wraps every `tgl_*_f64`
entry in `@autoreleasepool`, so Metal buffer retains are flushed per
call. Promotion: **Candidate 1** (sub-threshold malloc-chain blocks)
is now top hypothesis. The chunk-header + munmap path landed in d24340c
likely has a size threshold below which blocks stay on the chain.
Each train step at d=64 seq=1024 generates ~10–15 intermediate Tensor
outputs in the 4–8 MB range (matmul, attention, softmax), all of which
SHOULD hit the munmap path. If even one allocation site goes through
a code path that doesn't write the chunk header (e.g. an older
`float_arr_new` call site that wasn't migrated), those blocks leak
linearly. **Compile.rail bisect of `_rail_chained_malloc` call sites
is the next investigation step.**

## Fix paths

**A. Deep fix (2–4 h).** Inspect `tools/metal/tensor_gpu_lib.m`. For
each foreign entry that returns a float_arr: confirm the caller-side
buffer is freed after consumption. If the dylib `malloc`s and hands
back a pointer, the Rail-side wrapper needs to `_free` it (probably
via `_rail_chained_malloc`'s pair primitive).

**B. Workaround (30 min).** Periodic process fork: every 500 steps,
save checkpoint via `stdlib/checkpoint.rail`, kill current process,
exec a fresh one with `--resume`. Shell-level wrapper. Bounded RSS
at ~2 GB but 500-step launch overhead per interval (~startup wall).

**C. Arena-GC force (1–2 h).** Add a Rail builtin `arena_drain 0`
that walks the malloc chain and `munmap`s everything below some
threshold. Call it every N steps. Less invasive than A, more
principled than B.

**Recommended sequence:** A first (diagnose root cause), fall back
to C if A reveals deep dylib issues that aren't fixable from Rail.
B is a bail-out for overnight training if neither ships in time.

## Phase 2a implication

With the leak unfixed, Phase 2a runs at ≤3000 steps consume up to
~10 GB RSS. Studio has 64 GB — still survivable but wasteful (heavy
page-fault rate, sys-CPU at 63% of wall in T5). Landing the fix
first is a real productivity win.

**If the fix isn't tractable this session:** Phase 2a at 3000 steps
is still workable on Studio (10 GB fits). The instrumented multi-
chunk eval remains the critical enabler — that one LANDED, is
validated, and unblocks Phase 2a's meaningful comparison.

## Artifacts

- `/tmp/t5_bisect.log` — full bisect stdout (17 MB, ~2000 steps).
- `/tmp/t5_bisect.meta` — start/end wall.
- `/tmp/t5_rss.txt` — step=X rss_kb=Y per 500 steps.
- `/tmp/t5_eval.txt` — eval@step=X mean=Y std=Z n=10 per 100 steps.
- `/tmp/analyze_bisect.sh` — summarizer, produces this doc's data
  table automatically on re-run.
