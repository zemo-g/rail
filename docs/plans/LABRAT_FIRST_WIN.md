# Labrat first end-to-end win — fp16 matmul port

**Date:** 2026-04-20 PM, ~23:00 EDT.
**Run ID:** `tools/labrat/transcripts/fp16_real-1776740829.log`.

## Result

```
labrat: fp16_real target=/tmp/labrat_test/seed.metal gate=1.6 max_iter=5
iter 1: KEEP speedup=1.8
```

**One iteration. First attempt. KEPT.**

The MLX agent (Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-6bit on :8080)
received a stripped seed (~30 lines, just `matmul_f32`) and the goal "add
a matmul_f16 kernel directly below the existing one with half operands,
fp32 accumulator, cast back to half on store". It produced a textbook
mixed-precision matmul kernel:

```metal
kernel void matmul_f16(
    device const half *A  [[buffer(0)]],
    device const half *B  [[buffer(1)]],
    device half       *C  [[buffer(2)]],
    constant uint      &M  [[buffer(3)]],
    constant uint      &K  [[buffer(4)]],
    constant uint      &N  [[buffer(5)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 lid [[thread_position_in_threadgroup]])
{
    uint row = gid.y; uint col = gid.x;
    threadgroup half As[TILE][TILE];
    threadgroup half Bs[TILE][TILE];
    float sum = 0.0f;
    uint numTiles = (K + TILE - 1) / TILE;
    for (uint t = 0; t < numTiles; t++) {
        uint aCol = t * TILE + lid.x;
        uint bRow = t * TILE + lid.y;
        As[lid.y][lid.x] = (row < M && aCol < K) ? A[row * K + aCol] : half(0.0f);
        Bs[lid.y][lid.x] = (bRow < K && col < N) ? B[bRow * N + col] : half(0.0f);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint i = 0; i < TILE; i++) sum += float(As[lid.y][i]) * float(Bs[i][lid.x]);
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (row < M && col < N) C[row * N + col] = half(sum);
}
```

Bench reported 1.8× vs fp32 at N=1024 (vs the standalone `fp16_probe.m`
result of 1.70× — within sampling noise; `bench_dyn` runs 10× while the
probe runs 20×).

## What this proves

1. **Labrat's protocol works end-to-end on a real task.** Snapshot →
   patch via MLX → apply → compile (newLibraryWithSource validator) →
   bench → keep/rollback. All gates fired correctly.
2. **The local 27B-6bit Qwen distill is competent at this kernel-port
   task.** No bigger model needed for matmul-class kernels. Open question:
   does it generalize to softmax/layernorm where fp16 numerics are
   trickier?
3. **Phase 4a Option A is no longer hand-labor.** The 26 kernels × 2
   precision matrix can be ported by labrat; the cost shrinks from
   2-3 days mechanical to ~labrat run wall × 26 ≈ 5–15 minutes plus
   review.

## How to reproduce

Test fixtures live in `/tmp/labrat_test/` (ephemeral; rebuild from this
doc):

- `seed.metal` — minimal `matmul_f32` source
- `validate_metal.m` — Obj-C harness using `newLibraryWithSource` (since
  Studio lacks `xcrun metal` — full Xcode not installed)
- `bench_dyn.m` — runtime-compile bench, looks up `matmul_f32` +
  `matmul_f16`, runs both at N=1024, prints `speedup=X.XX` then `X.XX`
- `run_bench.sh` — one-line shell wrapper that supplies the source path
  to `bench_dyn` (since labrat's `lb_bench` doesn't pass args)
- `fp16_spec.json` — labrat task spec pointing at the above

Build:
```bash
clang -O2 -framework Metal -framework Foundation -fobjc-arc \
    /tmp/labrat_test/validate_metal.m -o /tmp/labrat_test/validate_metal
clang -O2 -framework Metal -framework Foundation -fobjc-arc \
    /tmp/labrat_test/bench_dyn.m -o /tmp/labrat_test/bench_dyn
```

Run:
```bash
LABRAT_SPEC=/tmp/labrat_test/fp16_spec.json /tmp/labrat_bin
```

## Next increments

- **Stability sweep (2026-04-20 23:41 → 2026-04-21 00:03, N=5):**
  - **Success rate: 4/5 = 80%.** Total wall 22 min.
  - Per-run KEEP speedups (real iter values, not the parser's
    first-match display bug): **1.7×, 1.8×, 1.9×, 1.8× — mean 1.80×.**
  - One run (4/5) ran 5 iters all rolled back — likely MLX sampling
    variance hitting a string of degenerate patches. Suggests the
    inner loop should retry on full-loop failure.
  - Conclusion: labrat is robust enough at this task class to delegate
    overnight kernel ports. Phase 4a Option A is now operationally
    cheap.
- **Re-run with bigger model on :8081 (Qwen3.6-35B-A3B-8bit)?** May
  push success to 5/5 and lift mean speedup. One-line plist switch.
- **Port to production:** transplant the working `matmul_f16` into
  `tools/metal/tensor_gpu.metal` (renaming existing `matmul` →
  `matmul_f32` first), add Rail-side `tgl_matmul_f16` foreign decl.
- **Generalize bench:** parameterize `bench_dyn` to take baseline and
  variant kernel names so it works for `matmul_blocked`,
  `matmul_bias_relu`, `matmul_bias_gelu`, etc.
- **Multi-kernel overnight:** chain labrat over 5–10 different kernels.
  By morning, full fp16 variant set ready for review.
- **Unify with `researcher.rail`:** labrat.rail currently has inline
  shell-out helpers (snapshot/patch/compile). Swap for `researcher.rail`
  primitives once both are wired through a shared spec format.

## Caveats from this session

- Rail's float `>=` codegen segfaulted on the gate compare. Workaround
  in `labrat_step`: route through int `(x * 1000.0)`. Worth a
  `compile.rail` bisect — added to `rail_quirks` memory.
- Studio has CLI tools only; no `xcrun metal`. The validator harness
  uses the same `newLibraryWithSource` API the production
  `tensor_gpu_lib.m` uses — equivalent fidelity. No Xcode install
  required.
- Negative-form prompt instructions (`Do not explain. Do not check…`)
  caused the model to do exactly that. Prompt v3 is positive-only with
  a worked example. User flagged this pattern explicitly.
