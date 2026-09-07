# Known miscompiles and surprising semantics: the target list for semantic testing

`tools/fuzz/known/` holds one small program per case and `cases.json` its
status, expected output, and a one-line cause. `tools/fuzz/known_cases.py`
runs them all against a compiler and exits 0 iff every fixed case passes and
every live case still fails (a live case that starts passing is reported as
PROMOTE so its status gets updated rather than the pass going unnoticed).

Statuses were measured on 2026-09-07 against the master seed after #66, not
copied from notes. Older notes about several of these lived only in a private
memory index; this directory is now the shared record.

## Why this list exists

`semantic.py` found nothing in 116 cases while every probe was rendered as an
argument to `show`. Rendered as a function body instead, it found `lit_neg_cmp`
in 14. Rail's codegen bugs cluster by **position** (function tail, comparison
operand, tail self-call argument, let-bound value crossing a call) and by
**type inference across calls** (float-ness known only from call sites), not
by expression shape. A generator that covers expression shapes in one position
will keep reporting green. Each case below is a template: the generator should
be able to emit its shape, and the oracle should predict its expected output.

## Live cases (targets)

| Case | Shape | What happens |
|---|---|---|
| `float_result_compose_bare` | `mul2 a b = a * b` (bare ops, float-ness only from call sites); `let y = mul2 0.5 0.25` then `mse y 1.0` | 5.27e+36. The callee's return type is never inferred float, so the consumer's param is treated as int bits. Dotted ops (`*.`) in either function fix it; t140 passes only because its `relu` has a `0.0` literal seeding the lattice. |
| `float_result_square_bare` | same, one-param consumer `sq y = y * y` | 1.4e+306 |
| `head_on_string` | `head "abc"` | SIGSEGV. Strings are not cons lists; `chars` first. |
| `char_from_int_nul` | `join "" ["A", char_from_int 0, "A"]` | length 2, the NUL is dropped: strings are strlen-bounded. Binary must travel as hex. |
| `under_application` | 3-param fn called with 2 args | runs with a garbage third param (no closure, no error) |
| `over_application` | 2-param fn called with 3 args | runs with the extra arg dropped |
| `concat_in_let` | `let s = "ab" ++ "cd"` | parse error; `++` only in return position |

The two float cases are the ones a differential oracle can find more of:
milestone 2 should generate float user functions with bare operators whose
float-ness comes only from call-site literals, and compose their results
through a second function. The arity cases are a language decision (Rail has no
arity check); the oracle should treat wrong-arity programs as out of domain
until that changes.

## Fixed cases (regression templates; the generator should reach each shape)

| Case | Shape | Fixed |
|---|---|---|
| `lit_big_tail` | int literal >= 32768 as a function's return value | f851882 |
| `lit_big_cmp` | int literal >= 32768 as a comparison operand | f851882 |
| `lit_neg_cmp` | large negative folded constant as a comparison operand in a user fn | #66 |
| `early_return_labels` | two early-return functions in one program | #66 |
| `selfloop_crossdep` | tail self-call where a new arg reads another arg updated in the same call | 6a8551a |
| `selfloop_constmul` | `d * 4` as a tail self-call argument | 6a8551a |
| `selfloop_div` | `n / 2` as a tail self-call argument | 6a8551a |
| `float_acc_reads_index` | float accumulator whose update indexes arrays by the loop counter | 2026-06 |
| `float_arr_new_bare_var` | bare int var as `float_arr_new` length | 2026-06 |
| `dotted_ops_real` | `+.` on let-bound floats | ee1608f |
| `toplevel_const_sub` | `period - dt` with top-level consts | 2026-05-14 |
| `filter_lambda` | `filter (\x -> ...)` | 2026-05 |
| `wide_mixed_params` | 22-param self-loop, int next to float | passes in this shape; original was inside a training loop |
| `float_params_callsite` | float params inferred from call sites: arithmetic, int-into-float, arity 5 | t137, t139 |

The self-loop family is the richest template: tail self-recursion with 1 to 3
int params in registers, argument expressions that read other params, constant
multiplies, division and modulo. The literal family needs values on both sides
of 32767 and their negatives, in tail, comparison, and argument positions.

## Defined semantics the oracle must model, not flag

| Case | Rule |
|---|---|
| `and_or_eager` | `&&` and `||` evaluate both sides; no short-circuit |
| `div_mod_truncate` | `/` truncates toward zero; `%` takes the dividend's sign |
| `split_single_char` | `split` uses only the first character of its delimiter |

Also: ints are 63-bit tagged (`n * 2 + 1`); overflow wraps at 63 bits, which
`semantic.py` excludes by bounding values at 2^40. `head []` is 0 and `tail []`
is `[]` by design.

## Out of scope for a semantic oracle (listed so they are not rediscovered)

FFI: a `foreign` returning a pointer as `int` gets tagged and corrupted; use the
builtin allocator. `foreign sleep` is int-only. GPU: an in-place tensor mutation
between two GPU matmuls is invisible to the second. Backends: the x86_64 backend
still has the pre-f851882 literal bug; WASM is fragile. Performance, not
semantics: `length xs == 0` is O(N) per call, a top-level float const reference
is a runtime `atof` on every evaluation, the bump arena has a cliff for repeated
TLS handshakes. Runtime: `read_file` on a missing path leaks and later hangs;
`shell` inherits no environment; `\r` cannot be written as a literal.
