# compile.rail diagnostic-quality fixes — handoff

Branch: `worktree-agent-a7709a68069804bba` (worktree, not pushed).

## What was changed

Two "the error message lies" bugs in `tools/compile.rail`. Neither is a
correctness bug — both cost real time when hitting them in unfamiliar
territory.

### Bug A — ld_result/as_result first-line truncation (FIXED)

`trim s = head (split "\n" s)` is first-line-only. Applied to `ld`/`as`
multi-line output, it silently throws away the symbol names and the
"symbol(s) not found" sentinel.

Fix:
- Added `strip_trailing_ws` (and inner `strip_trailing_ws_loop`) near the
  existing `trim` definition (`tools/compile.rail:3704`). Walks back over
  trailing `\n` / space / `\t` / `\r` and slices with `str_sub`,
  preserving interior newlines.
- Replaced `trim` with `strip_trailing_ws` at the three multi-line
  sites that matter:
  - `compile.rail:~3662` `as_result` in `build`
  - `compile.rail:~3688` `ld_result` in `build`
  - `compile.rail:~4074` `as_res`, `~4077` `ld_res` in `self_compile`

Did NOT touch the 50+ other `trim (shell ...)` callsites that consume
single-value shell output (paths, "yes/no", "0/1", `mktemp` names);
those genuinely want the first line.

### Bug B — `./rail_native run`'s argv joined with spaces (FIXED)

`join_args lst n = join " " lst` (after dropping the first n elements).
`compile_and_run` then built `shell (cat [prefix, " ", extra, " 2>&1"])`
and let the shell re-tokenise. Quoted argv with embedded spaces were
flattened.

Fix:
- Added `shell_quote_arg`, `shell_quote_join`, `join_args_quoted` at
  `compile.rail:~4092`. Single-quote wrapping with `'\''` escape for
  embedded single quotes (POSIX standard). Empty string becomes `''`.
- Routed the `run` dispatch (`compile.rail:~6802`) through
  `join_args_quoted` instead of `join_args`.

`generate` and any future subcommands still use the old `join_args` —
unchanged.

## Before / after error messages

### Bug A — missing-symbol smoke

```
$ cat > /tmp/missing_sym.rail <<'EOF'
foreign zz_missing_symbol_for_demo x -> int
main = zz_missing_symbol_for_demo 42
EOF
$ ./rail_native /tmp/missing_sym.rail 2>&1
```

Before (HEAD):
```
Compiling /tmp/missing_sym.rail (81 chars)...
  as: OK
  ld: Undefined symbols for architecture arm64:
```

After:
```
Compiling /tmp/missing_sym.rail (81 chars)...
  as: OK
  ld: Undefined symbols for architecture arm64:
  "_zz_missing_symbol_for_demo", referenced from:
      _main in rail_build_XXX.o
ld: symbol(s) not found for architecture arm64
```

### Bug B — quoted argv smoke

```
$ cat > /tmp/argv.rail <<'EOF'
main =
  let _ = print (head (tail args))
  0
EOF
$ ./rail_native run /tmp/argv.rail "hello world" 2>&1
```

Before (HEAD): `hello`

After: `hello world`

Also handles embedded single quotes (e.g. `"can't stop"` survives intact).

## Falsification tests

Both written under the `test_*.rail` naming convention so they are
auto-discovered by `tools/test/rail_test.rail`:

- `tools/test/test_ld_error_propagation.rail` — compiles a Rail source
  declaring a fake `foreign` symbol, captures compiler stdout, asserts
  BOTH the symbol name AND the `symbol(s) not found` sentinel survived
  the trim chain.
- `tools/test/test_argv_quoted_preservation.rail` — runs three child
  invocations through `./rail_native run`: argv with space, no argv,
  argv with an apostrophe. Uses a `TAG:` prefix to disambiguate child
  stdout from the `rail_native run` driver's "Compiling..." preface.
  Asserts each round-trips intact.

