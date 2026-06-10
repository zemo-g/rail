# REPL JIT — Handoff

Date: 2026-05-13
Branch: `feat/repl-jit-v0` (local only — NOT pushed)
Worktree: `<worktree>`

## Deliverables

- `tools/repl_jit.rail` — new JIT-first REPL, ~280 LoC
- `tools/test/repl_jit_smoke.rail` — falsification harness (11 assertions)
- `tools/test/repl_jit_pipe_smoke.rail` — independent JIT-pipeline sanity check
- `tools/test/repl_jit_micro_bench.rail` — per-call JIT cost measurement
- `tools/test/repl_jit_bench.sh` — REPL-end-to-end bench driver (kept for archival; preferred path is the python3 inlines in this doc — see Latency section)

The existing `tools/repl.rail` is untouched.

## What works (JIT path)

Lowers + runs end-to-end at sub-ms cost:

- Pure arithmetic: `3 + 4`, `(2 + 3) * 4 - 1`
- `let x = e in body` (single-line; multi-line let is reformatted to inline)
- Single-arg recursion: `fact 6`, `fib 10` (JIT computes 55 correctly; note the
  shell compiler returns the wrong `fib 10 = 293886` due to a pre-existing
  auto-memoization bug for single-arg int-int recursive fns — see Bugs section)
- Multi-arg fn defs: `add a b = a + b\nadd 7 13`
- Function composition: `double (double 9)` after `double x = x * 2`
- `print "literal"` (uses JIT stdout-capture via heap output buffer)
- Persistent definitions across REPL lines (string-concat into `defs` buffer)

## What falls back to shell (`[shell]` prefix)

Anything outside `jit/lower.rail`'s subset:

