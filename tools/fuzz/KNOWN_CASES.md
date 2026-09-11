# Known miscompiles and surprising semantics: the target list for semantic testing

`tools/fuzz/known/` holds one small program per case and `cases.json` its
status, expected output, and a one-line cause. `tools/fuzz/known_cases.py`
runs them all against a compiler and exits 0 iff every fixed case passes and
every live case still fails (a live case that starts passing is reported as
PROMOTE so its status gets updated rather than the pass going unnoticed).

Statuses were measured on 2026-09-07 against the master seed, not copied from
notes, and re-measured after the consolidation fixes the same day. Older notes about several of these lived only in a private
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
| `char_from_int_nul` | a 0x00 byte through join, +, cat, chars | dropped: those routines measure with strlen. Their results live outside the GC arena on purpose (the compiler resets arena windows while holding strings); a length-tagged in-arena version passed the suite at gen 1, which still ran on the old runtime, and wedged the compiler at gen 2. Needs a representation decision. Binary travels as hex or int arrays. |

Closed on 2026-09-07 (kept below as regression templates): the two float
result-composition cases, head/tail on a non-list, constants outside the
immediate range in tail self-call arguments, wrong-arity calls (now a compile
error), and `++` (never an operator; the parser now
says so). Wrong-arity programs are out of domain for the oracle: the compiler
refuses them.

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
| `float_result_compose_bare`, `float_result_square_bare` | `mul2 a b = a * b` (float only from call sites), result composed into a second bare-operator fn | 2026-09-07, t193: a second call-site round after the param-aware float-return pass |
| `selfloop_bigconst`, `selfloop_addbig` | constants above 65535 (`*`, `/`) or 4095 (`+`, `-`) as tail self-call arguments; the first was silently wrong, the second refused by the assembler | 2026-09-07, t194: every constant through the register loader, no bail to the fallback |
| `under_application`, `over_application` | wrong number of arguments to a top-level fn | 2026-09-07: compile error from the arity check in `compile_checked` |
| `float_param_bare_mul_lsb` | `mul2c a b = a * b` called with floats | 2026-09-07, t197: the raw-register param convention was chosen syntactically and could not see the call-site float proof, so floats were untagged and retagged as ints, 2 ulp high. Hidden for months by 15-digit printing; found within an hour of bit-exact comparison |
| `selfloop_compound_arg`, `selfloop_literal_arg` | a tail self-call argument the direct lowering cannot express (`(acc + 2) / 3`, `(n - 1) * 1`, a let-bound value) and a plain literal argument | 2026-09-11, t206 (findings F-1003-22/901/902/903): the bottom-test loop refuses unless every argument is direct, the fallback stacks and untags the general values, the literal loads raw |
| `string_ordering` | `<` `>` `<=` `>=` on two strings, both let orders, cat-built operands | 2026-09-11, t207 (F-5000-3): the runtime routines had no string branch and compared offset 8 of each object; they now dispatch like `_rail_eq` |
| `string_param_plus` | a 1..3-param fn using only `+` or an ordering op on its params, called with strings | 2026-09-11, t208 (F-5000-1): `used_in_arith` counted the string-polymorphic `+` as int evidence; the call-site proof (argf slot 3 or 0) now vetoes raw registers, the syntactic int mark and the early-return raw compare |
| `frame_sibling_lets` | five sibling lets in one list literal; lets beside applied lambdas | 2026-09-11, t209 (F-1002-114): `max_sl_list` threads siblings cumulatively, and compile_func re-sizes the frame from the slot cg actually reached |
| `float_from_container` | a float out of a tuple, a list, an ADT field, with bare and dotted operators, comparisons, through a 2-param fn | 2026-09-11, t210 (F-5000-2): the float representation boundary (a raw float entering a generic location is boxed; a generic value read as a float goes through `_rail_fval`) |
| `mixed_int_from_fn` | `0.1 - (gint 0)`, `2^52 - (length [0])` | 2026-09-11, with the boundary above: a generic operand of a float op is read through `_rail_fval`, which converts a tagged int instead of reinterpreting its bits. `semantic.py` generates mixed arithmetic by default since then (`--no-mixed` restores the old grammar) |

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
| `concat_in_let` | `++` is not an operator anywhere in Rail; strings concatenate with `+` or `join "" [..]`; since 2026-09-07 the parser says exactly that |
| `head_on_string` | `head`/`tail` walk cons cells only; a string, tuple, or other heap object yields 0 / `[]` like an empty list (was SIGSEGV before 2026-09-07, t195) |

Also: ints are 63-bit tagged (`n * 2 + 1`); overflow wraps at 63 bits, which
`semantic.py` excludes by bounding values at 2^40. `head []` is 0 and `tail []`
is `[]` by design.

## Out of scope for a semantic oracle (listed so they are not rediscovered)

FFI: a `foreign` returning a pointer as `int` gets tagged and corrupted; use the
builtin allocator. `foreign sleep` is int-only. GPU: an in-place tensor mutation
between two GPU matmuls is invisible to the second. Backends: the x86_64 backend
carries the same top-level-const guard as ARM64 (`x86_emit_rcx`, `both_s` with
`cl_local_v`) and x86-64 `mov r64, imm64` takes any immediate, but nothing here can
run or even assemble x86_64 since the last x86 machine left, so it is unverified
rather than known-broken; WASM is fragile. Performance, not
semantics: `length xs == 0` is O(N) per call, a top-level float const reference
is a runtime `atof` on every evaluation, the bump arena has a cliff for repeated
TLS handshakes. Runtime: `read_file` on a missing path leaks and later hangs;
`shell` inherits no environment; `\r` cannot be written as a literal.
