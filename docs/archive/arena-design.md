# Rail Arena Memory Model

**Status:** A1.P1 (spill counter), A1.P2.1 (1 GB static arena step), A1.P4 (runtime `mmap` arena + `RAIL_ARENA_MB` env var + envp passthrough) all shipped 2026-04-30.

## The big picture

Rail uses a single contiguous bump-arena as its primary allocation surface, with a free-list + conservative mark-sweep GC for reuse, and a chained-malloc fallback for any allocation that won't fit. This is unusual — most language runtimes use either a single global heap (Python, Ruby) or a generational copying collector with multiple regions (V8, OCaml, Go).

Why bump-arena:

1. **Compiler-as-workload.** Rail's compiler is the canonical Rail program. It does many small allocations during parse → AST → codegen, and at the end of compile_program almost everything goes out of scope at once. Bump-allocation is O(1) per call; "free everything" is O(0) (just reset the pointer). This perfectly matches a compile pipeline's allocation pattern.

2. **Training-loop friendliness.** A training step also allocates many tensors and discards them at step end. `arena_mark` at step start, `arena_reset` at step end = bulk-free in constant time. No GC pause needed if pressure stays under arena size.

3. **No C runtime dependency.** Rail's runtime is ARM64 assembly embedded in the compiler. A bump-arena is implementable in ~10 lines of asm; a generational collector with write barriers is hundreds. Self-hosting purity.

4. **Predictable peak footprint.** Programs allocate up to the arena size and then either spill to malloc (slow path), GC, or fail. There's no progressive resident-set growth as long as the workload respects mark/reset.

Trade-offs:

- Long-running programs that don't use mark/reset accumulate (until GC kicks in).
- A single huge allocation that exceeds the arena spills entirely to libc malloc, which is slower and goes through `_rail_malloc_chain_drain` only on `arena_reset`.
- Concurrent threads can't share the arena cleanly (Rail is single-threaded today; this would need rework if that changes).

## Allocation paths

```
_rail_alloc(size)                               -- compile.rail:2590
  ├─ FAST: bump pointer; if heap_ptr+size ≤ heap_end → return ptr; advance
  ├─ SLOW (.Lalloc_slow):
  │   ├─ free_list_alloc(size) — first-fit on free list (built by GC sweep)
  │   ├─ if hit → return
  │   ├─ _rail_gc — full mark-sweep
  │   ├─ free_list_alloc(size) again
  │   ├─ if hit → return
  │   └─ chained_malloc(size) — libc malloc, prepend to chain
  │       └─ INCREMENTS _rail_arena_spill_count   ← A1.P1
  └─ result returned to caller
```

Direct `_rail_chained_malloc` callers (bypassing _rail_alloc) include `_rail_float_arr_new`, `_rail_args`, `_rail_chars`, `_rail_split`, `_rail_str_split`, `_rail_show*`. These DON'T increment the spill counter — the spill counter is specifically for "bump-arena couldn't satisfy this." Direct chained_malloc calls are intentional, not fallback.

## Lifecycle: mark and reset

```rail
let m = arena_mark 0    -- snapshot heap_ptr + chain head
-- ... allocate freely ...
let _ = arena_reset m   -- restore heap_ptr; drain chain back to mark
```

`arena_reset` (compile.rail:1037):
1. Stores the saved heap_ptr → restores bump pointer
2. Calls `_rail_malloc_chain_drain` → walks chain head→mark, munmaps chunks > 64 KB, returns smaller chunks to size-class freelist
3. Calls `_rail_free_list_clear` → resets the GC's free list (since reset implicitly invalidates it)

**The drain mechanism is byte-for-byte tight.** Empirically verified 2026-04-30: 10 cycles of `arena_mark → 1.12 GB allocation (forces spill) → arena_reset` reports `spill_count=10, munmap_count=10`. No memory accumulates.

The 2026-04-15 seq1499 investigation's worry that `arena_reset` orphans malloc chunks **does not apply to the current code**; the drain was added between Apr 15 and Apr 22.

## Sizing and the macOS dyld ceiling

The arena is currently statically allocated as a BSS section in the binary. macOS `dyld` has a hard limit on static-BSS size somewhere between 1 GB and 2 GB — at 2 GB the binary fails to load (`dyld cache '(null)' not loaded: syscall to map cache into shared region failed`). 1 GB is the documented maximum that loads reliably.

