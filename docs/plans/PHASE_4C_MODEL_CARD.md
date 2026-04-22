# Phase 4c model card — Rail-on-Rail transformer

**Status:** 2026-04-22 numbers locked for d=256 × 2-block and d=256 × 4-block. 6000-step run in flight on Studio (Session 6, ETA ~5h completion); numbers for the longer-training variant will be appended when it lands.
**Written:** 2026-04-21 evening → 2026-04-22 ongoing.
**Predecessor docs:** `HALFTENSOR_SESSION2_RESULT.md` (precision substrate), `PHASE_5A_HALF_TRAIN_RESULT.md` (2-block pipeline), `PHASE_5_RESULT.md` (2-block d=256 arc + first bench), `PHASE_5B_RESULT.md` (4-block d=256 deeper), `PHASE_5C_SAMPLING_RESULT.md` (top-k sampling negative result).

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
| v3 chunked d256 half | HalfTensor fwd / f64 bwd | 256 | 2 | 3000 | 3.49 ± 0.17 | 2.58 |
| **v3 chunked d256 4-block half (S4)** | HalfTensor fwd / f64 bwd | 256 | 4 | 3000 | **3.39 ± 0.19** | **2.57** |
| v3 chunked d256 4-block half 6k (S6 in flight) | HalfTensor fwd / f64 bwd | 256 | 4 | 6000 | pending | pending |

Context on the two d=128 baselines: at d=128, depth alone doesn't help. 4-block matches 2-block within 1σ of eval noise. The 4-block model memorizes individual chunks more aggressively (min 0.965 vs 1.37) but doesn't generalize to held-out chunks. This is the motivation for the d=256 flagship: width, not depth, is the next dial.

