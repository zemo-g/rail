# JIT-grade fast-path for substrate hard-bench — handoff

Date: 2026-05-13
Branch: `feat/bench-jit-grade-fastpath` (based on `next` @ `def1bcd`)

## TL;DR

JIT-first batch grader wired into `tools/bench/repro_anthropic.py` via a
`--jit-fast` flag. On a synthesized 30-prompt × N=20 grading workload the
JIT path measures **1.18× faster wall-clock** than shell-only (101.75s →
86.18s). **JIT lower-hit: 14.2% (170/1200 candidates).** Modest win that
doesn't unlock what the comparable `harvest_teacher` integration did
(2.06×, 32.4%). Both findings explained below.

## Files touched

- `tools/bench/jit_grade_batch.rail` — NEW. Pure-Rail batch grader. Reads a
  manifest of candidate paths, JIT-lowers each via `jit_can_lower` from
  `jit/grade.rail`; on fail falls back to shell-grade via `./rail_native`.
  Emits `JIT_PASS:<path>` / `SHELL_PASS:<path>` / `FAIL:<path>` per
  candidate plus a `SUMMARY:<jit_pass>,<shell_pass>,<fail>,<total>` trailer.
- `tools/bench/repro_anthropic.py` — added `--jit-fast` flag, `ensure_jit_batch_bin()`
  helper, `grade_completion_batch_jit()` per-prompt batch path. Shell-only
  path is unchanged when `--jit-fast` is not set.
- `tools/bench/time_jit_grade.py` — NEW. Grading-only timing harness using
  pre-canned completions so the measurement is decoupled from Anthropic
  API jitter and cost.
- `tools/bench/test_jit_grade_parity.rail` — NEW. Falsification test that
  the batch grader's `JIT_PASS` verdict implies `rail_native exit=0` (i.e.,
  every fast-path-marked candidate is genuinely accepted by the canonical
  compile).

## Measured wall-clock (honest)

Grading-only timing on synthesized completions for all 30 bench prompts
× N=20 reranks (1200 candidate variants total, since each completion
contributes both `stripped` and `prompt+stripped` files):

```
shell-only:    101.75s
jit-fast:       86.18s     (1.18x speedup)
```

Run on an M1 Ultra (2x concurrent agents also running rail_native
during the measurement; both paths likely degraded equally). No
Anthropic API was used — `time_jit_grade.py` synthesizes deterministic
completions per prompt so the measurement is pure grading throughput.

**The real bench is API-bound, not grade-bound.** Full repro of
`repro_30of30.sh` is ~15-20 min wall-clock dominated by ~600 Anthropic
calls. The grading step is ~1-2 min of that. Even an infinite speedup on
grading would only shave a couple of minutes off the public reproduction.
The `--jit-fast` flag is wired correctly and works, but does not
materially change the public-reproduction wall-clock.

## JIT lower-hit %

```
synthesized bench candidates: 1200 total
  JIT_PASS  (jit_can_lower=1):    170   ( 14.2% )
  SHELL_PASS (rail_native ok):    210   ( 17.5% )
  FAIL      (neither):            820   ( 68.3% )
```

The synthesized completions include many "stub" forms that don't fully
compile under either path, hence the ~68% FAIL share. **On hand-curated
canonical completions** for the bench's success shapes, lower-hit is
higher — `test_jit_grade_parity.rail` exercises 15 bench-shaped programs
and the JIT lowers **6 of 15 (40%)**. The 5 fundamental-band programs
(fact, add, square_sum, fib, triangular) all lower; IO/tools/comp/adv
bands typically don't because their canonical solutions use HOFs
(`fold`/`map`/`filter`), string builtins (`split`/`join`), or ADT
constructors that fall outside the JIT v1 subset.

## Why the speedup is smaller than `harvest_teacher`'s 2.06×

1. The bench corpus is concentrated around HOF/ADT/string patterns where
   the JIT subset is thinnest. `harvest_teacher` works over a larger,
   more varied corpus that includes more int-arith / recursion programs
   the JIT can lower.
