# SHIMS.md — Non-Rail surface in the Rail build/runtime

Rail aims at zero non-Rail dependencies in the user program. The compiler is written in Rail and emits its own assembly; stdlib is Rail; tooling is Rail. The files below exist because kernel boundaries, GPU drivers, framework C ABIs, and bare-metal CPU bringup demand a small irreducible surface in another language. Each entry names the boundary, the byte cost, and what would let us delete it.

Totals: **31 in-tree files**, ~407 KB. Plus 8 gitignored UAV files (~213 KB) called out in their own section. Anything not listed is Rail.

---

## 1. Kernel / syscall boundary

The Rail runtime makes raw Linux syscalls. macOS uses dyld + libc indirectly via the assembler's `bl _printf` etc., emitted from Rail. These files are the assembly trampolines that turn Rail's calling convention into the platform ABI.

| Path | Lang | Bytes | Reason it must exist | To retire |
|---|---|---|---|---|
| `tools/linux_libc.s` | asm-arm64 | 35,459 | Pure-syscall libc (write/read/openat/close/lseek/exit/mmap, string ops) for cross-compiled Linux ARM64 binaries — no glibc dependency. | Never — this IS the Linux ABI boundary. |
| `tools/linux_data.s` | asm-arm64 | 683 | Runtime data symbols for cross-compiled Linux binaries when the generated `.s` omits its own `.data` (Pi memory-pressure path). | When chunked `.s` writer lands; see `feedback_rail_compile_traps.md`. |
| `tools/x86_libc.s` | asm-x86_64 | 6,220 | Pure-syscall libc for Rail x86_64 Linux (no glibc, no dynamic linking). | Never — kernel boundary. |
| `tools/x86_rt.s` | asm-x86_64 | 59,385 | Rail x86_64 Linux runtime (glibc-linked variant): GC inner loop, list ops, string ops, tagged-int math in hand-written x86_64 asm. | Partial: GC + list ops can be ported to Rail-emitted asm; the glibc trampolines stay. |

**Sub-total:** 4 files / 101,747 bytes.

---

## 2. GPU driver interop (Metal)

Apple's Metal API is Objective-C. Rail can call C ABI but cannot speak ObjC selectors or `id` messaging. Every Metal-backed kernel needs a thin `.m` host that creates the device, command queue, and pipeline state, then dispatches the kernel. Rail talks to these via either dylib FFI (`tensor_gpu_lib.m`) or stdin/socket IPC (`tensor_daemond.m`).

### Active

| Path | Lang | Bytes | Reason | To retire |
|---|---|---|---|---|
| `tools/metal/tensor_gpu_lib.m` | ObjC | 98,135 | Metal tensor kernels (23 ops: matmul, rmsnorm, rope, silu, etc.) as a dylib that Rail's `stdlib/tensor.rail` FFIs into. | When Rail emits MSL + drives the Metal driver itself — Phase 3 of `rail-jit-fused-kernels-plan.md`. |
| `tools/metal/tensor_gpu.m` | ObjC | 29,318 | Persistent stdin-protocol Metal compute server (predecessor of the dylib path). | Superseded by `tensor_gpu_lib.m`; kept while Rail self-train scripts still spawn the server. |
| `tools/metal/tensor_daemond.m` | ObjC | 20,321 | Unix-socket daemon that keeps Metal device + pipelines warm across Rail invocations (avoids ~200 ms cold-start per call). | When Rail has a long-lived process model that owns the Metal handle directly. |
| `tools/metal/libtensor_gpu_linux_stub.c` | C | 1,807 | No-op stub exporting the ~25 `tgl_*` symbols so Linux ELF programs that `import "stdlib/tensor.rail"` link — Metal is macOS-only. | When linker-level optional symbols land in the Rail backend. |
| `tools/metal/tensor_gpu_lib_stub.m` | ObjC | 164 | Two-line isolation stub used to debug a link issue with `tensor_gpu_lib.m`. | Delete now — diagnostic-only, no live caller. |
| `tools/gpu_host.m` | ObjC | 2,957 | Minimal generic Metal compute host: load `.metallib`, run kernel by name, print result. Reference impl for JIT path. | When `tools/metal/tensor_gpu_lib.m` covers all paths. |
| `tools/jit_call.c` | C | 1,370 | Pre-compiled trampolines for the pure-Rail JIT — bridges Rail's calling convention into JITted machine code at runtime. | Never — this is the JIT/runtime interior boundary. |

### Test / smoke harnesses (pure scaffolding, not in the runtime path)

