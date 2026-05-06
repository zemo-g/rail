# JIT — starting prompt for future model training sessions

Paste the section between the rules into a fresh model-training session.
This briefs the model on the current JIT state and how to integrate it
into Spur RLVR / distillation / bench filtering work.

---

## What the JIT is

A pure-Rail JIT that lowers a subset of Rail source → IR → ARM64 machine
code → executes via `mmap+pthread_create`. End-to-end runnable today
(2026-05-06, branch `jit` on `next`).

**Stage 3 complete:** Rail source → IR lowering shipped. You no longer
need to hand-build IR; pass a Rail source string and get a callable JIT.

## One-line entry

```rail
import "jit/emit.rail"      -- brings in jit/ir.rail transitively
import "jit/loader.rail"
import "jit/lower.rail"

let r = lower_source "fact n = if n < 2 then 1 else n * fact (n - 1)\nmain = fact 5"
-- r is ["ok", fns] | ["err", msg]
let fns = head (tail r)
let res = emit_program fns
let page = make_executable (emitted_buf res) (emitted_size res)
let answer = call_jit page 0    -- arg passed to main; main has no params
let _ = free_jit page
```

## Lowerable program shapes (handle in-process; ~ms per rollout)

| Shape | Example |
| --- | --- |
| Integer expression | `main = 7 + 13` |
| Let binding | `main = let x = 7 + 13 in x` |
| Let chain | `main = let a = 1+2 in let b = a*5 in b-4` |
| Single-arg recursion | `fact n = if n < 2 then 1 else n * fact (n - 1)\nmain = fact 5` |
| Two recursive calls per branch | `fib n = if n<2 then n else (fib (n-1)) + (fib (n-2))` |
| Print form | `main = print (show (fact 5))` |

The `print (show e)` pattern is recognized; emitted as `op_print_int`
(decimal stdout via `svc #0x80 write(2)`).

## Fallback shapes (lower_source returns "err" → use `./rail_native` shell grade)

* Multi-arg user functions (`add a b = a + b`) — single-arg only in v1.
* Strings, lists, ADT match, closures, file I/O — not in IR yet.
* Floats — not in IR yet.
* Non-tail `if` whose result is consumed by another call — `v_result`
  preservation across calls isn't yet wired through `let`-with-call-body.
  (Most real code doesn't hit this; flag it if you see lowering reject.)

## Distillation integration sketch

```
for each candidate src from teacher:
  r = lower_source src
  if r.tag == "err":
    grade via ./rail_native (slow path, ~100 ms)
    continue
  fns = r.payload
  bytes = emit_program fns
  page = make_executable bytes
  output = capture_stdout (call_jit page 0)
  match against expected
  free_jit page
```

The wins:
- Sub-ms grade per candidate that lowers (vs ~100 ms shell grade).
- Compiler-as-open-substrate: any IR-level signal you want (op-trace,
  process-reward, partial-correctness) is one `op_*` away.

## Bench coverage projection (Spur)

| Configuration | Bench / 30 |
| --- | --- |
| Shell-grade only (today's flywheel) | full bench, ~100 ms each |
| + JIT lowering for shapes above | ~10/30 in-process (~1 ms each) |
| + Stage 4 (strings) | ~15/30 |
| + Stage 5 (lists/ADT) | full bench |

(See `jit/NEXT_STAGES.md` for the staged plan.)

## Caveats to know cold

1. **`pthread_create` per `call_jit`** (~50–200 µs Apple Silicon). Sub-ms
   only holds for 1 call per rollout. Stage 2 (direct `blr` via
   `compile.rail` primitive) is the planned escape.
2. **Page leak**: tests don't always `free_jit` — if you're doing many
   thousands of rollouts, call it.
3. **No hardened-runtime entitlement** — works only because `./rail_native`
   is dev-built. Don't ship signed/notarized.
4. **Negative-int corner case**: `op_const` and `op_print_int` haven't been
   tested with negative integers (sign-extension untested in `emit_const`,
   division-by-10 loop assumes non-negative). Use `0 - x` patterns
   carefully.
5. **20-byte `op_print_int` layout** uses `x10..x15` and `x9` as scratch.
   Caller's `v0..v6` are clobbered after `op_print_int`. Use `v10/v11`
   (callee-save) to preserve values across.

## Memory entries to access (auto-memory)

* `jit_in_pure_rail.md` — full project memory, updated 2026-05-06 with
  Stage 1 + Stage 3 state.
* `rail_top_level_int_add_bug.md` — relevant if you write helper
  constants (e.g., `prologue_bytes = 12; ... prologue_bytes + body`
  silently miscompiles; inline literals).

## Key files

| File | Purpose |
| --- | --- |
| `jit/lower.rail` | source → fn list (Stage 3, this PR) |
| `jit/lex.rail` | Rail-subset tokenizer |
| `jit/syntax.rail` | recursive-descent parser → AST |
| `jit/emit.rail` | IR → ARM64 bytes |
| `jit/loader.rail` | mmap + pthread_create dance |
| `jit/test_lower.rail` | 14 end-to-end tests; run to verify environment |
| `jit/README.md` | Full IR contract + API reference |
| `jit/NEXT_STAGES.md` | Roadmap (Stages 2, 4, 5, 6) |

## How to verify your environment is good

```bash
./rail_native run jit/test_lower.rail
# expect: ALL LOWER PASS

./rail_native test
# expect: 137/137 tests passed
```

If both pass, JIT is live and integration is safe to start.

---

(End of paste-able prompt. The training session can take it from here —
slot the lower-then-jit call into the distill harness, fall back to
shell grade for non-lowerable shapes, and report the speedup.)
