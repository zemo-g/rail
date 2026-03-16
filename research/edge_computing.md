# Edge Computing Research: Languages, Runtimes, and Pi Zero 2 W

Research date: 2026-03-16
Target hardware: Raspberry Pi Zero 2 W (quad-core Cortex-A53 @ 1GHz, 512MB LPDDR2, WiFi)
Use case: Running a compiled functional language runtime that talks to Mac Mini over Tailscale

## Pi Zero 2 W Baseline

- CPU: BCM2710A1, 4x Cortex-A53 @ 1GHz (can OC to 1.3GHz)
- RAM: 512MB LPDDR2 total, ~180MB used at idle with stock OS, ~310MB available
- 18,400 DMIPS total, 40% more single-thread than original Zero, 5x multi-thread
- Idle power: ~0.4W (80mA)
- Price: ~$15

---

## 1. MicroPython vs CircuitPython

**Not relevant for Pi Zero 2 W.** These target microcontrollers (ESP32, RP2040) with KB of RAM, not Linux SBCs with 512MB. Included for reference.

| Metric | MicroPython | CircuitPython |
|--------|------------|---------------|
| Heap at boot (ESP32) | 64KB total, ~1.5KB used | Similar, slightly larger |
| Heap at boot (ESP32 + PSRAM) | 4MB total, ~5KB used | N/A |
| Performance | Baseline | ~10% faster on RP2040 benchmarks |
| 1000 integers | ~210KB | Similar |
| 1000 strings | ~310KB | Similar |

**Verdict**: Irrelevant for Pi Zero. If you're running Linux, use a compiled language.

## 2. TinyGo

Go compiler targeting small places. Uses LLVM instead of the standard Go toolchain.

| Metric | TinyGo | Standard Go |
|--------|--------|-------------|
| Hello world (ARM, stripped) | **5.5KB** (~2KB machine code) | 564KB |
| With full optimizations | Down to **1.6KB** from 93KB | N/A |
| Minimum target | Tens of KB flash, few KB RAM | Requires Linux + MB of RAM |

**How it achieves small binaries:**
- LLVM backend with aggressive dead code elimination
- Optional: `-scheduler=none` (removes goroutines), `-panic=trap` (removes panic strings), `-gc=leaking` (removes GC)
- New HTML size report tool shows exactly what's in the binary

**Tradeoffs:**
- Not all Go packages supported (reflection limited, some stdlib missing)
- Goroutine support is optional and simplified
- Debugging harder than standard Go
- Still has a GC by default (can be disabled)

**Relevance to Rail**: TinyGo proves LLVM can produce <2KB binaries from a high-level language. Rail compiling to ARM64 natively should be able to match or beat this since Rail doesn't need a GC or goroutine scheduler.

## 3. Rust on Embedded

| Metric | Value |
|--------|-------|
| Minimal no_std binary (.text) | **130 bytes** with full optimization |
| Minimal no_std binary (full) | **~1KB** |
| Hello world (default, macOS) | 3MB+ (includes stdlib, debug info) |
| Hello world (stripped, optimized) | **~30KB** |
| Compilation time (clean build) | Painful — minutes for embedded projects with dependencies |

**Key pain points from real users:**
- Monomorphization bloats binaries (each generic instantiation = new code)
- `core::fmt` (string formatting) alone adds ~20KB — must avoid for tiny binaries
- Compilation times are the #1 complaint, especially with many dependencies
- Debug info for all dependencies compiled by default (Rust-specific problem)
- Borrow checker fights are real in embedded where you share hardware peripherals
- `unsafe` blocks common in embedded code, partially defeating Rust's safety story

**What works well:**
- `no_std` + `no_main` gives C-level control
- Type system catches real bugs at compile time
- Embedded ecosystem (embedded-hal, probe-rs) is mature
- opt-level=s + LTO + strip gets competitive with C

