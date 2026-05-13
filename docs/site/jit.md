# JIT

Rail ships its own JIT compiler, written in Rail, in `jit/`. It lowers a small bytecode IR to ARM64 machine code, `mmap`s the bytes executable, and calls them via a foreign-call trampoline. About 6,600 lines across 20 source files. No C extensions, no LLVM, no external dependency beyond `libSystem` (for `mprotect` and `pthread_create`).

## Why it's here

If the claim is *substrate, not model* — the substrate is the verifier, the substrate is the compiler, the substrate is what the language can do for itself — then a self-hosted JIT is the bluntest version of that claim. The compiler can not just produce machine code from disk; from within a running Rail program, it can produce machine code for a new function, install it, and call it. The verifier isn't a black box you query — it's a library you import.

This is the difference between *a small language that compiles to native code* and *a substrate*.

## End-to-end demo

```bash
./rail_native run jit/test_codegen.rail
```

```
[fact5] emitted 196 bytes
JIT WORKS: 120
[fact1] emitted 196 bytes
JIT WORKS: 1
[fact0] emitted 196 bytes
JIT WORKS: 1
[fib10] emitted 216 bytes
JIT WORKS: 55
[fib0] emitted 216 bytes
JIT WORKS: 0
[fib1] emitted 216 bytes
JIT WORKS: 1
ALL PASS
```

Each line is a Rail program lowered to IR, emitted as ARM64 bytes, `mmap`ed executable, called, and the result returned to the running Rail process. `196 bytes` is the entire compiled `fact` (8-instruction loop including prologue and epilogue). `JIT WORKS: 120` is `fact 5` computed by the JIT-emitted code.

## What works

| Feature | Status |
|---|---|
| Integer arithmetic (`+`, `-`, `*`, `<`, `==`, etc.) | shipped |
| Branches, loops, recursion | shipped |
| Multi-argument user functions | shipped |
| String literals + `print`/`str_eq`/`str_len`/`str_at` | shipped |
| Cons cells / `head` / `tail` / `is_nil` (lowering only) | partial — execution blocked on foreign-pointer ABI |
| Float arithmetic, float user-fn args, float returns | shipped (P4) |
| Lambdas (compile-time inline substitution) | shipped (P3) |
| Higher-order functions via `op_apply` | shipped |
| Builtins: `not`, `&&`, `||`, `read_file` | shipped |

Per-stage history is in [`jit/CHANGELOG.md`](https://github.com/zemo-g/rail/blob/main/jit/CHANGELOG.md).

## Verify the floor

```bash
./rail_native run jit/test_codegen.rail   # 8 end-to-end fixtures
./rail_native run jit/test_enc.rail       # 17 ARM64 encoder unit tests + 8 ldp/stp
./rail_native run jit/test_opt.rail       # 29 optimizer + profiler + icache assertions
./rail_native run jit/test_lower.rail     # 26 source → JIT tests (multi-stage)
./rail_native run jit/test_print.rail     # 5 stdout fixtures
./rail_native run jit/test_parse.rail     # 5 IR-roundtrip tests
```

All six are exit-0 + last-line `PASS`/`OK`-shaped on macOS ARM64.

## How it's structured

| File | Role |
|---|---|
| `jit/ir.rail` | Opcodes (21 ops), accessors, IR struct helpers |
| `jit/parse.rail` | Parser for the in-tree IR text format |
| `jit/lex.rail` | Source-text lexer for lower-from-source flow |
| `jit/lower.rail` | Source AST → IR lowering, register allocation, liveness |
| `jit/opt_const_fold.rail` | Per-block constant propagation + folding |
| `jit/opt_dce.rail` | Dead-code elimination + block-offset remap |
| `jit/arm64.rail` | 39 ARM64 instruction encoders, all verified against `as`+`objdump` |
| `jit/codebuf.rail` | Byte-granular code buffer (little-endian word emit) |
| `jit/emit.rail` | Two-pass IR → bytes; per-op size budget keeps block offsets stable |
| `jit/loader.rail` | `mprotect` + `sys_icache_invalidate` + indirect-call trampoline |
| `jit/ffi.rail` | Foreign bindings for `mprotect`, `pthread_create`, `pthread_join`, `read_u64`, `write_u64` |
| `jit/heap.rail` | Bump-pointer cons-cell heap (64 KB mmap'd page) |
| `jit/icache.rail` | Monomorphic inline cache (3-int records) |
| `jit/profile.rail` | Per-site hot-counter primitives |
| `jit/grade.rail` | Bench grader using JIT for compatible programs |
| `jit/parity_check.rail` | Differential check: interpreter result vs JIT result |

The IR contract (opcode table, `op_call` packed-arg encoding, block layout) is documented in [`jit/README.md`](https://github.com/zemo-g/rail/blob/main/jit/README.md).

## The trampoline trick

Calling JIT-emitted code from a host language usually needs either inline assembly or a C shim. Rail does it through `pthread_create`: the executable page address is passed as the thread start-routine, the argument is passed as the user data pointer, and the result comes back via `pthread_join`'s join-value. No `compile.rail` edits, no extra dylib link. `jit/loader.rail` is ~50 lines.

A direct-call trampoline (`tools/jit_call.c`, ~20 lines of C) is checked in as an option but unused on the default path; the pthread approach avoids the cross-language link entirely.

## Limitations (honest)

- **List execution blocked.** Cons cells lower and emit; bumping the heap fails because Rail's foreign-pointer ABI returns opaque handles, not real addresses. The lowering machinery is shipped behind the blocker. Three unblock paths are sketched in [`jit/NEXT_STAGES.md`](https://github.com/zemo-g/rail/blob/main/jit/NEXT_STAGES.md).
- **ARM64 only.** No x86 JIT yet. The encoders, the loader, and the trampoline are all macOS-ARM64-specific.
- **Subset of the language.** No ADTs, no effect handlers, no full pattern matching. List-pattern `match` is supported. The covered subset is what the bench grader's "lower-hit" set runs JIT-fast; the rest falls back to the regular compiler path.

The 2.06× real-corpus wall-clock speedup in `jit/grade.rail` over the regular compile path is on the covered subset; full coverage would change the multiplier.

## Where to start reading

If you want to convince yourself the JIT is real, the shortest path is:

1. `jit/test_codegen.rail:build_fact` — hand-built IR for `factorial`.
2. `jit/emit.rail` — find `emit_op_add` (~20 LoC) to see one opcode → bytes.
3. `jit/loader.rail` — `make_executable` + `call_jit`, ~50 LoC total.

That's the substrate-honesty argument compressed to three files.
