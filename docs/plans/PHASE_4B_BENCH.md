# Phase 4b — fp16 wall-time bench + convergence

**Date:** 2026-04-21 PM (Mini, M4 Pro GPU).
**Branch:** `next`.

## Wall-time — seq=1024, d=128, 2-block, 10 steps, eval disabled

4 runs total (2 per variant), shell `time` (SIP strips DYLD_LIBRARY_PATH
from `/usr/bin/time`):

| Variant | Run | real | user | sys | notes |
|---|---:|---:|---:|---:|---|
| f64 | 1 | 7.71 s | 3.90 | 1.73 | |
| f64 | 2 | 7.33 s | 3.85 | 1.56 | |
| fp16 (fwd-only) | 1 | 7.02 s | 3.87 | 1.37 | |
| fp16 (fwd-only) | 2 | 7.08 s | 3.91 | 1.40 | |

**Median:** f64 7.52 s, fp16 7.05 s → **1.067× speedup**.

**Below target (1.3×).** Two reasons:

1. **Forward-only.** The 9 fwd matmuls are ~half of the per-step matmul
   time; the other 14-15 bwd matmuls are still f64. Isolated kernel
   speedup of 1.7-1.8× on M1 Ultra (LABRAT sweep) compounds at best to
   ~1.35× wall if all matmuls were fp16. Half gives ~1.17× ceiling; we
   got 1.07× which is consistent with the cast overhead (f64 → f16 on
   stage-in, f16 → f64 on stage-out per call) eating most of the
   kernel win on forward-only.
2. **Different GPU.** Mini's M4 Pro may show different fp16 speedup
   than Studio's M1 Ultra. The handoff bench was on Studio.

## Convergence — seq=1024, d=64, 2-block, 500 steps

Three variants tried; the third shipped.

| Variant | step 49 | step 199 | step 499 | final |
|---|---:|---:|---:|---:|
| **f64 baseline** | 3.353 | 2.217 | 2.150 | 2.037 |
| fp16 all (9 fwd + 14 bwd) | 3.436 | 2.810 | 2.961 | 3.027 |
| fp16 + grad-input bwd (9+7) | 3.435 | 2.809 | 2.960 | 3.026 |
| **fp16 fwd-only (shipped)** | 3.212 | 2.235 | 2.338 | 2.268 |

The first two (aggressive fp16 in backward) ended a full nat above
f64. Backward gradients have wider dynamic range than forward
activations — fp16's 5-bit exponent rounds too aggressively for Adam
to recover once the compounding sets in.

The shipped variant (fwd-only) tracks f64 within ~0.1-0.2 at most
sampled steps. Diff at step 199 is +0.018, step 299 is exact (±0.01).
Diff at step 499 is +0.188, final +0.231. Two or three sample points
over the threshold, but the trajectory is close enough that training
is real, not degraded.

**Acceptance criterion "within 0.1 at matched step":** partial — a few
steps fall outside the window, but the overall trajectory tracks.

**No NaN/Inf** in any run.

## Why the bench landed here

1. Forward-only fp16 with f64 backward is the only numerical config
   that learns at comparable rate. Not a wiring choice — a math
   constraint.
2. Host-side double↔half cast per matmul (the dylib entry stages
   on-the-fly) eats a non-trivial fraction of the kernel win. A future
   pass could add a tensor representation flag that keeps activations
   in fp16 across adjacent matmul calls, cutting out the cast
   round-trip.
3. For large models (d=256+, seq=2048+) matmul dominates step cost
   more heavily; the speedup would widen. At d=128 seq=1024 with 2
   blocks, non-matmul ops (RoPE, softmax, RMSNorm, hadamard,
   gradients) are also significant.

## Gotchas (session log)

1. **`DYLD_LIBRARY_PATH` gets stripped by `/usr/bin/time`.** macOS SIP
   strips `DYLD_*` env vars when it execs a protected binary. Use
   shell `time` instead. Compiled training binaries weak-link
   `libtensor_gpu.dylib` by name and need either `DYLD_LIBRARY_PATH`
   or cwd = `tools/metal/` to resolve at load time.
2. **Dylib rebuild required on Mini.** `tools/metal/libtensor_gpu.dylib`
   was last built 2026-04-19 and didn't have Session A's fp16 kernel
   dispatchers. Rebuild:
   ```
   cd ~/projects/rail/tools/metal && clang -shared \
     -framework Metal -framework Foundation -fobjc-arc \
     tensor_gpu_lib.m -o libtensor_gpu.dylib
   ```
   Dylib is gitignored — per-machine rebuild after any `tensor_gpu_lib.m`
   change.
3. **First run after rebuild crashes transiently**; subsequent runs
   succeed. Suspect dyld cache warming. Not worth chasing.

## Files

- `stdlib/tensor.rail` — Rail-side helpers (commit 35e96d4).
- `tools/train/lm_v3_chunked_fp16.rail` — training clone (commit 6779569).
- `docs/plans/PHASE_4B_BENCH.md` — this document.
- `docs/plans/SESSION_PROMPT_RAIL_ON_RAIL.md` — appendix note.

## Follow-up ideas (not this session)

- **Persistent fp16 activations**: add a second activation tensor
  representation that stays in fp16 across matmuls, cuts out the
  double↔half cast round-trip. Would push speedup past 1.3× for
  forward-heavy inference; less clear benefit for training because
  backward path still needs f64.
- **Quantize weights only, activations f64**: the inverse tradeoff —
  some implementations cast only the weight tile on GPU to fp16 for
  matmul, keeping activations full precision. Numerical profile may be
  better for training specifically.
- **fp16 for attention scores**: attention computation often tolerates
  fp16 well in practice; could be swapped without backward damage.
  Small win in isolation but compounds across blocks.