| Path | Lang | Bytes | Reason |
|---|---|---|---|
| `tools/metal/smoke_test.c` | C | 9,002 | Verifies every `libtensor_gpu.dylib` export before wiring into Rail. |
| `tools/metal/test_dylib.c` | C | 2,266 | Single-symbol dylib link check (used once during dylib bringup). |
| `tools/metal/tensor_daemond_smoke.c` | C | 3,330 | Socket-protocol smoke for `tensor_daemond` (PING + MATMUL roundtrip). |
| `tools/metal/bench_matmul.m` | ObjC | 6,056 | Tiled vs blocked matmul throughput comparison — one-off benchmark, not shipped. |
| `tools/metal/probes/fp16_probe.m` | ObjC | 9,177 | fp16-vs-fp32 matmul throughput probe (Option A decision gate for mixed precision). |

All five are candidate deletions on the next cleanup pass — none is on a live caller path.

**Sub-total:** 12 files / 177,915 bytes.

---

## 3. Framework bridges (Quartz, Cocoa, Foundation)

These call macOS frameworks whose public APIs are ObjC selectors on opaque handles (`CGEventTap`, `NSWindow`, `CVDisplayLink`). C ABI alone cannot reach them; a `.m` shim is the minimum viable bridge.

| Path | Lang | Bytes | Reason | To retire |
|---|---|---|---|---|
| `tools/desk/quartz_bridge.m` | ObjC | 12,714 | CGEventTap on a dedicated runloop thread → fixed-size struct queue Rail reads via FFI. Backs `stdlib/quartz.rail`. | Never — Quartz is selector-based. |
| `tools/plasma/mhd_live.m` | ObjC | 18,022 | Headless Metal compute + Foundation file I/O for the live 2D MHD beacon (`/tmp/plasma_live.bin`). | When Rail emits MSL directly and drives the Metal command queue. |
| `tools/plasma/mhd_ot_2d_256_host.m` | ObjC | 11,505 | Orszag-Tang 256² MHD host (Metal kernel driver, init + step loop). | Same as above. |
| `tools/plasma/neural_mhd_gpu_host.m` | ObjC | 36,516 | GPU-trained MLP surrogate for MHD: Metal compute pipeline + Foundation file I/O. | Same as above. |
| `tools/plasma/neural_renderer.m` | ObjC | 11,844 | Real-time neural-MHD renderer: Cocoa NSWindow + Metal draw loop. | Never — NSWindow is selector-only. |
| `tools/plasma/_dormant/plasma_3d_host.m` | ObjC | 10,582 | Dormant 3D MHD volume renderer (Cocoa + Metal). | Delete-candidate (`_dormant` prefix says so). |

**Sub-total:** 6 files / 101,183 bytes.

---

## 4. CPU bringup (bare-metal startup, pre-Rail-runtime)

These run BEFORE the Rail runtime exists. On Cortex-M, the reset vector points at hand-written asm that sets up the stack and jumps to `_main`. On v5 Linux ARM64 test programs, `_start` is the bare ELF entry the kernel calls — these are stress fixtures for the v5 self-hosted assembler, not part of the Rail runtime.

| Path | Lang | Bytes | Reason | To retire |
|---|---|---|---|---|
| `tools/cortexm_rt/startup.s` | asm-armv7m | 3,200 | Cortex-M4 vector table + Reset_Handler (Apollo2 / Instinct gen-1). Pre-`_main` CPU init. | Never — this IS the CPU boundary. |
| `tools/cortexm_rt/rv_startup.s` | asm-riscv | 886 | RISC-V (rv32imc) bare-metal startup for `qemu-system-riscv32 -M virt`. | Never — pre-runtime. |

### v5 assembler fixtures (test-only)

| Path | Lang | Bytes | Reason |
|---|---|---|---|
| `tools/v5/hello_linux.s` | asm-arm64 | 461 | `.data` + adrp + `:lo12:` + write syscall fixture. Byte-verifies the v5 ELF assembler. |
| `tools/v5/fib_linux.s` | asm-arm64 | 918 | Multi-section fixture: calls, branches, stack frame writeback. |
| `tools/v5/exit42_linux.s` | asm-arm64 | 72 | Minimum-viable fixture: `exit(42)`. |
| `tools/v5/bss_test_linux.s` | asm-arm64 | 423 | `.bss` + `.comm` + adrp/`:lo12:` ldr/str fixture. |
| `tools/v5/example_program.s` | asm-arm64 | 123 | Smallest possible v5 program. |

These five fixtures stay because they're the byte-verification corpus for `tools/v5/elf_asm.rail` — deleting them deletes the test that proves the assembler is bit-correct.

