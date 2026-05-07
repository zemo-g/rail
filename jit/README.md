# Rail JIT (v1)

A pure-Rail JIT compiler that lowers a small bytecode IR to ARM64 machine code, mmaps it executable, and runs it via `pthread_create` as the indirect-call mechanism. No `compile.rail` edits required; built entirely on `stdlib/mmap.rail` + `stdlib/dlopen.rail` + raw libSystem `foreign` bindings.

End-to-end: integer arithmetic, recursive multi-arg functions, string literals + builtins, and stdout printing (decimal ints + raw strings) via `svc` syscall. List opcodes are wired through lowering + emit but execution is blocked on a foreign-pointer ABI issue (see Stage 5 caveat below).

## Quick start

```bash
./rail_native run jit/test_codegen.rail   # 8 fixtures: addk, sq1, fact5/1/0, fib10/0/1
./rail_native run jit/test_print.rail     # 5 print fixtures: 42, 0, 1, 12345, 999999
./rail_native run jit/test_parse.rail     # 5 round-trip parse tests
./rail_native run jit/test_opt.rail       # 29 optimizer/profiler/icache assertions
./rail_native run jit/test_enc.rail       # 17 ARM64 encoder unit tests
./rail_native run jit/test_lower.rail     # 26 end-to-end source -> JIT tests (Stages 3+4)
```

## IR contract

### Opcodes (in `jit/ir.rail`)

| Opcode          | Value | Slots (a, b, c)                       | Semantics                                     | Bytes |
| --------------- | ----- | ------------------------------------- | --------------------------------------------- | ----- |
| `op_const`      | 0     | dst, imm, _                           | `vDst := imm`                                 | 16    |
| `op_add`        | 1     | dst, src1, src2                       | `vDst := vSrc1 + vSrc2`                       | 4     |
| `op_sub`        | 2     | dst, src1, src2                       | `vDst := vSrc1 - vSrc2`                       | 4     |
| `op_mul`        | 3     | dst, src1, src2                       | `vDst := vSrc1 * vSrc2`                       | 4     |
| `op_lt`         | 4     | dst, src1, src2                       | `vDst := (vSrc1 < vSrc2) ? 1 : 0`             | 8     |
| `op_jmp`        | 5     | block_idx, _, _                       | unconditional branch                          | 4     |
| `op_jz`         | 6     | cond, block_idx, _                    | branch if `vCond == 0`                        | 4     |
| `op_call`       | 7     | dst, fn_idx, packed_args              | `vDst := fn[idx](args...)` (1..4 args; ABI)   | 4..20 |
| `op_ret`        | 8     | src, _, _                             | `return vSrc`                                 | 16    |
| `op_print_int`  | 9     | src, _, _                             | `printf("%lld\n", vSrc)` to fd 1              | 80    |
| `op_mov`        | 10    | dst, src, _                           | `vDst := vSrc`                                | 4     |
| `op_str_lit`    | 11    | dst, pool_off, _                      | `vDst := &pool[pool_off]` (PC-relative `adr`) | 4     |
| `op_print_str`  | 12    | src_ptr, _, _                         | `write(1, str+8, *str)` length-prefixed       | 20    |
| `op_str_len`    | 13    | dst, src_ptr, _                       | `vDst := *src_ptr` (read length prefix)       | 4     |
| `op_str_eq`     | 14    | dst, s1_ptr, s2_ptr                   | `vDst := (s1 == s2) ? 1 : 0` byte loop        | 72    |
| `op_str_at`     | 15    | dst, src_ptr, idx                     | `vDst := zext(src_ptr[8 + idx])`              | 8     |
| `op_nil`        | 16    | dst, _, _                             | `vDst := 0` (nil sentinel)                    | 4     |
| `op_cons`       | 17    | dst, head_val, tail_ptr               | bump-alloc 16B cell, write [head, tail]       | 24    |
| `op_head`       | 18    | dst, src_ptr, _                       | `vDst := *src_ptr`                            | 4     |
| `op_tail`       | 19    | dst, src_ptr, _                       | `vDst := *(src_ptr + 8)`                      | 4     |
| `op_is_nil`     | 20    | dst, src_ptr, _                       | `vDst := (src_ptr == 0) ? 1 : 0`              | 8     |

