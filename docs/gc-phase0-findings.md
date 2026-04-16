# GC Phase 0 — Diagnostic Findings

**Status:** complete, 2026-04-15
**Deliverable of:** main precise-GC plan, Phase 0
**Tool:** `tools/debug/gc_probe.rail` + narrow microbenchmarks in `/tmp/n*.rail`

## TL;DR — the plan needs to pivot

The main precise-GC plan was built on the hypothesis that tight loops
allocating transient BSTs (like `bpe_count_pairs`) exhaust the 512MB
bump arena because the conservative GC over-marks stale stack roots
and fails to reclaim.

**This hypothesis is wrong.** The arena never fills. Peak RSS at the
crash point is ~7MB. A precise-stack-map GC would not have helped; the
real crash source is elsewhere.

Precise-GC is still the long-term right thing for a serious language
runtime, but it is no longer the correct fix for the specific BPE
segfault that motivated it.

## Reproducer

```rail
import "stdlib/map.rail"
build_big_bst n m = if n <= 0 then m else build_big_bst (n - 1) (map_put m n n)
loop n = if n == 0 then 0 else
  let m = build_big_bst 500 (map_new 0) in loop (n - 1)
main = let _ = loop 80 in 0
```

No `arena_mark`/`arena_reset`. Segfaults. Binary-searched the crash
boundary between N=60 (passes) and N=80 (crashes).

## What we measured

| Case | Result | Peak RSS |
|---|---|---|
| N=60 iters, no arena_mark | OK | 6.73 MB |
| N=80 iters, no arena_mark | **Segfault** | 6.75 MB |
| N=500 iters, WITH arena_mark/reset | OK | ~7 MB |
| N=80 iters under `lldb` | **OK** | N/A |

Key data points:
- **Peak RSS at crash is 7MB.** Arena size is 512MB. Not close to full.
- **Crash disappears under `lldb`.** Environment-sensitive.
- **`ulimit -s unlimited` doesn't help.** Not a user-space stack cap.
- **`arena_mark`/`reset` workaround reliably prevents it.** So the pattern is allocation-count-sensitive, just not arena-capacity-sensitive.

## What this rules out

- **Conservative GC over-marking → arena exhaustion.** Ruled out by 7MB peak.
- **`_rail_malloc_chain` overflow (Track D / prior session's concern).** Same reason.
- **User-code logic error.** Same code with `arena_mark` runs for 500+ iters fine.
- **Stack size.** 256MB `LC_MAIN` stack + `ulimit` doesn't change outcome.

## What it suggests

The crash is **not** a resource exhaustion. It is almost certainly a
**latent bug in the GC/allocator assembly** that accumulates state
corruption over GC cycles. Candidates, in likelihood order:

1. **`_rail_gc` mark stack overflow or underflow.** The mark stack is
   allocated via `bl _malloc` in `rt_gc_1` (size 4MB). After N GC
   cycles, bounds-check failures or leaked-frame corruption could
   write past end.
2. **`_rail_free_list` cycle formation.** If a freed block's
   free-list-next pointer ever points back into the live region, a
   subsequent `_rail_free_list_alloc` returns live memory →
   double-use corruption.
3. **`_gc_try_mark` recursion through a corrupted header.** When GC
   walks a MapNode, it reads the tag/size header. If any write went
   to a stale header, subsequent GCs interpret the object as wrong
   kind and scan past its end.
4. **Signal-handling / page-protection flakiness.** Explains why lldb
   masks the crash. Possibly macOS-specific interaction with stack
   guards. Less likely given reproducibility without lldb.
5. **Deep-tree `map_put` recursion blowing stack guard page silently.**
   A 500-deep path-copy allocates ~500 stack frames per call, with
   500 calls per iter and 80 iters → peak live frames ≤ 500, so this
   should be fine, but worth verifying.

## What the main plan should do instead

The 14–21 day "precise stack maps + generational GC" plan is the
right long-term direction for Rail, but it is overkill and wrong-fit
for fixing this specific segfault. A shorter diagnostic-then-fix path:

### Phase 0.5 — locate the crash (1–2 days)

Dig the actual crash address. Options:
- Set `MallocStackLogging=1 MallocScribble=1` + run under
  `malloc_history` to see corruption origin.
- Instrument `_rail_gc` entry/exit with stderr cycle counter,
  correlate cycle number with the crash iter.
- Strip the reproducer down to minimum: binary-search whether the
  bug needs `map_put` depth, or whether any 7MB+GC-trigger pattern
  reproduces.

### Phase 0.6 — fix the bug (likely 1–3 days)

Based on what Phase 0.5 finds, the fix is likely a <100-line change to
`rt_gc_1..4` or `_rail_alloc`'s slow path. Probably a buffer overrun,
a missing bounds check, or a free-list corruption guard.

### Phase 1+ (precise GC) — deferred

Still worth doing eventually for correctness and performance, but it's
a long-horizon language-maturity project, not an emergency fix. Revisit
after 0.5/0.6 ship and the immediate seq=1499 RSS issue is settled by
Track D (Metal pool) + the identified GC bug fix.

## What we still don't know

- The actual crash address / function.
- Whether this same bug affects `seq=1499` training RSS growth, or if
  that's a separate Metal-pool issue.
- Whether the bug is new (introduced in `rt_gc_*` during a past
  session) or has been latent since GC bootstrap.

These are the questions Phase 0.5 should answer.

## Artifacts shipped with this report

- `tools/debug/gc_probe.rail` — two-mode probe demonstrating the
  boundary between crash and non-crash.
- This file — written summary.

## Decision: do NOT start precise-GC implementation yet

Given that:
- The specific symptom (BPE segfault) is caused by a bug, not by a
  precision deficiency
- A 14–21 day project built on the wrong hypothesis will likely
  produce subtly wrong code (see session's earlier Obj 3 attempt:
  root-clearing didn't fix the crash either, confirming same pattern)
- Phase 0.5 can almost certainly identify the real bug in <2 days

**Recommended next action:** run Phase 0.5 diagnostic (under `lldb`
with controlled break conditions + `malloc_history`) to pinpoint the
actual corruption. Precise-GC can return to the plan after that ships.
