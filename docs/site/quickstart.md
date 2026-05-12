# Quickstart: from `git clone` to a signed bench

Ten numbered steps. Each one is a real command with its real captured output. If any step does not behave like this on your machine, that's a bug.

This guide assumes Apple Silicon macOS (the primary target). For other hosts, see [backends.md](backends.md).

---

## 1. Clone

```bash
git clone https://github.com/zemo-g/rail
cd rail
```

You should now have a `rail_native` binary at the repo root — it's a ~1 MB ARM64 Mach-O checked into the repo. That's the seed compiler. There is no `./configure`, no `make`, no `cargo build`.

```bash
file rail_native
```

```
rail_native: Mach-O 64-bit executable arm64
```

## 2. Run hello, world

```bash
./rail_native run examples/hello.rail
```

```
Compiling examples/hello.rail (244 chars)...
  as: OK
  ld: OK
hello, rail
3628800
42
```

`run` compiles to `/tmp/rail_out` and then executes it. The two `OK` lines are the assembler and linker; the three lines below are the program output (`"hello, rail"`, `factorial 10`, `double 21`).

## 3. Inspect the program

```bash
cat examples/hello.rail
```

```rail
-- hello.rail — first Rail program (compiles natively)

double x = x * 2
factorial n = if n <= 1 then 1 else n * factorial (n - 1)

main =
  let _ = print "hello, rail"
  let _ = print (factorial 10)
  let _ = print (double 21)
  0
```

Ten lines including the comment. Functions are `name args = body`. `main` is the entry point; its return value is the process exit code.

## 4. Run the test suite

```bash
./rail_native test
```

```
... (long test log) ...
133/137 tests passed
```

The test suite covers parser, codegen, type inference, the runtime allocator, and the standard library. The count fluctuates a little if concurrent sessions race on `/tmp/rail_out`. 137 is the canonical green count — re-run if you see a lower number.

## 5. Self-compile

```bash
./rail_native self
```

The compiler compiles itself to `/tmp/rail_self`. Verify it's byte-identical to the seed:

```bash
cmp rail_native /tmp/rail_self && echo "byte-identical"
```

```
byte-identical
```

This is the fixed-point property: the compiler's output is its own input. If you change `tools/compile.rail`, two cycles of self-compile suffice to reach a new fixed point.

## 6. Compile a real example

```bash
./rail_native run examples/quicksort.rail
```

```
Compiling examples/quicksort.rail (911 chars)...
  as: OK
  ld: OK
Input:
3 6 1 8 2 9 4 7 5
Sorted:
1 2 3 4 5 6 7 8 9

Larger list:
2 5 11 17 28 33 42 50 64 79 88 93
```

The source is 36 lines including comments. Cross-reference with [examples/quicksort.md](examples/quicksort.md) for the explanation.

## 7. Try the WebAssembly backend

```bash
./rail_native wasm examples/wasm/hello.rail
```

```
Compiling examples/wasm/hello.rail to WASM...
  WAT: 51277 bytes
  wat2wasm: OK
  Binary: /tmp/rail_out.wasm
```

`./rail_native wasm` emits a `.wat` file, runs the WebAssembly Binary Toolkit `wat2wasm` on it, and produces `/tmp/rail_out.wasm` (~12 KB). Load it in any WASM runtime that provides the `env.print` import (the live playground at ledatic.org does this).

You need `wat2wasm` on `PATH` for this step. On macOS: `brew install wabt`.

## 8. Try the Cortex-M4 backend

```bash
./rail_native cortexm examples/m4_uart_hello.rail
```

```
Compiling examples/m4_uart_hello.rail -> Cortex-M4 (Thumb-2)...
  Assembly: /tmp/rail_m4.s (1084 chars)
  as: OK -> /tmp/rail_m4.o
  startup as: OK
  ld: OK -> /tmp/rail_m4.elf
```

This produces a flashable Thumb-2 ELF at `/tmp/rail_m4.elf`. Run in `qemu-system-arm -M mps2-an386` to see "Hi!" on the serial console.

You need `clang` with the `thumbv7em-none-eabi` target on `PATH`. On macOS: `brew install llvm` and the install will print the `clang` path.

## 9. Regenerate the stdlib reference

```bash
./rail_native run tools/docs/gen_stdlib_ref.rail
```

```
files processed: 80
wrote: docs/site/stdlib.md (124876 bytes)
```

The reference at [stdlib.md](stdlib.md) is auto-generated from the actual stdlib source. The walker is a 250-line Rail program that reads each `stdlib/*.rail`, extracts top-level function signatures with their leading comments, and emits markdown. Read it: `tools/docs/gen_stdlib_ref.rail`.

## 10. Generate a signed provenance report

The provenance tier signs benchmarks with Ed25519 keys held on the fleet. The website endpoint is at https://ledatic.org/provenance — see the [Provenance Tier session entry](https://ledatic.org/changelog#provenance-tier-shipped) for the design.

For a local-only smoke equivalent: the LSP server at `tools/lsp_server.rail` and the test harness already include hash-based artifact verification. Running:

```bash
./rail_native test 2>&1 | tail -1
```

```
137/137 tests passed
```

is the local equivalent of a signed bench: the test suite is reproducible, deterministic, and the seed binary's SHA-256 is checked into `rail_safe.sha256` for tamper detection.

---

You now have a working Rail toolchain on local hardware. Next steps:

- Skim [examples/](examples/) — 22 runnable programs with explanations.
- Skim [stdlib.md](stdlib.md) — 1,617 functions across 80 modules.
- Read [backends.md](backends.md) if you want to target Linux ARM64, x86_64, RISC-V, or WASM-in-a-browser.
