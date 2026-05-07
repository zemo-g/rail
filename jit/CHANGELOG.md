# Rail JIT Changelog

One-line summary per commit on the `jit` branch since it forked from `next`.
Use this to grok history fast — read top-to-bottom for the staged build-up,
or jump to the stage tag for the relevant chunk.

---

## P4-arg (COMPLETE — float user-fn args; last named v1 limit closed)

- **jit: float user-fn args via call-site fixed-point inference**
  - Registry shape: `[name, idx, ret_ty]` → `[name, idx, meta_arr]` where meta is a mutable int_arr; slot 0 = ret_ty bit, slots 1..n = per-arg type bits.
  - `build_registry` now does initial pass + `fixed_point_arg_types` (cap 4 iterations). Each pass walks every fn body, propagates float arg types into callee registries via `walk_calls_for_arg_types` + `propagate_arg_types_to_callee`, and re-infers ret_ty with updated param types in env.
  - `op_call_fret` (43) folded into `op_call` (7) via bit 28 of c-slot. Bits 24..27 carry per-arg type bits. New helpers in `ir.rail`: `call_pack_typed`, `call_arg_type_n`, `call_ret_type`, `call_arg_n`. Hand-built fixtures with op_call_fret still work via thin emit_op_call_fret wrapper that forces bit 28.
  - `emit_op_call` decodes c-slot per-arg: int → `mov x_int_slot, x_preg(arg)`; float → `fmov d_float_slot, d_arg`. After bl, ret-type bit dispatches int (`mov x_preg(a), x0`) vs float (`fmov d_a, d0`) capture. AAPCS64 mixed-arg ABI: int_slot and float_slot index INDEPENDENTLY.
  - `emit_prologue` reads new `arg_types` slot from fn struct and emits per-arg moves the same way. Same 4-byte-per-arg budget.
  - `make_fn_n` now stores `arg_types_arr` (default all-int); `make_fn_n_typed` for explicit types. `fn_arg_types` accessor.
  - `build_arg_env` consults registry's per-arg type. Float params bind name to f-vreg in caller-save range; if used after a call, preserved into f8/f9 (callee-save). Bumps ctr[8] past the param's slot so body's st_alloc_float skips it.
  - `lower_expr_scoped` now also save/restores `ctr[8]` (caller-save float counter) at expression boundaries. Mirrors the int live-mask scope reset; lets deeply-nested float expressions (recursive pow with cross-call b preservation) reuse d0..d7 as scratch.
  - 6 new fixtures in test_lower (fa1..fa6) and test_capture (fa_area..fa_pow). DONE CRITERION fixture: `area r = 3.14 * r * r; main = print (show (area 5.0))` → `78.5\n`. Recursive `pow b e = if e < 1.0 then 1.0 else b * pow b (e - 1.0)`; `pow 2.0 3.0` = 8.

## Stage 5 (PARTIAL — lowering shipped, execution blocked)

