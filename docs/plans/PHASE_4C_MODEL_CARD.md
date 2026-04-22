# Phase 4c model card — Rail-on-Rail transformer

**Status:** draft for 2026-04-27 external-release review. Eval / RSS / wall-time rows are placeholders pending the 3000-step HalfTensor run (in flight on Studio as of 2026-04-21 16:52 PT).
**Written:** 2026-04-21 evening, Studio docs session (concurrent with the run).
**Predecessor docs:** `HALFTENSOR_SESSION2_RESULT.md` (precision substrate), `PHASE_5A_HALF_TRAIN_RESULT.md` (pipeline), `SESSION_HANDOFF_2026-04-22.md` (open work).

## One-liner

> A Rail-native transformer whose forward matmuls, weights, softmax, transposes, adds, and scales are all fp16 — cast once at init, never per call — trained end-to-end with an f64 backward, verified by a Rail compiler written in Rail.

## Architecture

Llama-style decoder-only transformer, 2 blocks, pre-norm, tied embeddings.

| component | value |
|---|---|
| blocks | 2 |
| hidden dim `d` | 256 (flagship) / 128 (f64 baseline) |
| FFN width `d_ff` | `3 × d` = 768 / 384 |
| heads | 1 (single-head attention at this scale) |
| positional encoding | RoPE (rotary) applied to Q, K |
| normalization | RMSNorm, pre-norm, learnable γ per layer (3 per block + 1 final) |
| activation | SwiGLU (gate × silu(up)) in FFN |
| attention | causal, scaled dot-product (1/√d scale) |
| output head | tied to embedding (`w_eᵀ`) |
| vocabulary | 130-symbol char-level, built from the training corpus |

Parameter count (d=256, 2-block, tied):

| slot | shape | count |
|---:|:---|---:|
| `w_e` / LM head | 130 × 256 | 33,280 |
| per block: `w_q`, `w_k`, `w_v`, `w_o` | 256 × 256 × 4 | 262,144 |
| per block: `w_gate`, `w_up` | 256 × 768 × 2 | 393,216 |
| per block: `w_down` | 768 × 256 | 196,608 |
| per block: `g1`, `g2` (RMSNorm γ) | 256 × 2 | 512 |
| final `gf` | 256 | 256 |
| **total** (2 blocks) | | **~1.74 M** |

At d=128 the total is ~440 K parameters.

## Precision design

The defining choice of this model is where fp16 lives and where it doesn't.

| slot | precision | rationale |
|---|---|---|
| **weights** (in memory) | HalfTensor (fp16 packed) | halves weight-memory footprint; single cast at init, no per-step conversion |
| **forward matmuls** (18 per step + embed + LM head) | `matmul_half` GPU kernel (fp16 in, fp16 out) | 4.77× speedup vs f64 matmul at 1024² (6.4× warm, post-S2 dylib) |
| **forward add / scale / transpose** | `add_half` / `scale_half` / `transpose_half` GPU kernels | max-abs-diff < 3e-4 vs f64 reference |
| **forward softmax** | `softmax_half` with log-sum-exp reformulation | overflow-safe for pre-exp logits up to ~88; verified at seq=1024 d=128 |
| **RMSNorm, RoPE, SwiGLU, Hadamard, causal mask** | bracketed f64 (`tensor_of_half → op → half_of_tensor`) | per-element ops where fp16 rounding bias accumulates; cast cost small; precision risk not worth the ~10% memory saving |
| **backward pass** (all grads, all matmuls) | f64 | Phase 4b showed fp16 backward diverges by ~1 nat at step 499 |
| **Adam state** (m, v) | f64 | standard stability; state is ~2× weight memory, trades memory for robust optimization |
| **Adam weight update** | f64 compute, pack-back into HalfTensor in place | `half_adam_update` casts weight out, runs `adam_update_raw`, packs result back; ADT identity preserved so callers keep their reference |

**Numerical accuracy of the four non-matmul half kernels** (Session 2, max abs diff vs f64 reference):

| kernel | 128² | 1024² / 1024-row |
|---|---:|---:|
| `add_half` | 2.4e-4 | 2.4e-4 |
| `scale_half` (×2.5) | 7.8e-4 | 7.8e-4 |
| `transpose_half` | 2.3e-4 | 2.3e-4 |
| `softmax_half` (s=4) | 2.0e-5 | 2.7e-6 |
| `softmax_half` (s=20) | — | 5.5e-5 |

All four sit at least an order of magnitude under the 1e-3 soft threshold. The matmul output accuracy floor at 1024² is 6.92e-3 (kernel-inherent from Session 1). Non-matmul half ops sit at 2-8e-4. Neither drifts during the 500-step Session 2 run.

