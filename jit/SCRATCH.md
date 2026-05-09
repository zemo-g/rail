# SCRATCH — negative-int op_print_int dry run 2026-05-09

## Spec claim

`jit/README.md` caveat #6: "`op_print_int` of negative ints — currently
the divide-by-10 loop assumes `n >= 0`. Negative inputs would behave
incorrectly. v2: detect sign, emit `-` prefix."

## Hypothesis

The spec's premise is FALSE on tip-of-tree (HEAD = d884166). Negative-int
printing already works. README.md caveat #6 is stale documentation; the
fix landed silently in a prior session. Evidence:

1. `jit/test_capture.rail:33` — fixture `print_neg`:
   `"main = print (show (0 - 5))"` expects `"-5\n"`. Reported PASS in
   tonight's baseline run (`ALL CAPTURE PASS`).
2. `jit/CONTINUATION.md:498` — "Negative-int `op_print_int`" listed under
   "What's stable today (do NOT regress)".
3. `jit/emit.rail:846` — `emit_print_int_impl` doc comment: "Handles
   negative ints, writes digits to a stack-local scratch buffer..."
4. `jit/emit.rail:864-873` — explicit sign-detection prologue:
   - `mov x21, #0` (sign flag = 0)
   - `cmp x12, #0`
   - `b.ge +3` (skip neg setup)
   - `mov x21, #1` (sign flag = 1)
   - `neg x12, x12` (absolute value)
5. `jit/emit.rail:898-905` — conditional `-` prepend after digit loop:
   - `cbz x21, +3 inst` (no_minus)
   - `sub x10, x10, #1`
   - `mov w15, #45` (ASCII '-')
   - `strb w15, [x10]`

## Falsification

Cheapest test: add the spec's DONE-CRITERION fixtures verbatim to
`jit/test_capture.rail` and run. If they pass without any `emit.rail`
edit, the hypothesis stands and the feature is already shipped. If they
fail, the existing `print_neg` fixture must be a measurement bug
(suspect: runner accepts ERR as PASS, or cap'd at first-N fixtures).

## Action

1. Add `print_neg_42` (`-42\n`), `print_neg_1` (`-1\n`), and the
   `print_zero` boundary preserves (already covered by existing `r2`).
   The positive regression guard is also already covered by `r1`.
2. Run test_capture.rail. Expected: ALL CAPTURE PASS.
3. Run full sweep + parity_check.
4. If green: surface to user — feature was already complete. No commit
   beyond fixtures (regression guard).
5. If red: actual bug; pivot to impl.

## Non-falsification (separate)

The spec mentions caveat #6 in README. README also has caveat #5
(`emit_const` sign-extension for high-chunk movks) which is explicitly
out of scope. Don't conflate.