### `op_call` packed-arg encoding

Slot `c` packs `n_args` (1..4 supported in v1) and up to four 5-bit arg vregs:

```
bits  0..3   n_args (1..4)
bits  4..8   arg0 vreg
bits  9..13  arg1 vreg
bits 14..18  arg2 vreg
bits 19..23  arg3 vreg
```

Build with `call_pack_1 a` / `call_pack_2 a b` / `call_pack_3 a b c` / `call_pack_4 a b c d` (all in `jit/ir.rail`). Decode with `call_n_args c` and `call_arg_0..3 c`. The lowerer fills these in for you; hand-written IR uses them directly (see `jit/test_codegen.rail:build_fact` and `build_fib`).

The emitted call sequence is `mov x0..xN-1, vArg0..vArgN-1` (one per arg) + `bl <target_offset>` + `mov vDst, x0` — total `4 + 4 + 4*n_args` bytes.

### Instruction encoding

Each instruction occupies 4 consecutive `int_arr` slots: `[op, a, b, c]`. Instruction `i` lives at `[4*i .. 4*i+3]`. Build with `ir_emit ir i op a b c` (defined in `jit/ir.rail`).

### Function struct

A function is a Rail list `[ir_arr, n_instructions, n_regs, block_offsets_arr, n_args]`. Construct with `make_fn ir n_instr n_regs blocks` (defaults `n_args = 1`, back-compat) or `make_fn_n ir n_instr n_regs blocks n_args` (new; `n_args ∈ 0..4`). `block_offsets_arr[k]` is the start instruction index of block `k`.

### Register ABI v1

| vreg       | preg       | Class                                              |
| ---------- | ---------- | -------------------------------------------------- |
| `v0..v9`   | `x9..x18`  | caller-save: clobbered by `op_call`                |
| `v10..v19` | `x19..x28` | callee-save: preserved across `op_call`            |

For v1, only `x19/x20` are actually saved by the prologue, so use `v10/v11` for cross-call preservation. To copy a value into callee-save, use `op_mov v10 v0`. The lowerer auto-allocates callee slots when an expression contains a call that would otherwise clobber a live caller-save vreg.

For multi-arg fns, args arrive in `x0..x{n_args-1}`; the prologue emits `mov v0_preg, x0`, `mov v1_preg, x1`, …, one per arg.

### Heap (`jit/heap.rail`)

A separate 64 KB mmap'd RW page used for cons-cell allocation. Layout: bump pointer at offset 0, cells start at offset 8. Each cell is 16 bytes (`[head_value, tail_pointer]`); nil sentinel is `0`.

```rail
let heap = heap_alloc 0     -- mmap a fresh 64 KB heap page
... emit + run JIT here ...
let _ = heap_free heap
```

`emit_function` and `emit_program` accept `heap` as their last argument and bake the heap address into the JIT page so `op_cons`/`op_head`/`op_tail` can dereference it via `x27` (loaded once in the prologue).

**Stage 5 unblocked 2026-05-06:** Rail represents `foreign` pointer returns as `(real_addr >> 1)`; the foreign boundary multiplies by 2 when passing args to C. `heap_alloc` now does `shl p 1` before storing the bump pointer, so the JIT-side `ldr [x27]` reads the real address. Heap is passed as `call_jit`'s arg slot (ABI v2): the prologue captures `mov x27, x0` immediately. End-to-end verified: `len [1,2,3,4,5]` returns 5; `sum [10,20,30]` returns 60.

## Canonical import order

Rail imports aren't deduped, so each direct-importer file must include `ir.rail` exactly once via the canonical chain. Use this order in the test driver / your own caller:

```rail
import "jit/heap.rail"     -- canonical importer for stdlib/mmap.rail + jit/ffi.rail
import "jit/emit.rail"     -- transitively brings ir.rail, arm64.rail, codebuf.rail
import "jit/loader.rail"
import "jit/lower.rail"    -- transitively brings lex.rail, syntax.rail
```

