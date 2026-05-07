# Floats — design + scaffold

Status: NOT shipped. ~4–6 hr to ship; the printf-via-dlsym half is
the gnarly part.

---

## Surface syntax

```rail
main = 3.14 + 0.5
let x = 1.5 in print_float (x * 2.0)        -- 3.0
let r = sqrt 2.0 in ...                        -- foreign sqrt; Rail has it
if 0.5 < 1.0 then 1 else 0
```

## Register schema

ARM64 has 32 d-registers (d0..d31) for IEEE-754 doubles. Use them
directly; don't share with x-registers.

Schema: parallel preg map for floats:
- `fN` (float vreg N) → `dN`
- `fN.preg = N` (no offset, since d0 is fine; or use d8..d23 callee-save?)

Caller-save: d0..d7, d16..d31. Callee-save lower-half: d8..d15.

For our v1, simplest: f0..f7 → d0..d7 (caller-save). Up to 8 float values
simultaneously live; preserve to callee via `stp d8, d9, [sp, #...]`
in the prologue if needed.

Or just use d8..d23 throughout (callee-save range), and ignore the
"callee preserves" requirement since we always set them ourselves.

## IR opcodes

| Op | Slots | Semantics |
| --- | --- | --- |
| `op_fconst`     | a=dst (float vreg), b=lo32, c=hi32 | dst := bit_cast(c<<32 | b, double) |
| `op_fadd` `fsub` `fmul` `fdiv` | a=dst, b=src1, c=src2 | binary float ops |
| `op_flt` `feq` `fgt` | a=int_dst (0/1), b=src1, c=src2 | float compare → int |
| `op_int_to_float` | a=float_dst, b=int_src | scvtf dN, xN |
| `op_float_to_int` | a=int_dst, b=float_src | fcvtzs xN, dN |
| `op_print_float` | a=src | printf("%.6f\n", x) via dlsym |

## Float literals

Lex extension: a number with a `.` becomes a float token `["float", repr]`
where repr is the source string. Parse-time conversion: parse repr to
double, encode as 64-bit.

For storing a literal in the IR: split into hi32 + lo32 since IR slots
are 32-bit (or whatever Rail int width). At emit, use four movz/movk
to load the 64-bit pattern into a scratch x-register, then `fmov dN, xN`
to put it in the float reg.

```
movz x_temp, #lit_lo16
movk x_temp, #lit_lo32, lsl #16
movk x_temp, #lit_hi32, lsl #32
movk x_temp, #lit_hi16, lsl #48
fmov dN, x_temp
```

5 instructions = 20 bytes per float literal. (Same as op_const for ints,
plus the fmov.)

## Type tracking

Extend the env's type field to include "float". `infer_type`:
- Float literal → "float"
- Float-arithmetic result → "float"
- `int_to_float` → "float"
- Float compare → "int" (returns 0/1)

Operator overloading: `+`, `-`, `*`, `/` on float-typed operands lower
to `op_fadd` etc. On int-typed → existing op_add etc. Mixed-type:
auto-promote to float (mirrors `int_to_float` Rail behavior in CLAUDE.md).

## printf for op_print_float

The hard part. ARM64 macOS printf:
- `printf` symbol resolved via `dlsym(RTLD_DEFAULT, "printf")` at
  JIT-init time.
- printf address is a 64-bit value; bake into JIT page as data and
  `ldr` at runtime, OR pass via heap.
- ABI: `printf(format, ...)` — format in x0, first vararg in d0
  (for double; per Apple Silicon ABI, varargs go on stack — different
  from non-vararg which use d0 directly).

Apple Silicon vararg quirk: varargs pass on the stack, not registers.
This is different from Linux! Need to push the double onto the stack.

```
adr x0, format_str_in_pool       -- "%.6f\n"
sub sp, sp, #16                  -- 16-byte alignment for arg
str d_value, [sp]                -- push double on stack
ldr x16, [heap_addr_or_pc, #printf_offset]   -- load printf address
blr x16
add sp, sp, #16
```

~6 instructions = 24 bytes per `op_print_float`. Plus the format
string in the pool ("%.6f\n\0" + length prefix).

Alternative: skip printf, write a manual decimal formatter. ~150
instructions, error-prone. Don't.

## Files to touch

| File | Change |
| --- | --- |
| `jit/ir.rail` | Add op_fconst..op_print_float (~7 opcodes). |
| `jit/lex.rail` | Float literal tokenizer (digits + `.` + digits + optional `e<sign>digits`). |
| `jit/syntax.rail` | `ast_float`. |
| `jit/lower.rail` | Float-typed env; arithmetic operator overloading by type; `int_to_float` / `float_to_int` builtins. |
| `jit/emit.rail` | Float ARM64 emit; printf-via-dlsym for op_print_float. |
| `jit/floats.rail` (new) | Float-specific helpers: encoding constants, printf-resolution at JIT-init. |
| `jit/test_lower.rail` | 5–8 float tests: const, arithmetic, compare, conversion, print. |

---

## Non-goals (v1 floats)

- Float64 vs Float32 distinction — only Float64 supported.
- Long-double / quad — never.
- IEEE NaN/Inf semantics correctness — best-effort.