Both tests verified to FAIL on the pre-fix HEAD binary and PASS on the
post-fix binary:

```
$ ./rail_native run tools/test/rail_test.rail tools/test/ 2>&1 | tail
discovered 5 test files
  FAIL exit=1  tools/test/examples/test_arith_fail.rail   # designed-to-fail example
  PASS  tools/test/examples/test_arith_ok.rail
  PASS  tools/test/examples/test_loop.rail
  PASS  tools/test/test_argv_quoted_preservation.rail
  PASS  tools/test/test_ld_error_propagation.rail
4 passed, 1 failed (3 seconds)
```

## Bootstrap log

Source-only changes — 1 cycle suffices for the source to take effect,
but I ran 3 cycles to verify the byte-identical fixed point.

```
cycle 1: ./rail_native self          → /tmp/rail_self (gen1)
cycle 2: cp /tmp/rail_self rail_native; ./rail_native self
  cmp rail_native /tmp/rail_self: differs at byte 1064552
cycle 3: cp /tmp/rail_self rail_native; ./rail_native self
  cmp rail_native /tmp/rail_self: differs at byte 1064552
```

Investigated: bytes 1064552..1072982 are inside the `LC_CODE_SIGNATURE`
load command (signature starts at offset 1064552, `fade 0cc0` magic),
i.e. the codesign hash, which is non-deterministic across invocations
on macOS.

Verified true fixed point by stripping signatures and re-comparing:

```
cp rail_native /tmp/rn_a && cp /tmp/rail_self /tmp/rn_b
codesign --remove-signature /tmp/rn_a /tmp/rn_b
cmp /tmp/rn_a /tmp/rn_b
  → "UNSIGNED BYTE-IDENTICAL"
```

The compiler is at a byte-identical fixed point (modulo macOS codesign
non-determinism, which is environmental).

## Test suite

`./rail_native test`: 136/140 — same as the pre-fix HEAD baseline.

The 4 failures are env-related (this worktree lacks `tools/metal/libtensor_gpu.dylib`,
so t105/t108/t109/t110 see `_tgl_*` undefined-symbol link errors).
**Confirmed pre-existing** by running `./rail_native test` against the
HEAD binary and seeing the same 4 failures.

Notably: those 4 failures are themselves Bug A in action — pre-fix the
test output was just `ld: symbol(s) not found for architecture arm64`
with the symbol name truncated. Post-fix the full multi-line ld error
including `_tgl_transpose_f64`, `_tgl_transpose_half_host`, etc. is
visible in the test log. (Net effect on tests: still 4 failures, but
the diagnostic quality of those failures improved.)

`diff_fuzz seed=42 n=5`: 5 agree / 0 DIVERGENCE.

## Honesty notes

- 57 callsites use `trim`; I intentionally left 54 of them alone because
  they consume single-value shell output. Audited the remaining 3
  (`as_result` x2, `ld_result` x2 — `self_compile` has its own pair)
  as the only multi-line cases.
- The argv fix is via single-quote POSIX shell quoting. This handles
  spaces, tabs, globs, $-expansions, and embedded single quotes. It
  does NOT preserve NULs or arbitrary binary in argv — but those don't
  survive libc argv either, so that's a non-issue.
- `run_test`'s `let output = trim (shell ...)` at `compile.rail:~3711`
  also truncates multi-line test stdout to its first line. I did NOT
  change it — t1..t134 currently rely on first-line-only output via
  `echo $?` at the end. Touching it would risk regressing the test
  suite. Flagged here for a future cleanup pass; out of scope for this
  fix.
- Used `git stash`/`git stash pop` to swap binaries during falsification
  testing on HEAD; restored to the fixed binary at the end.

## Deliverables

- `tools/compile.rail` — edits to add helpers and re-route 5 sites.
- `tools/test/test_ld_error_propagation.rail` — new.
- `tools/test/test_argv_quoted_preservation.rail` — new.
- `rail_native` — re-bootstrapped binary (byte-identical fixed point
  modulo signature).

No push.
