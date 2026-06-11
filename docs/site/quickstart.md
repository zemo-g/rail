# Quickstart: from `git clone` to a verified attestation

Eleven numbered steps. Each one is a real command with its real captured output. If any step does not behave like this on your machine, that's a bug.

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
170/170 tests passed
```

The test suite covers parser, codegen, type inference, the runtime allocator, and the standard library. The full run takes ~17 minutes on an Apple M-series. The count fluctuates a little if concurrent sessions race on `/tmp/rail_out`. 170 is the canonical green count — re-run if you see a lower number.

## 5. Self-compile

```bash
./rail_native self
```

The compiler compiles itself to `/tmp/rail_self` — ~5.5 minutes per cycle on an Apple M-series. On a clean checkout the first cycle may differ — the seed's shipped runtime asm doesn't always match what its own source emits. Install gen1 and re-run to confirm convergence at gen2:

```bash
cp /tmp/rail_self ./rail_native
./rail_native self
cmp rail_native /tmp/rail_self && echo "byte-identical"
```

```
byte-identical
```

This is the fixed-point property: the compiler's output is its own input. The bootstrap is a 2-cycle limit cycle — gen2 == gen3 == gen4 byte-identically. If `cmp` still differs after 3 cycles, codegen is non-deterministic and wants investigation. See `notes/bootstrap_convergence_audit_2026-05-13.md`.

## 6. Compile a real example

```bash
./rail_native run examples/quicksort.rail
```

```
Compiling examples/quicksort.rail (1089 chars)...
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
Hello from Rail!
Running as WebAssembly.
```

`./rail_native wasm` emits a `.wat` file, runs the WebAssembly Binary Toolkit `wat2wasm` on it, and produces `/tmp/rail_out.wasm` (4,489 bytes for this program). If `wasmtime` is on `PATH`, the compiler runs the module immediately — that's the two program lines above. Without `wasmtime` it stops at `  Binary: /tmp/rail_out.wasm`; load that in any WASM runtime that provides the `env.print` import (the live playground at ledatic.org does this).

You need `wat2wasm` on `PATH` for this step. On macOS: `brew install wabt`. Optional: `brew install wasmtime` to run modules directly.

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
files processed: 94
wrote: docs/site/stdlib.md (159878 bytes)
```

The reference at [stdlib.md](stdlib.md) is auto-generated from the actual stdlib source. The walker is a 222-line Rail program (`wc -l`) that reads each `stdlib/*.rail`, extracts top-level function signatures with their leading comments, and emits markdown. Read it: `tools/docs/gen_stdlib_ref.rail`.

## 10. Verify a release attestation — offline, in Rail

The v5.1.0 release was witnessed by an independent node (fleet0) that signed the artifact digest with Ed25519. The signature, the witness public key, and the verifier are all in this repo — so a bare clone verifies the release fully offline, and the verifier is itself a Rail program:

```bash
git show v5.1.0:tools/compile.rail > /tmp/rail_v510_src.rail
./rail_native run tools/attest/verify.rail /tmp/rail_v510_src.rail \
    releases/v5.1.0/compile.rail.attestation.json
```

```
ok  artifact=compile.rail  pulse_id=1004626  pk_fp=cac5f21a70564aeb
```

(~4 s. The verifier's compile prints two spurious typechecker warnings — `'malloc' is not defined`, `'free' is not defined` — before the `ok`; the warning system is itself running. Fix tracked in [TODO.md](TODO.md).) The pinned witness key is `releases/witness-fleet0/fleet0.pub.pem`; what the signature covers and how to check the key fingerprint out-of-band is in [docs/VERIFY.md](../VERIFY.md).

## 11. Replay the whole claim ledger

Every public claim in the README carries a receipt ID (`[R04]`, `[R10]`, ...). One script replays them all:

```bash
bash tools/prove/prove.sh
```

```
16/16 receipts verified, 6 skipped (gated)
```

The fast tier runs in seconds. `--core` adds the fixed point (step 5) and the full suite (step 4). Gated tiers (`--net`, `--gpu`, `--key`, `--hw`) print SKIP with the reason unless you opt in. The full claim table is [PROOFS.md](../../PROOFS.md).

---

You now have a working Rail toolchain on local hardware. Next steps:

- Skim [examples/](examples/) — 23 program walkthroughs with explanations.
- Skim [stdlib.md](stdlib.md) — every top-level function across 94 stdlib modules (`ls stdlib/*.rail | wc -l`).
- Read [backends.md](backends.md) if you want to target Linux ARM64, x86_64, RISC-V, or WASM-in-a-browser.
