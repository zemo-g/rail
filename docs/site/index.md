# Rail

Rail is a self-hosted ARM64 language with six backends (macOS ARM64, Linux ARM64, Linux x86_64, WebAssembly, Cortex-M4, RISC-V rv32imc), an LLM training substrate, and a verifiable provenance layer. The compiler is 8,049 lines of Rail (`wc -l tools/compile.rail`) compiling itself byte-identically at gen2; the runtime is ARM64 assembly embedded in the compiler. Zero C dependencies. One binary.

## Quickstart

```bash
git clone https://github.com/zemo-g/rail
cd rail
./rail_native run examples/hello.rail
```

Expected output:

```
Compiling examples/hello.rail (244 chars)...
  as: OK
  ld: OK
hello, rail
3628800
42
```

The seed binary (`rail_native`, 1,193,744 bytes — ~1.2 MB ARM64) is checked into the repo and self-compiles to a byte-identical fixed point at gen2 (the first cycle may differ; gen2 == gen3 always). No build step before "hello, world".

For Apple Silicon you're done. Other targets need cross-toolchains — see [backends.md](backends.md).

## What's here

- **[quickstart.md](quickstart.md)** — eleven steps from `git clone` to a verified release attestation. Real commands, real outputs.
- **[PROOFS.md](../../PROOFS.md)** — the claim ledger. Every public claim in the README carries a receipt ID; `bash tools/prove/prove.sh` replays them from a bare clone.
- **[stdlib.md](stdlib.md)** — auto-generated reference for every top-level function in `stdlib/*.rail` (94 modules — `ls stdlib/*.rail | wc -l`). Regenerate with `./rail_native run tools/docs/gen_stdlib_ref.rail`.
- **[backends.md](backends.md)** — one-page-per-backend with the literal command line you'd type.
- **[jit.md](jit.md)** — a self-hosted JIT in pure Rail. ARM64 emit + `mmap`-executable, called via a `pthread_create` trampoline. ~6,600 LoC across 20 files.
- **[examples/](examples/)** — 23 program walkthroughs with source, command, and real captured output. Start with [hello](examples/hello.md), [pattern_matching](examples/pattern_matching.md), [calculator](examples/calculator.md).
- **[TODO.md](TODO.md)** — what's deferred for v0 and why.

## Language at a glance

```rail
-- Comments start with --
add a b = a + b
factorial n = if n <= 1 then 1 else n * factorial (n - 1)

type Option = | Some x | None
unwrap opt d = match opt
  | Some x -> x
  | None -> d

main =
  let _ = print (show (factorial 10))      -- 3628800
  let _ = print (show (unwrap (Some 42) 0)) -- 42
  0
```

Functions are `name args = body`. `main` is the entry point and returns an int. ADTs use `type T = | Ctor args | ...`. Pattern matching uses `match` (no `with`). Tail calls are compiled to loops with no stack growth.

## Six backends, one compiler

```bash
./rail_native run file.rail        # macOS ARM64 (native execute)
./rail_native linux file.rail      # Linux ARM64 (cross)
./rail_native x86 file.rail        # Linux x86_64 (cross, emits .s)
./rail_native wasm file.rail       # WebAssembly
./rail_native cortexm file.rail    # Cortex-M4 (Thumb-2)
./rail_native riscv32 file.rail    # RISC-V rv32imc
```

The same source compiles to all of them. See [backends.md](backends.md) for toolchain requirements.

## Why it exists

The thesis is in [CLAUDE.md](../../CLAUDE.md): the compiler is the source of truth. The HTTPS client, the training loop, the documentation generator you're reading — all are compiled by the same binary you cloned. If it compiles, it runs.

The closer-term motivation for *this* documentation: open-source LLMs are bad at Rail because there's no Rail corpus to read. These pages, together with the auto-generated stdlib reference, are the substrate fix.
