# Backends

One Rail compiler, six targets. All driven from the same `rail_native` binary.

| Backend | Verb | Output | Toolchain needed | Status (local-verified) |
|---|---|---|---|---|
| macOS ARM64 (Mach-O) | _(default)_ / `run` | `/tmp/rail_out` | none (host `as`+`ld`) | runs end-to-end |
| Linux ARM64 (ELF) | `linux` | `/tmp/rail_linux` | `aarch64-elf-as`, `aarch64-elf-ld` | needs cross-binutils |
| Linux x86_64 (ELF, source-only) | `x86` | `/tmp/rail_x86.s` | remote `gcc` (or Docker `linux/amd64`) | emits `.s`, 71/79 conformance via Docker harness |
| WebAssembly | `wasm` | `/tmp/rail_out.wasm` | `wat2wasm` (wabt) | compiles end-to-end |
| Cortex-M4 (Thumb-2 ELF) | `cortexm` | `/tmp/rail_m4.elf` | `clang --target=thumbv7em-none-eabi` | compiles end-to-end |
| RISC-V rv32imc (ELF) | `riscv32` | `/tmp/rail_rv32.elf` | `clang --target=riscv32-unknown-none-elf` | compiles end-to-end |

---

## macOS ARM64 (Mach-O)

This is the primary target. No flags, no setup.

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

`rail_native` uses the system's `as` and `ld` directly. No libc; the runtime (allocator, GC, string ops, list ops) is ARM64 assembly emitted inline.

## Linux ARM64 (ELF)

```bash
./rail_native linux examples/hello.rail
```

If you have `aarch64-elf-as` and `aarch64-elf-ld` on `PATH` (look for `aarch64-elf-binutils` via Homebrew or your distro), this produces `/tmp/rail_linux`. `scp` it to a Pi Zero 2 W and run.

Without the cross-tools:

```
Cross-compiling examples/hello.rail for Linux ARM64...
  as: /bin/sh: /opt/homebrew/bin/aarch64-elf-as: No such file or directory
  ld: /bin/sh: /opt/homebrew/bin/aarch64-elf-ld: No such file or directory
  Binary: /tmp/rail_linux
  /tmp/rail_linux: cannot open `/tmp/rail_linux' (No such file or directory)
```

To install on macOS:

```bash
brew install aarch64-elf-binutils
```

## Linux x86_64 (source-only)

```bash
./rail_native x86 examples/hello.rail
```

With `x86_64-elf-as` / `x86_64-elf-ld` installed (`brew install x86_64-elf-binutils`):

```
Compiling examples/hello.rail → x86_64 (244 chars)...
  Assembly: /tmp/rail_x86.s (60880 chars)
  Assembler: /opt/homebrew/bin/x86_64-elf-as
  as: OK
  ld: /opt/homebrew/bin/x86_64-elf-ld: cannot find -lc: Invalid argument
  Binary: /tmp/rail_x86
```

Honest reading of that transcript: the assembly and the `.o` are good; the final link **fails on a Mac** because the cross-`ld` has no Linux libc to link against — and the driver still prints `Binary:` and exits 0 (known display lie, tracked in [TODO.md](TODO.md)). The supported path is the `.s`: copy `/tmp/rail_x86.s` to a Linux x86_64 host and `gcc -o prog rail_x86.s`. Without cross-binutils the driver says exactly that (`tools/compile.rail`, `dispatch_x86`): `No local x86_64 assembler. Install x86_64-elf-as / x86_64-elf-ld, or copy /tmp/rail_x86.s to a Linux x86_64 host and assemble there.`

The x86_64 backend was bootstrapped against a remote x86_64 Linux (WSL) host rather than for cross-tools-on-mac. The x86 runtime asm lives at `tools/x86_rt.s`.

**Conformance:** `bash tools/test/x86_conformance.sh` (requires Docker + `linux/amd64` image, e.g., Colima/Rosetta) currently passes **71/79** representative tests covering ints, strings, lists, ADTs, closures, floats, FFI, TCO, and arena ops. The 8 remaining failures are 3 ELF-prefix ffi-libc tests and 5 missing str-runtime symbols.

## WebAssembly

```bash
./rail_native wasm examples/wasm/hello.rail
```

```
Compiling examples/wasm/hello.rail to WASM...
  WAT: 51277 bytes
  wat2wasm: OK
Hello from Rail!
Running as WebAssembly.
```

Requires `wat2wasm` from the WebAssembly Binary Toolkit (`brew install wabt`). The output is `/tmp/rail_out.wasm` (4,489 bytes for this program). With `wasmtime` on `PATH` the driver runs the module immediately — the two program lines above; without it, the driver stops at `  Binary: /tmp/rail_out.wasm` — drop that into any WASM runtime that provides the `env.print` import. The live playground at https://ledatic.org embeds exactly this output.

Known WASM-backend limits (see CLAUDE.md): no `filter`/`map`/`fold` as WASM builtins, 1 MB linear memory. Closures, ADTs, pattern matching, and string ops all work.

## Cortex-M4 (Thumb-2)

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

Requires `clang` with the `thumbv7em-none-eabi` target. On macOS: `brew install llvm` (Apple's bundled clang doesn't include the bare-metal targets). The driver also assembles the startup vector (`tools/cortexm_rt/startup.s`) and links into `/tmp/rail_m4.elf`.

To verify in qemu (no real hardware needed for CMSDK UART programs):

```bash
qemu-system-arm -M mps2-an386 -nographic -kernel /tmp/rail_m4.elf
```

## RISC-V rv32imc

```bash
./rail_native riscv32 /tmp/test_riscv.rail
```

```
Compiling /tmp/test_riscv.rail -> RISC-V (rv32imc)...
  Assembly: /tmp/rail_rv32.s (314 chars)
  as: OK
  startup: OK
  ld: OK -> /tmp/rail_rv32.elf
```

Requires `clang` with `riscv32-unknown-none-elf` target. The minimal `main = 42` program boots in `qemu-system-riscv32 -M virt -bios none -kernel /tmp/rail_rv32.elf` and exits 42 via the SiFive test register.

The rv32 backend is v0 — literals only. See [`memory:riscv32_backend_v0`](https://ledatic.org/memory/riscv32_backend_v0) for the supported subset.

---

## Adding a backend

Look at `tools/compile.rail` around line 6605: the `cmd` dispatch table. Each backend is roughly:

1. A new "emit" pass that walks the AST.
2. A driver function (`compile_cortexm`, `compile_riscv32`, etc.) that calls the right assembler/linker via `shell`.
3. A startup file under `tools/cortexm_rt/` or equivalent.

Cortex-M4 took about 600 lines of compiler code; RISC-V was about 300 because Thumb-2 paved the road.
