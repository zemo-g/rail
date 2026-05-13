# JIT-Agent v0 — Demo Transcript

Captured 2026-05-13 on the `feat/agent-jit-loop` branch (worktree
`/Users/user/projects/rail/.claude/worktrees/agent-a5a8afdc5111183af`).

The harness is `tools/agent/jit_loop.rail`. It is a *single Rail process*
that:

1. Reads a problem statement (positional argv, `--problem-file`, or stdin)
2. Asks the Anthropic API for a Rail program that solves it
3. JIT-compiles and executes the response via `jit/grade.rail`
4. Prints the integer result

For development without an API key, `--offline` and `--src` / `--src-file`
exercise steps 3-4 directly with canned or user-supplied Rail source. The
LLM round-trip is `--problem-file` / positional argv (online).

---

## Demo 1 — `--offline` (canned LLM response, no API)

The canned response is `fib n = ...; main = fib 10`. Verifies the JIT
pipeline end-to-end without paying for an API call.

Command:

```
/tmp/jit_loop_a5a8 --offline
```

Output:

```
rail-on-rail JIT agent v0 -- pure-Rail LLM + JIT loop
----------------------------------------------------
MODE: --offline (canned response, no API)
PROBLEM: fib(10)
--- Rail source ---
fib n = if n < 2 then n else fib (n - 1) + fib (n - 2)
main = fib 10

--- JIT lower + run ---
RESULT = 55
```

Exit code: 0. Correct: fib(10) = 55.

---

## Demo 2 — `--src` (raw Rail source, no LLM)

Skip the LLM and feed a one-liner directly. Useful for spot-checks.

Command:

```
/tmp/jit_loop_a5a8 --src "main = 7 + 13"
```

Output:

```
rail-on-rail JIT agent v0 -- pure-Rail LLM + JIT loop
----------------------------------------------------
MODE: --src / --src-file (raw Rail source, no LLM)
--- Rail source ---
main = 7 + 13

--- JIT lower + run ---
RESULT = 20
```

---

## Demo 3 — `--src-file` (multi-line program, JIT-subset)

A real-shaped program (Euclid's GCD), supplied via file. Verifies the JIT
handles recursion + `mod`.

`/tmp/p3_gcd.rail`:

```
gcd a b = if b == 0 then a else gcd b (mod a b)
main = gcd 1071 462
```

Output:

```
rail-on-rail JIT agent v0 -- pure-Rail LLM + JIT loop
----------------------------------------------------
MODE: --src / --src-file (raw Rail source, no LLM)
--- Rail source ---
gcd a b = if b == 0 then a else gcd b (mod a b)
main = gcd 1071 462

--- JIT lower + run ---
RESULT = 21
```

Correct: gcd(1071, 462) = 21.

---

## Demo 4 — Multi-function program (`is_prime`)

`/tmp/p4_prime.rail`:

```
divides_any n d = if d * d > n then 0 else if mod n d == 0 then 1 else divides_any n (d + 1)
is_prime n = if n < 2 then 0 else if divides_any n 2 == 1 then 0 else 1
main = is_prime 97
```

Output:

```
rail-on-rail JIT agent v0 -- pure-Rail LLM + JIT loop
----------------------------------------------------
MODE: --src / --src-file (raw Rail source, no LLM)
--- Rail source ---
divides_any n d = if d * d > n then 0 else if mod n d == 0 then 1 else divides_any n (d + 1)
is_prime n = if n < 2 then 0 else if divides_any n 2 == 1 then 0 else 1
main = is_prime 97

--- JIT lower + run ---
RESULT = 1
```

Correct: 97 is prime.

---

## Demo 5 — Fence-stripped input

What the model is *supposed* to output (per `system_prompt.txt`) is raw
Rail, no fences. The agent strips backtick fences as defense in depth so
a sloppy model response can still JIT.

`/tmp/p_with_fence.txt` (literal contents — note the fences):

```
` ` `rail
double n = n * 2
main = double 21
` ` `
```

(Backticks shown spaced for markdown rendering; the actual file has
unbroken triple-backtick fences.)

Output:

```
rail-on-rail JIT agent v0 -- pure-Rail LLM + JIT loop
----------------------------------------------------
MODE: --src / --src-file (raw Rail source, no LLM)
--- Rail source ---
double n = n * 2
main = double 21

--- JIT lower + run ---
RESULT = 42
```

---

## Demo 6 — Online round-trip (NOT RUN — no API key on this host)

The script for the online demo, if a key were available, would be:

```
export ANTHROPIC_API_KEY=...           # or supply --key-path /path/to/keyfile
./rail_native tools/agent/jit_loop.rail
cp /tmp/rail_out /tmp/jit_loop_<host>
/tmp/jit_loop_<host> "factorial of 8"
```

Expected transcript shape (based on the system prompt's example outputs):

```
rail-on-rail JIT agent v0 -- pure-Rail LLM + JIT loop
----------------------------------------------------
MODE: online (Anthropic API)
PROBLEM: factorial of 8
--- Rail source ---
fact n = if n < 2 then 1 else n * fact (n - 1)
main = fact 8

--- JIT lower + run ---
RESULT = 40320
```

Online wall-clock (estimated): ~1-3s for the Anthropic HTTPS call
(`claude-haiku-4-5-20251001` default), <50ms for lower+JIT+exec. Total
end-to-end inside a single Rail process.

Cost estimate (per request): ~1500 input tokens (system prompt + user
prompt) + ~80 output tokens = ~$0.0007 per request on Haiku 4.5 at
current pricing.

---

## Out-of-subset rejection (5/5 cleanly fail)

To validate that the JIT lowerer (not just the prompt) is the gatekeeper,
five intentionally-out-of-subset programs were fed via `--src-file`:

| Program shape                | Lower error                                           |
| --- | --- |
| `map`/`filter`/`fold` + list literal | `lower failed`                            |
| `fold add 0 [1,...]`         | `lower failed`                                        |
| ADT + `match`                | `primary: unexpected token tag=pipe`                  |
| `\x -> x + 1` + `|>`         | `fn_def: expected ident, got tag=pipe`                |
| `length "hello"`             | `lower failed`                                        |

All 5 were correctly refused with diagnostic `JIT FAIL: lower: ...`
messages and exit code 1. The lowerer is doing its job — it will keep
the agent honest when the LLM strays outside the subset.
