# JIT — starting prompt for future model training sessions

Paste the section between the rules into a fresh model-training session.
This briefs the model on the current JIT state and how to integrate it
into Spur RLVR / distillation / bench filtering work.

---

## What the JIT is

A pure-Rail JIT that lowers a subset of Rail source → IR → ARM64 machine
code → executes via `mmap+pthread_create`. End-to-end runnable today
(2026-05-06, branch `jit` on `next`).

**Stages 1, 3, 4, and 5 (lists/heap) complete.** You no longer need to
hand-build IR; pass a Rail source string and get a callable JIT.
Multi-arg fns, string ops (literal print, `str_eq`/`str_len`/`str_at`),
list ops (`cons`/`head`/`tail`/`is_nil` + `[a,b,c]` literals + recursive
list traversal) all work end-to-end. `match` syntax sugar is the only
Stage 5 piece still pending — list-ADT logic via `if is_nil` works today.

## One-line entry

```rail
import "jit/heap.rail"      -- canonical importer for stdlib/mmap.rail + jit/ffi.rail
import "jit/emit.rail"      -- transitively brings ir.rail
import "jit/loader.rail"
import "jit/lower.rail"

let r    = lower_source "fact n = if n < 2 then 1 else n * fact (n - 1)\nmain = fact 5"
-- r is ["ok", fns, pool] | ["err", msg]
let fns  = head (tail r)
let pool = head (tail (tail r))
let heap = heap_alloc 0
let res  = emit_program fns pool heap
let page = make_executable (emitted_buf res) (emitted_size res)
let answer = call_jit page 0    -- arg passed to main; main has no params
let _ = free_jit page
let _ = heap_free heap
```

## Lowerable program shapes (handle in-process; ~ms per rollout)

| Shape | Example |
| --- | --- |
| Integer expression | `main = 7 + 13` |
| Let binding | `main = let x = 7 + 13 in x` |
| Let chain | `main = let a = 1+2 in let b = a*5 in b-4` |
| Single-arg recursion | `fact n = if n < 2 then 1 else n * fact (n - 1)\nmain = fact 5` |
| Multi-arg fn (1..4 args) | `add a b = a + b\nmain = add 7 13` |
| Multi-arg recursion | `pow b e = if e < 1 then 1 else b * pow b (e - 1)\nmain = pow 2 10` |
| Two recursive calls per branch | `fib n = if n<2 then n else (fib (n-1)) + (fib (n-2))` |
| Print int | `main = print (show (fact 5))` |
| Print string literal | `main = print "hello"` |
| Print let-bound string | `main = let s = "abc" in print s` |
| String equality | `main = if str_eq "abc" "abc" then 1 else 0` |
| String length | `main = str_len "hello"`  → `5` |
| String char-at | `main = str_at "hello" 0` → `104` |
| String escapes | `\n \t \\ \"` inside `"..."` literals |
| List literal | `main = head [10, 20, 30]` → 10 |
| Recursive list traversal | `len xs = if is_nil xs then 0 else 1 + len (tail xs)` |
| List sum | `sum xs = if is_nil xs then 0 else (head xs) + (sum (tail xs))` |
| Match on list | `len xs = match xs \| nil -> 0 \| cons h t -> 1 + len t` |
| Match (any branch order) | `\| cons h t -> ... \| nil -> ...` works too |
| Comparison ops | `==`, `<`, `>`, `<=`, `>=` (all at cmp precedence) |
| Arithmetic ops | `+`, `-`, `*`, `/`, builtin `mod a b` |
| Unary minus | `0 - x` desugar; literal `-5` works as `(0 - 5)` |
| Boolean | `&&`, `\|\|` (parse-time desugar to if-then-else; short-circuit) |
| Sequencing | `let _ = print "x = " in print (show n)` -> "x = n\n" |
| Print loop | `print_list xs = match xs \| nil -> 0 \| cons h t -> let _ = print (show h) in print_list t` |

`print (show e)` is recognized as `op_print_int`; bare `print "lit"` /
`print str_var` route through `op_print_str` via type inference.
String pool is laid out at the end of the JIT page; `op_str_lit` uses
PC-relative `adr` to load addresses.

## Stage 5 status (lists shipped 2026-05-06)

List operations work end-to-end. `len`, `sum`, fold-style traversal
with `is_nil + head + tail` all execute correctly. The earlier
foreign-pointer ABI blocker was resolved: Rail represents `foreign`
pointer returns as `(real_addr >> 1)`; `heap_alloc` now does `shl p 1`
before storing the bump pointer, so the JIT-side `ldr [x27]` reads
the real address. ABI v2: heap is passed as `call_jit`'s arg slot.

## Fallback shapes (lower_source returns "err" → use `./rail_native` shell grade)

