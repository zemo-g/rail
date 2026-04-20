# Mixed-precision scoping — fp16 / bf16 for RailML training

**Date:** 2026-04-20
**Author:** Studio orchestrator session
**Status:** Decision doc. Scope, cost, precision risk, and a recommended path.
Week-inclusion is a user call. Not coding work yet.

## TL;DR

1. Rail-side tensors are **already `double` (f64)**; Metal kernels are already
   **`float` (fp32)**. Conversion happens at the dylib boundary — see
   `tools/metal/tensor_gpu_lib.m`'s `_f64 → float*` copy pattern.
2. Bandwidth and memory savings live in **two distinct layers**. You can
   take only the GPU-side win (fp16 kernels, kept at f64 in Rail), or the full
   f64 → f16 migration across CPU+GPU.
3. Transformer training at pure fp16 without loss scaling diverges. Plain
   `f32 → f16` halves weights but gets you nothing if gradients underflow to
   zero. Any serious path is **mixed precision**: fp16 activations, fp32
   master weights, loss scaling.
4. **Recommendation:** Option A (fp16 Metal kernels only, f64 stays in Rail)
   this week as an isolated capacity+throughput test. Option C (full mixed
   precision) is a 1-2 week effort and benefits from an overnight baseline
   under Option A to quantify the precision headroom we actually have.

## Current state

### Precision topology

| Layer | Precision | Notes |
|---|---|---|
| Rail `float_arr` | f64 | IEEE 754 doubles. `float_arr_new`, `float_arr_set`, `float_arr_get` |
| `foreign tgl_*_f64` | f64 pointers | `stdlib/tensor.rail:200-221` — 21 entry points |
| Dylib boundary | f64 → f32 copy | `tools/metal/tensor_gpu_lib.m`: offset +8 past count header, copy into a `float *` staging buffer |
| Metal kernels | fp32 | All 26 kernels in `tools/metal/tensor_gpu.metal` use `device float` |
| Dylib return | f32 → f64 copy | Result written back into Rail's f64 `float_arr` payload |

So every GPU call already pays **two full-tensor conversions** plus the
host-to-device copy. Dropping to fp16 inside Metal adds one more conversion
layer at the GPU boundary; doing fp16 throughout avoids the CPU-side
conversion too.

### Memory / bandwidth baseline (rough)

For a `d=128, L=4, seq=1024, vocab=256` run (Phase 2a-b target):

- Parameters: ~800 KB at f64, ~400 KB at f32, ~200 KB at f16
- Activations (per layer, batch=1): ~4 MB at f64, ~2 MB at f32, ~1 MB at f16
- GPU memory bandwidth (M1 Ultra): 800 GB/s theoretical, ~400 GB/s
  sustained on matmul. fp16 would halve the bytes-per-op.

The plan's "2× memory + bandwidth" claim is accurate vs. **f32**, which is
what we already have on the GPU side. It's "4× vs f64" if we also migrate the
Rail layer.

## Three paths

### Option A — fp16 Metal kernels only (GPU-local)

**What changes:** each `tensor_gpu.metal` kernel gets a `half` variant.
Dylib stages Rail f64 into a `half *` buffer instead of `float *`. Rail API
unchanged; `tgl_*_f64` entry points keep their signatures. Name the new
entry points `tgl_*_f16` so callers opt in per-op.

**Files touched:**
- `tools/metal/tensor_gpu.metal` — 26 kernels × (fp32 + fp16 variants) = 52
  total, or factor out via template macros. fp16 requires careful
  accumulator typing (accumulate in fp32 even if operands are fp16) to avoid
  catastrophic rounding on reductions.
- `tools/metal/tensor_gpu_lib.m` — parallel dispatch path for each `_f16`
  entry. Conversion helpers `double → half` on host.
- `stdlib/tensor.rail` — new `foreign tgl_*_f16` decls. New wrappers like
  `matmul_fp16` alongside existing `matmul`. Gate selection somehow —
  either per-op explicit or a global config.

**Scope:** ~2-3 days. Half kernels are mechanical. The main unknown is
whether fp16 accumulation alone is stable for attention softmax+layernorm;
expect to promote the final reductions to fp32 regardless (this is what
FlashAttention-2 does on fp16 paths).

**Precision risk:** contained. Rail master weights stay f64, so training
can still converge even if fp16 kernels have rounding drift. Loss
comparison is clean: run same seed+config with and without fp16 flag, diff
the loss curves.

**Value:** 2× GPU memory (bigger batches) + 2× GPU bandwidth (faster matmul,
estimated 1.5× end-to-end step time for d=128). **Does not** reduce Rail-side
memory (still f64 in arena).

### Option B — Full f16 migration (Rail + GPU)

**What changes:** Rail gets a native `half_arr` type. `float_arr_new` stays
f64; new `half_arr_new` allocates half-width. Compiler emits f16 load/store.
`foreign tgl_*_f16` takes half-pointer.

