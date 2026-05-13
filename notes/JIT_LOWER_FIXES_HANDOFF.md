# JIT lower.rail fixes — handoff (2026-05-13)

**Branch**: `fix/jit-lower-multiline-silent-soundness` (local only; not pushed)
**Scope**: three bugs filed by parallel-agent sessions on the JIT (`jit/`).
**Bootstrap**: NO `compile.rail` change → no `./rail_native self` needed.

## Summary

| Bug | File touched | LOC | Behavior change |
|---|---|---|---|
| A — multi-line `let` rejected | `jit/syntax.rail` | +7 | `main =\n  let _ = ...\n  body` now lowers |
| B — `LOWER ERR` stdout pollution | `jit/lower.rail` | ~25 net | `lower_source` is silent; err msg flows through return tuple |
| C — `jit_can_lower` unsound | `jit/grade.rail` | +14 | Returns 0 for programs using `str_eq`/`str_len`/`str_at`/`is_nil` |

3 new falsification tests, 0 pre-existing tests regressed.

## Bug A — multi-line `let` parser

**Root cause**: `parse_fn_body` in `jit/syntax.rail` called `parse_expr toks`
directly without `skip_nls` first. After consuming `=`, the next token in
`main =\n  let _ = ...` is `nl`, and `parse_primary` immediately bailed with
`"primary: unexpected token tag=nl"`.

The parser already supported newline-as-implicit-`in` via `parse_let_in`
(line ~203, `if (is_nl toks) == 1`). The bug was only at the function-body
entry point.

**Fix**: Insert `let toks_body = skip_nls toks` at the top of
`parse_fn_body` and parse from there.

**Before** (canonical newline form fails):
```
$ ./rail_native run /tmp/jit_bugA_repro.rail
--- multi-line ---
tag = err msg=primary: unexpected token tag=nl
--- multi-leading-nl ---
tag = err msg=primary: unexpected token tag=nl
```

**After**:
```
--- multi-line ---
tag = ok msg=
--- multi-leading-nl ---
tag = ok msg=
--- multi-many ---
tag = ok msg=
```

**Falsification**: `jit/test_multiline_let.rail` covers 5 shapes
(`bare_nl_body`, `single_let_nl`, `two_lets_nl`, `print_then_int`,
`mixed_in_nl`). All five lower AND execute through the JIT.

## Bug B — `LOWER ERR` stdout pollution

**Root cause**: `st_fail s msg` (in `jit/lower.rail`) called
`print (cat ["LOWER ERR: ", msg])` directly. `mk_err_fn msg` did the same
with `"lower failed (see prior LOWER ERR)"`. Both pollute the harness
stdout when callers use `lower_source` / `try_jit_grade` programmatically.

The state record allocated `err_msg = cons "" []` with a comment saying
"Rail lists are immutable, so we store the err in the err_msg cell via a
different slot. For v1, we just print the err and rely on err_flag." That
side-channel was never used.

**Fix**: Convert `err_msg` to a 1-element mutable Rail array (same pattern
as `stdlib/https_session.rail:64`). `st_fail` stores the first message via
`arr_set err_msg 0 msg` and no longer prints. A new helper
`mk_err_fn_from_state s fallback` reads the captured message and threads
it into the `["err", msg]` return tuple. Only the FIRST error is captured
(deepest `st_fail`); later boilerplate doesn't overwrite the root cause.

**Before** (every failed lowering prints two lines to stdout):
```
LOWER ERR: lower: unbound variable x
LOWER ERR: lower failed (see prior LOWER ERR)
after-call tag=err
```

**After**:
```
after-call tag=err
```

And the err message now propagates the root cause instead of the boilerplate:
```
tag=err | msg=lower: unbound variable x
```

**Falsification**: `jit/test_lower_silent.rail` has three checks:
1. **in-proc**: err tuple carries a non-empty, non-boilerplate message.
2. **sub-proc**: spawn rail_native on a tiny driver, capture full stdout
   to file, assert `"LOWER ERR"` does NOT appear.
3. **msg content**: err message contains `"unbound variable"` (the actual
   root cause from `st_fail`).

All three pass.

## Bug C — `jit_can_lower` unsound for `str_eq` / `str_len` / `str_at` / `is_nil`

**Root cause**: `jit_can_lower` reported `1` (lowerable) for programs the
JIT happily lowers but `rail_native` rejects at link time
(`ld: Undefined symbols`). The four offenders today: `str_eq`, `str_len`,
`str_at`, `is_nil`. rail_native uses `==`, `length`, `str_sub`, and ADT-style
`match | nil -> ... | cons h t -> ...` instead.