`jit/lower.rail` deliberately does NOT import `jit/ir.rail`; it relies on the caller having imported `emit.rail` first. `jit/loader.rail` relies on `heap.rail` for `mmap.rail` + `ffi.rail`.

## API surface

```rail
import "jit/heap.rail"
import "jit/emit.rail"
import "jit/loader.rail"
import "jit/lower.rail"

-- Path 1: hand-built IR
let fn   = build_fact                  -- (or any function from make_fn / make_fn_n)
let heap = heap_alloc 0
let res  = emit_program (cons fn []) [] heap
-- or single-fn shorthand:
let res  = emit_function fn heap

-- Path 2: lower from Rail source
let r    = lower_source "fact n = if n < 2 then 1 else n * fact (n - 1)\nmain = fact 5"
let fns  = head (tail r)
let pool = head (tail (tail r))
let heap = heap_alloc 0
let res  = emit_program fns pool heap

-- Common tail: load + run
let buf     = emitted_buf res
let nbytes  = emitted_size res
let offsets = emitted_offsets res        -- only for emit_program
let page    = make_executable buf nbytes
let result  = call_jit page arg_int      -- pthread_create + pthread_join
let _       = free_jit page
let _       = heap_free heap
```

`lower_source` returns `["ok", fns, pool]` on success or `["err", msg]` on failure.

## Worked examples

### Single-arg recursion (`fact 5 = 120`)

```rail
let r = lower_source "fact n = if n < 2 then 1 else n * fact (n - 1)\nmain = fact 5"
-- result: 120
```

### Multi-arg user fn

```rail
let r = lower_source "add a b = a + b\nmain = add 7 13"
-- result: 20
```

```rail
let r = lower_source "muladd a b c = a * b + c\nmain = muladd 4 5 6"
-- result: 26
```

### String literal print

```rail
let r = lower_source "main = print \"hello\""
-- stdout: hello
```

### String comparison + branch

```rail
let r = lower_source "main = if str_eq \"abc\" \"abc\" then 1 else 0"
-- result: 1
```

### Let-bound string

```rail
let r = lower_source "main = let s = \"hello\" in print s"
-- stdout: hello
```

### Hand-built IR (factorial)

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
  let _ = ir_emit ir 8  op_call  5 0 (call_pack_1 4)  -- v5 := fn0(v4) recurse
  let _ = ir_emit ir 9  op_mul   6 10 5    -- v6 := v10 * v5
  let _ = ir_emit ir 10 op_ret   6 0 0     -- return v6
  let blocks = arr_new 2 0
  let _ = arr_set blocks 0 0
  let _ = arr_set blocks 1 6
  make_fn ir 11 11 blocks
```

`fact(5) = 120`, `fact(0) = 1`. Total emitted code: 132 bytes (single-fn `emit_function`; `emit_program` adds an 8-byte heap-addr slot).

## File map

| File                     | Purpose                                                                   |
| ------------------------ | ------------------------------------------------------------------------- |
| `ir.rail`                | Opcode constants + `int_arr` accessors + function-struct helpers + call_pack_*/call_arg_* |
| `parse.rail`             | Stack-VM bytecode text → IR                                               |
| `print.rail`             | IR → human-readable string                                                |
| `fixtures_ir.rail`       | Hand-built IR for tests                                                   |
| `lex.rail`               | Rail-subset tokenizer (idents, ints, ops, strings with `\n \t \\ \"` escapes) |
| `syntax.rail`            | Recursive-descent parser → AST                                            |
| `lower.rail`             | Rail source → fn-list + string pool (Stage 3+4)                           |
| `opt_const_fold.rail`    | IR → IR const-fold pass                                                   |
| `opt_dce.rail`           | IR → IR dead-code elimination                                             |
| `profile.rail`           | Counter helpers for hot-path detection                                    |
| `icache.rail`            | Inline-cache record/lookup                                                |
| `arm64.rail`             | ARM64 instruction encoders (incl. `enc_adr` for PC-relative addresses)    |
| `codebuf.rail`           | Byte-oriented code buffer                                                 |
| `ffi.rail`               | foreign bindings: mprotect, sys_icache_invalidate, pthread, malloc, etc.  |
| `heap.rail`              | Bump-pointer cons-cell heap; canonical importer for mmap.rail + ffi.rail  |
| `emit.rail`              | IR → ARM64 lowering (single + multi-fn; pool + heap-addr layout)          |
| `loader.rail`            | mmap RW → write → mprotect RX → pthread_create → pthread_join             |
| `test_*.rail`            | One test driver per layer                                                 |