**Sub-total:** 7 files / 6,083 bytes.

---

## 5. External device drivers

Hardware whose driver is not in the kernel (or where the Linux driver requires running as root via `/dev/spidev*`). The bridge is small C glue around `ioctl` + `write`.

| Path | Lang | Bytes | Reason | To retire |
|---|---|---|---|---|
| `tools/fleet/spi_lcd.c` | C | 4,571 | ST7789v2 SPI LCD driver (init / push RGB565 / backlight) for `fleet_display.rail` on Pi Zero 2 W. | When Rail has a raw `ioctl` FFI binding — moderate effort. |

**Sub-total:** 1 file / 4,571 bytes.

---

## 6. GC inner loop / concurrent runtime

Hand-tuned C where Rail's emit pipeline isn't yet expressive enough.

| Path | Lang | Bytes | Reason | To retire |
|---|---|---|---|---|
| `tools/runtime/concurrent.c` | C | 16,319 | Bounded blocking channels + `pthread_spawn` for `stdlib/concurrent.rail`. Uses `pthread_mutex` + `pthread_cond` — neither has a Rail-side abstraction yet. | When Rail emits its own threading primitives (deferred — `int64`-only channels suffice for v0). |

Note: the conservative mark-sweep GC itself is **not** here — it is hand-written ARM64 assembly embedded inside `tools/compile.rail` as string literals, emitted by Rail. The compiler's `rt_*` runtime asm is Rail source, not a non-Rail file.

**Sub-total:** 1 file / 16,319 bytes.

---

## 7. UAV / ZEMOG (gitignored — private repo `Ledatic-Empire/zemog`)

Listed here because the `find` walk surfaces them, but `tools/uav/` is gitignored and lives in a separate private repo (`feedback_drone_private.md` — drone code is never in public repos). Not part of the Rail public-thesis surface. The files are the live ZEMOG flight controller + 3D simulator + brain inference; they predate Rail and have not been ported.

| Path | Lang | Bytes | Reason |
|---|---|---|---|
| `tools/uav/zemog.h` | C header | 90,521 | Dual-mode quadrotor physics (TRAINING / RESEARCH). |
| `tools/uav/zemog_3d.c` | C | 47,256 | SDL2 + OpenGL 3D viewer with motor-level sim. |
| `tools/uav/zemog_brain.c` | C | 12,403 | Headless brain training driver. |
| `tools/uav/zemog_flight.c` | C | 11,789 | Real-world Pi Zero 2 W flight controller (MSP UART → Betaflight). |
| `tools/uav/failsafe.h` | C header | 19,601 | Safety-critical failsafe state machine (NOMINAL → HOVER_HOLD → LAND → DISARM). |
| `tools/uav/msp.h` | C header | 15,391 | MSP v1 (MultiWii Serial Protocol) header-only library. |
| `tools/uav/aigp/old/pilot_impl.c` | C | 14,267 | Old Python-ctypes pilot shim (dead — superseded by Rail native brain). |
| `tools/uav/aigp/old/pilot_ffi.h` | C header | 2,386 | Old pilot FFI ABI. |

Plus ~17 files under `tools/uav/archive/` (ES, GRU/MapGRU eval kernels, weight I/O) — all dead, gitignored, retained for paper-archaeology.

**Sub-total (gitignored):** 8 in-tree files / ~213 KB; archive ~12 KB more. Not part of the public Rail surface.

---

## Tally

| Category | Files | Bytes |
|---|---|---|
| 1. Kernel / syscall | 4 | 101,747 |
| 2. GPU driver interop (active) | 7 | 154,072 |
| 2. GPU driver (test scaffolds) | 5 | 29,831 |
| 3. Framework bridges | 6 | 101,183 |
| 4. CPU bringup (M4 + RISC-V) | 2 | 4,086 |
| 4. v5 assembler fixtures | 5 | 1,997 |
| 5. External device drivers | 1 | 4,571 |
| 6. GC / concurrent runtime | 1 | 16,319 |
| **In-tree total** | **31** | **413,806** |
| 7. UAV (gitignored, private) | 8 | ~213,000 |

Public-thesis count: **31 non-Rail files**. Everything else in this repo — the compiler, the stdlib (102 modules), the deploy tooling, the JIT tracer, the v5 assembler, the test harness, the package manager, the docs generator — is Rail.

Removable on next cleanup pass (no live caller, scaffolding only): `tensor_gpu_lib_stub.m`, `test_dylib.c`, `bench_matmul.m`, `fp16_probe.m`, `_dormant/plasma_3d_host.m`. Net would drop to 26 files / ~377 KB.