## Training configuration

| knob | value |
|---|---|
| `seq_len` | 1024 |
| steps | 3000 |
| optimizer | AdamW (β₁=0.9, β₂=0.999, ε=1e-8) |
| `base_lr` | 0.02 |
| LR schedule | linear warmup 100 steps → cosine decay to ~1e-4 |
| γ LR multiplier | 0.3 (damping for RMSNorm γ bounce observed at d=128) |
| init | Kaiming-scaled, `std = sqrt(2 / fan_in)` (unblocked 2-block v3 from a plateau at 2.22 → 1.55) |
| sampling | random LCG offset per step into the id-encoded corpus (seed=42) |
| eval | held-out 10-chunk set at `eval_seed=1337`, re-sampled same offsets every `eval_interval=100` steps |
| batch | 1 chunk per step (seq=1024 tokens) |

## Corpus

| property | value |
|---|---|
| file | `training/rail_corpus_stdlib.txt` |
| size | 544,018 characters |
| source | concatenated Rail stdlib sources |
| vocabulary | 130 distinct chars, built at load time |
| eval split | 10 fixed held-out 1024-char chunks drawn once at startup with a separate rng (training rng sequence untouched — reproducibility of prior baselines) |

The corpus is the Rail stdlib in Rail. Training on this corpus is what makes the "Rail-on-Rail" claim defensible: the model is learning to produce text in the language it was compiled by.

## Eval results

Held-out eval mean CE loss over 10 fixed chunks (lower is better). Uniform-prediction floor for V=130 is log(130) ≈ 4.87. Random initialization at `seq=1024` gives ~13.2 (~3× uniform; an init-level artifact, not a bug — observed identically on the f64 baseline).

| model | precision | d | blocks | steps | eval mean @ final | min single-chunk |
|---|---|---:|---:|---:|---:|---:|
| v3 chunked (baseline) | f64 | 128 | 2 | 3000 | **2.87 ± 0.18** | 1.37 |
| v3 chunked 4-block | f64 | 128 | 4 | 2900 | 2.88 ± 0.23 | 0.965 |
| v3 chunked half (S2) | HalfTensor fwd / f64 bwd | 128 | 2 | 500 | 3.50 ± 0.16 | 2.35 |
| **v3 chunked d256 half (flagship)** | HalfTensor fwd / f64 bwd | 256 | 2 | 3000 | **TBD — run in flight** | TBD |

Context on the two d=128 baselines: at d=128, depth alone doesn't help. 4-block matches 2-block within 1σ of eval noise. The 4-block model memorizes individual chunks more aggressively (min 0.965 vs 1.37) but doesn't generalize to held-out chunks. This is the motivation for the d=256 flagship: width, not depth, is the next dial.