- **`93ad7c1` jit: Stage 5 infrastructure (lists/heap/match-pending) + execution blocker**
  - New file `jit/heap.rail`: bump-pointer cons-cell heap (64 KB mmap'd RW page; canonical importer for `stdlib/mmap.rail` + `jit/ffi.rail`).
  - IR adds `op_nil` (16), `op_cons` (17), `op_head` (18), `op_tail` (19), `op_is_nil` (20).
  - `emit.rail`: `op_cons` (24 B; bump-alloc + write head/tail), `op_head`/`op_tail` (4 B `ldr`), `op_nil` (4 B `mov #0`), `op_is_nil` (8 B `cmp + cset`). Prologue grows to load heap_addr into `x27` via PC-relative `adr+ldr` (heap_addr stored as 8 raw bytes after code).
  - `lower.rail`: list literals `[1,2,3]` parse + lower; `cons`/`head`/`tail`/`is_nil` recognized as safe builtins (don't clobber caller-save).
  - **Blocker**: Rail's foreign-pointer ABI hands back opaque handles (not real addresses); baked heap_addr therefore mismatches what the runtime sees. `ldr [x27]` faults. Three unblock paths documented in `NEXT_STAGES.md`. List execution disabled in `test_lower.rail`; lowering machinery is shipped and ready.

## Stage 4 (COMPLETE — strings + multi-arg fns)

- **`6c58ed0` jit: Stage 4c/d — op_str_eq + op_str_len + op_str_at builtins**
  - New IR opcodes: `op_str_eq` (14, 72 B 18-instr byte loop), `op_str_at` (15, 8 B `add+ldrb`). `op_str_len` (13) wired (was unused).
  - Lowerer recognizes `str_eq s1 s2`, `str_len s`, `str_at s i` as builtins via `is_builtin` / `lower_builtin_*`.
  - Encoding bug caught and fixed: first attempt at `op_str_eq` used x10/x11 as scratch but those overlap with v1/v2's pregs (common s1/s2 callers). Moved scratch to x21..x27 (outside v0..v11 → x9..x20 vreg map).

- **`a469997` jit: Stage 4b — multi-arg user fns + type-tracked env**
  - Function struct gains `n_args` slot. `make_fn` is back-compat 1-arg shim; `make_fn_n ir n_instr n_regs blocks n_args` is the new constructor (`n_args ∈ 0..4`). `fn_nargs` accessor added.
  - Prologue is now `12 + 4*n_args` bytes; emits `mov v_i_preg, x_i` for each arg. `emit_one_function` + `fn_total_bytes` updated.
  - Lowerer: AST-level type inference (`int` vs `str`) so let-bound strings work and `print str_var` dispatches to `op_print_str`. `infer_arg_type` heuristic (`s`/`s1`/`s2`/`str`/`name` → str).
  - `op_call` packed-arg encoding: bits 0..3 = n_args, bits 4..23 = up to four 5-bit arg vregs. `call_pack_1..4` build, `call_n_args` + `call_arg_0..3` decode.

- **`c42166a` jit: Stage 4a — string literals + op_print_str + multi-arg op_call infra**
  - Lexer: `"..."` with `\n \\ \" \t` escapes → `["str", value]` tokens.
  - Parser: `ast_str` primary; participates in app continuation.
  - Lowerer: per-program string pool (length-prefixed, mmap'd at end of JIT page). `lower_source` returns `["ok", fns, pool]` | `["err", msg]`. `lower_str` appends to pool, emits `op_str_lit`.
  - `print "literal"` → `op_print_str`; `print int_expr` → `op_print_int` (existing).
  - New IR: `op_str_lit` (11, 4 B PC-relative `adr`), `op_print_str` (12, 20 B `ldr+add+mov+mov+svc`).
  - `arm64.rail`: `enc_adr` for PC-relative byte addresses.
  - Multi-arg `op_call` encoding scaffolding (decode helpers; >1 arg not yet emitted by the lowerer until 4b).

## Stage 3 (COMPLETE — Rail source → IR lowering)

- **`8ce3bac` jit: Stage 3 — lowering harness (Rail source → IR → JIT)**
  - New files: `jit/lex.rail` (~150 lines tokenizer: comments, idents, ints, ops `+ - * <`, parens, `=`, NL, EOF); `jit/syntax.rail` (~200 lines recursive-descent parser); `jit/lower.rail` (~400 lines AST → IR lowerer).
  - Lowerer features: live-bitmask caller-save allocator (v1..v9), callee-save preservation (v10/v11) at fn entry if body has any call and across binary ops/let bodies, function-name registry (resolves user calls to `op_call` fn_idx), `move_main_first` so `main` is fn 0.
  - Subset support: integer arithmetic + comparison + `if` + `let` + named function calls + `print (show e)`.
  - `jit/test_lower.rail`: 14 end-to-end tests for shapes (`const_add`, `let_form`, `let_chain`, `fact5/10`, `fib10`, `tri100`, `ssq5`, plus `print_*` forms and negative tests).

## Stage 1 (COMPLETE — JIT primitives)

- **`03dfebe` jit: op_call + op_print_int + op_mov + 32-byte frame + multi-fn emit_program**
  - ABI v1: `v0..v9 → x9..x18` (caller-save), `v10..v19 → x19..x28` (callee-save; only x19/x20 saved by prologue in v1).
  - New opcodes: `op_call` (7, 12 B `bl + arg/return shuffle`), `op_print_int` (9, 80 B `svc #0x80 write(1, decimal+\n)`), `op_mov` (10, 4 B reg-to-reg).
  - `emit.rail`: 32-byte frame (stp x29,x30 + stp x19,x20). `emit_program` for multi-function buffers with `fn_offsets` table (op_call resolves `bl` targets relatively).
  - `test_codegen.rail` extended with `build_fact` (single-fn self-recursive), `build_fib` (two recursive calls per branch).

- **`1e9b291` jit: unify C (drop ir_c.rail; emit imports ir.rail; tests use ir_emit)**
  - Session C's local `ir_c.rail` dropped; `emit.rail` now imports `ir.rail` directly. Tests switched to canonical `ir_emit`.

- **`95a457e` merge: jit-codegen (Session C)** — Session C's branch merged in. (Original commit: `056aca3`)

- **`056aca3` jit: codegen + loader (Session C) - first JITted Rail-emitted code runs**
  - Pure-Rail ARM64 emitter + mmap+mprotect loader. IR → 4-byte ARM64 words written into `int_arr` codebuf, copied to executable page, called via `pthread_create` (the indirect-call mechanism — no `compile.rail` edits, no extra dylib).
  - Files: `jit/ir_c.rail` (mirror of B's), `jit/arm64.rail` (11 verified instruction encoders), `jit/codebuf.rail`, `jit/emit.rail` (initial), `jit/loader.rail`, `jit/ffi.rail` (mprotect, sys_icache_invalidate, pthread_create/join, malloc/free), `jit/test_codegen.rail`, `jit/test_enc.rail`.

- **`0d838b4` jit: unify A+B (drop ir_b.rail; bare opcode bindings; B helpers folded into ir.rail)**
  - Session B's `ir_b.rail` dropped; opcodes become bare nullary bindings in `ir.rail`. B's helpers folded in.

- **`58476d6` merge: jit-opt (Session B)** — Session B's optimizer/profiler/icache merged. (Original commit: `24e4037`)

- **`24e4037` jit: optimizer + profiler (Session B)**
  - `jit/ir_b.rail` (initial opcode definitions; later folded into `ir.rail`), `jit/opt_const_fold.rail` (per-block const propagation), `jit/opt_dce.rail` (dead-code elimination + block-offset remap), `jit/profile.rail` (hot counters), `jit/icache.rail` (monomorphic 3-int inline cache records), `jit/test_opt.rail` (29 assertions).

- **`b5b7015` jit: frontend (Session A)**
  - `jit/ir.rail` (initial opcodes + accessors + fn struct), `jit/parse.rail` (stack-VM bytecode text → IR), `jit/print.rail` (IR → human-readable string), `jit/fixtures_ir.rail` (hand-built IR), `jit/test_parse.rail` (5 round-trip tests).

---

## Sessions structure (historical)

The JIT was built in three parallel sessions on 2026-05-06:
- **Session A (frontend)**: IR + parser + printer + fixtures.
- **Session B (optimizer)**: const-fold + DCE + profiler + icache.
- **Session C (codegen)**: ARM64 encoder + emitter + mmap loader + FFI.

Sessions converged via `0d838b4` (A+B) and `1e9b291` (C), after which Stages 1+ were built linearly on the unified branch.
