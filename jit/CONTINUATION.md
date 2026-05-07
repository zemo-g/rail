# JIT — continuation roadmap

State at end of session 2026-05-06: branch `jit` @ `a885dd6` on `next`,
~28/30 bench shapes lowerable. This doc breaks the remaining work into
self-contained pieces. Each section names files to touch, sketches the
design, and flags unknowns.

The pieces are mostly independent — pick by leverage, not order.

---

## P0 — Output capture (gates distill integration)

**Problem:** The training session's distill loop needs to *grade* a JIT'd
program by comparing its stdout against an expected string. Today's JIT
writes via `svc #0x80 write(1, ...)` which goes to the parent process's
fd 1. To grade, the harness must capture that output.

### Three options

**(a) Stdout-pipe redirect.** Foreign-bind `dup`, `dup2`, `pipe`, `close`,
`read`. Around `call_jit`: save fd 1 via `dup`, create a pipe, `dup2` the
write end onto fd 1, run the JIT, `dup2` the saved fd back, read from the
pipe's read end into a Rail buffer.

- Pros: no JIT changes; works for any printing op.
- Cons: ~6 new foreign declarations; pipe buffer ~64 KB per OS limits;
  requires an explicit "drain" step before `dup2` restore.

**(b) Memory-buffer write.** Replace `op_print_int`/`op_print_str` syscalls
with byte-stores into a buffer. The buffer pointer + cursor live at known
offsets in the heap page (already mmap'd by `heap_alloc`). After
`call_jit`, the harness reads the buffer.

- Pros: clean; no fd manipulation; deterministic capture.
- Cons: every print op grows by ~5–8 instructions (load cursor, write
  bytes, store cursor); changes the "print = visible-side-effect" mental
  model — debug printing during JIT is harder.

**(c) Temp-file write.** Open a temp file in Rail, point the JIT's syscall
at its fd via a configurable `print_fd` baked into the page. Read the
file after.

- Pros: tiny code change (just the fd constant in `op_print_int` /
  `op_print_str`); reads are simple file I/O.
- Cons: filesystem hit per JIT call (~50–200 µs on macOS APFS); same
  ballpark as the existing `pthread_create` overhead so no perf win.

**Recommendation: (b).** Long-term it's the cleanest substrate. The print
ops grow by ~24 bytes each but distill integration becomes trivial. It
also future-proofs us for "log all op_call outcomes for process-reward
training" — that's just another buffer write.

### File-level changes for (b)

| File | Change |
| --- | --- |
| `jit/heap.rail` | Reserve heap[8..16] = output buffer cursor (was implicitly the bump pointer for cells; add a second cell). |
| `jit/emit.rail` | `emit_op_print_int_impl`: replace the `svc` block with: ldr cursor from heap[8]; write byte sequence at heap[cursor..]; update cursor. Same for `emit_op_print_str`. |
| `jit/loader.rail` | Add a `read_jit_output heap_addr` Rail function that reads the buffer up to cursor and returns the string. |
| `jit/grade.rail` (new) | `try_jit_grade src expected -> [tag, payload]`. See P1. |

### File-level changes for (a) — alternative

| File | Change |
| --- | --- |
| `jit/ffi.rail` | Add `dup`, `dup2`, `pipe`, `close`, `read` foreign decls. |
| `jit/loader.rail` | New `call_jit_capture page heap` that wraps `call_jit` with the pipe-redirect dance. |
| `jit/grade.rail` (new) | Use `call_jit_capture`. |

Either approach is ~1–2 hr to ship.

---

## P1 — Distill-integration helper (`jit/grade.rail`)

A single Rail function the training session calls in its rollout loop:

```rail
import "jit/grade.rail"

let result = try_jit_grade candidate_rail_src expected_stdout
match result
| ["jit_pass"]                  -> good rollout
| ["jit_fail", actual_stdout]   -> wrong but well-formed
| ["err", reason]               -> fall back to shell-grade
```

Internally:

```
try_jit_grade src expected:
  let r = lower_source src
  if (head r) == "err" then ["err", err_msg]
  else
    let fns  = head (tail r)
    let pool = head (tail (tail r))
    let heap = heap_alloc 0
    let res  = emit_program fns pool heap
    let page = make_executable buf nbytes
    let _    = call_jit page heap
    let actual = read_jit_output heap   -- needs P0 first
    let _ = free_jit page
    let _ = heap_free heap
    if str_eq_rail actual expected then ["jit_pass"]
    else ["jit_fail", actual]
```

This is the function the training session imports. It hides the
emit/load/run dance behind a one-liner.

**Status:** blocked on P0.

---

## P2 — Stage 6 parity check (`jit/parity_check.rail`)

Confidence-builder for the JIT vs `./rail_native` semantics. For each
int-return lowerable program:

1. Run via JIT, get `N`.
2. Compile + run via `./rail_native run file.rail`, capture exit code (0–255).
3. If `N` (mod 256) ≠ exit code, report mismatch.

**Limit:** Exit codes wrap mod 256, so test fixtures must return values
< 256. `fact 5 = 120` ✓. `fact 10 = 3628800` ✗ (would need stdout grade
via P0).

For programs that print (no int return; main returns 0): use stdout
grade — also needs P0.

Without P0, parity_check.rail can verify ~half our int-return fixtures.
Worth shipping anyway — it's a regression net.

**Effort:** ~30 min once written. Just shells out to `./rail_native`
via existing foreign-call infra and compares.

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

## P4 — Floats

Less common in compute-style bench prompts but bench has some.

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

Given the training session's stated need (distill integration with
sub-ms grading), the leverage-per-hour ranking:

1. **P0 (output capture, option b)** — ~1–2 hr; *unblocks distill integration*.
2. **P1 (`grade.rail` helper)** — ~30 min after P0.
3. **P2 (parity check)** — ~30 min; partial without P0, full with.
4. **P6 (direct call, option b)** — ~1 hr; collapses pthread overhead.
5. **P3 variant (closures-without-captures)** — ~1 hr; opens HOF prompts
   that pass *named* functions.
6. **P5 (file I/O)** — ~2–3 hr.
7. **P3 full (closures with captures)** — ~4–6 hr.
8. **P4 (floats)** — ~4–6 hr.

Stop after step 4 if the corpus profiling shows the remaining gap is
non-list-non-string-non-multi-arg shapes that are rare. Continue with
steps 5–8 as bench coverage measurement demands.

---

## What's stable today (do NOT regress)

- All 60 positive + 3 negative `test_lower.rail` fixtures.
- All 8 hand-built `test_codegen.rail` fixtures.
- All 5 `test_print.rail` fixtures.
- 137/137 main suite.
- Stage 5 list ops (cons/head/tail/is_nil + `[a,b,c]`).
- Match syntax desugar.
- All cmp/arith/bool ops.
- Negative-int `op_print_int`.
- The ABI-v2 prologue (`mov x27, x0` captures heap_addr from pthread arg).

Any change to the prologue or `op_call`'s packed encoding affects everything.