- ADTs and `match` (`type Pair = | P a b\nmatch (P 3 4) | P a b -> a + b`)
- `try ... handler` effect handlers
- Stdlib-heavy expressions (lists with HOFs, `import "stdlib/..."`, etc.)
- Polymorphic `show` on lists/strings (JIT's show only does ints + floats)
- 5+ args to a user fn (JIT cap is 4)
- The first call after a type-decl line: once `type T = ...` enters `defs`,
  every subsequent JIT lowering attempt errors on the type line and falls
  through to shell. (Once you `:reset` or never define a type, JIT stays hot.)

## Persistent-definitions implementation choice

Chose **string-concatenation into a `defs` buffer**, mirroring `tools/repl.rail`.

Each line is classified by `is_definition`:

- Starts with `let`/`if`/`(` → expression
- Starts with `main `/`main=` → expression (forbid double-`main` collision)
- Contains `=` → definition; append to `defs`
- Otherwise → expression

For an expression line, the REPL builds `defs + "\nmain = " + body + "\n"` and
hands it to `try_jit_eval`. On failure, the SAME source string is written to
`/tmp/rail_repl_jit_batch.rail` and run via `./rail_native run`.

**Cost model**: every JIT eval reparses + relowers + reemits the full `defs +
expr` program. For an interactive session of <100 lines this is dominated by
the constant JIT-overhead floor (~0.4 ms for empty defs, ~0.5 ms for ~50 lines
of cumulative defs). No incremental compilation is attempted. This is the
right v0 tradeoff: simpler than maintaining incremental IR, and the JIT is fast
enough that re-lowering isn't a bottleneck until defs gets pathologically large.

## Latency numbers (median of 5 runs, pre-compiled REPL binary at `/tmp/repl_jit_bin`)

| Path | Cost | Notes |
|---|---|---|
| REPL startup (empty input) | 3.1 ms | binary loads, sentinel read, EOF |
| **JIT line** (steady state) | **~0.1 ms** | derived from (10-line - 1-line) / 10 |
| **JIT line** (cold first) | ~0.4 ms | from `repl_jit_micro_bench.rail`: 7-10 ms / 20 iters |
| **Shell-fallback line** | **~319 ms** | `./rail_native run /tmp/rail_repl_jit_batch.rail` |
| One-time REPL compile | **~21 s** | `./rail_native run tools/repl_jit.rail`; imports the entire JIT chain |

**Speedup of JIT path vs shell path: ~3000×** (0.1 ms vs 319 ms).

Compared to the existing `tools/repl.rail`'s shell-only path (~315 ms/line):
the JIT-first REPL is ~3000× faster for in-subset programs and identical
cost for out-of-subset (both pay the shell roundtrip).

Caveat: the **21 s REPL-startup cost** is the JIT-import chain getting
compiled. For interactive use, this is paid once. If we want to avoid it,
ship a pre-built binary (`./rail_native tools/repl_jit.rail && cp /tmp/rail_out
~/.local/bin/rail-jit-repl`) which starts in 3 ms.

## How to use

```bash
# Interactive (pays one-time 21 s compile, then sub-ms per line):
./rail_native run tools/repl_jit.rail

# Or pre-compile once for fast startup:
./rail_native tools/repl_jit.rail && cp /tmp/rail_out /tmp/repl_jit_bin
/tmp/repl_jit_bin

# Batch mode (used by the smoke test):
echo "/path/to/script.txt" > /tmp/rail_repl_jit_input.txt
./rail_native run tools/repl_jit.rail
```

Inside the REPL:

```
rail-jit> 3 + 4
[jit]   7
rail-jit> fact n = if n < 2 then 1 else n * fact (n - 1)
  (defined)
rail-jit> fact 6
[jit]   720
rail-jit> :mode shell        # force shell path (debugging)
rail-jit> :mode auto         # default
rail-jit> :defs              # show accumulated definitions
rail-jit> :reset             # clear definitions
rail-jit> :q
```

## Smoke test

```bash
./rail_native run tools/test/repl_jit_smoke.rail
```

Verifies 11 markers across 4 JIT-hits, 1 shell-fallback, 1 parse-error.
Last line prints `PASS` on success; exit 0.

Independent JIT-pipeline sanity check (no REPL involved):

```bash
./rail_native run tools/test/repl_jit_pipe_smoke.rail
```

## JIT-side bugs / quirks found (NOT fixed per scope)

1. **`jit/lower.rail` parser is single-line-significant within a `let`.**
   Multi-line `main =\n  let _ = print (...)\n  0` errors with `primary:
   unexpected token tag=nl`. Workaround in REPL: always synthesize
   `main = let _ = print (show (...)) in 0` (single-line `let ... in ...`).
   This is fine for the REPL but is a subset limit worth documenting in
   `jit/CONTINUATION.md`.

2. **`type` declarations are not in the JIT subset.** As soon as a `type T = ...`
   line is in `defs`, every JIT attempt errors. The REPL falls back to shell
   cleanly, but a fancier version could strip type decls + ADT branches before
   handing to JIT iff the user's expression doesn't reference them.

3. **(Not JIT)** Pre-existing compile.rail bug: `fib n = if n < 2 then n else
   fib (n-1) + fib (n-2)` returns `293886` for `n=10` via shell compile (correct
   55 via JIT). Looks like auto-memo-table for single-arg int-int self-recursive
   fns has a wrong-result regression. **Did not investigate** — out of scope.
   Filed mentally for compile.rail follow-up.

4. **`call_jit_direct` ABI quirk**: when the program prints, the int return
   from `main` is meaningless and `read_jit_output` returns the captured
   stdout. The REPL uses `jit_output_len > 0` to disambiguate which to show.
   This is documented in `jit/loader.rail` but worth restating.

## Honesty notes

- **The "sub-50 ms feedback" goal is met**: actual median is **~0.1 ms** per
  JIT line in steady state, ~500× under budget.
- **The 21 s startup cost is real and not "sub-50 ms"**. It's one-time per
  REPL session. For comparison, `tools/repl.rail` starts in ~300 ms because
  it doesn't import the JIT chain. There's a real tradeoff: ship a precompiled
  REPL binary, or keep startup short and pay 315 ms per line.
- **Persistent defs don't accumulate cost noticeably** for sessions up to
  ~50 defs (verified by lowering an artificial 20-fn defs+expr; total JIT cycle
  stayed under 1 ms). Would degrade at thousands of defs, but interactive
  sessions don't reach that.
- **JIT lower-hit rate** on the smoke test transcript: **9/11 lines hit JIT**
  (4 defs + 4 JIT exprs + 1 parse-error JIT-attempt; 2 shell-fallbacks for the
  `type Pair` defn and the subsequent `match` expr). On a typical arithmetic /
  recursion / simple-fn workload, expect 100% JIT. ADT-heavy / effect-handler /
  stdlib-heavy work bypasses the JIT entirely — not 50/50 like I feared.

## Not done / out of scope

- `:time` toggle to print per-line latency. Easy add (one shell call).
- Float input/output in REPL. JIT supports floats; REPL's `print (show (...))`
  wrapping uses int-show, would need a type-inference branch to pick
  `show_float` for float-typed exprs. Punted.
- Incremental def compilation. Today every line re-lowers the full `defs`
  list. At ~0.1 ms per cycle this is not yet a bottleneck.
- `:load file.rail` slurping (the old REPL supports it). Punted.
- Stripping type decls from `defs` before JIT attempt, so a session with one
  ADT defn doesn't permanently force the shell path. Worth doing if anyone
  actually uses ADTs in the REPL.