The d=128 half result (3.50) was a 500-step intermediate, not a training endpoint — its role was to prove the half pipeline converges to within eval noise of f64 at every checkpoint (max Δ 0.28, within 1.5σ of each side's eval std).

**Flagship result analysis.** Neither d=256 × 2-block (3.49) nor d=256 × 4-block (3.39) cleared the ≤2.87 bar set by the f64 d=128 baseline. Interpretation: **width alone does not compensate for half precision at 3000 steps** on this corpus; **depth narrows the gap by 0.10** but doesn't close it. The 4-block min-single-chunk (2.57) is lower than any prior checkpoint's, suggesting deeper models have the capacity to memorize better but lack the training signal to generalize. Both runs plateau from step ~2500 onward — more training steps may be the operative lever (Session 6's 6000-step run tests this hypothesis directly).

**Success thresholds** (for the still-running and future runs):
- **Primary:** eval mean < 2.7. Clears the d=128 f64 baseline meaningfully.
- **Stretch:** eval mean < 2.5.
- **Minimum viable:** bench_railnative ≥ 5/30, regardless of held-out eval (bench is the deadline gate).

## Hardware

| property | value |
|---|---|
| machine | Apple Mac Studio (M1 Ultra, 64 GB) |
| GPU | M1 Ultra integrated (Metal) |
| kernels | custom fp16 GEMM + 4 fp16 elementwise ops (`tools/metal/tensor_gpu.metal`) |
| OS | macOS (Darwin 25.4) |
| peak RSS (d=256 × 2-block × 3000) | 580 MB |
| peak RSS (d=256 × 4-block × 3000) | 606 MB |
| wall-time (d=256 × 2-block × 3000) | 84 min (1.68 s/step) |
| wall-time (d=256 × 4-block × 3000) | 171 min (3.43 s/step) |

**Memory analysis.** At d=128, peak RSS was ~parity between fp16 and f64 (512 MB vs 508 MB, 10-step bench) — cast temps for the bracketed f64 ops reclaimed the weight-memory savings. At d=256 × 2-block, the measured 580 MB is below the 600 MB soft ceiling and essentially tied with the d=128 f64 baseline despite training a ~4× larger model — **the HalfTensor weight-memory halving hypothesis held**. Going from 2-block to 4-block at d=256 added only +26 MB (606 vs 580), consistent with ~20 MB per extra block of activation cache, confirming the per-block cache contribution is on the order of (12 half tensors × seq × d) ≈ 25 MB/block as projected.

**Speedup.** 4-block at d=256 runs at 3.43 s/step vs 2-block at 1.68 s/step — ~2.04× per step for 2× model size. Forward path with real half kernels scales sub-quadratically with depth thanks to the half matmul compiler cost amortizing.

## `bench_railnative`

| checkpoint | bench score | total quality | notes |
|---|---:|---:|---|
| d=256 × 2-block × half (S3) | **1/30** | 17,706 | Fund 1/5, others 0/5. Single pass from Fund-1 (fact+main prompt was already a complete program; empty completion compiled) |
| d=256 × 4-block × half (S4) | **1/30** | 17,706 | Byte-identical to 2-block result — model's whitespace-dominated output means both checkpoints produce same completions |
| d=256 × 4-block × half × 6000 (S6) | pending | pending | Session 6 run in flight |
| d=256 × 4-block × half (S4) with top-k 5 sampling (S5) | not completed | — | Killed at task 4/30 after 7 min wall; per-step cost 15× higher; sampling-smoke diagnostics showed one non-whitespace char then collapse to newlines, predicted bench delta of zero |

**Target:** ≥5/30 (2026-04-27 milestone).
**Current ceiling at this model scale:** 1/30 via argmax, same via sampling, because the model's softmax at char-level perplexity ~30 has mass ≈1.0 on `\n` after any content char.
**Gap:** 4 more passes. Requires either (a) longer training to push eval below ~2.5 where non-whitespace chars get top-1, (b) bigger corpus to teach the model program-level structure, (c) better inference harness (beam search, constrained decoding against Rail grammar).

Bench format (as of 2026-04-04): 30 questions across 6 bands of 5 each (FUND / IO / TOOLS / COMP / ADV / COMPREHEND); score is total compile-passes out of 30. Historical range on prior model states: 0/30 — 14/30 (see `DEADLINE_2026-04-27_PUNCHLIST.md` §"Historical bench data").

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
# The 2-block d=256 3000-step flagship (S3 Run 2 with lr_mult=0.3):
git checkout 255b279                                       # "train: lm_v3_chunked_d256_half — lr_mult=0.3 on γ + final checkpoint save"
./rail_native test                                         # expect 136/137 on Studio, 137/137 on Mini
./rail_native self && cmp rail_native /tmp/rail_self       # verify byte-identical self-compile
./rail_native run tools/train/lm_v3_chunked_d256_half.rail

# The 4-block d=256 3000-step run (S4):
git checkout 7218806                                       # "train: lm_v3_chunked_d256_4block_half — Session 4 deeper variant"
./rail_native run tools/train/lm_v3_chunked_d256_4block_half.rail

# Bench a landed checkpoint:
./rail_native run flywheel-local/bench_railnative.rail \
    --prefix training/rail_native/checkpoints/d256_4block_half_step3000 \
    --max 128 --k 1 --temp 1.0
```

Expected compile time ~6-8 s. Expected wall-time: d=256 × 2-block × 3000 steps → 84 min; d=256 × 4-block × 3000 → 171 min; d=256 × 4-block × 6000 → 340 min. All on M1 Ultra.

The Metal dylib (`tools/metal/libtensor_gpu.dylib`) is gitignored; the training binary dlopens it from the source path via `-install_name`. Rebuild locally after checkout:

```bash
cd tools/metal && clang -shared -fobjc-arc \
  -framework Metal -framework Foundation \
  -install_name "/Users/$USER/projects/rail/tools/metal/libtensor_gpu.dylib" \
  tensor_gpu_lib.m -o libtensor_gpu.dylib
```

## Scaling position

The architecture shipped here (RMSNorm + RoPE + SwiGLU + tied embeddings + HalfTensor forward + f64 backward) is the same recipe used at 7B-70B scale by Llama / Mistral / Qwen. It is not a dead-end shape. On a Studio-class M1 Ultra (128 GB unified memory), the theoretical ceiling of this stack is approximately:

| config | params | est. peak RSS | notes |
|---|---:|---:|---|
| d=256 × 4-block (this model) | 3.4M | 606 MB | shipped |
| d=512 × 8-block | ~28M | ~1.2 GB | single-file edit from current shape |
| d=1024 × 12-block | ~164M | ~4 GB | needs arena bump (one compile.rail constant) |
| d=2048 × 16-block | ~830M | ~18 GB | needs fp16/bf16 Adam to be practical |
| d=2560 × 20-block | ~1.7B | ~35 GB | needs gradient checkpointing |
| d=3072 × 16-block | ~2.0B | ~40 GB | Studio's comfortable ceiling |

**Four concrete engineering items gate the path to ~2B:**
1. Arena: bump from 512 MB to ~4 GB in `tools/compile.rail` (~30 min).
2. Checkpoint resumption CLI: wired into `lm_v3_chunked_d256_4block_half_6k.rail` via `--resume <prefix>` this session (commit pending at writing).
3. bf16/fp16 Adam state — halves the dominant memory line at scale (~2-3 days).
4. Gradient checkpointing — re-run forward during backward instead of caching, -60% cache line (~1 week).

**The hard bottleneck is corpus**, not compute or RAM. Training a 2B-param model to Chinchilla-optimal needs ~40 GB of Rail source; all public Rail code is ~10 MB total (4000× short). The `self_train.rail` flywheel is the theoretical path to closing this gap but is empirically unproven at the scale we'd need.

## Load-bearing references

- `docs/plans/HALFTENSOR_SESSION2_RESULT.md` — precision substrate, all four half kernels + convergence result.
- `docs/plans/PHASE_5A_HALF_TRAIN_RESULT.md` — Studio-lane pipeline result, cast strategy, residual f64 ops.
- `docs/plans/PHASE_4B_BENCH.md` — fp16-in-backward divergence finding.
- `tools/train/lm_v3_chunked_half.rail` — training loop source (d=256 variant lives in `lm_v3_chunked_d256_half.rail`).
- `stdlib/tensor.rail` — `HalfTensor` ADT, `matmul_half`, `add_half`, `scale_half`, `transpose_half`, `softmax_half`.
- `tools/metal/tensor_gpu.metal` — the fp16 kernels themselves.

---

The model is not the point. The substrate is. This card exists because it documents the substrate.