## Audit caveats (v1)

1. **`pthread_create` overhead** — every `call_jit` spawns a thread (~50–200 µs on Apple Silicon). One JIT call per rollout: sub-ms holds. N calls per rollout: pthread spawn dominates. Direct-call (`blr`) needs a `compile.rail` primitive — not in v1.
2. **Page leak** — `make_executable` allocates a 4 KB page; `free_jit` exists but tests don't always call it. Cosmetic for short-lived tests. Heap pages need `heap_free` similarly.
3. **No hardened-runtime entitlement** — works only because `./rail_native` is dev-built. A signed/notarized binary would need `MAP_JIT` + `pthread_jit_write_protect_np` toggling, or `com.apple.security.cs.allow-jit`.
4. **Register-pressure cliff** — `preg vreg = vreg + 9` so `v0..v19` map to `x9..x28`. `v20+` would clobber `x29` (FP) / `x30` (LR). Documented as v1 limit; no compile-time guard. The lowerer caps callee-save at v10/v11 (matching prologue's stp pair).
5. **Negative-int handling in `emit_const`** — `bit_and imm 65535` extracts low chunk fine; high movks need sign-extension for negative values. Untested. Fixtures use only non-negative ints.
6. **`op_print_int` of negative ints** — currently the divide-by-10 loop assumes `n >= 0`. Negative inputs would behave incorrectly. v2: detect sign, emit `-` prefix.
7. **Fixed `emit_const` budget** — always emits 4 instructions (`movz` + 3 `movk`) even for small constants — wasteful but keeps block offsets stable.
8. **Only x19/x20 are callee-saved** — per the v1 ABI table. Higher vregs (v12..v19) work but aren't preserved across calls. v2: scan IR for max vreg used, save the spanning pairs.
9. **Foreign-pointer ABI blocker for lists** — heap_addr baked into the JIT page (via `byte_set` on Rail-handle bytes) doesn't match the real address Rail's foreign boundary yields, so `ldr [x27]` faults. List execution disabled until one of the three unblock paths in `NEXT_STAGES.md` lands. Lowering machinery is shipped and ready.
10. **`op_call` arity cap** — 1..4 args supported (5-bit vreg fields × 4 slots in packed `c`). `lower_source` rejects `>4`-arg fn defs with a clear error.
11. **String pool max 16 KB per program** — `max_pool_bytes` in `lower.rail`. Larger corpora bump it; no run-time check beyond the fail message.

## How to extend

* **Add an opcode**: pick a new int (`op_X = N` in `ir.rail`), update `ir_op_name`, add a size in `ir_byte_size` (`emit.rail`), add an `else if op == op_X` branch in `emit_one`. If the opcode emits more than ~4 instructions, factor out an `emit_X_impl`.
* **Add a builtin to the lowerer**: add to `is_builtin` in `lower.rail`, add a `lower_builtin_X` function, route through `lower_builtin`. Update `is_safe_builtin` if the new op doesn't clobber caller-save vregs (so `contains_call` can return 0 for it).
* **Add an encoder**: define `enc_X` in `arm64.rail`. Always verify against `as`+`otool` round-trip. Add to `test_enc.rail`.
* **Add a fixture**: hand-build IR in `test_codegen.rail` using `ir_emit`; call `run_program` (multi-fn) or `run_fixture` (single-fn).

## Building C trampoline (optional)

If you want to switch the loader from `pthread_create` to a `dlopen`-based path, build the trampoline:

```bash
sh jit/build_trampoline.sh   # produces jit/libjit_call.dylib
```

Currently unused — `pthread_create` does the indirect-call dance without it.