**Relevance to Rail**: Rust proves you can get 130-byte .text sections from a safe language. But the compilation time and complexity cost is high. Rail's simpler type system and direct ARM64 emission should give faster compilation with similar binary sizes.

## 4. Zig on Pi

| Metric | Value |
|--------|-------|
| Minimal firmware (FixedBufferAllocator) | **6KB** |
| GPIO binary (stripped, Pi) | **4KB** |
| Cross-compile command | `zig build -Dtarget=aarch64-linux-musl` |
| External toolchain needed | **None** — Zig bundles its own |

**What makes Zig compelling for embedded:**
- Same source compiles to 32KB embedded image, 64-core server, or WASM
- No hidden allocations, no hidden control flow
- Cross-compilation is trivial (no gcc-multilib, no sysroots)
- MicroZig framework for microcontrollers (Pi Pico best supported)
- C interop is seamless (can import C headers directly)

**Real experience on Pi:**
- People have run Zig on Pi Zero successfully for GPIO, bare-metal blinky
- `aarch64-linux-musl` target works out of the box
- Community is small but growing

**Relevance to Rail**: Zig's cross-compilation story is the gold standard. Rail's ARM64 compiler should target `aarch64-linux-musl` (static linking, no libc dependency) for Pi deployment. Zig proves 4-6KB binaries are achievable for real work on Pi.

## 5. Forth

| Metric | Value |
|--------|-------|
| Full interpreter+compiler | **~2KB** code+data |
| Minimal kernel | **100-500 bytes** |
| Stack requirement | **~24 bytes** recommended |
| Minimum target | 1KB program memory, 64 bytes RAM |

**Why Forth is still used:**
- Interactive development ON the target device (REPL on the microcontroller itself)
- Used in Open Firmware (boot loaders), ESA Philae spacecraft, NASA
- Zero abstraction overhead — direct hardware manipulation
- Concatenative model (stack-based) eliminates need for variable allocation
- Self-hosting: the compiler IS the runtime IS the development environment

**Why it's so small:**
- No parser needed (whitespace-delimited words)
- No type system overhead
- Dictionary threading: words are just pointers to other words
- No separate compilation step — defining a word compiles it immediately

**Relevance to Rail**: Forth's lesson is that a self-hosting language can fit in 2KB. Rail's bootstrap interpreter is already self-hosting. The question is whether Rail's functional semantics (closures, pattern matching) can approach Forth's density. Probably not 2KB, but sub-100KB is absolutely achievable.

## 6. Lua on Embedded

| Metric | Value |
|--------|-------|
| Full interpreter binary | **~150KB** |
| VM size (no dependencies) | **~200KB** |
| Minimal core (no parser) | **~25KB** |
| Flash footprint (Lua 5.4.6, real hardware) | **72.2KB** |
| RAM at startup | **~17KB** (Lua 5.1.4) |
| GC-reported usage (minimal program) | **<8KB** |

**Lua 5.5 (Dec 2025):**
- 60% memory savings for large arrays
- Incremental generational GC
- Global variable declarations (finally)

**NodeMCU/eLua specifics:**
- LTR (Lua Tiny RAM) patch reduces RAM by 20-25KB on ESP8266
- Read-only tables in flash, not RAM
- SPIFFS filesystem optimized for embedded
- Debug/math libraries removed to save space
- Users select modules per-project, build custom firmware

**Relevance to Rail**: Lua proves a full scripting language with GC fits in 72KB flash / 17KB RAM. Rail's compiled output (no interpreter needed) should use less RAM at runtime. Lua's approach of optional modules and stripping unused libraries is worth emulating — Rail could ship a minimal runtime and let users opt into features.

## 7. WASM on Edge

| Runtime | Binary Size | RAM Footprint | Type |
|---------|------------|---------------|------|
| wasm3 | **~64KB** | 134KB (Pi Pico), 156KB (ESP32) | Interpreter |
| WAMR | **~200KB+** | Higher | Interpreter + AOT |
| Wasmtime | MB+ | MB+ | JIT (not for Pi Zero) |

