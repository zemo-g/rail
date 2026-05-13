# Auto-memo fib correctness fix

**Branch**: `worktree-agent-a599a24c724e77632`
**Worktree**: `/Users/user/projects/rail/.claude/worktrees/agent-a599a24c724e77632`
**Date**: 2026-05-13

## Root cause

`compile.rail::compile_func` emitted **inconsistent keys** for memo
lookup vs memo store in the auto-memoization path.

At function entry (memo_lookup), the input `x0` was the **tagged** arg,
so the lookup key was correctly computed as `asr x8, x0, #1` (untagged
n).

At the end of the function body (memo_store), `x19` already held the
**untagged** arg (set by `asr x19, x0, #1` in the prologue's
`.Lmm_<fn>` path). But memo_store emitted `asr x8, x19, #1` — **a
second untag** — so it stored at `memo[n / 2]` instead of `memo[n]`.

Trace for fib (lookup keys by n; store keys by n/2):

| call    | x19 | store key | stored at | reads     |
| ------- | --- | --------- | --------- | --------- |
| fib(0)  |  0  |  0        | memo[0]   | -         |
| fib(1)  |  1  |  0        | memo[0]   | -         |
| fib(2)  |  2  |  1        | memo[1]   | memo[1]+memo[0] |
| fib(3)  |  3  |  1        | memo[1]!  | memo[2]+memo[1] |
| fib(4)  |  4  |  2        | memo[2]!  | memo[3]+memo[2] |
| ...     |     |           |           |           |

memo[1] is read for fib(2)'s second call (looking up fib(0)) — but it
holds fib(1)'s tagged result (3, tagged 1) because of the n/2 collision.
Similarly fib(2)'s value is overwritten by fib(3) before fib(4) can
read it. Cascading staleness → 293886 for fib(10).

### Why fact (the only existing self-rec single-arg int test) passed

`fact n = if n <= 1 then 1 else n * fact (n - 1)` has **one** recursive
call. The memo table is written but never read across a single
top-level call. Each `fact(n)` computes fact(n-1), fact(n-2), ... once
each in order; no slot is ever read after another value collided with
it. fact returns the right answer despite the corrupt memo state.

The bug only manifests for functions with **two or more** recursive
calls. fib(2) reads `memo[fib(0)]` and `memo[fib(1)]` — the latter is
written by fib(1) at slot `1>>1 = 0`, the same slot fib(0) writes to.
The two values race; the corrupted state propagates upward.

## Fix decision: fix (not disable)

The bug was a one-character codegen error (`asr x8, x19, #1` should
have been an x19-direct index). I fixed it rather than disabling the
optimization. Rationale:

1. The fix is local (one emit string at `tools/compile.rail:2593`) and
   trivially auditable.
2. It keeps the optimization intact — fact, fib, ackermann, and any
   future single-arg int recursive function benefit.
3. Disabling auto-memo entirely would regress benchmark numbers
   needlessly when the cause is mechanical.
4. The new emit uses `x19` directly as the index register
   (`str x0, [x9, x19, lsl #3]`), adds a `b.lt` guard for negative n
   (cheap defense against signed-overflow into the table — the prior
   emit was implicitly safe via the `asr` halving negative n upward,
   but we lose that with direct indexing), and keeps the `cmp x19,
   #1024 / b.hs` upper bound. Memo capacity is 1024 slots × 8 B = 8KB,
   matching `.comm _memo_<fn>,8192,3`.

## Files changed

- `tools/compile.rail` — fix the memo_store emit (lines 2590-2603,
  one functional line + 6 comment lines).
- `rail_native` — rebuilt via 2-cycle bootstrap (byte-identical fixed
  point in cycle 2-on, modulo the embedded path-name string in
  __LINKEDIT which is `rail_self` vs `rail_native`).
- `tools/test/auto_memo_fib_correctness.rail` — new falsification test.

## Bootstrap cycles run

1. cycle 1: rail_native (pre-fix binary) compiled patched source →
   `/tmp/rail_self` (cycle-1 binary). Installed as `rail_native`.
   - Verified fib(10) = 55, foo(2..4) = 2/4/8, fact(5) = 120.
   - Verified disasm: `str x0, [x9, x19, lsl #3]` in memo_store.
2. cycle 2: cycle-1 binary compiled patched source → cycle-2 binary.
3. cycle 3, 4: same, all byte-identical to cycle 2 modulo the path-string
   diff.
4. Definitive proof: two successive `./rail_native self 2>&1` runs (both
   writing to `/tmp/rail_self`) → byte-identical. Diff between
   `rail_native` and `/tmp/rail_self` is ONLY the embedded filename string
   (`rail_native-<uuid>` vs `rail_self-<uuid>` in __LINKEDIT).

## Verification

| Check | Result |
| --- | --- |
| `./rail_native run` on fib(10) | **55** (correct) |
| `./rail_native run` of `tools/test/auto_memo_fib_correctness.rail` | **PASS** (exit 0) |
| `./rail_safe run` of same test (pre-fix path) | FAIL: got 293886 / 5160927832 / 97358072471589632 |
| `./rail_native test` | **136/140** (4 pre-existing `tensor_*` failures from `/tmp/rail_out` race with parallel agents — `feedback_rail_test_tmp_race`; not from this fix) |
| 2-cycle bootstrap (same-path) | **byte-identical** |
| 2-cycle bootstrap (rail_native vs /tmp/rail_self) | differ only in embedded path string (expected; see CLAUDE.md) |
| Test of fact (existing inline t5) | passes |
| Disasm of fib's `_fib:` memo_store block | `str x0, [x9, x19, lsl #3]` (direct x19 index) |

## Falsification test

`tools/test/auto_memo_fib_correctness.rail`:
- Defines fib in the canonical 2-recursion form.
- Computes fib(10), fib(12), fib(15).
- Compares to hardcoded `[55, 144, 610]`.
- Prints `PASS` and exits 0 on all-match, prints `FAIL` and exits with
  the number of failures otherwise.

## Out of scope (not touched)

- `jit/*`
- `stdlib/*`
- `rt_arith` / int-float ordering fixes
- The 4 failing `tensor_*` tests (pre-existing tmp-file race, owned by
  test infrastructure / unrelated to this fix)
- The pure-Rail diff-fuzzer / lint / trace tools (foundations work)

## Open questions / followups

- The `tensor_*` test failures are race-induced when ≥2 agents are
  active. Memory `feedback_rail_test_tmp_race` calls for a permanent
  fix to the `/tmp/rail_out.o` mktemp; not in scope here.
- `tools/test/rail_test.rail` only discovers `test_*.rail` files. The
  new falsification test uses the older `auto_memo_*` naming convention
  (matches the handoff request); to integrate it into the rail_test
  runner, it would need to be renamed to `test_auto_memo_fib.rail`.
  Did NOT do this to honor the handoff spec literally.

## Commits

`fix(compile): auto-memo memo_store keyed n/2 instead of n`

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
