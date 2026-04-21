# Metal probes

One-off GPU experiments that don't wire into the training tree. Each probe is
self-contained (own shader source, own .m host) and does NOT touch
`tensor_gpu.metal` / `libtensor_gpu.dylib`.

## fp16_probe

Decision-gate experiment for `MIXED_PRECISION_SCOPE.md` Option A: measures
fp16 vs fp32 matmul throughput on Studio's M1 Ultra.

```bash
clang -O2 -framework Metal -framework Foundation -fobjc-arc \
    tools/metal/probes/fp16_probe.m -o tools/metal/probes/fp16_probe
./tools/metal/probes/fp16_probe
```

**Do not run concurrent with `lm_v3_chunked` training** — both share the Metal
queue and the timings will be polluted.

Decision rule: Option A is worth pursuing only if fp16 shows ≥1.6× speedup at
N=1024. Below that, the 2-3 day kernel port isn't worth the step-time win.
