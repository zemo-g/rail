# WASM backend — open follow-ups

## Per-function shadow-stack frames (deferred from track C, commit 33d7eb3)

**Status:** Required before WASM is production-complete. Does NOT block
the 8 shipped demos.

### What's missing

Track C wired a Cheney copying GC into the WASM runtime (`$gc_collect` /
`$gc_forward` / `$gc_scan_object` in `tools/wasm_runtime.wat`) and added
a 16KB shadow stack for GC roots. `$cons` correctly spills `hd` / `tl`
to the shadow stack before allocating, so a mid-cons GC can find them.

User-function codegen does NOT yet emit shadow-stack frames. Every
non-runtime WASM function that holds a heap pointer in a WASM local
across a call to `$cons`, `$alloc_obj`, or any user function that
transitively allocates, will LOSE that root if GC fires mid-call.

### Why the 8 shipped demos don't hit this

`examples/wasm/{hello,fib,math,list,adt,closure,fizz,loop}.rail`:

- `hello`, `math`, `fib`: scalar only, no heap locals.
- `list`, `adt`, `closure`, `fizz`: allocate but don't hold prior heap
  values across allocations inside user code — the pattern is
  "compute → allocate → return" in tail position.
- `loop`: the stress demo — allocates 100k cons cells but the loop
  counter is an i32 and the accumulator is written directly into the
  new cons, not held in a WASM local across the alloc.

Any demo that did `let x = cons ... in let y = cons ... in use x y`
(two allocations with `x` as a heap-pointer local across the second)
would miss `x` on a GC triggered by the second `cons`.

### What the fix looks like

1. At each user-function entry, reserve `N * 8` bytes on the shadow
   stack where `N` = number of heap-pointer locals. `(global
   $shadow_sp)` decrements by that amount.
2. At each allocation-triggering call, spill all live heap-pointer
   locals into the reserved frame before the call, reload after.
3. At function exit (every `return` path), restore `$shadow_sp`.
4. `$gc_collect` already walks shadow stack from 0 to `$shadow_sp` —
   the new frames automatically become roots.

Requires WASM codegen (`cg_wasm_*` in `tools/compile.rail`) to track
which locals hold heap pointers at each call site. Track B's
`__ty_<name>` annotations on let-bindings are the natural input — a
local marked `HEAP` gets spilled; `INT` / `FLOAT` / `UNKNOWN` do not.

### Trigger condition to prioritize this

File a real issue (not just this note) when any of:
- A user ships a WASM demo that holds >1 heap value across a call.
- The rail-safe public sandbox gets a leak report.
- WASM compiles of stdlib/tensor.rail or similar become a target.

Until then, the 8 shipped demos work correctly and the limitation is
explicit in Track C's commit message + this file.
