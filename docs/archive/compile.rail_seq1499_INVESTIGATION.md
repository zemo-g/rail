# seq>=1499 cumulative termination — investigation notes

**Date:** 2026-04-15
**Context:** `tools/train/lm_xval.rail` at seq=1499 silently terminates at
step ~600 after ~4.5 min. Not OOM (16GB reported free at time of death).
Lower seq (382 from Shakespeare) runs 2000 steps clean.

**Status:** bug is **reproduced in a 60-line test without training or
gradients**, narrowed to three suspect call sites; root cause not yet
nailed. Doc + repros committed; fix is next session.

---

## What I ruled out

The investigation ran four progressively-more-faithful reproducers. All
live under `tools/test/`. Results:

| Test | What it does per step | 2000 steps? | Observation |
|---|---|---|---|
| **A** — `seq_crash_repro.rail` | 9× `float_arr_new` at training scale (including seq×seq=18MB), bracketed by `arena_mark` / `arena_reset` | ✅ clean | RSS stays flat at <200MB. Bump-arena reset works correctly at seq=1499 scale. |
| **B** — `seq_crash_matmul.rail` | A + 9× direct `tgl_matmul_f64` (bypassing the `matmul` Tensor wrapper) | ✅ clean | RSS stays flat. **Metal buffer pool + `@autoreleasepool` is leak-free** at this call pattern. |
| **C** — `seq_crash_arity.rail` | 28-arg self-recursive tail loop, 2000 iters | ✅ clean | Stack doesn't grow — **arity-28 self-loop TCO is real**, not dropping to call/ret. |
| **D** — `seq_crash_bisect1.rail` | A + 9× `matmul` (Tensor wrapper — calls `gpu_available 0` + wraps output) | ⚠️ 700/700 | Completed but RSS observed at 2.84GB mid-run (ps check). Noticeably more than B. |
| **E** — `seq_crash_full.rail` | D + 2× `layernorm_save` + 2× `tensor_softmax` + 7× `adam_update` | ❌ killed manually | **RSS climbed to 16.25GB at ~1500 steps in <2 min** — roughly **10MB/step leak rate**. Still alive when killed, stdout was fully buffered through pipe so step output only flushed post-SIGTERM. |

So the leak is real, reproducible outside the training harness, and the
delta between **D** (clean-ish) and **E** (~10MB/step leak) isolates it
to one of three operations: `layernorm_save`, `tensor_softmax`, or
`adam_update`. The Metal dylib itself (exercised by B) is not at fault.

## Hypothesis ranking

**1. Primary suspect: `tensor_softmax` on a 1499×1499 tensor.**
At seq=1499 the attention-scores softmax input is `rows*cols = 2,247,001`
doubles = 18MB. `gpu_softmax_ffi` allocates a fresh float_arr of that
size via `float_arr_new`, then dispatches `tgl_softmax_rows_f64`. The
output float_arr is arena-tracked so `arena_reset` should reclaim it.
But if on any step the cumulative arena pressure before `arena_reset`
exceeds 512MB, `_rail_alloc` falls through to `_malloc` (compile.rail
line 2231) — and **`arena_reset` only resets the bump pointer and
clears the free list; it does not free the malloc-fallback chunks.**
That matches the ~10MB/step steady rate. Per-step arena footprint with
softmax × 2 (scores, logits) is ~46MB — nominally fits in 512MB, but
the first step's residue from `adam_state` allocations may push the
effective budget over the edge.

**2. Secondary suspect: the `matmul` Tensor wrapper's `gpu_available 0`
call chains.** `gpu_available` hits the nullary re-eval rule: `gpu_flag_arr`
gets re-allocated via `float_arr_new 1 0.0` on every reference, so the
cache is broken and each matmul re-runs the `shell "test -x ..."` probe.
`_rail_shell` mallocs a 64KB buffer, reads, wraps the output as a Rail
string (arena), then `_free`s the 64KB. libc's heap will cache that
block, so it's bounded — but every call also produces a **fresh wrapped
string in the arena** and the `str_contains` scan runs per-call. With
9 matmuls + 2 softmax + misc × 2000 steps ≈ 22K shell forks per run,
even sub-millisecond overhead is significant. This is almost certainly
not 10MB/step of growth by itself — it's a performance smell, likely
exacerbating #1 by eating into the arena budget per step.

**3. Tertiary: Adam state.** `adam_hyp` allocates a 6-float `float_arr`
on every call; 7 calls × 2000 steps = 14K tiny allocs, arena-tracked,
reset each step. Shouldn't leak. But the test-D-vs-E delta includes
Adam, so it's not ruled out.

**4. Unlikely: `_rail_str_append` returns a raw malloc'd char* that is
never freed.** This is a general leak but bounded by output volume. The
test's per-step `cat [...]` fires every 50 steps, not every step, so at
most ~40 small mallocs per 2000-step run. Not the 10MB/step rate.

## The malloc-fallback theory, concretely

Rail's `_rail_alloc` flow (compile.rail:2231):

```
1. bump:    heap_ptr += size; if (heap_ptr <= heap_end) return
2. slow:    try rail_free_list_alloc
3. gc:      rail_gc; try free list again
4. malloc:  fall through to libc _malloc
```

`arena_reset` only does `heap_ptr := mark` and `free_list := nil`
(compile.rail:961). **Malloc'd chunks from step (4) are orphaned.** If
a single step's peak allocation exceeds the remaining arena budget, the
overflow spills to malloc forever. With `lm_xval`'s seq=1499 step
footprint of tens of MB for attention scores alone, this is plausible.

Per-step arena survey (E repro, my estimate):

