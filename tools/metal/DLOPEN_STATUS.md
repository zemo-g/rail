# Dlopen GPU Path — Investigation Notes (2026-04-13)

## Verdict (2026-04-15): ABANDONED in favor of daemon IPC.

Path A (direct dlopen) is preserved here for historical reference. Fork B adopts
**Path B (Rail-native Metal daemon)** — see `~/projects/rail/FORK_B_PLAN.md` §M3.
A small ObjC binary on a Unix socket keeps the ObjC runtime hermetic in a
separate process; Rail talks to it via `stdlib/socket.rail`. No Python in the
inner training loop. Existing `tensor_daemon.py` is the working reference
protocol; the daemon is being ported to ObjC.

## Result (original, 2026-04-13)
**Partially blocked.** The dylib works from C but crashes when loaded from Rail.

## What Works
- `libtensor_gpu.dylib` builds cleanly from `tensor_gpu_lib.m`
- Exports `tgl_init`, `tgl_matmul_f64`, `tgl_relu_f64` with correct C ABI
- From a pure C test program: **0.29 ms per 128×128 matmul** (14.6 GFLOPS)
  - Compare: file-based path is ~50 ms per call. **170x speedup** if we can wire it.
- Rail compiler updated to optionally weak-link libtensor_gpu when present
- Stub dylibs (pure C, no Metal) called successfully from Rail

## What Doesn't Work
- Rail calling a Metal-backed dylib function segfaults *inside* the function,
  before any `fprintf` debug output. The stderr buffer is never flushed.
- The segfault occurs during the Metal framework load / Objective-C runtime
  interaction with Rail's process.

## Hypothesis
Rail's runtime does not set up the Objective-C runtime the way a normal
Cocoa app does. Metal framework likely expects:
1. NSAutoreleasePool initialization
2. A Cocoa main event loop (or at least CFRunLoop)
3. Signal handlers not to conflict with Metal's own

Rail installs its own signal handlers (SIGSEGV for GC scan), uses a custom
256MB stack via `-stack_size 0x10000000`, and does not initialize Cocoa.

## Paths Forward
1. **Constructor attribute** in the dylib: `__attribute__((constructor))`
   to run ObjC init code before any Rail call dispatches.
2. **Detach from autoreleasepool** — rewrite tensor_gpu_lib.m to use
   explicit `CFTypeRef` + manual retain/release instead of ARC + pools.
3. **Fork a worker process** — Rail forks a helper that runs the Metal
   work and pipes results back via named pipe / shared mmap.
4. **Abandon dlopen, keep file-based binary** — the current f32 binary
   path is "only" 10x slower and doesn't have ObjC runtime risk.

## Benchmark for Reference
```
./test_dylib (pure C driver):
  matmul 128×128 × 100 iterations: 29ms total, 0.29ms/call
  Equivalent file-mode Rail call: ~50ms/call
  Theoretical speedup: 170x
```

## Files
- `tensor_gpu_lib.m` — the dylib source (works from C)
- `libtensor_gpu.dylib` — compiled library
- `test_dylib.c` — C test driver (passes all tests)
- `test_dylib_rail2.rail` — Rail caller (segfaults)

Build:
```
cd tools/metal
clang -shared -framework Metal -framework Foundation -fobjc-arc \
  tensor_gpu_lib.m -o libtensor_gpu.dylib
clang test_dylib.c -L. -ltensor_gpu -o test_dylib
DYLD_LIBRARY_PATH=. ./test_dylib    # passes
```
