# Independent semantic differential testing, milestone 1

`semantic.py` complements `diff_fuzz.rail`. Its reference evaluator runs in
CPython rather than in a binary built by Rail. It imports no Rail compiler code
and uses no compiler result to calculate expected values. Python 3.10+ and the
standard library are sufficient; this is deliberately an external testing tool,
not a new Rail runtime dependency.

## Run

From the repository root on a machine that can execute `rail_native`:

```sh
python3 -m unittest discover -s tools/fuzz -p 'test_semantic.py' -v
python3 tools/fuzz/semantic.py --seed 42 --cases 50 --output /tmp/rail-semantic-42
python3 tools/fuzz/semantic.py --replay /tmp/rail-semantic-42/seed-42-case-8-tail/case.json
python3 tools/fuzz/semantic.py --seed 2026 --cases 100 --keep-going --output /tmp/rail-campaign-2026
```

The replay path is an example: use the path printed on failure. Use a fresh
output directory for each campaign; existing repros are never overwritten.
`--compiler /absolute/path/to/compiler` selects another seed, and `--repo`
selects the working directory for compiler resource lookup. This first milestone
targets native macOS ARM64, using the existing `--out-prefix` compiler interface.

Each campaign runs eight hand-written controls followed by `--cases` generated
expressions. Every expression is tested in four positions: a function's tail
body, a `show` argument, a let-bound value, and a comparison operand. The
comparison wrapper checks equality to the independently evaluated reference
integer and must print 1. This checks the whole value, not just its sign.
Thus 20 generated expressions plus
8 controls result in 112 native comparisons. Reduction and replay preserve the
failing position. Older saved cases without a position replay as arguments.
Generation is seeded, depth-limited (default 3, maximum 5), and uses
only in-scope variable names. Leaf literals are mostly in `[-10, 10]`, with one
in eight drawn from the 16-bit tagged-immediate boundary (32767, 32768, 65536,
16777216 and negatives), where ARM64 codegen has miscompiled before. Out-of-domain generated expressions are counted
and regenerated, with a bounded rejection budget. Saved ASTs are the durable
replay format; Python version and schema version are recorded.

The `semantic` CI job runs the oracle tests and a fixed seed-42 campaign of 20
generated cases plus the eight controls. Failure repros are uploaded as a CI
artifact. Larger local campaigns can use different seeds and depths.

## Specified subset

Programs are pure expressions wrapped in `main`, print exactly one integer and
a newline, then return 0. The JSON AST is independently evaluated and rendered
as Rail source. This is **an AST interpreter, not a parser for arbitrary Rail**.

- Integer literals and all evaluated arithmetic intermediates lie in
  `[-2^40, 2^40]`. Arithmetic is mathematical within that interval. Overflow is
  out of domain, not assigned wrapping semantics.
- Addition, subtraction, multiplication, signed division and remainder.
  Division truncates toward zero. Remainder is `a - trunc(a / b) * b`.
  Evaluated division by zero is out of domain.
- `if a < b then c else d` evaluates only the selected branch. A fixed control
  places division by zero in the unselected branch to check laziness.
- Nonrecursive `let`, lexical variable lookup, single-argument functions,
  first-class closures and application. Closures capture the environment at
  definition; shadowing at the call site cannot replace a captured binding.
  Call-by-value evaluation is left to right. The subset has no effects, so it
  cannot establish observable ordering of side effects.
- Integer list literals, `length`, and `head`/`tail` on nonempty lists.
- The reference interpreter has shared evaluation fuel (10,000 AST visits).
  Exhaustion is an out-of-domain condition, never a matching native timeout.

Excluded for now: floating point, integer overflow, recursion, ADTs/pattern
matching, effects, arbitrary source parsing, FFI, GC stress and cross-backend
execution. A disagreement is a **candidate** compiler, renderer, or oracle bug;
it is not automatically a confirmed miscompilation.

## Failure handling and shrinking

Every compilation gets a new temporary directory and explicit output prefix.
A zero compiler exit without a fresh executable is a compile failure. Compilation
and execution statuses are checked separately. Output comparison preserves all
bytes after UTF-8 decoding; extra stdout, nonempty stderr, and nonzero exits do
not pass because the first output line happens to match. Per-process timeouts
default to ten seconds and terminate the process group, including descendants.

By default the campaign stops at the first failure and exits nonzero (CI mode).
`--keep-going` saves every failing expression/position and completes the campaign,
then exits nonzero if any failed. Failures are not deduplicated into presumed
root causes, so a second bug is not hidden by the first; reduction budgets apply
per failure and large failing campaigns can take longer. It saves original
and minimized `.rail` files plus JSON containing both ASTs, expected/actual
results, process exits, logs, compiler SHA-256, seed and case index. Compile and
runtime failures are saved too, rather than silently excluded from success.

The reducer tries subexpressions, small constants, list deletion and recursive
replacements. It independently re-evaluates candidates, rejecting unbound,
ill-typed, or out-of-domain candidates, and preserves the original failure
category. Each accepted candidate decreases AST size or literal magnitude.
`--reduce-steps` bounds compiler trials (default 50). Reduction is greedy and
budgeted, not guaranteed globally minimal. The final candidate is rerun; if the
failure is unstable it falls back to the original and records stability.

`case.json` can be replayed after a compiler repair: exit 0 means the saved case
now agrees. Review a case before promoting it into the compiler's permanent
suite; expected values come from the independent interpreter and can be checked
by hand in the minimized source.

## Trust boundary

This adds implementation diversity, not a proof of correctness or a solution to
trusting-trust. The evaluator and generator are new code that can be wrong. Unit
tests check hand-calculated arithmetic and closure controls; injected compiler
faults check that full output, missing executables, failures, timeouts, reduction,
and replay are handled honestly. The existing broader Rail-side fuzzer remains
useful and unchanged.