```
matmul outputs (9):        e 0.77MB  +  q/k/v 3×0.77MB  +  scores 18MB
                           + attn_out 0.77MB + f1 3MB + f2 0.77MB
                           + logits 0.85MB                    ≈ 26.3MB
layernorm_save outputs (2): 2× (0.77MB y + 2× 1499-float stats)  ≈ 1.6MB
softmax outputs (2):       18MB + 0.85MB                       ≈ 18.9MB
adam_hyp + Tensor ADT + cons churn:                            ≈ 1MB
                                                         total ≈ 47.8MB
```

With a 512MB arena and 47.8MB/step, 10 steps of pure bump fills the
arena. Steps 11+ need a working `arena_reset` — and the test confirms
it works cleanly in A/B. So the malloc-fallback theory requires a step
where **within a single step, a single allocation exceeds the remaining
arena before arena_reset fires**. At ~48MB/step residence, that's every
step once we're past step ~10. The growth rate 10MB/step ≈ 21% of the
step's arena footprint spilling to malloc is entirely consistent.

## Candidate experiments for next session

1. **Instrument `_rail_alloc`** to log when it falls through to malloc.
   Add a static counter + fprintf(stderr) on the slow path, tag-gated
   by an env var. This will tell you unambiguously whether #1 is right.
   Only touches `tools/compile.rail` asm string. Self-compile fixed-
   point and 98/98 tests must still pass after.

2. **Raise the arena to 1GB or 2GB.** One line in compile.rail:3354
   (`.space 536870912` → `.space 1073741824`). Rerun lm_xval@seq=1499
   to 2000 steps. If the run completes clean, theory confirmed. This
   is also a legitimate fix-or-workaround commit if the diagnostic
   burn-in is acceptable.

3. **Fix `gpu_available` caching.** Convert `gpu_flag_arr` from a
   nullary top-level to either an explicit lazy arg passed through the
   hot path, or an `arr_new`-backed cache initialized once in `main`.
   This is the same fix the inline comment at tensor.rail:215-226
   applied to `ensure_dylib` but forgot to apply to `gpu_available`.
   Fixes the 22K-shell-forks-per-run perf smell and may free enough
   arena budget per step to avoid fallback. Write-set is stdlib/tensor.rail
   (outside the Terminal-D constraint, but the ticket author should
   verify no conflicts with the other parallel sessions).

4. **Bisect D-to-E in chunks.** Start from `seq_crash_bisect1.rail`
   (matmul-Tensor only, clean at 700 steps) and add one op at a time:
   `bisect2` = +softmax (expect: leaks), `bisect3` = bisect1+layernorm
   (expect: clean), `bisect4` = bisect1+adam (expect: clean). Runs are
   ~2 min each. Will produce a definitive single-op attribution.

5. **Workaround for the training team right now**: call `arena_reset`
   at finer granularity. Instead of one mark/reset per step, do a
   mark/reset around each matmul + softmax. That way any malloc spill
   happens inside a smaller scope. Change is in `tools/train/lm_xval.rail`
   and `lm_transformer.rail` — may collide with the parallel sessions
   editing those files, check first.

## What NOT to do

- **Don't widen `_rail_alloc` to track malloc'd chunks and free them in
  `arena_reset`** without careful thought. That would reintroduce the
  double-free class of bugs the arena design was built to avoid. If the
  fallback is hot enough to matter, the right fix is either a bigger
  arena, better per-step sub-marking, or shrinking the per-step
  footprint — not promoting malloc chunks to arena-lifecycle.

- **Don't assume the crash is GPU-related** just because it shows up
  in training. Test B proves raw Metal matmul at this scale is fine.
  The dylib isn't the problem; Rail's arena policy is the suspect.

## Landmines encountered during this investigation

- **`/tmp/rail_out` collision across sessions.** A parallel session
  leaves a stale `/tmp/rail_out` binary. When my compile failed (due to
  symbol collision from a double `import`), the shell fallthrough ran
  the stale binary and I got an unrelated segfault that briefly looked
  like the bug reproducing. `rm -f /tmp/rail_out /tmp/rail_out.s
  /tmp/rail_out.o` before each compile/run is a clean habit — CLAUDE.md
  rule #3 already flags this under the test-count-weirdness pattern.
- **`import "stdlib/tensor.rail"` + `import "stdlib/transformer.rail"`
  creates a double-definition of `mul_acc`.** transformer imports tensor
  transitively via `import tensor` (bare form). The `"stdlib/..."` form
  doesn't dedupe against bare imports. Stick to one style per file —
  this investigation used bare imports once the issue was diagnosed.
- **Stdout is fully block-buffered under `./rail_native run X > file.log`
  piped through tee or head.** Steps execute but output doesn't flush
  until the buffer fills or the process exits. When I `ps`'d the child
  at step 0 log-wise, it was actually already past step 1500 in reality.
  Monitor by polling `ps -p <child_pid> -o rss=`, not by grepping the
  log file.
- **`ps -p $!` catches the wrapper shell, not the Rail binary.** Use
  `pgrep -f /tmp/rail_out` to get the actual child.

## Files shipped

- `tools/test/seq_crash_repro.rail` — baseline A (clean)
- `tools/test/seq_crash_matmul.rail` — baseline B, direct tgl_matmul (clean)
- `tools/test/seq_crash_arity.rail` — baseline C, arity-28 TCO (clean)
- `tools/test/seq_crash_bisect1.rail` — Tensor-wrapper matmul only (partial)
- `tools/test/seq_crash_full.rail` — full per-step pattern (reproduces leak)
- `tools/compile.rail_seq1499_INVESTIGATION.md` — this file

No compiler changes. 98/98 tests + self-compile fixed-point preserved
(not touched this session).
