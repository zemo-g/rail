# Phase 1d.4 — Leak-fix result

**Date:** 2026-04-21 AM session (Mini).
**Branch:** `next`.
**Approach:** Option A from `docs/plans/1D4_MEMORY_LEAK.md` — small-block
free list inside `compile.rail`'s emitted runtime.

## What changed

`tools/compile.rail` runtime stubs. Three surgical edits inside `rt_gc_1`:

1. **`_rail_small_fl` in `.data`** — 12 quad slots, one head pointer per
   power-of-two class (32B, 64B, 128B, 256B, 512B, 1024B, 2048B, 4096B,
   8192B, 16384B, 32768B, 65536B).
2. **`_rail_chained_malloc`** — requests ≤64KB now round up to the
   nearest power-of-two class and pop `_rail_small_fl[class_idx]` first.
   On miss: `_malloc(class_bytes)`. On hit: reuse chunk. Large (>64KB)
   requests still use the aligned total, unchanged. `[chunk+8]` always
   stores the actual block size so drain's `munmap` path is unchanged.
3. **`_rail_malloc_chain_drain`** — the `.Lmdrn_small` branch (was
   `bl _free` = no-op) now inlines a free-list push: class-index from
   the power-of-two size at `[chunk+8]`, `chunk[0] = fl[idx]`,
   `fl[idx] = chunk`. Chunks >64KB still `munmap`.

`_free` itself remains a no-op — raw-`_malloc` callers (which pass a
bump pointer with no header) are unchanged.

## Why a free list and not "just munmap everything"

Sub-64KB chunks live *inside* `_malloc`'s shared 4MB bump page. You
cannot `munmap` an individual chunk in that page without corrupting
every other live allocation. The free list is a **process-local
recycling pool**: drain pushes on, next `chained_malloc` pops off. RSS
doesn't shrink, but it stops growing past the working-set size.

## Fixed-point status

- 137/137 tests pass on the new binary.
- Self-compile is byte-identical in 2 passes (gen3 unsigned == gen4
  unsigned). Earlier cmp diffs were codesign artifacts — `codesign
  -s -` embeds an ad-hoc signature and the freshly-compiled
  `/tmp/rail_self` is unsigned, so signed-vs-unsigned cmp always
  disagrees. The real fixed-point test is two unsigned outputs.

## Bisect — before vs after

Same config as the 2026-04-20 bisect: `seq_len=1024`, `d=64`, 2 blocks,
`max_steps=2000`. Script: `/tmp/bisect_1d4.rail` (copy of
`tools/train/lm_v3_chunked.rail` with the two params bumped). Run
under `/usr/bin/time -l`.

| Metric | Baseline (2026-04-20) | Fix (this run) | Reduction |
|---|---:|---:|---:|
| Peak memory footprint | 7,497 MB (6.99 GB)¹ | **4,641 MB (4.64 GB)** | **38.1%** |
| Max RSS               | — | 4,574 MB (4.57 GB) | — |
| Leak rate (MB/step)   | 3.14 MB/step | **2.13 MB/step** | **32.2%** |
| Real time             | — | 1,837 s (30.6 min) | — |
| user / sys            | — | 588 s / 809 s | — |
| Final loss            | ~2.34 | **2.05** | — (training OK) |

¹ Baseline used the 500-step snapshot growth rate extrapolated to step
2000 (319 MB + 2000 × 3.14 MB/step ≈ 6.6 GB) plus the observed T5 peak
of 35.84 GB at 12,000 steps. The 6.99 GB figure is the observed T5
peak at step 2000 per the original 1D4_MEMORY_LEAK.md.

### Sampled trajectory (post-fix)

| Step | RSS live (MB) | Baseline projection (MB) |
|---:|---:|---:|
| ~23 | 438 | ~392 |
| 129 | 596 | ~725 |
| 254 | 810 | ~1,119 |
| 378 | 1,104 | ~1,509 |
| 500 | 1,264 | 1,850 |
| 665 | 1,737 | ~2,414 |
| 879 | 2,158 | ~3,087 |
| 1,000 | 2,416 | 3,480 |
| 1,435 | 3,250 | ~4,840 |
| 1,691 | 3,872 | ~5,645 |
| 1,948 | 4,358 | ~6,457 |
| 1,999 (peak) | 4,641 | ~6,619 |

