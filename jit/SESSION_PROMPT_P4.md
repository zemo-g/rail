# JIT — P4 (floats) session prompt

Paste below the rule line into a fresh session. Self-contained; ship P4
end-to-end in one session.

---

Branch `jit` on `next` (origin = Mini → GitHub `zemo-g/rail.git`). Pull,
build the trampoline dylib, then verify environment:

    git pull
    bash jit/build_trampoline.sh
    ./rail_native run jit/test_lower.rail      # ALL LOWER PASS  (75+3)
    ./rail_native run jit/test_capture.rail    # ALL CAPTURE PASS (15)
    ./rail_native run jit/parity_check.rail    # PARITY OK
    ./rail_native test                          # 137/137

If any fail: stop, don't start P4 on broken state.

## Memory to fetch

- `jit_in_pure_rail.md` — full project state through P3-full v1
- `rail_top_level_int_add_bug.md` — relevant for any helper int constants

## 5-minute read

- `jit/CONTINUATION.md` — sequencing + status
- `jit/SESSION_PROMPT.md` — paste-ready briefing for distill integration
- skim `jit/emit.rail::emit_print_int_impl` — pattern for any print-like emit

## DONE CRITERION

`try_jit_grade_str "main = print (show (3.14 * 2.0))" "6.28\n"` returns
`["jit_pass"]`. Plus 5+ regression fixtures in test_lower.rail covering
fadd/fsub/fmul/fdiv, int→float promotion, float compare, conditional float.

Commit + push (Studio→Mini→GitHub flow at the bottom).

## Design decisions — locked in, do not re-derive

**Float register space.** Float vregs `f0..f15` map to d-regs `d0..d15`.
v1 only uses caller-save `d0..d7`; values that must live across calls
spill through int regs (via op_float_to_int + reload). Don't extend the
prologue frame for float-callee-saves yet.

**Float printing path: dlsym + blr indirect.** Add to `tools/jit_call.c`:

    char *jit_print_float(double x, char *cursor) {
        int n = snprintf(cursor, 64, "%g\n", x);
        return cursor + n;
    }
    long jit_float_bits(double x) { return *(long *)&x; }

Rebuild via `bash jit/build_trampoline.sh`. Declare in `jit/ffi.rail`:

    foreign jit_print_float x cursor -> ptr
    foreign jit_float_bits x -> int