**wasm3 specifics:**
- Minimum: 64KB Flash, 10KB RAM
- Runs on ARM, RISC-V, MIPS, Xtensa
- Fastest cold start of any WASM runtime
- Predictable, deterministic execution
- Best for: battery-powered, simple tasks

**Can you run WASM on Pi Zero?** Yes, easily. Pi Zero 2 W with 512MB RAM is overkill for wasm3. Even WAMR runs fine. The question is whether WASM adds value vs native ARM64.

**Performance vs native:**
- WASM interpreted (wasm3): ~10-50x slower than native
- WASM AOT (WAMR): ~1.5-3x slower than native
- Overhead is the cost of sandboxing

**Relevance to Rail**: Rail could compile to WASM as an alternative backend (portability). But for Pi Zero specifically, native ARM64 is strictly better — no interpretation overhead, no sandbox tax. WASM backend is interesting for "compile once, run on Pi AND browser" story, but not the primary path.

## 8. Tailscale on Pi

**Setup**: One-liner install, `curl -fsSL https://tailscale.com/install.sh | sh && tailscale up`

| Scenario | Latency |
|----------|---------|
| Same LAN, direct connection | **<1ms** (within margin of error) |
| Same LAN via DERP relay | 5-20ms |
| Cross-internet, direct (NAT traversal) | Varies by ISP, typically 10-50ms |

**Key facts:**
- Traffic between two devices on the same LAN stays on that LAN
- Direct peer-to-peer over UDP (WireGuard under the hood)
- Pi Zero 2 W handles Tailscale fine — WireGuard is lightweight
- No port forwarding needed, NAT traversal is automatic
- Tailscale daemon uses ~10-20MB RAM

**Pi-to-Mac on same network:**
- Direct connection established automatically
- Latency: sub-millisecond (same as raw WireGuard, same as no VPN)
- Throughput limited by Pi's WiFi (~30-50 Mbps on 2.4GHz)
- Stable, persistent connection — survives network changes

**Relevance to Rail**: Tailscale is the right choice for Pi-to-Mac communication. Sub-millisecond latency on LAN means you can treat the Pi as a remote execution target with negligible overhead. Rail could compile on Mac, scp binary to Pi, execute — or run a tiny agent on Pi that receives and runs binaries over Tailscale. The 10-20MB RAM overhead of Tailscale is acceptable on 512MB.

## 9. Minimum Viable Language Runtime for 512MB

With ~310MB available after OS + Tailscale, here's what you can fit:

**What you keep:**
- Compiled native code (no interpreter overhead)
- Simple mark-sweep or reference-counting GC (if needed at all)
- Stack-based execution for function calls
- Basic I/O (files, network sockets)
- Static linking (no dynamic loader overhead)

