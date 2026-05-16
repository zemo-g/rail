# A1 — Arena leak fix strategy (corrected from initial backlog)

## Why the original plan was wrong

My initial backlog (option **b**: "track malloc chunks in `arena_reset` and `munmap` them") is **explicitly forbidden** by `tools/compile.rail_seq1499_INVESTIGATION.md` (lines 145–152):

> Don't widen `_rail_alloc` to track malloc'd chunks and free them in `arena_reset` without careful thought. That would reintroduce the double-free class of bugs the arena design was built to avoid.

That section's recommended approaches are: bigger arena, finer per-step sub-marking, or shrinking per-step footprint — **not** promoting malloc chunks to arena-lifecycle.

## What the actual fix should be (in priority order)

### Path 1 — Diagnostic first (no semantics change, safe to ship)

Instrument `_rail_alloc` (compile.rail line 2590) to log when it falls through to `_rail_chained_malloc` (the slow-path malloc fallback). Gate on env var `RAIL_DEBUG_ARENA`. Counter + fprintf(stderr) format `arena_spill: req=%zu after_step=%zu malloc_total=%zu`.

This produces the data needed to know whether (and how often) any given workload spills. No risk, useful for future diagnosis.

### UPDATE 2026-04-30: arena allocator is sound — leak source must be elsewhere

Empirical test: 10 cycles of `arena_mark → arr_new 140M (1.12 GB, spills) → arena_reset` reports `spill=10, munmap=10` exactly. Bytes-for-bytes drain. No accumulation in RSS.

This **falsifies the 2026-04-15 investigation's primary hypothesis** that `arena_reset` orphans malloc-fallback chunks. The `_rail_malloc_chain_drain` mechanism (which now exists; was added between 2026-04-15 and 2026-04-22) handles the spill chunks correctly.

Implication: the historical seq=1499 ~10 MB/step leak observed in lm_xval *must come from a different source*. Candidates per the original investigation's secondary suspects:

1. **`matmul` Tensor wrapper's `gpu_available 0` re-eval** — every call re-allocates `gpu_flag_arr`, generates fresh wrapped strings, runs `str_contains` per-call. With 9 matmuls × 2000 steps, this is real allocation churn that may bypass arena_reset's scope (allocations done before/after the per-step mark).

2. **Allocations outside any `arena_mark`/`arena_reset` scope.** Top-level allocs at training-loop init (e.g., adam_state) live forever; if they accidentally happen inside the per-step loop instead of pre-init, they accumulate.

3. **Direct `_rail_chained_malloc` calls from runtime helpers** (e.g., string ops in tight loops like cat / show) — these go on the chain but if they happen between mark and reset, they're correctly drained; if they happen BEFORE the first mark or AFTER the last reset, they're leaked.

Next-session test: run `seq_crash_full.rail` (the original repro that showed 10 MB/step) with the new `arena_spill_count` counter sampled per step. If spill increases but munmap matches, the arena allocator is innocent. If spill increases without matching munmap, we've found a new bug. Either way, the spill counter pinpoints the source.

### UPDATE 2026-04-30: Path 2 partially landed at 1 GB

After bumping was falsified at 2 GB, I tested 1 GB. **1 GB works.** Both bootstrap cycles reach fixed-point; the resulting binary loads cleanly under dyld; 70M-element `arr_new` (560 MB) that previously spilled now fits in arena; 140M-element `arr_new` (1.12 GB) correctly spills with `arena_spill_count` incrementing. Shipped 2026-04-30.

The macOS dyld ceiling for a static-BSS arena is therefore **between 1 GB and 2 GB**. Going further requires switching to a runtime `vm_allocate`/`mmap`-based arena (which sidesteps dyld's load-time mapping window).

A path forward (A1.P4, deferred to a focused session):
- Remove the static `_rail_heap` BSS allocation
- Add an `__mod_init_func` constructor that `mmap`s the arena at startup, before main
- Initialize `_rail_heap_ptr` and `_rail_heap_end` from the mmap result
- This buys arbitrarily-large arenas (limited only by virtual address space)

Until A1.P4 lands, **1 GB is the cap**. Combined with `alloc_stats_snapshot[14]`, this is sufficient for all observed workloads except seq=1499-class training that pushes ≥1 GB per step.

### Path 2 — Arena size bump (FALSIFIED at 2 GB)

**Tried 2026-04-30, broke the binary.** Bumping `_rail_heap` from 512 MB to 2 GB caused dyld load failure on macOS:

```
dyld[]: dyld cache '(null)' not loaded: syscall to map cache into shared region failed
dyld[]: Library not loaded: /usr/lib/libSystem.B.dylib
```

The 2 GB BSS pushes the binary's virtual layout past the dyld shared-region mapping window. The binary self-compiled cleanly (both bootstrap cycles produced byte-identical output at 940 KB), but the resulting binary failed to load libSystem at startup. Source reverted to 536870912.

**What this rules out:** A naive single-bump 4× headroom mitigation. macOS imposes a hard limit somewhere between 512 MB and 2 GB BSS for the standard binary layout — needs investigation (the actual ceiling, and whether it's per-process or per-image).

**What might still work:**
- 1 GB (1073741824) bump — between 512 MB and the 2 GB ceiling
- `vm_allocate` / `mmap` the arena at runtime instead of a static BSS section, sidestepping the dyld load-time issue
- Use `-headerpad_max_install_names` linker flag or a custom layout
- Or stop relying on a single contiguous arena and use a chunked arena (multiple 256 MB segments)

The 1 GB bump is the next thing to try — should be tested first before any further investment.

### Path 3 — Smaller per-step footprint (training-side, out of compiler scope)

Per the investigation, candidate 5: insert finer-grained `arena_mark` / `arena_reset` pairs around each matmul + softmax in the training loop. Out of compiler scope; this is a `tools/train/lm_*` edit and explicitly model-related work, deferred per the workflow split.

## Why this didn't ship today

Path 1 (diagnostic) is the right standalone deliverable — but adding fprintf+counter to the asm string (~15 lines of careful asm-string editing in `_rail_alloc` plus a global counter symbol) is real surgery. ~2–3 hours of careful work + bootstrap + fixed-point verification + a real repro test before declaring victory. Beyond the time available in this sweep.

Path 2 (size bump) is a one-line edit but bootstrap-coupled. Acceptable to ship as a soft mitigation alongside Path 1, not as a substitute.

## Recommended next session

1. Implement Path 1 (RAIL_DEBUG_ARENA instrumentation), self-compile, fixed-point check.
2. Run `seq_crash_full.rail` with the env var on; capture the spill log.
3. If confirmed: ship Path 2 (arena bump to 1 GB or 2 GB) as immediate mitigation while a real fix is designed (likely candidate 5 — finer-grained sub-marking — implemented as a `with_subarena` macro that wraps single ops).
4. Land both in one commit so the diagnostic instrumentation + mitigation arrive together.

## Status

A1 deferred; corrected strategy documented. Original backlog ranking (D3 / EV high) preserved — work is well-defined, just bigger than I budgeted.