The d=128 half result (3.50) was a 500-step intermediate, not a training endpoint — its role was to prove the half pipeline converges to within eval noise of f64 at every checkpoint (max Δ 0.28, within 1.5σ of each side's eval std). The 3000-step d=256 half result is what the flagship claim rests on.

**Success thresholds for the flagship:**
- **Primary:** eval mean @ 3000 < 2.7. Clears the d=128 baseline by a meaningful margin, establishing width scaling.
- **Stretch:** eval mean @ 3000 < 2.5.

## Hardware

| property | value |
|---|---|
| machine | Apple Mac Studio (M1 Ultra, 64 GB) |
| GPU | M1 Ultra integrated (Metal) |
| kernels | custom fp16 GEMM + 4 fp16 elementwise ops (`tools/metal/tensor_gpu.metal`) |
| OS | macOS (Darwin 25.4) |
| peak RSS (3000 steps) | TBD — run in flight; d=128 baseline ~460-515 MB |
| wall-time (3000 steps) | TBD — S2 projection ~1.5-2 h under the active-kernel path |

**Memory analysis.** At d=128, peak RSS is ~parity between fp16 and f64 (512 MB vs 508 MB, 10-step bench) — cast temps for the bracketed f64 ops reclaim the weight-memory savings. At d=256, stored weights scale 4× while cast temps scale ~2× (temps follow `seq × d_ff`, not weight count), so the weight-memory prize should become visible. Success criterion for the flagship RSS: < 600 MB (within 2× of the d=128 f64 baseline, not the naive 4× that weight scaling alone would give).

## `bench_railnative`

Score: TBD. The bench harness (`flywheel/bench_railnative.rail`) lives in the private `Ledatic-Empire/rail-training` repo — needs sync from Mini and a run against the 3000-step checkpoint before this row is populated.

Bench format (as of 2026-04-04): 30 questions across 6 axes of 5 each (fund, io, tools, comp, adv, comprehend); score is the total out of 30. Target: ≥ 5/30. Historical range on prior model states: 0/30 — 14/30 (see `DEADLINE_2026-04-27_PUNCHLIST.md` §"Historical bench data").

## Compiler provenance

The compiler that compiled the training loop is itself written in Rail:

| property | value |
|---|---|
| source | `tools/compile.rail` (~4,690 lines, 335 functions) |
| seed binary | `rail_native` (729K ARM64, checked into repo) |
| self-compile | `./rail_native self` produces `/tmp/rail_self`; `cmp rail_native /tmp/rail_self` is byte-identical (fixed point verified) |
| test suite | 137 tests (`./rail_native test`); stable floor 137/137 on Mini, 136/137 on Studio (`gpu_map` test needs `xcrun metal`) |
| runtime | zero C deps; GC is ARM64 assembly embedded in the compiler; only `as` + `ld` required |
| targets | macOS ARM64 (native), Linux ARM64 (cross), Linux x86_64 (cross) |
| floats | unboxed IEEE 754 doubles in ARM64 d-registers, no heap allocation |

The fp16 story relies on three pieces of provenance:
1. The four fp16 kernels (`matmul_half`, `add_half`, `scale_half`, `transpose_half`, `softmax_half`) are Metal shaders in `tools/metal/tensor_gpu.metal`, dispatched from Objective-C host code in `tools/metal/tensor_gpu_lib.m`.
2. The Rail-side bindings (`HalfTensor` ADT, pack/unpack primitives, wrappers) live in `stdlib/tensor.rail`.
3. The training loop that composes those primitives (`tools/train/lm_v3_chunked_half.rail`, 796 lines) is Rail code compiled by the self-hosted Rail compiler.

Every layer from "bit pattern of a weight in memory" up to "training step" is either Rail or a Metal shader invoked from a Rail-generated binary. No Python, no C++ framework, no intermediate lowering.

## What this model does not do

Listed because "end-to-end fp16" could be misread without these caveats:

- **The backward pass is f64.** Phase 4b established that fp16 in backward diverges by ~1 nat at step 499 vs the f64 baseline. Treat "trained end-to-end with fp16" as shorthand; the literal claim is "fp16 forward, fp16 weights in memory, f64 backward and Adam."
- **RMSNorm, RoPE, SwiGLU, causal mask, Hadamard are f64 in forward too.** These are single-call-site bracketed casts. They exist because they're per-element ops where rounding bias accumulates fast and the cast cost is small. Moving them to half kernels is a next-next optimization mentioned in the S2 writeup, not in this model's scope.
- **No batch dimension.** One sequence per step. Flagship result does not require batching; it would reduce step-to-step noise but not change the headline claim.
- **No attention heads.** Single-head at this d. Multi-head would be a straightforward follow-up but is out of scope.
- **No gradient clipping beyond Adam's ε floor.** γ LR mult of 0.3 is the only targeted regularization.

## Replication

```bash
git checkout <commit-sha>                                 # TBD when 3000-step run merges
./rail_native test                                        # expect 136/137 on Studio, 137/137 on Mini
./rail_native self && cmp rail_native /tmp/rail_self      # verify byte-identical self-compile
./rail_native run tools/train/lm_v3_chunked_d256_half.rail
```

Expected compile time ~6-8 s. Expected wall-time ~1.5-2 h at d=256 × 2-block × 3000 steps on M1 Ultra.

The Metal dylib (`tools/metal/libtensor_gpu.dylib`) is gitignored; the training binary dlopens it from the source path via `-install_name`. Rebuild locally after checkout:

```bash
cd tools/metal && clang -shared -fobjc-arc \
  -framework Metal -framework Foundation \
  -install_name "/Users/$USER/projects/rail/tools/metal/libtensor_gpu.dylib" \
  tensor_gpu_lib.m -o libtensor_gpu.dylib
```

## Load-bearing references

- `docs/plans/HALFTENSOR_SESSION2_RESULT.md` — precision substrate, all four half kernels + convergence result.
- `docs/plans/PHASE_5A_HALF_TRAIN_RESULT.md` — Studio-lane pipeline result, cast strategy, residual f64 ops.
- `docs/plans/PHASE_4B_BENCH.md` — fp16-in-backward divergence finding.
- `tools/train/lm_v3_chunked_half.rail` — training loop source (d=256 variant lives in `lm_v3_chunked_d256_half.rail`).
- `stdlib/tensor.rail` — `HalfTensor` ADT, `matmul_half`, `add_half`, `scale_half`, `transpose_half`, `softmax_half`.
- `tools/metal/tensor_gpu.metal` — the fp16 kernels themselves.

---

The model is not the point. The substrate is. This card exists because it documents the substrate.