RSS is **bursty** — within a step, large tensor allocations (attention
scores at seq=1024 are 8 MB, FFN hidden 1.5 MB, etc.) spike and drain;
`ps` snapshots catch varying positions in that cycle. Long-window
averages are the interpretable signal.

## Surprises / gotchas

1. **Codesign breaks naive fixed-point cmp.** `cp /tmp/rail_self
   rail_native && codesign -s - --force rail_native` produces a signed
   rail_native. The next `./rail_native self` writes an unsigned
   `/tmp/rail_self`. cmp disagrees on the signature bytes regardless of
   code determinism. Real test: compare two unsigned outputs.

2. **33% reduction, not >90%.** The fix eliminates the *chained-malloc
   chain* leak (sub-64KB drain→no-op), which accounted for maybe a third
   of the per-step growth. The remainder is a separate source — see
   below.

3. **RSS briefly *decreased* at step 191.** 545 MB, down from 596 MB at
   step 129. That's drain munmap'ing >64KB chunks faster than they were
   being re-allocated in a low-amplitude sampled interval. Real, not a
   measurement error.

## Residual ~2 MB/step — where it's coming from

Candidates in decreasing likelihood:

1. **Direct `_malloc`/`_free` callers.** `_rail_show_float` and
   `_rail_print_float` are the hot ones (called once each per logged
   step via `show_float lr`, `show_float loss`). 32-byte chunks, leaked
   on each call → 64 B × 2000 = 128 KB. Negligible. Non-hot-path
   callers (shell, read_file, float_arr_to/from_f32_file, try, rc_*)
   aren't called per-step.

2. **`_malloc`'s 4MB bump pages**. When a size class is requested whose
   free list is empty, we fall through to `_malloc`, which may mmap a
   new 4MB page if the current one can't fit. After a few warmup steps
   this *should* stabilize, but if per-step allocation variety is wider
   than 12 classes (or the order of requests shifts such that some
   classes rarely fill their free list), new pages can keep arriving.
   Address-space is never returned to the OS because individual chunks
   can't be munmap'd from shared pages.

3. **Large-chunk mmap/munmap churn**. Each step mmap's several
   multi-MB tensors (attention, FFN, embedding grads) and munmap's them
   at arena_reset. macOS mmap metadata or virtual-address
   fragmentation might inflate peak-memory-footprint accounting
   without actual resident memory growth.

4. **GC mark stack allocation**. `_rail_gc` mallocs a 4 MB mark stack
   each invocation and frees it (raw `_free`, no-op). If GC runs often
   in training, that's 4 MB × runs. But training has arena_reset every
   step so the 512MB arena never fills, GC rarely fires. Unlikely
   dominant.

5. **`malloc`'s own heap metadata**. Ruled out — we call the syscall
   `mmap` directly in `_malloc`, not libc malloc.

Next investigation (not this session): add a per-class counter to
`_rail_chained_malloc` that increments on free-list miss. Run 500
steps. If most classes have miss count = 1 (first-time population),
the free list is doing its job. If some classes have high steady-state
misses, those are the ones driving new-page allocation.

## Files touched

- `tools/compile.rail` — three string edits in `rt_gc_1` (data section
  + `_rail_chained_malloc` + `_rail_malloc_chain_drain`).
- `docs/plans/1D4_FIX_RESULT.md` — this document.

No changes to stdlib, training scripts, or tests.

## Commit trail

Three commits on `next`:

1. `compile: small-block free list — add _rail_small_fl data`
2. `compile: _rail_chained_malloc pops from free list for sub-64KB`
3. `compile: drain pushes sub-64KB chunks onto _rail_small_fl instead of _free no-op`

Followed by:

4. `docs: 1d.4 fix result — 33% RSS reduction at 2000 steps`

(Actual commit SHAs filled in at push time.)