2. The bench's `grade_completion` already double-grades each completion
   (stripped + prompt+stripped variants), so per-completion shell cost
   is ~2× higher in absolute terms, but the JIT path has to grade both
   too. Speedup ratio is preserved, not amplified.
3. ~68% of candidates fail under both paths (synthesized "stub"
   completions), forcing the JIT path to also shell-grade them — no win
   on those.

## Soundness finding (the parity test caught a real divergence)

Initial implementation used `jit_can_lower=1` as the `JIT_PASS` predicate
directly. `tools/bench/test_jit_grade_parity.rail` immediately falsified
this: the program

```rail
main = if str_eq "abc" "abc" then 1 else 0
```

`jit_can_lower` returns 1 (JIT supports `str_eq` as a builtin), but
rail_native rejects it (`str_eq` is not a rail_native builtin — rail
programs use `==` for string equality). Marking such a candidate as
`JIT_PASS` would silently inflate the bench score.

**Fix**: `jit_grade_batch.rail` ships a `contains_unsafe_jit_builtin`
guard that refuses the JIT fast path for any source containing the
JIT-only tokens `str_eq`, `str_len`, `str_at`, or `is_nil`. Such
candidates always fall through to shell-grade. The parity test now
explicitly exercises this guard with `c_streq_guard` and asserts the
batch grader's `JIT_PASS` verdict is sound against rail_native across
both handcrafted and bench-shaped corpora. Test PASSes.

## Per-task usage

Reproduce the timing measurement:
```bash
python3 tools/bench/time_jit_grade.py --n 20
```

Run the parity falsification:
```bash
./rail_native run tools/bench/test_jit_grade_parity.rail
```

Use the JIT-fast path in the real bench (requires `ANTHROPIC_API_KEY`):
```bash
ANTHROPIC_API_KEY=sk-ant-... python3 tools/bench/repro_anthropic.py --jit-fast
```

The shell-only path remains the default; `--jit-fast` is opt-in.

## JIT-side observations (file as bugs against `jit/`; do NOT fix here)

1. `jit/lower.rail` always prints `LOWER ERR: ...` to stdout on failed
   lowering, even when the failure is expected (e.g. callsite asks
   `lower_source` whether something lowers as a probe). This noise leaks
   to the batch grader's stdout and forces consumers to filter on the
   `JIT_PASS|SHELL_PASS|FAIL|SUMMARY` line prefixes. Quieting these would
   be a small UX win for harness integrations.
2. `jit_can_lower` accepts string-builtin programs (`str_eq` etc.) that
   rail_native doesn't compile. The JIT subset is not a strict subset of
   the rail_native compile envelope. For users who want
   `jit_can_lower → rail_native_ok`, the JIT-side fix would be either
   (a) lift the JIT-only builtins out of the lowering subset, or (b)
   ship a stricter `jit_can_compile` predicate that checks for
   rail_native-only-foreign builtins before returning 1. We worked
   around this with the guard in `jit_grade_batch.rail`, but the
   underlying invariant gap is a real JIT-side concern.

## Build prerequisites

- `jit/libjit_call.dylib` must be built (`bash jit/build_trampoline.sh`).
  Both `jit_grade_batch.rail` and `ensure_jit_batch_bin()` rely on it
  being linked (rail_native picks it up via `-weak-ljit_call`, so missing
  dylib silently links but crashes at JIT-call time).
- macOS native ARM64 only; the JIT pipeline is `mmap` + `pthread_create`
  + Apple `sys_icache_invalidate`. Linux ARM64 / x86_64 cross-compile
  not addressed.

## Status

Shipped: batch grader, harness integration, falsification test, timing
harness, this handoff. **No production-ship of the JIT fast path on the
public `repro_30of30.sh` driver.** The driver still picks shell-only by
default; opt in with `--jit-fast` when invoking `repro_anthropic.py`
directly. The win on the public bench is small (~15s out of ~15-20 min)
and the JIT subset gap is real, so flipping the default is not
recommended without a wider JIT subset.