* `>4`-arg user functions (rejected with clear error).
* `match | C x -> ...` syntax — workaround: rewrite as `if is_nil ...`.
* Closures, file I/O, floats — not in IR yet.
* Any string return from a user fn (str-typed args at call sites work,
  str-typed returns do not).

## Distillation integration sketch

```
for each candidate src from teacher:
  r = lower_source src
  if r.tag == "err":
    grade via ./rail_native (slow path, ~100 ms)
    continue
  fns  = r.payload[0]
  pool = r.payload[1]
  heap = heap_alloc 0
  bytes = emit_program fns pool heap
  page = make_executable bytes
  output = capture_stdout (call_jit page 0)
  match against expected
  free_jit page; heap_free heap
```

The wins:
- Sub-ms grade per candidate that lowers (vs ~100 ms shell grade).
- Compiler-as-open-substrate: any IR-level signal (op-trace,
  process-reward, partial-correctness) is one `op_*` away.

## Bench coverage projection (Spur)

| Configuration | Bench / 30 |
| --- | --- |
| Shell-grade only (today's flywheel) | full bench, ~100 ms each |
| + JIT lowering (Stages 1+3) | ~10/30 in-process (~1 ms each) |
| + Stage 4 (strings + multi-arg) | ~15/30 in-process |
| + Stage 5 (lists/heap) | ~25/30 |
| + match syntax + cmp/arith ops + bool + sequencing — TODAY | ~28/30 |
| + closures + file I/O + floats | full bench |

(See `jit/NEXT_STAGES.md` for the staged plan + Stage 5 blocker.)

## Caveats to know cold

1. **`pthread_create` per `call_jit`** (~50–200 µs Apple Silicon). Sub-ms
   only holds for 1 call per rollout. Stage 2 (direct `blr` via
   `compile.rail` primitive) is the planned escape.
2. **Page leak**: tests don't always `free_jit` / `heap_free` — for
   thousands of rollouts, call them.
3. **No hardened-runtime entitlement** — works only because `./rail_native`
   is dev-built. Don't ship signed/notarized.
4. **Negative-int corner case**: `op_const` and `op_print_int` haven't been
   tested with negative integers (sign-extension untested in `emit_const`,
   division-by-10 loop assumes non-negative).
5. **String pool 16 KB cap** per program (`max_pool_bytes` in lower.rail).
6. **`infer_arg_type` is heuristic**: `s`/`s1`/`s2`/`str`/`name` route as
   "str", everything else as "int". If your generated code names a
   string-typed arg differently, it'll be lowered as int and `print` will
   route to `op_print_int` — yields garbage. Reword args or extend
   `infer_arg_type`.
7. **Foreign-pointer ABI blocker for lists** — see Stage 5 caveat above.

## Memory entries to access (auto-memory)

* `jit_in_pure_rail.md` — full project memory, updated 2026-05-06 with
  Stages 1, 3, 4, and 5-lowering state.
* `rail_top_level_int_add_bug.md` — relevant if you write helper
  constants (e.g., `prologue_bytes = 12; ... prologue_bytes + body`
  silently miscompiles; inline literals).

## Key files

| File | Purpose |
| --- | --- |
| `jit/lower.rail` | source → fn list + string pool (Stages 3+4) |
| `jit/lex.rail` | Rail-subset tokenizer (incl. string escapes) |
| `jit/syntax.rail` | recursive-descent parser → AST |
| `jit/heap.rail` | bump-pointer cons-cell heap (Stage 5; canonical mmap importer) |
| `jit/emit.rail` | IR → ARM64 bytes (incl. string pool + heap-addr layout) |
| `jit/loader.rail` | mmap + pthread_create dance |
| `jit/test_lower.rail` | 26 end-to-end tests; run to verify environment |
| `jit/README.md` | Full IR contract + API reference |
| `jit/NEXT_STAGES.md` | Roadmap (Stage 2, Stage 5 blocker, Stage 6) |
| `jit/CHANGELOG.md` | One-line summary per `jit/` commit, Stages 1..5 |

## How to verify your environment is good

```bash
./rail_native run jit/test_lower.rail
# expect: ALL LOWER PASS  (covers Stages 3+4: 26 tests)

./rail_native run jit/test_codegen.rail
# expect: ALL PASS (8 hand-built IR fixtures, Stage 1)

./rail_native test
# expect: 137/137 tests passed
```

If all three pass, JIT is live and integration is safe to start.

---

(End of paste-able prompt. The training session can take it from here —
slot the lower-then-jit call into the distill harness, fall back to
shell grade for non-lowerable shapes, and report the speedup. Avoid
list-using prompts until Stage 5's ABI blocker is resolved.)
