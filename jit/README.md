# Rail JIT (v1)

A pure-Rail JIT compiler that lowers a small bytecode IR to ARM64 machine code, mmaps it executable, and runs it via `pthread_create` as the indirect-call mechanism. No `compile.rail` edits required; built entirely on `stdlib/mmap.rail` + `stdlib/dlopen.rail` + raw libSystem `foreign` bindings.

End-to-end: integer-only, recursive functions with stdout printing via `svc` syscall.

## Quick start

```bash
./rail_native run jit/test_codegen.rail   # 8 fixtures: addk, sq1, fact5/1/0, fib10/0/1
./rail_native run jit/test_print.rail     # 5 print fixtures: 42, 0, 1, 12345, 999999
./rail_native run jit/test_parse.rail     # 5 round-trip parse tests
./rail_native run jit/test_opt.rail       # 29 optimizer/profiler/icache assertions
./rail_native run jit/test_enc.rail       # 17 ARM64 encoder unit tests
```

## IR contract

### Opcodes (in `jit/ir.rail`)

| Opcode         | Value | Slots (a, b, c)                       | Semantics                            | Bytes |
| -------------- | ----- | ------------------------------------- | ------------------------------------ | ----- |
| `op_const`     | 0     | dst, imm, _                           | `vDst := imm`                        | 16    |
| `op_add`       | 1     | dst, src1, src2                       | `vDst := vSrc1 + vSrc2`              | 4     |
| `op_sub`       | 2     | dst, src1, src2                       | `vDst := vSrc1 - vSrc2`              | 4     |
| `op_mul`       | 3     | dst, src1, src2                       | `vDst := vSrc1 * vSrc2`              | 4     |
| `op_lt`        | 4     | dst, src1, src2                       | `vDst := (vSrc1 < vSrc2) ? 1 : 0`    | 8     |
| `op_jmp`       | 5     | block_idx, _, _                       | unconditional branch                 | 4     |
| `op_jz`        | 6     | cond, block_idx, _                    | branch if `vCond == 0`               | 4     |
| `op_call`      | 7     | dst, fn_idx, arg_reg                  | `vDst := fn[idx](vArg)` (1-arg ABI)  | 12    |
| `op_ret`       | 8     | src, _, _                             | `return vSrc`                        | 16    |
| `op_print_int` | 9     | src, _, _                             | `printf("%lld\n", vSrc)` to fd 1     | 80    |
| `op_mov`       | 10    | dst, src                              | `vDst := vSrc`                       | 4     |

### Instruction encoding

Each instruction occupies 4 consecutive `int_arr` slots: `[op, a, b, c]`. Instruction `i` lives at `[4*i .. 4*i+3]`. Build with `ir_emit ir i op a b c` (defined in `jit/ir.rail`).

### Function struct

A function is a Rail list `[ir_arr, n_instructions, n_regs, block_offsets_arr]`. Construct with `make_fn ir n_instr n_regs blocks`. `block_offsets_arr[k]` is the start instruction index of block `k`.

### Register ABI v1

| vreg       | preg       | Class                                              |
| ---------- | ---------- | -------------------------------------------------- |
| `v0..v9`   | `x9..x18`  | caller-save: clobbered by `op_call`                |
| `v10..v19` | `x19..x28` | callee-save: preserved across `op_call`            |

For v1, only `x19/x20` are actually saved by the prologue, so use `v10/v11` for cross-call preservation. To copy a value into callee-save, use `op_mov v10 v0`.

The function entry point: `v0 = x0` is the input arg (set by the prologue's `mov v0, x0`). The return value goes through `x0` (set by `op_ret`'s `mov x0, vSrc`).

## API surface

```rail
import "jit/emit.rail"
import "jit/loader.rail"

-- 1. Build the IR
let fn = build_fact          -- (or any function constructed with make_fn)

-- 2. Emit ARM64 bytes
let res = emit_program (cons fn [])    -- multi-fn list; first fn is entry
-- or, for a single function:
let res = emit_function fn

let buf     = emitted_buf res          -- int_arr of bytes
let nbytes  = emitted_size res
let offsets = emitted_offsets res      -- only for emit_program

-- 3. Load + run
let page = make_executable buf nbytes  -- mmap RW, copy, mprotect RX, icache
let result = call_jit page arg_int     -- pthread_create + pthread_join
let _ = free_jit page
```

## Worked example: factorial