The bench-grade agent had to add a `contains_unsafe_jit_builtin` guard
in `tools/bench/jit_grade_batch.rail` to work around. That workaround
stays as defense-in-depth.

**Fix**: Add a `contains_rail_native_incompatible_builtin` substring guard
inside `jit_can_lower` itself, before calling `lower_source`. The guard
mirrors the bench-grade list and is documented to be kept in sync with it.

**Caveat**: Naive substring matching has false positives. A program
containing the literal string `"is_nil_helper"` (e.g. in a comment or
string literal) will trip the guard and fall through to shell-grade.
That's the safe failure mode — preferred over silently mismarking real
failures as passes. A cleaner long-term fix is to align the JIT's builtin
set with rail_native's, but that's out of scope here.

**Before**:
```
--- str_eq ---
jit_can_lower=1                              # BUG: claims it lowers
rail_native exit: 1                          # ...but rail_native rejects
```

**After**:
```
--- str_eq ---
jit_can_lower=0
rail_native exit: 1
```

**Falsification**: `jit/test_can_lower_soundness.rail` asserts
`jit_can_lower == 0` for 5 programs (one per offender + one with the
offender in a helper fn rather than `main`) AND `jit_can_lower == 1`
for 3 known-good programs (sanity that the predicate is still useful).
All 8 checks pass.

## Test results

| Test | Before | After |
|---|---|---|
| `jit/test_lower.rail` | ALL LOWER PASS (with LOWER ERR noise) | ALL LOWER PASS (clean) |
| `jit/test_codegen.rail` | ALL PASS | ALL PASS |
| `jit/test_opt.rail` | 29/29 | 29/29 |
| `jit/test_print.rail` | PRINT OK | PRINT OK |
| `jit/test_parse.rail` | 5/5 PASS | 5/5 PASS |
| `jit/test_enc.rail` | ENC OK | ENC OK |
| `jit/test_capture.rail` | ALL CAPTURE PASS | ALL CAPTURE PASS |
| `jit/test_encoders.rail` | 39/39 MATCH | 39/39 MATCH |
| `tools/test/repl_jit_smoke.rail` | PASS 11/11 | PASS 11/11 |
| `tools/test/repl_jit_pipe_smoke.rail` | PIPELINE PASS | PIPELINE PASS |
| `tools/bench/test_jit_grade_parity.rail` | PARITY OK | PARITY OK |
| **NEW** `jit/test_multiline_let.rail` | (5 shapes failed) | PASS 5/5 |
| **NEW** `jit/test_lower_silent.rail` | (LOWER ERR on stdout) | PASS 3/3 |
| **NEW** `jit/test_can_lower_soundness.rail` | (5 false positives) | PASS 8/8 |

`jit/test_lex_check_lower.rail` was failing before AND after my changes
(unrelated `caller-save vreg overflow >9 simultaneously live` issue —
not touched, not regressed; err message is now slightly more informative
because Bug B's fix surfaces the root-cause message instead of the
boilerplate).

## Files

- Modified: `jit/syntax.rail`, `jit/lower.rail`, `jit/grade.rail`
- Added: `jit/test_multiline_let.rail`, `jit/test_lower_silent.rail`,
  `jit/test_can_lower_soundness.rail`
- Untouched (per scope): `tools/compile.rail`, `stdlib/`, `tools/repl_jit.rail`,
  `tools/bench/jit_grade_batch.rail`, `tools/agent/jit_loop.rail`

## Out-of-scope notes (for follow-up)

- The right long-term fix for Bug C is to align JIT and rail_native builtin
  sets, not maintain two parallel blacklists. Either teach `rail_native` the
  4 missing builtins (cheaper at the link layer — add stubs to `rt_string` /
  `rt_list`), or have the JIT desugar them at lower time. Today's
  defense-in-depth (guard in both `jit_can_lower` AND
  `tools/bench/jit_grade_batch.rail::contains_unsafe_jit_builtin`) keeps
  the fast path sound while that decision pends.
- `jit/test_lex_check_lower.rail` (pre-existing failure) — `caller-save vreg
  overflow` in the `ascii_ok` recursive helper. Looks like the lowerer is
  running out of caller-save slots inside the nested `if`-cascade in the
  packed-arg form. Out of scope for this task; flagging for a follow-up.
