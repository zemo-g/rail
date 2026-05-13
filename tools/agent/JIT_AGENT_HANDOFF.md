# JIT-Agent v0 — Handoff (2026-05-13)

## Branch + files

- **Branch:** `feat/agent-jit-loop` (worktree
  `~/projects/rail/.claude/worktrees/agent-a5a8afdc5111183af`).
  Local commit only; not pushed.
- **Files (all new):**
  - `tools/agent/jit_loop.rail` — agent main (~210 lines).
  - `tools/agent/system_prompt.txt` — JIT-subset Rail system prompt.
  - `tools/agent/test_jit_loop.rail` — offline smoke test (fib10=55, fact6=720).
  - `tools/agent/DEMO_TRANSCRIPT.md` — captured demos.
  - `tools/agent/JIT_AGENT_HANDOFF.md` — this file.

No `jit/`, `stdlib/`, or `tools/compile.rail` files were modified.

## What works

End-to-end JIT pipeline, single-process, no `./rail_native` subprocess:

```
./rail_native tools/agent/jit_loop.rail        # build
cp /tmp/rail_out /tmp/jit_loop_<tag>           # namespace away from parallel agents
/tmp/jit_loop_<tag> --offline                  # canned fib(10) = 55 demo
/tmp/jit_loop_<tag> --src "main = 7 + 13"      # raw source, RESULT = 20
/tmp/jit_loop_<tag> --src-file path.rail       # raw source from file
/tmp/jit_loop_<tag> --problem-file p.txt       # online, problem text from file
/tmp/jit_loop_<tag> "factorial of 8"           # online, direct exec only
```

Verified end-to-end (offline path, captured in `DEMO_TRANSCRIPT.md`):