`heap_alloc` dlopens `jit/libjit_call.dylib`, dlsyms `jit_print_float`,
stores the absolute address at `heap[24..31]`. Bump `cells_offset`
16400 → 16416 to reserve the slot. op_print_float emits:

    ldr  x21, [x27, #8]       ; cursor
    ldr  x16, [x27, #24]      ; jit_print_float addr (dlsym'd at heap_alloc)
    fmov d0, d_src             ; arg 0 (double); skip if d_src == d0
    mov  x1, x21              ; arg 1 (cursor)
    blr  x16
    str  x0, [x27, #8]        ; new cursor returned

dlsym ABI: verify what stdlib/dlopen.rail returns (Rail handle vs raw)
with a probe like `/tmp/probe_arith.rail` from prior session before
committing. The `shl p 1` trick may or may not apply.

**Float literal lex.** Extend `scan_digits` → `scan_number` returning
either `mk_int n` or `mk_float "3.14"` (literal kept as string). Float
syntax: `DIGITS '.' DIGITS [eE [+-]? DIGITS]?` and `DIGITS [eE [+-]? DIGITS]`
(so `1e6` is float, `1` is int).

**op_fconst.** At lower time, parse the literal via `to_float "3.14"`,
then `let bits = jit_float_bits f`, then emit 4 movz/movk into a temp
x register + `fmov d_dst, x_temp`. Reuses existing `emit_const`
machinery; just adds a trailing `fmov`.

**Operations to ship (12):**

| Op | Slots | ARM64 |
|---|---|---|
| op_fconst | a=dst_freg, b=lo32, c=hi32 | 4× movz/movk + fmov d, x  (5 inst) |
| op_fadd / fsub / fmul / fdiv | a=dst, b=src1, c=src2 | 1 inst each |
| op_flt / feq / fgt / fge | a=dst_INT, b/c=floats | fcmp + cset cond (2 inst) |
| op_int_to_float | a=dst_freg, b=src_int | scvtf d_dst, x_src |
| op_float_to_int | a=dst_int, b=src_freg | fcvtzs x_dst, d_src |
| op_print_float | a=src_freg | the blr-indirect sequence above (6 inst) |

Defer `op_show_float` (string-returning). Bench uses `print (show e)` —
recognize float-typed inner expression in `lower_print_show` and route
to op_print_float directly.

## Files to touch (in order)

1. `tools/jit_call.c` — add 2 C functions.
2. `bash jit/build_trampoline.sh` — rebuild dylib.
3. `jit/ffi.rail` — 2 foreign decls.
4. `jit/heap.rail` — bump `cells_offset` 16400→16416, dlsym at heap_alloc.
5. `jit/arm64.rail` — encoders: enc_fadd/fsub/fmul/fdiv/fcmp/scvtf/fcvtzs/
   fmov_d_x/cset_mi (use `as`+`otool`+python on every constant).
6. `jit/ir.rail` — opcodes 29..40.
7. `jit/lex.rail` — scan_number → int|float branch.
8. `jit/syntax.rail` — ast_float; parse_primary float branch.
9. `jit/lower.rail` — float vreg alloc, lower_op promotion logic,
   lower_print_show float branch.
10. `jit/emit.rail` — emit handlers + ir_byte_size for the 12 new ops.
11. `jit/test_lower.rail` + `jit/test_capture.rail` — 8+ fixtures.
12. `jit/CONTINUATION.md` + `jit/SESSION_PROMPT.md` + memory entry update.

## Gotchas to know cold

1. **No hex literals.** `byte_set p 0 0x40` parses as 4 args (`0`, ident
   `x40`); ld errors `_RAIL_UNDEFINED_IDENT_x40`. Decimal everywhere.
2. **Hand-converting hex→decimal is a trap.** Burned 30 min last
   session. Always pipe through `python3 -c 'print(int("F9400775",16))'`
   AFTER `as`+`otool` confirms the disassembly.
3. **Foreign-call ABI matters.** `-> int` retags result; `-> ptr` does
   not; `-> float` returns d0 + post-call `fmov x0, d0`. Float ARGS go
   in d0..d7, not x0..x7. compile.rail handles this via untag_float_args.
4. **48-byte frame is sacred.** x27 is saved at `[sp,#32]`; main does
   `mov x27, x0`, non-main emits NOP. Don't change the frame size.
5. **AAPCS64 d-regs.** d0–d7 caller-save, d8–d15 callee-save (low 64 bits
   only). v1: only allocate floats in d0..d7; spill cross-call via int.
6. **dlsym Rail-side handle.** Probe what `dlsym lib "name"` returns
   (raw addr vs Rail tagged) before stuffing into heap. Use the
   `write_u64`/`read_u64` round-trip pattern from `/tmp/probe_arith.rail`.
7. **`to_float "3.14"` is a Rail builtin** that parses string→float bits
   at lower time. Use it. Don't try to parse decimals in Rail by hand.

## Suggested pacing (one session, ~6 hr)

1. (15 min) C trampoline + dylib rebuild + foreign decl probe.
2. (30 min) Lex + parse float literals.
3. (45 min) IR opcodes + encoders (verified).
4. (1 hr) Lower: arith + promotion + vreg alloc.
5. (15 min) Checkpoint: arith fixtures pass, no print yet. Commit.
6. (45 min) Wire dlsym; verify heap[24] has the right address.
7. (1 hr) emit_op_print_float; first asm in /tmp/asmtest_pf.s, then port
   to emit.rail.
8. (30 min) Comparisons + conditional float fixtures.
9. (30 min) test_capture fixtures (3.14, 6.28, 1.5e-3 * 1000.0 = 1.5).
10. (30 min) Doc + memory updates. Commit + push.

## Stop conditions / fallback scopes

If float printing turns into a tar pit past ~2 hr:

- Ship arith only. Success: `let r = float_to_int (3.14 * 2.0) in print
  (show r)` → "6\n". Document op_print_float as deferred. Still unblocks
  bench prompts that compute floats and round to int.

If d-reg vreg allocation tangles:

- Drop the allocator: every op_f* takes the d-reg number directly in
  IR slots, no env tracking. Single-use floats only. Adequate for
  straight-line `3.14 * 2.0` style in main.

## Floors to protect (regression net)

- 137/137 main suite
- 75+3 test_lower fixtures
- 15 test_capture fixtures
- parity_check 11 rows
- 20 test_enc encoder fixtures
- 48-byte frame size

## Round-trip flow

    # On Studio:
    git add jit/... tools/jit_call.c
    git commit -m "jit: P4 floats — fadd/fsub/fmul/fdiv + dlsym print_float"
    git push origin jit                                               # → Mini
    ssh <user>@<host> 'cd ~/projects/rail && git push origin jit'  # → GitHub

If `tools/compile.rail` changed (it shouldn't for P4 — link line already
picks up new symbols via `-weak-ljit_call`), bootstrap with
`./rail_native self && cp /tmp/rail_self rail_native && ./rail_native test`
and only commit rail_native after verifying 137/137.

---

(End of paste-able prompt.)
