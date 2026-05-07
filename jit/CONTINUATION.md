# JIT — continuation roadmap

State at end of session 2026-05-07: branch `jit` on `next`.
**P4 (floats) shipped 2026-05-07** on top of the 2026-05-06 stack
(P0 / P1 / P2 / P3-variant / P3-full v1 / P5 / P6).

All baselines hold:
- `jit/test_lower.rail`: 87 positive + 3 negative (12 new float fixtures).
- `jit/test_capture.rail`: 23 positive + 1 negative (8 new float fixtures).
- `jit/parity_check.rail`: PARITY OK.
- `./rail_native test`: 137/137.

DONE CRITERION:
`try_jit_grade_str "main = print (show (3.14 * 2.0))" "6.28\n"` returns
`["jit_pass"]`. Same for fadd/fsub/fmul/fdiv, int→float promotion,
float compare, conditional float (`if cond then f1 else f2`).

---

## P0 — Output capture ✅ SHIPPED 2026-05-06

Implementation: option (b), memory-buffer write.

**Heap layout** (in 64 KB mmap'd page; updated 2026-05-07 for P4):

| Range | Purpose |
| --- | --- |
| `heap[0..7]`        | bump pointer for cons cells (real addr) |
| `heap[8..15]`       | output cursor for op_print_*  (real addr) |
| `heap[16..23]`      | reserved (alignment) |
| `heap[24..31]`      | absolute address of `jit_print_float` (P4) |
| `heap[32..16415]`   | output buffer (~16 KB; first byte = R+32) |
| `heap[16416..]`     | cons cell area (~48 KB) |

**Function frame layout** (64 bytes; bumped 48→64 by P4-ext):

| Range | Purpose |
| --- | --- |
| `[sp+0..15]`        | stp x29, x30 (FP, LR) |
| `[sp+16..31]`       | stp x19, x20 (int callee-save) |
| `[sp+32..39]`       | x27 (heap addr; ABI v2 callee-save) |
| `[sp+40..47]`       | pad (alignment) |
| `[sp+48..63]`       | stp d8, d9 (float callee-save; P4-ext) |

**Print op emission** (`jit/emit.rail`):
- `op_print_int`: 116 → 136 bytes (29 → 34 inst). The `svc write(1, …)`
  block was replaced by a 9-instruction copy loop that appends bytes at
  `[x27, #8]` and advances the cursor.
- `op_print_str`: 20 → 44 bytes (5 → 11 inst). Same shape: load cursor,
  byte-copy loop, store cursor.

**Frame extension** (consequence of x27 use): every function's prologue/
epilogue grew from 16 → 20 bytes to add `str x27, [sp, #32]` /
`ldr x27, [sp, #32]`. x27 was previously clobbered by every prologue's
`mov x27, x0`; now only main does that, while non-main functions emit a
NOP placeholder so size stays uniform. Result: x27 propagates through
the call chain as callee-save, so any op (cons/print) that needs heap
finds it correctly.

**Reader** (`jit/loader.rail`): `read_jit_output h` returns the captured
bytes as a Rail string (via `byte_at` + `char_from_int` + `cat`).
Companion: `jit_output_len h`, `reset_jit_output h`.

---

## P1 — Distill-integration helper ✅ SHIPPED 2026-05-06

`jit/grade.rail` exports:

```rail
try_jit_grade_str src expected
  -> ["jit_pass"]                 -- captured stdout == expected
  -> ["jit_fail", actual_stdout]  -- ran cleanly but mismatched
  -> ["err", reason]              -- couldn't lower (use shell fallback)

jit_grade_str src expected -> 1 | 0    -- same, returns int
```

The training session's rollout loop is now a one-liner. Sub-ms grade
per candidate that lowers (vs ~100 ms shell grade).

Verified end-to-end via `jit/test_capture.rail` (11 fixtures incl.
labeled output, sequencing, negative case).

---

## P6 — Direct call (perf lever) ✅ SHIPPED 2026-05-06 evening

Replaced `pthread_create + pthread_join` with a static foreign call
through `libjit_call.dylib` (a 14-line C trampoline). End-to-end:

| Path | µs/call |
| --- | --- |
| Old: `call_jit` (pthread) | ~26 |
| New: `call_jit_direct` (libjit_call.dylib) | <1 |
| Full `try_jit_grade_str` (lower→emit→run→read) | ~52 |

Net speedup of the call itself: **~2900×** measured locally; end-to-end
grade is now ~52 µs (down from ~78 µs) because lowering dominates the
remaining cost. Either way the JIT grade beats the ~100 ms shell grade
by ~2000×.

### Implementation summary

| File | Change |
| --- | --- |
| `tools/jit_call.c` | Already in tree; `long jit_call(long(*fn)(long), long arg) { return fn(arg); }`. |
| `jit/build_trampoline.sh` | Already in tree; `cc -O2 -dynamiclib …` builds `jit/libjit_call.dylib`. |
| `tools/compile.rail` | Mirror of the libtensor_gpu pattern: optional `-L jit -weak-ljit_call` link flag if the dylib is present. **One-cycle bootstrap** required after this edit (source-only logic). |
| `jit/ffi.rail` | New foreign decl `foreign jit_call fn arg -> int`. |
| `jit/loader.rail` | New `call_jit_direct page arg`; old pthread-based `call_jit` retained for tests/back-compat. |
| `jit/grade.rail` | `try_jit_grade` and `try_jit_grade_str` now call `call_jit_direct`. |

### Prereq

Run `bash jit/build_trampoline.sh` once per checkout (≈1 sec). The
compile.rail link line is gated on `test -f jit/libjit_call.dylib` and
silently skipped if absent — so non-JIT builds aren't affected. Without
the dylib, `jit_call` is a weak symbol that resolves to NULL and
crashes on call; `call_jit` (pthread path) remains the safe fallback.

---

## P2 — Stage 6 parity check ✅ EXTENDED 2026-05-06

`jit/parity_check.rail` now supports two modes:
- `"test"`: int-return programs, exit-code grade (mod 256).
- `"stdout"`: programs that print, byte-equal stdout grade (uses the
  P0 capture pipeline + `run_rail_native_stdout`).

`fact10` (3628800) and `tri100` (5050) moved from `skip_big` to `stdout`
and pass cleanly. `pow` was promoted from `skip_big` to `stdout` and
revealed a real Rail-side bug: `pow 2 10` returns 0 on `./rail_native`
even though the JIT computes 1024 correctly. Marked as `known_diverge`
with a header note (probable auto-memoization × multi-arg interaction).

---

## P3 — Closures (capture-aware lambdas)

The biggest remaining gap. Plan in detail:

### Surface

```rail
\x -> body                    -- single arg
\a b -> body                  -- multi-arg (lex flattens to (\a -> \b -> body))
let inc = \x -> x + 1 in inc 5
map (\x -> x * 2) [1, 2, 3]
```

### IR + heap layout

A closure value = pointer to heap record:

```
[code_offset_in_jit_page]  (8 bytes)
[n_captured]               (8 bytes)
[captured_var_0]           (8 bytes)
[captured_var_1]           (8 bytes)
...
```

### New opcodes

| Op | Slots | Semantics |
| --- | --- | --- |
| `op_make_closure` | a=dst, b=fn_idx, c=n_captures | bump-alloc 16+8n bytes from heap; store code_offset + n + captured values from v0..v(n-1); dst = ptr |
| `op_set_capture` | a=closure_ptr, b=index, c=src_reg | store src_reg at closure[16 + 8*index]. Used after make_closure to fill captures. |
| `op_apply` | a=dst, b=closure_ptr_reg, c=packed_args | indirect call: load code from [closure, 0]; pass closure as x0; user args in x1..xN |

### Lowering pipeline

1. **AST**: `["lambda", arg_names, body]`.
2. **Pre-pass**: scan all functions for nested lambdas. Hoist each to a
   top-level helper with synthesized name `__lam_<n>`. The helper takes
   `(closure_ptr, user_arg0, user_arg1, ...)` — closure_ptr lets the body
   access captured vars via `ldr xN, [closure, 16 + 8*idx]`.
3. **Free-var analysis**: walk lambda body; vars used but not in arg
   list AND not bound by inner `let` are free → captured.
4. **Lower lambda site**: emit `op_make_closure` to alloc + populate
   record; the result is a value.
5. **Lower call site**: when calling a value (var of inferred type
   "closure" or unknown), emit `op_apply` instead of `op_call`.

### ARM64 emit for `op_apply`

For a single-arg closure call:

```
ldr  x16, [closure_ptr, #0]   ; load code_offset
adr  x17, <jit_page_base>     ; PC-relative to known anchor (or use saved x27)
add  x16, x17, x16            ; x16 = absolute code address
mov  x0, closure_ptr          ; closure goes in x0 (callee uses for env)
mov  x1, user_arg              ; user arg in x1
blr  x16                       ; indirect call
mov  dst, x0
```

But wait — `<jit_page_base>` needs to be known at emit time. Store it
as the first 8 bytes of the heap (similar to heap_addr trick), or
compute via `adr x_anchor, current_pc` and subtract a known offset.

Simpler: store the code as an *absolute* function pointer in the
closure record (resolved at make_closure time, when we know the JIT
page address). Then `op_apply` is just:

```
ldr  x16, [closure_ptr, #0]   ; absolute code ptr
mov  x0, closure_ptr
mov  x1, user_arg
blr  x16
mov  dst, x0
```

5 instructions = 20 bytes per call.

### Files to touch

| File | Change |
| --- | --- |
| `jit/lex.rail` | Already has `\` as catch-all op; add explicit handling. |
| `jit/syntax.rail` | `parse_lambda_expr` after seeing `\` op; nested-lambda flatten. |
| `jit/lower.rail` | Pre-pass `hoist_lambdas`; free-var analysis; lower_apply for closure-typed calls. Type-track "closure" alongside "int"/"str". |
| `jit/ir.rail` | Add op_make_closure (27), op_set_capture (28), op_apply (29). |
| `jit/emit.rail` | Three new emit handlers; bump-allocate from heap (same allocator as cons cells). |
| `jit/test_lower.rail` | Closures in `let`, in fn args (`map (\x -> x+1) xs`), capturing locals. |

**Effort:** ~4–6 hr. The lambda-lifting + free-var analysis is the
trickiest part. Once that's clean, the IR/emit are mechanical.

### Variant: closures-without-captures (1 hr)

If captures are too much, ship "named function pointers" first:

- `let f = some_named_fn in f 5` — `f` holds a fn_idx as an int.
- `op_apply` dispatches via a switch table over known fn_idx values
  (works because we know all fns at emit time).
- Captures: not supported. Free vars in the lambda body must already
  be in scope as named top-level fns.

This handles the `map` pattern where `f` is a top-level fn:
`add5 x = x + 5` ; `main = map add5 [1,2,3]`.

It does NOT handle `let n = 10 in map (\x -> x + n) xs` (captures).

Per Rail's CLAUDE.md ("use named 2-arg functions, NOT nested lambdas"),
the corpus may not need captures. Worth profiling first.

---

## P4 — Floats ✅ SHIPPED 2026-05-07

### What landed

| Aspect | Implementation |
|---|---|
| Float literal lex | `3.14`, `0.5`, `1e6`, `2.5e-3` (decimal + scientific). `tokenize_float_after_dot` / `_after_exp` in `jit/lex.rail`. |
| AST node | `["float", "3.14"]` (literal kept as string; `parse_float` runs at lower time). |
| 12 new opcodes | `op_fconst` (29), `fadd/fsub/fmul/fdiv` (30..33), `flt/feq/fgt/fge` (34..37), `int_to_float` (38), `float_to_int` (39), `op_print_float` (40), `op_fmov` (41 — used for if-merge). |
| Float vregs | `f0..f7` map to `d0..d7` (caller-save). Simple bumping allocator (`st_alloc_float`) — no live mask, no cross-call preservation. |
| ARM64 encoders | `enc_fadd/fsub/fmul/fdiv/fcmp/scvtf/fcvtzs/fmov_d_x/fmov_d_d/cset_mi/ldr_x27/str_x27/blr` in `jit/arm64.rail`, all verified via `as`+`otool`+python. |
| Float printing | `jit_print_float(d0=value, x0=cursor)` C trampoline; address `dlsym`-equivalent via `jit_print_float_addr` foreign, stored at `heap[24..31]`. JIT emits `ldr x0/x16, blr x16, str x0` (5 inst, 20B). Output format: `%g\n`. |
| Heap layout | Bumped `cells_offset` 16400 → 16416 to reserve the float-print-addr slot at `heap[24..31]`. Cursor base moved from `heap+16` → `heap+32`. `read_jit_output` updated to read from `+32`. |
| C trampolines | Added `jit_print_float`, `jit_float_bits_lo`, `jit_float_bits_hi`, `jit_print_float_addr` to `tools/jit_call.c`. Same `-weak-ljit_call` link-line gate as `jit_call`. |
| Type inference | `infer_type` returns "float" when AST is float-typed; `infer_type_op` propagates float type through arithmetic; `infer_type_if` joins branches. Comparison ops always return "int". `int_to_float` builtin recognized. |
| Lower path | `lower_op` dispatches to `lower_op_float` if either operand is float-typed. `lower_print_show` routes through `op_print_float` for float-typed inner. `lower_if` builds a float-merge variant (`lower_if_float`). |
| int→float promotion | `lower_expr_float` promotes int-typed expressions via `op_int_to_float`. So `3 + 1.5` lowers cleanly. |
| Float arith vs cmp | `lower_op_float_emit` checks `is_compare_op` and dispatches; arith returns float vreg, cmp returns int vreg. |

### Limitations of v1 (status)

- **~~No cross-call float preservation~~** ✅ LIFTED 2026-05-07. Frame extended 48→64 to add `stp d8, d9, [sp, #48]` callee-save. `preserve_callee_float` emits `op_fmov` to slots f8/f9 (=d8/d9) before any rhs-with-call. v1.5 limit: only 2 float callee-save slots (f8, f9).
- **~~No `<=` for floats~~** ✅ LIFTED 2026-05-07. Added `op_fle` + `enc_cset_ls`. Uses `ls` cond (not `le`) for NaN-safety.
- **~~No float-returning user fns~~** ✅ LIFTED 2026-05-07. Registry now tracks ret_type per fn (single-pass forward inference using `infer_type` with the registry-so-far seeded into env). `op_call_fret` (43) captures result via `fmov f_dst, d0`; `op_ret_float` (44) returns via `fmov d0, d_v`. `lower_call_emit` dispatches based on `reg_lookup_ret_ty`; `lower_fn_finalize` chooses `op_ret` vs `op_ret_float` based on `infer_type(body)`.
- **No float-typed function args.** `build_arg_env` still assumes int args (with str/fn name heuristic). Float args would need:
  1. Per-arg type detection at fn def (no clear name heuristic for float; inference from body usage is circular for binary ops; call-site inference is forward-only and O(n²)).
  2. Prologue `fmov d_i, d_i` for float args (currently emits `mov x_i, x_i`).
  3. Caller-side `fmov d_i, d_arg` for float args in op_call (currently emits `mov x_i, x_arg`).
  Workaround for v1.5: write fns that take int args and convert internally via `int_to_float`, e.g., `scale n = int_to_float n * 1.5`. Bench programs handle this naturally.
- **`%g` format.** `42.0` prints as `42` (not `42.0`). Common surprise — not a real limit, just a format choice.

### Bug fix log

- The original spec said "x1 = cursor" for `jit_print_float`. AAPCS64 actually puts the `char *` arg in **x0** (since `double` goes to `d0` and `char *` is the first int-class arg). Bug surfaced as `cursor_after = h_real + 5` (snprintf wrote at h_real, not h_real+32). Fixed by changing `enc_ldr_x27 1 8` → `enc_ldr_x27 0 8` in `emit_op_print_float`.
- Incremental fixtures landed first (arith without printing), then printing once the AAPCS bug was tracked.

---

## P4-future — float work not in v1

### Plan

ARM64 has dedicated d-registers (d0..d31, 64-bit doubles) and float
ops (`fadd`, `fsub`, `fmul`, `fdiv`, `fcmp`, `fcvtzs`, `scvtf`).

### IR + register schema

Two parallel preg maps:
- Int vregs `vN` → `xN+9` (existing).
- Float vregs `fN` → `dN` (new; d0..d31).

Or: one vreg space with type-tag determining x vs d. Cleaner.

### New opcodes

| Op | Slots | Semantics |
| --- | --- | --- |
| `op_fconst` | a=dst, b=imm_lo32, c=imm_hi32 | dst = bit_cast(b<<32 | c, double) |
| `op_fadd`/`fsub`/`fmul`/`fdiv` | a=dst, b=src1, c=src2 | binary float ops |
| `op_flt`/`feq`/`fgt` | a=dst (int 0/1), b=src1, c=src2 | float compare → int bool |
| `op_int_to_float` | a=dst, b=src | scvtf |
| `op_float_to_int` | a=dst, b=src | fcvtzs |
| `op_print_float` | a=src | format + print as `%.6f\n` (C printf would help; manual is hard) |

### Float printing

This is the gnarly part. `op_print_float` ideally calls `printf("%.6f\n", x)`
via libSystem. Requires:
- printf address resolved via dlsym at JIT-init.
- format string in the JIT page (rodata at known offset).
- `blr` indirect call, with x0 = format ptr, d0 = value.

Or write a manual decimal formatter (~150 instructions, error-prone).

Recommend: dlsym-printf path. Same indirect-call infrastructure as
closures' `blr xN` — these unblock together.

### Files to touch

| File | Change |
| --- | --- |
| `jit/ir.rail` | Add float ops (~7 opcodes). |
| `jit/lex.rail` | Float literals: `3.14`, `0.5`, `1e-3`. Multi-char number scanner. |
| `jit/syntax.rail` | `ast_float`. |
| `jit/lower.rail` | Float-typed env (extend type tracking); float arithmetic lowering. |
| `jit/emit.rail` | Float arm64 emits; printf via dlsym for `op_print_float`. |
| `jit/floats.rail` (new) | float-specific helpers (encoding constants for fadd etc.). |

**Effort:** ~4–6 hr. Most of the difficulty is float-print.

---

## P5 — File I/O

Comparatively small surface but useful for bench prompts that read
input from a file.

### Plan

| Op | Semantics |
| --- | --- |
| `op_open_file` | open(path_str, RDONLY) → fd or -1 |
| `op_read_byte` | read 1 byte from fd → int (0..255) or -1 EOF |
| `op_close_file` | close(fd) |

All via `svc` syscalls (open=5, read=3, close=6 on macOS).

For path strings, use existing string-pool infrastructure. The path
is a string literal; string pool emits the bytes; `op_open_file` loads
the str pointer and calls `open` syscall.

### Files to touch

| File | Change |
| --- | --- |
| `jit/ir.rail` | Add 3 opcodes (30, 31, 32). |
| `jit/emit.rail` | Three emit handlers; each is ~3–5 ARM64 instructions for the syscall. |
| `jit/lower.rail` | Add `read_file`/`open`/etc. as builtins. |

**Effort:** ~2–3 hr.

---

## P6 — Stage 2 direct call (perf lever)

`pthread_create` per `call_jit` costs ~50–200 µs. For RLVR with many
short rollouts, this dominates. The fix: a foreign primitive that
invokes a function pointer directly.

### Approach

The Session-C audit identified two clean paths:

**(a) `compile.rail` primitive.** Add `foreign call_addr addr arg -> int`
whose codegen is `blr x0`. ~30 lines of compile.rail. Then `call_jit`
becomes a direct call, not a pthread spawn. Bootstrap cycle required.

**(b) Pre-built C trampoline.** Already exists at `tools/jit_call.c`
(written by Session C as fallback). Build to `libjit_call.dylib`, dlopen
in `loader.rail`, dlsym `jit_call`, replace `pthread_create` with that.

Both are ~30 min once committed to. (b) avoids touching `compile.rail`
and is the safer choice. (a) is cleaner long-term if Rail is going to
develop other JIT-like substrates.

### Files to touch (option b)

| File | Change |
| --- | --- |
| `jit/build_trampoline.sh` | Already exists; wire into a make target. |
| `jit/ffi.rail` | Replace `pthread_create` usage with `dlopen` + `dlsym` + foreign call_addr (declared with the dlopen handle). |
| `jit/loader.rail` | Replace `call_jit` body. |

**Effort:** ~1 hr.

---

## Sequencing recommendation

P0/P1/P2/P3-variant/P3-full v1/P4/P5/P6 shipped. Remaining:

1. **P3-full v2 (real closure values)** — ~3–4 hr; replaces inline
   substitution with heap-allocated closure records so lambdas can be
   *passed* as args (`map (\x -> ...) xs`). Currently inline-only.
2. **Float-callee-save** — ~2 hr; supports float values held across
   function calls via op_float_to_int + op_int_to_float spill, or via
   d8..d15 callee-save (would need 16-byte frame extension).
3. **Float-typed user fn returns** — ~1 hr; `is_float` env tracking on
   user-fn registry so `infer_type_app` knows the return type without
   the special-case `int_to_float` only branch.

Continue as bench coverage measurement demands. The JIT path now beats
shell grade by ~2000× per call, so the bottleneck for distill is
lowerable shape coverage, not call latency.

---

## What's stable today (do NOT regress)

- All 87 positive + 3 negative `test_lower.rail` fixtures (12 new floats).
- All 8 hand-built `test_codegen.rail` fixtures.
- All 5 `test_print.rail` fixtures.
- 23 `test_capture.rail` fixtures (8 new floats).
- `test_enc.rail` encoder fixtures.
- `parity_check.rail`: 11 PARITY OK rows.
- 137/137 main suite.
- Stage 5 list ops (cons/head/tail/is_nil + `[a,b,c]`).
- Match syntax desugar.
- All cmp/arith/bool ops.
- Negative-int `op_print_int`.
- P4 floats: arith / cmp / promotion / printing / if-merge.
- The ABI-v2 prologue, with **48-byte frame and saved x27**:
    main: `stp fp/lr -48; mov fp,sp; stp x19/x20 +16; str x27 +32; mov x27,x0; <arg moves>`
    non-main: same but `mov x27,x0` → `nop`. x27 is callee-save and
    propagates from main throughout the call chain.

Any change to the prologue, `op_call`'s packed encoding, or the heap
layout (esp. `cells_offset = 16416` post-P4, `output_offset = 32`,
`heap[24..31] = jit_print_float addr`) affects everything.