A1.P4 sidesteps this by:
- Removing the static `.zerofill` for `_rail_heap`
- Adding a `_rail_heap_base` runtime pointer (used by `_str_unwrap`, `_rail_wrap_str`, GC mark, etc. for "is this in the heap?" checks)
- Initializing `_rail_heap_base`, `_rail_heap_ptr`, `_rail_heap_end` at runtime via `mmap(MAP_ANON|MAP_PRIVATE)`
- Reading `RAIL_ARENA_MB` env var via `_getenv` + `_atoi` to pick the size (default 1024 = 1 GB)
- Wiring the init via `.section __DATA,__mod_init_func,mod_init_funcs` (modernized to `__init_offsets` by Apple's linker, runs before main)
- Saving `envp` (x2 at main entry) into `_rail_envp` global; `_rail_shell`'s execve passes it instead of NULL so child processes inherit env vars

After A1.P4, programs can opt into larger arenas with no recompilation, and the env var propagates correctly through `./rail_native run prog.rail`:

```bash
RAIL_ARENA_MB=4096 ./my_rail_program       # 4 GB arena
RAIL_ARENA_MB=512  ./my_rail_program       # 512 MB arena (smaller)
./my_rail_program                          # 1 GB default
```

The upper limit becomes virtual address space (≈ 47 bits = 128 TB on aarch64 macOS), which in practice means "however much physical RAM + swap you have."

## Diagnostics

`alloc_stats_snapshot 0` returns a 17-element int array (post-A1.P5):

| User idx | Symbol | What it counts |
|---|---|---|
| 0..11 | `_rail_small_fl_miss[0..11]` | Per-size-class free-list misses (size class i = 2^(i+5) bytes) |
| 12 | `_rail_munmap_count` | `_rail_malloc_chain_drain` munmap calls (chunks > 64 KB freed) |
| 13 | `_rail_mmap_large_count` | Direct `_malloc` mmap calls for chunks > 64 KB |
| 14 | `_rail_arena_spill_count` | **Bump-arena overflow events** — bump failed AND free-list+GC didn't satisfy |
| 15 | `_rail_gc_count` | `_rail_gc` invocations |
| 16 | `_rail_arena_spill_bytes` | Cumulative bytes spilled to chained_malloc |

Plus an env-var-gated stderr trace: setting `RAIL_ARENA_TRACE=1` (any non-empty value) prints `rail_arena_spill\n` to stderr on every spill event. Useful for catching the first spill and correlating it with workload state.

Recommended diagnostic pattern for any long-running workload suspected of leaking:

```rail
let s0 = alloc_stats_snapshot 0
-- ... workload ...
let s1 = alloc_stats_snapshot 0
let _ = print (cat ["spill=", show (arr_get s1 14 - arr_get s0 14),
                   " munmap=", show (arr_get s1 12 - arr_get s0 12)])
```

If `spill_delta == munmap_delta`, the allocator is innocent (every spill chunk was drained on reset). If `spill_delta > munmap_delta`, something allocated outside an `arena_reset` scope — find that allocation.

## Known leak vectors (per the 2026-04-15 investigation, post-falsification)

The arena allocator itself doesn't leak. Real leak sources to look at if a long-running program shows resident growth:

1. **`gpu_available 0` re-eval.** `gpu_flag_arr` is a top-level nullary binding; per Rail's nullary re-eval rule, it gets re-allocated on every reference. In a tight matmul loop, this is real allocation churn.

2. **Allocations outside `arena_mark` scope.** If a per-step allocation accidentally happens before the step's first `arena_mark`, it's never reclaimed.

3. **Tensor wrapper bookkeeping.** `matmul`'s wrapper does `gpu_available 0` checks, ADT cons, and runs `str_contains` per call. Even with mark/reset, if the wrapper allocates outside the marked scope, it leaks.

4. **String append in tight loops.** `_rail_str_append` calls `_rail_chained_malloc`. If you're concatenating strings inside a loop with no surrounding `arena_mark`, every append leaks.

The fix for any of these is workload-side, not allocator-side.

## Future work

- **A1.P4** (in flight): runtime mmap arena, RAIL_ARENA_MB env var
- **Generational collector**: `_rail_young_a` and `_rail_young_b` (64 MB semi-spaces) are allocated and zeroed but the Cheney scavenge isn't wired up. Once enabled, would reduce GC cost for the common case of "most allocations die young."
- **Per-thread arena**: required if Rail ever ships preemptive concurrency. Single-arena assumption is baked into the codegen (heap_ptr is global).
- **Arena diagnostics in debug mode**: a `RAIL_ARENA_TRACE=1` env var that emits a stderr line on every spill, including allocation size + (if available) calling function name. Useful for pinpointing leak sources without sampling counters.