**What you cut:**
- JIT compiler (complex, memory-hungry, not needed if AOT-compiled)
- Rich type metadata / reflection (adds KB per type)
- Debug symbols in production (strip them)
- Large standard library (ship minimal, load on demand)
- String formatting machinery (Rust's core::fmt is 20KB alone)
- Exception handling tables (use return codes or simple panic)
- Unicode tables (if not needed — ICU alone is MB)
- Generational GC (simple GC is fine for 310MB heap)

**Realistic budget for a Rail runtime on Pi Zero 2 W:**

| Component | Size |
|-----------|------|
| OS (Raspberry Pi OS Lite) | ~180MB RAM |
| Tailscale daemon | ~15MB RAM |
| Rail compiled binary (typical) | 10-100KB on disk, <1MB RSS |
| Rail runtime (GC, allocator) | 1-5MB RAM |
| Application heap | Up to ~300MB available |
| **Total available for Rail programs** | **~300MB** |

**The lesson from all the research**: On 512MB, you are NOT constrained. Forth runs in 2KB. Lua runs in 17KB. Even MicroPython runs in 64KB. A compiled functional language with a simple GC has hundreds of MB to work with. The constraint is CPU (1GHz quad-core), not RAM.

## 10. Edge AI on Pi Zero 2 W

| Framework | Binary/Library Size | Inference Time | Notes |
|-----------|-------------------|----------------|-------|
| TensorFlow Lite | ~2-5MB library | **120ms** (CNN, 300x150 input, 4 threads) | Best supported on ARM |
| ONNX Runtime | ~5-10MB library | Similar to TFLite | More model format flexibility |
| Unquantized model | 37.5MB | 220ms+ | May crash on 512MB |
| INT8 quantized model | **9MB** | **84ms** | 75% memory reduction |

**What fits on Pi Zero 2 W:**
- MobileNet V2 (image classification): ~3MB quantized, ~100ms inference
- Tiny YOLO (object detection): ~6MB quantized, ~200-500ms
- Small CNNs (audio/sensor classification): <1MB, <120ms
- NOT viable: anything >50MB, any LLM (even tiny ones struggle)

**Key requirement**: INT8 quantization is mandatory. Float32 models will either crash or take seconds per inference.

**Relevance to Rail**: If Rail ever wants to run ML models on Pi, TFLite is the path — call it via C FFI from compiled Rail code. But the more likely use case is Rail as the orchestrator: Pi collects sensor data, sends to Mac over Tailscale, Mac runs the model, sends result back. Sub-millisecond Tailscale latency makes this viable even for near-real-time applications.

---

## Synthesis: What This Means for Rail on Pi Zero 2 W

### The architecture that makes sense

```
[Pi Zero 2 W]                    [Mac Mini M4 Pro]
Rail binary (ARM64, <100KB) ---> Tailscale (<1ms LAN) ---> Rail compiler
Collects data, runs tasks         Compiles, heavy compute
Minimal runtime, no interpreter   24GB RAM, 10-core CPU
Static musl binary, no deps       Full development environment
```

### Concrete targets for Rail on Pi

| Target | Achievable? | Evidence |
|--------|-------------|----------|
| Binary size < 100KB | Yes | Zig: 4-6KB, Rust no_std: 1KB, TinyGo: 5.5KB |
| Static binary, no dependencies | Yes | `aarch64-linux-musl` target, like Zig |
| Runtime RAM < 5MB | Yes | Lua: 17KB, Forth: 2KB. Even with GC overhead |
| Cross-compile on Mac for Pi | Yes | Standard ARM64 cross-compilation |
| Sub-second program startup | Yes | Native binary, no interpreter, no JIT warmup |
| Talk to Mac over Tailscale | Yes | <1ms latency on LAN, ~15MB RAM overhead |

### What Rail should NOT do on Pi

- Ship an interpreter (compile to native ARM64 instead)
- Include a JIT (AOT is sufficient, JIT wastes RAM)
- Bundle large runtime libraries (keep it minimal, static link)
- Try to run ML models locally (offload to Mac over Tailscale)
- Use dynamic linking (static musl = zero dependencies)

### Priority path

1. Rail ARM64 compiler already works (8/8 tests pass)
2. Add `aarch64-linux-musl` as a cross-compilation target
3. Produce static binaries that run on Pi Zero 2 W with zero dependencies
4. Tailscale for Pi-to-Mac communication
5. Keep runtime minimal: allocator + simple GC + I/O = done

The 512MB Pi Zero 2 W is not the constraint people think it is. The real constraint is developer ergonomics — how fast can you iterate? Answer: compile on Mac (fast), scp to Pi (instant over Tailscale), run (native speed). Total cycle time: under 2 seconds.

---

## Sources

- [Benchmarking MicroPython](https://blog.miguelgrinberg.com/post/benchmarking-micropython)
- [MicroPython Benchmarks (scruss)](https://scruss.com/blog/2025/01/21/micropython-benchmarks/)
- [MicroPython Memory Management Docs](https://docs.micropython.org/en/latest/develop/memorymgt.html)
- [TinyGo - Optimizing Binaries](https://tinygo.org/docs/guides/optimizing-binaries/)
- [TinyGo GitHub](https://github.com/tinygo-org/tinygo)
- [TinyGo Binary Size Issue #376](https://github.com/tinygo-org/tinygo/issues/376)
- [min-sized-rust (GitHub)](https://github.com/johnthagen/min-sized-rust)
- [Embedded Rust Book - Speed vs Size](https://docs.rust-embedded.org/book/unsorted/speed-vs-size.html)
- [How to speed up the Rust compiler (Dec 2025)](https://nnethercote.github.io/2025/12/05/how-to-speed-up-the-rust-compiler-in-december-2025.html)
- [How to Reduce Rust Binary Size by 43%](https://markaicode.com/binary-size-optimization-techniques/)
- [Gettin' Ziggy With It On The Pi Zero](https://www.leemeichin.com/posts/gettin-ziggy-with-it-pi-zero)
- [Zig GPIO on Raspberry Pi](https://zig.news/geo_ant/low-ish-level-gpio-on-the-raspberry-pi-with-zig-1cn3)
- [MicroZig Getting Started](https://microzig.tech/docs/getting-started/)
- [Forth in Embedded Systems (Hackaday)](https://hackaday.io/page/184029-rediscovering-forth-a-superior-choice-for-embedded-systems-development)
- [Forth - Brief Introduction (CMU)](http://users.ece.cmu.edu/~koopman/forth/hopl.html)
- [Running Embedded Lua on Microcontrollers](https://promwad.com/publications/article-electronicdesign-embedded-lua-microcontrollers)
- [Lua 5.5 Release Notes](https://byteiota.com/lua-5-5-drops-after-5-years-60-memory-savings-incremental-gc/)
- [eLua - Lua Tiny RAM](https://eluaproject.net/doc/v0.9/en_arch_ltr.html)
- [Using Lua in Embedded (mprogramming)](https://www.mprogramming.net/blog/using-lua-in-embedded)
- [WASM on Resource-Constrained IoT Devices (arXiv)](https://arxiv.org/html/2512.00035)
- [wasm3 GitHub](https://github.com/wasm3/wasm3)
- [WAMR Performance Wiki](https://github.com/bytecodealliance/wasm-micro-runtime/wiki/Performance)
- [WebAssembly Runtime Benchmarks 2026](https://wasmruntime.com/en/benchmarks)
- [Tailscale Performance Best Practices](https://tailscale.com/kb/1320/performance-best-practices)
- [Tailscale on Raspberry Pi (Pi My Life Up)](https://pimylifeup.com/raspberry-pi-tailscale/)
- [Tailscale Connection Types](https://tailscale.com/docs/reference/connection-types)
- [Pi Zero 2 W Benchmarks (Phoronix)](https://www.phoronix.com/review/raspberrypi-zero-2w)
- [Pi Zero 2 W Review (CNX Software)](https://www.cnx-software.com/2021/10/29/raspberry-pi-zero-2-w-mini-review-benchmarks-and-thermal-performance/)
- [TFLite Classification on RPi Zero (GitHub)](https://github.com/Qengineering/TensorFlow_Lite_Classification_RPi_zero)
- [Dolphin Whistle Detection on Pi Zero 2 W (MDPI)](https://www.mdpi.com/2218-6581/14/5/67)
- [TFLite vs ONNX Runtime for Edge AI](https://www.aimtechnolabs.com/blogs/tensorflow-lite-vs-onnx-runtime-edge-ai)
- [Deploy AI Model on Pi Zero 2W](https://www.alibaba.com/product-insights/step-by-step-guide-to-deploying-a-lightweight-ai-model-on-a-raspberry-pi-zero-2w.html)