**Files touched:**
- `tools/compile.rail` — codegen for `half_arr_*` family. ARM64 has `fp16`
  instructions (M1+) via `half` or NEON, but Rail's native float handling is
  currently d-register (f64); f16 would need separate register allocation.
  Estimate: **2-4 weeks**, high risk. Self-compile fixed point across f16
  codegen changes is non-trivial.
- `runtime/gc.o` — arena scanner needs to know half vs double payload sizes.
- `stdlib/tensor.rail` — entire Tensor ADT forks by precision, or gains a
  `precision` field in the `Tensor` constructor.
- Every consumer (transformer.rail, optim.rail, autograd.rail) — update.

**Precision risk:** high. Rail-side f16 means model state IS f16 — no fp32
fallback for weights. Any fp16 numerical issue is terminal for that run.

**Value:** 4× memory (f64 → f16) and 2× bandwidth everywhere.

**Assessment:** not this week. The compiler work alone is half the plan's
total time budget, and the payoff is mostly memory (which isn't the binding
constraint at current model sizes — we're compute-bound, not memory-bound).

### Option C — Mixed precision (fp16 fwd/bwd, fp32 master, loss scaling)

**What changes:** Rail keeps f64 weights (call them the "master copy").
Before each step: downcast master → fp32 shadow → fp16 activations for
forward. Gradients come back in fp16, accumulated in fp32, unscaled, and
applied to the master in f64. Implements the standard PyTorch `amp`
pattern.

**Files touched:**
- All of Option A (fp16 kernels on the dispatch path).
- `stdlib/optim.rail` — Adam update takes fp32 grad + f64 master; no API
  change at Rail level, but the dylib Adam entry point needs a fp16 → fp32
  unscale step before the f64 accumulate.
- `stdlib/autograd.rail` — backward pass dispatches to fp16 kernels.
- `tools/train/lm_v*.rail` — training loop adds a `loss_scale` scalar that
  multiplies loss before backward and divides gradients before optim step.
  Skip step on inf/nan grad.

**Scope:** 1-2 weeks. Option A is 60% of the kernel work; the training-loop
plumbing is another ~2-3 days.

**Precision risk:** low-medium. This is the battle-tested pattern for every
modern ML framework. Main risks are (1) loss scaling tuning — start at
`2^8`, halve on overflow, double every 2000 clean steps, (2) the
fp16-unsafe ops (softmax, layernorm) need fp32 fallback paths.

**Value:** 2× GPU throughput, similar convergence to f64. **This is the
actual goal** of "mixed precision" in the plan.

## Recommendation

**Week 1 (this week, if we include it):** Option A only.

Why: it's the minimum viable test. We get fp16 kernels working end-to-end,
we see whether the M1 Ultra actually gives ~2× matmul throughput at fp16,
and we measure whether our training is memory-bound or compute-bound at
d=128. If Option A shows real throughput gain AND the fp16 kernels don't
silently break the loss curve, we have everything we need to scope Option C.

**Week 2+:** Option C.

Why: Option B is strictly worse than C at this scale — we pay 2-4 weeks of
compiler work to save memory we don't need, while still having worse
numerical stability than keeping an f64 master. C is the
industry-standard pattern and gets us to production-quality throughput.

**Explicitly not recommending now:**
- Option B: wrong effort/reward ratio. Revisit when model scale makes
  f64 memory the binding constraint (probably d=512+).
- bf16: M1 Ultra does NOT have hardware bf16 support in Metal — it's
  emulated. Pure-fp16 on M1 is faster than bf16 on M1 for our workloads.
  Apple Silicon moves to bf16 starting M3; Studio (M1 Ultra) doesn't get
  this win. Revisit when hardware lands.

## Decision checklist

Before we commit to Option A:

- [ ] Do a fp16 throughput probe: single isolated matmul (d=1024) via a
      one-off kernel, measure fp32 vs fp16 wall on Studio's M1 Ultra. If
      fp16 isn't at least 1.6× faster, stop — the win isn't there.
- [ ] Run the current d=64×2-block lm_v3_chunked overnight (Phase 1c,
      in-flight) and get a clean f64 baseline loss curve. Option A's test
      is "does the same config at fp16 GPU reach within 5% of this loss in
      the same wall?"
- [ ] Decide on opt-in granularity. Global flag (env var, sentinel file)
      is the 1-hour version. Per-op flag is 1-day version. Global is fine
      for a first pass — worst case we revert the flag and keep f64.

## References

- Rail tensor surface: `stdlib/tensor.rail:200-221` (foreign decls).
- Metal kernels: `tools/metal/tensor_gpu.metal` — 26 kernels, all `device float`.
- Dylib bridge: `tools/metal/tensor_gpu_lib.m` — `_f64` entry points,
  f64→f32 copy staging.
- Prior art: NVIDIA Apex / PyTorch AMP for the mixed-precision pattern.
  Apple's Metal Performance Shaders (MPS) in `Metal.framework` has fp16
  matmul reference implementation.
- Rail quirks relevant here: `float_arr` nullary binding re-evaluation
  (watch for it in Option B). See `rail_quirks.md`.