| Demo                    | Source path             | Result |
| ---                     | ---                     | ---    |
| `--offline` (fib 10)    | canned in code          | 55 OK  |
| `--src "main = 7 + 13"` | argv                    | 20 OK  |
| fact 8                  | `--src-file`            | 40320 OK |
| fib 15                  | `--src-file`            | 610 OK   |
| gcd 1071 462            | `--src-file`            | 21 OK    |
| is_prime 97             | `--src-file`            | 1 OK     |
| Collatz steps 27        | `--src-file`            | 111 OK   |
| Fenced source           | `--src-file` w/ ```rail | 42 OK (fence stripped) |

Smoke test: `./rail_native run tools/agent/test_jit_loop.rail` exits 0
and prints `PASS`.

## JIT-compatibility rate

Hand-crafted dataset, separating in-subset from out-of-subset:

- **In-subset (model-respects-prompt):** 5 / 5 programs JIT-compiled and
  ran with correct integer answers (fact, fib, gcd, is_prime, Collatz).
- **Out-of-subset (model-strays):** 0 / 5 programs JIT-compiled. All 5
  were cleanly rejected by `lower_source` with diagnostic error strings
  surfaced through `try_jit_grade`. No segfaults, no silent wrong
  answers — the lowerer is doing its job.

So **the JIT-subset gate behaves as a hard verifier**: in-subset programs
pass, out-of-subset programs fail loudly. The remaining question is
how often a real LLM stays in-subset given the system prompt; that needs
an online run (not exercisable on this host — see below).

## Online round-trip: NOT RUN

No `ANTHROPIC_API_KEY` is set on this Studio session and there is no
key at the default file path `~/.fleet/anthropic_key`.
The online code path is wired (`call_llm` -> `anthropic_chat` from
`stdlib/anthropic_client.rail`) and reads the key from any of:

1. `--key-path FILE`
2. `ANTHROPIC_API_KEY` env var (written to `/tmp/rail_jit_agent_key` at
   runtime so the file-based client can consume it)
3. The legacy default `~/.fleet/anthropic_key`

To exercise online once a key is available (rough recipe; see
`DEMO_TRANSCRIPT.md` Demo 6):

```
./rail_native tools/agent/jit_loop.rail
cp /tmp/rail_out /tmp/jit_loop_<tag>
ANTHROPIC_API_KEY=sk-... /tmp/jit_loop_<tag> "factorial of 8"
```

Wall-clock estimate (not measured here): ~1-3s for the Anthropic HTTPS
call, <50ms for lower+JIT+exec. Cost estimate per request on
`claude-haiku-4-5-20251001`: ~$0.0007 (≈1500 input + 80 output tokens).

## Honest scope assessment

The shipped agent works **only for the narrow class of problems where
"Rail-as-int-only-with-recursion" is the right tool.** The JIT v1 subset
(per `jit/README.md` and `jit/lower.rail`) is:

- top-level fn defs, 1..4 args, integer arithmetic
- `if/else`, `let`, recursion
- builtins: `mod`, `not`, `cons/head/tail/is_nil`,
  `str_eq/str_len/str_at`, `read_file`, `int_to_float`/`float_to_int`,
  `print`, `show`
- NO: ADTs, `match`, lambdas, list literals, `map/filter/fold`,
  `length`, `range`, tuples, pipe `|>`, `error`, `arr_*`, `chars`,
  `split`, `join`, `cat`, string concatenation, mutable arrays.

The `system_prompt.txt` is therefore tightly worded: it specifies the
whole subset positively, includes a NEGATIVE list of >25 features the
model must not use, and supplies 5 worked examples (fact, sum, fib, gcd,
is_prime) that exactly match the shape the JIT can handle.

**Heavily-constrained prompt -> narrow problem class.** That's the honest
trade. A model could trivially solve "what's the SHA-256 of 'hello'" by
writing real Rail, but the JIT couldn't lower it. The strategic claim
of the demo is therefore "the verifier-as-a-library round-trip works
in a single process" — NOT "any code question is answerable." The two
are different theses; this demo proves the former.

## JIT-side issues encountered

1. **`libjit_call.dylib` is not checked in.** A fresh worktree doesn't
   have `jit/libjit_call.dylib` and `try_jit_grade` (which calls
   `call_jit_direct`) silently produces an undefined-symbol `ld:` error
   that `compile.rail`'s `trim` truncates to the unhelpful single line
   `ld: Undefined symbols for architecture arm64:`. Fix: `bash
   jit/build_trampoline.sh` (compiles `tools/jit_call.c` -> dylib). This
   is a one-time per-worktree step. **Not a JIT bug per se, but a setup
   gotcha worth documenting.** `compile.rail`'s `trim` swallowing the
   full ld stderr is a separate diagnostic-quality issue
   (`tools/compile.rail:3677` calls `trim` on `ld_result` and `trim` is
   defined as `head (split "\n" s)` -> only first line survives).
2. **`/tmp/rail_out` race with parallel worktree agents.** The CLAUDE.md
   warning was real: while developing, `cp /tmp/rail_out
   /tmp/jit_loop_<tag>` was racing with another agent's `./rail_native
   run`, producing nonsense output ("10", "120") that looked like the
   agent was broken. Mitigation: always copy `/tmp/rail_out` to a
   worktree-namespaced path immediately after a build, and never invoke
   `/tmp/rail_out` directly in a parallel session. Memory entry
   `feedback_rail_test_tmp_race` covers the same pattern for tests; this
   is the agent-tool variant.
3. **`./rail_native run` doesn't preserve quoted argv.**
   `compile.rail:6775` calls `compile_and_run prefix path (join_args a
   3)` which joins all extra args with spaces and reshells through
   `shell`. So
   `./rail_native run tools/agent/jit_loop.rail --src "main = 99"`
   reaches the agent as `[--src, main, =, 99]`. Workaround: compile
   first (`./rail_native tools/agent/jit_loop.rail`), then exec
   `/tmp/rail_out --src "main = 99"` directly. Documented in the
   agent's usage block. For `rail_native run` users, the agent supports
   `--src-file PATH` and `--problem-file PATH` as space-safe
   alternatives.

None of these are bugs in `jit/grade.rail` or the lower/emit pipeline
itself. The JIT lowered every in-subset program correctly and rejected
every out-of-subset program with a clean diagnostic.

## How to extend

- **Multiple attempts per problem.** Today the agent makes one LLM call.
  If lower fails, exit 1. A loop with `max_attempts` that re-prompts
  with the lower-error string ("your program failed to compile because
  X; try again") would dramatically widen the success window.
- **Test-case round-trip.** Today `main` returns an int and we print
  it. A future variant: include test cases in the problem statement
  ("for N=5, main should return 120") and have the agent verify the
  answer numerically before declaring success.
- **`try_jit_grade_str` path.** For string-output problems (the
  `print "yes"` / `print "no"` shape), wire a `--expected` flag and
  call `try_jit_grade_str` instead of `try_jit_grade`.
- **Online JIT-compatibility metric.** Once an API key is available,
  run a 30-problem evaluation: feed common int-shape problems
  (factorial, fib, sum, gcd, prime, perfect numbers, digit sum, etc.)
  and report `JIT_lower_pass / total`. That's the real "JIT
  compatibility rate" number the strategic claim wants.

## Running the smoke tests

```
./rail_native run tools/agent/test_jit_loop.rail
```

Expected last line: `PASS`. Exits 0. ~3s wall-clock total (compile +
JIT lower + 2 program executions).

For the agent itself:

```
# One-time per worktree:
bash jit/build_trampoline.sh

# Build then exercise the namespaced binary:
./rail_native tools/agent/jit_loop.rail
cp /tmp/rail_out /tmp/jit_loop_$(basename $(pwd) | head -c 8)
/tmp/jit_loop_<tag> --offline                      # canned demo
/tmp/jit_loop_<tag> --src-file some_program.rail   # raw source
ANTHROPIC_API_KEY=sk-... /tmp/jit_loop_<tag> "fib 10"   # online
```