```rail
build_fact =
  let n_instr = 11
  let ir = arr_new (n_instr * 4) 0
  let _ = ir_emit ir 0  op_mov   10 0 0    -- v10 := v0  (preserve n)
  let _ = ir_emit ir 1  op_const 1 2 0     -- v1 := 2
  let _ = ir_emit ir 2  op_lt    2 0 1     -- v2 := (v0 < v1)
  let _ = ir_emit ir 3  op_jz    2 1 0     -- if v2 == 0 goto block 1
  let _ = ir_emit ir 4  op_const 3 1 0     -- v3 := 1
  let _ = ir_emit ir 5  op_ret   3 0 0     -- return v3        (block 0 end)
  let _ = ir_emit ir 6  op_const 3 1 0     -- v3 := 1          (block 1 start)
  let _ = ir_emit ir 7  op_sub   4 0 3     -- v4 := v0 - v3
  let _ = ir_emit ir 8  op_call  5 0 4     -- v5 := fn0(v4)    (recursive)
  let _ = ir_emit ir 9  op_mul   6 10 5    -- v6 := v10 * v5
  let _ = ir_emit ir 10 op_ret   6 0 0     -- return v6
  let blocks = arr_new 2 0
  let _ = arr_set blocks 0 0
  let _ = arr_set blocks 1 6
  make_fn ir 11 11 blocks
```

`fact(5) = 120`, `fact(0) = 1`. Total emitted code: 132 bytes.

## File map

| File                     | Purpose                                                                   |
| ------------------------ | ------------------------------------------------------------------------- |
| `ir.rail`                | Opcode constants + `int_arr` accessors + function-struct helpers          |
| `parse.rail`             | Stack-VM bytecode text → IR                                               |
| `print.rail`             | IR → human-readable string                                                |
| `fixtures_ir.rail`       | Hand-built IR for tests                                                   |
| `opt_const_fold.rail`    | IR → IR const-fold pass                                                   |
| `opt_dce.rail`           | IR → IR dead-code elimination                                             |
| `profile.rail`           | Counter helpers for hot-path detection                                    |
| `icache.rail`            | Inline-cache record/lookup                                                |
| `arm64.rail`             | ARM64 instruction encoders                                                |
| `codebuf.rail`           | Byte-oriented code buffer                                                 |
| `ffi.rail`               | foreign bindings: mprotect, sys_icache_invalidate, pthread, malloc, etc.  |
| `emit.rail`              | IR → ARM64 lowering (single + multi-fn)                                   |
| `loader.rail`            | mmap RW → write → mprotect RX → pthread_create → pthread_join             |
| `test_*.rail`            | One test driver per layer                                                 |

## Audit caveats (v1)

1. **`pthread_create` overhead** — every `call_jit` spawns a thread (~50–200 µs on Apple Silicon). One JIT call per rollout: sub-ms holds. N calls per rollout: pthread spawn dominates. Direct-call (`blr`) needs a `compile.rail` primitive — not in v1.
2. **Page leak** — `make_executable` allocates a 4 KB page; `free_jit` exists but tests don't always call it. Cosmetic for short-lived tests.
3. **No hardened-runtime entitlement** — works only because `./rail_native` is dev-built. A signed/notarized binary would need `MAP_JIT` + `pthread_jit_write_protect_np` toggling, or `com.apple.security.cs.allow-jit`.
4. **Register-pressure cliff** — `preg vreg = vreg + 9` so `v0..v19` map to `x9..x28`. `v20+` would clobber `x29` (FP) / `x30` (LR). Documented as v1 limit; no compile-time guard.
5. **Negative-int handling in `emit_const`** — `bit_and imm 65535` extracts low chunk fine; high movks need sign-extension for negative values. Untested. Fixtures use only non-negative ints.
6. **`op_print_int` of negative ints** — currently the divide-by-10 loop assumes `n >= 0`. Negative inputs would behave incorrectly. v2: detect sign, emit `-` prefix.
7. **Fixed `emit_const` budget** — always emits 4 instructions (`movz` + 3 `movk`) even for small constants — wasteful but keeps block offsets stable.
8. **Only x19/x20 are callee-saved** — per the v1 ABI table. Higher vregs (v12..v19) work but aren't preserved across calls. v2: scan IR for max vreg used, save the spanning pairs.

## How to extend

* **Add an opcode**: pick a new int (`op_X = N` in `ir.rail`), update `ir_op_name`, add a size in `ir_byte_size` (`emit.rail`), add an `else if op == op_X` branch in `emit_one`. If the opcode emits more than ~4 instructions, factor out an `emit_X_impl`.
* **Add an encoder**: define `enc_X` in `arm64.rail`. Always verify against `as`+`otool` round-trip. Add to `test_enc.rail`.
* **Add a fixture**: hand-build IR in `test_codegen.rail` using `ir_emit`; call `run_program` (multi-fn) or `run_fixture` (single-fn).

## Building C trampoline (optional)

If you want to switch the loader from `pthread_create` to a `dlopen`-based path, build the trampoline:

```bash
sh jit/build_trampoline.sh   # produces jit/libjit_call.dylib
```

Currently unused — `pthread_create` does the indirect-call dance without it.
