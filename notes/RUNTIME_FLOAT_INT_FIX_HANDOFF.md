# Runtime fix handoff: ARM64 same-bug-class sweep, (float LHS, int RHS) ordering

**Branch**: worktree-agent-a047973803341bbea (off `next` @ 7fa3a3f)
**Date**: 2026-05-13
**Status**: ARM64 fix shipped + verified; x86 already had the fix in place.

## What was broken

The 2026-05-12 sweep (commits `b223960` x86 + `9e16aa7` ARM64) fixed the
`(tagged-int LHS, raw-f64 RHS)` ordering for 9 runtime helpers (add, sub,
mul, div, mod, lt, gt, le, ge). The **reverse** ordering
`(raw-f64 LHS, tagged-int RHS)` was not covered. ARM64 SIGSEGV'd; x86
already had the mirror branches.

Concrete failure on ARM64: `(arr_get a 0) <op> (arr_get a 1)` where
`a[0]=5.5; a[1]=2`. The runtime helper sees `x1 = raw-f64 bits` (low bit 0)
and `x0 = tagged int` (low bit 1). The fast-path `tst x1, #1; b.eq
.L<op>_float` routed to the float path, which then did `ldr d0, [x1, #8]`
— dereferencing raw-f64 bits as a heap pointer → SIGSEGV. For add the
analog was `.Ladd_heap` doing `ldr x2, [x1]`.

## What changed

`tools/compile.rail`, `rt_core::radd` (line 2636) and `rt_arith::r{sub,mul,
div,mod,lt,gt,le,ge}` (lines 2694–2701): each helper now branches into a
new `.L<op>_mixed_fi` block at the top of `.L<op>_float` (or `.Ladd_heap`
for add) when `tst x0, #1; b.ne` indicates the RHS is a tagged int. The
new block does:

```
fmov d0, x1           # treat x1 as raw f64
asr x0, x0, #1        # untag RHS int
scvtf d1, x0          # promote to double
f<op> d0, d0, d1
... box result (mov x0,#16; bl _rail_alloc; ...) ...
ret
```

This mirrors `.L<op>_mixed_if` (the (int, float) direction) with the
operand roles swapped. Comparisons (lt/gt/le/ge) don't box — they just
`cset` and tag a bool.

## Falsification tests (9, all PASS after fix)

`tools/test/{add,sub,mul,div,mod,lt,gt,le,ge}_float_int_ordering.rail` —
each pre-fix SIGSEGV'd, post-fix prints `PASS`. Pattern mirrors the
existing `*_int_float_ordering.rail` tests with operand order reversed:

```rail
let a = arr_new 2 0
let _ = arr_set a 0 <float>     -- LHS
let _ = arr_set a 1 <int>        -- RHS
let v = (arr_get a 0) <op> (arr_get a 1)
if show v == "<expected>" then ... PASS ...
```

`show v == "<str>"` is used over `v == <literal>` to bridge the heap-box
vs raw-f64 result asymmetry (see header comment in
`sub_int_float_ordering.rail` for the rationale).

## Verification

| Step | Result |
|---|---|
| 9 falsification tests pre-fix | 9× SIGSEGV (confirmed) |
| 9 falsification tests post-fix | 9× PASS |
| 9 pre-existing `(int, float)` tests post-fix | 9× PASS (regression-free) |
| `./rail_native test` | 136/140 — 4 `tensor_*` failures pre-existing (parallel-agent `libtensor_gpu.dylib` race per `rail_test_tmp_race`); identical count on pristine baseline before this change |
| Byte-identical fixed point (cycle 3) | `cmp rail_native /tmp/rail_self` matches (`72a10572...` SHA-1 unsigned) |

## Bootstrap log

The runtime-asm-string change requires 2 cycles to take effect (cycle 1
puts new strings in the data section; cycle 2 emits them as runtime asm).
This sweep is `source + runtime asm in one edit → 2 cycles` per the
`BOOTSTRAP CYCLE PATTERN` table in `CLAUDE.md`.

Sequence (atomic per-cycle to dodge the `/tmp/rail_self` race with the
other 3 parallel worktrees):

1. cycle 1: `./rail_native self` (gen0 → gen1; gen1 has new strings in
   data, still emits old runtime).
2. cycle 2: `cp /tmp/rail_self rail_native && codesign --force -s - rail_native && ./rail_native self`
   (gen1 → gen2; gen2 now emits new runtime).
3. cycle 3: same again (gen2 → gen3; `cmp` byte-identical = fixed point).

Intermediate artifacts named `rail_native_c{3,4,5}` and `rail_self_c{3,4,5}.s`
in the worktree (each immediately copied from `/tmp/rail_self*` to a
worktree-local path post-compile, to survive concurrent agents).

## x86 disposition

`tools/x86_rt.s` already has `.L<op>_mixed_fi` branches for all 9
operators (introduced in the original `b223960` sweep). Inspection of
`_rail_sub` etc. confirms the mirror branches and check_both routing are
already present. **No x86 code change needed.** This was anticipated by
the prior handoff.

x86 floats are heap-boxed throughout, so the x86 `.L<op>_mixed_fi`
uses `movsd qword ptr [rdi+8]` to deref the heap-box LHS, whereas the
ARM64 native-float v2.0 path uses `fmov d0, x1` to treat x1 as raw f64
bits. Same semantic, different operand convention.

(If a follow-up wants formal x86 verification via Docker, the obvious
move is to add `*_float_int_ordering` entries to `tools/test/x86_conformance.sh`
mirroring the `*_int_float_ordering` entries already there at lines
195–202.)

## Files changed

- `tools/compile.rail` (rt_core + rt_arith blocks, line 2636 + 2694–2701)
- `tools/test/{add,sub,mul,div,mod,lt,gt,le,ge}_float_int_ordering.rail` (new)
- `rail_native` (rebuilt; byte-identical fixed point)

## Out-of-scope (not touched, per prompt)

- `jit/` — JIT path
- `stdlib/` — pure-Rail
- Other sections of `compile.rail` (parser, x86 inline cache, auto-memo)

## Concurrent-agent friction observed

Three other agents in parallel worktrees actively rebuilding rail_native
during this session collided on `/tmp/rail_self`, `/tmp/rail_self.s`, and
`/tmp/rail_x86.s`. Mitigation used here: every `./rail_native self` was
followed immediately by `cp /tmp/rail_self ./rail_native_c<N>` and
`cp /tmp/rail_self.s ./rail_self_c<N>.s` to a worktree-local path before
the next agent could clobber.
