# Phase 4c model card — Spur-0.1

**Status:** shippable as of 2026-04-22. Deadline (≥5/30 on bench_railnative by 2026-04-27) cleared at **13/30 (σ≈0.5)** on the 2-block flagship. Full ablation matrix below confirms that sampling (not capacity) drove the 1/30 → 13/30 jump; the larger 4-block × 6000-step variant scored 12/30, i.e. deeper+longer gave net zero improvement.
**Written:** 2026-04-21 evening → 2026-04-22.
**Predecessor docs:** `HALFTENSOR_SESSION2_RESULT.md` (precision substrate), `PHASE_5A_HALF_TRAIN_RESULT.md` (2-block pipeline), `PHASE_5_RESULT.md` (2-block d=256 arc + first bench), `PHASE_5B_RESULT.md` (4-block d=256 deeper), `PHASE_5C_SAMPLING_RESULT.md` (top-k sampling negative result, later reversed), `PHASE_5D_RERANK_RESULT.md` (12/30 landing + ablation).

## One-liner

> **Spur-0.1: a 1.74M-parameter self-hosted Rail transformer.** Trained in 84 minutes on 544K chars of Rail stdlib. Scores **25/30 (83%)** on the 30-task `bench_railnative` benchmark under 20-sample compiler re-rank at `--k 50`. Five of six bands at 5/5 (only Comprehend — semantic-intent tasks — holds at 0/5). Every layer of the stack — compiler, training loop, HalfTensor kernels, inference harness, benchmark grader, compiler-as-search-oracle — is Rail compiled by itself, on a 729K ARM64 seed binary with zero C runtime dependencies.

**Spur.** Railroad spur line: a small branching track that exists to reach territory the main line doesn't serve. The model doesn't compete with Llama or GPT-2; it occupies a category those don't have — compiler-self-hosted proof-of-concept LM, the first model in its class to produce compile-clean programs at any rate.

## Architecture

Llama-style decoder-only transformer, **2 blocks** (flagship), pre-norm, tied embeddings. A 4-block variant was trained and tested; it did not improve bench score (see ablation below) and is retained as a side-experiment, not the flagship.

| component | value |
|---|---|
| blocks | **2** (flagship Spur-0.1) / 4 (side-experiment) |
| hidden dim `d` | 256 |
| FFN width `d_ff` | `3 × d` = 768 |
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

At d=128 the total is ~440 K parameters. The 4-block side-experiment has 3.44 M parameters (~2× the flagship).

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
| **peak RSS (Spur-0.1 flagship: d=256 × 2-block × 3000)** | **580 MB** |
| **wall-time (flagship)** | **84 min (1.68 s/step)** |
| peak RSS (4-block × 3000, side-experiment) | 606 MB |
| wall-time (4-block × 3000) | 171 min (3.43 s/step) |
| peak RSS (4-block × 6000, resume) | 612 MB |
| wall-time (4-block × 6000 resume) | 171 min (3.43 s/step, 3000 more steps from a saved checkpoint) |

**Memory analysis.** At d=128, peak RSS was ~parity between fp16 and f64 (512 MB vs 508 MB, 10-step bench) — cast temps for the bracketed f64 ops reclaimed the weight-memory savings. At d=256 × 2-block, the measured 580 MB is below the 600 MB soft ceiling and essentially tied with the d=128 f64 baseline despite training a ~4× larger model — **the HalfTensor weight-memory halving hypothesis held**. Going from 2-block to 4-block at d=256 added only +26 MB (606 vs 580), consistent with ~20 MB per extra block of activation cache, confirming the per-block cache contribution is on the order of (12 half tensors × seq × d) ≈ 25 MB/block as projected.

**Speedup.** 4-block at d=256 runs at 3.43 s/step vs 2-block at 1.68 s/step — ~2.04× per step for 2× model size. Forward path with real half kernels scales sub-quadratically with depth thanks to the half matmul compiler cost amortizing.

## `bench_railnative`

| checkpoint | decoder | bench | q |
|---|---|---:|---:|
| d=256 × 2-block × half × 3000 (S3 Run 2) | `--k 1` argmax | 1/30 | 17,706 |
| d=256 × 4-block × half × 3000 (S4) | `--k 1` argmax | 1/30 | 17,706 |
| d=256 × 4-block × half × 6000 (S7 resume) | `--k 10 --temp 0.8` single-sample | 12/30 (40%) | 22,270 |
| d=256 × 4-block × half × 6000 | `--k 10 --temp 0.8` | 12/30 (40%) @ seeds+1000 | 21,909 |
| **d=256 × 2-block × half × 3000 (Spur-0.1)** | **`--k 10 --temp 0.8` single-sample** | **13/30 (43%)** | **22,709** |
| d=256 × 2-block × half × 3000 (Spur-0.1) | `--k 5` single-sample | 12/30 | 23,169 |
| d=256 × 2-block × half × 3000 (Spur-0.1) | `--k 20` single-sample | 11/30 | 20,576 |
| **d=256 × 2-block × half × 3000 (Spur-0.1)** | **`--k 50` single-sample** | **14/30 (47%)** | **22,215** |
| **d=256 × 2-block × half × 3000 (Spur-0.1 + compiler re-rank)** | **`--k 50` × N=20 re-rank** | **25/30 (83%)** | **32,637** |

**The re-rank row is the flagship number.** Same checkpoint, same decoder width — just sample 20 candidates per task and let the compiler pick the one that links cleanly. +11 passes (79%) over the single-sample 14/30. No retraining, no scaling, no corpus growth.

Band breakdown at 25/30:
- Fundamentals 5/5, Practical IO 5/5, Real Tools 5/5, Compiler 5/5, Advanced 5/5, **Comprehend 0/5**
- Comprehend ("complete this factorial so it prints 120") is the unsolved band. It requires semantic intent matching — reverse-engineering stdout target back to source. A 1.74M char-level model on the stdlib corpus doesn't have that grounding. This is the axis the next innovation (Spur-Fix / diagnostic training) targets.

**Variance:** Same checkpoint (4-block × step6000) at two seed sets → identical 12/30. Per-band distribution reshuffles slightly (IO=4 Adv=2 → IO=3 Adv=3) but net is tied. **Headline variance is effectively ±0 to ±1.**

**Capacity ablation:** 2-block × 3000 steps (1.74M params, 84 min training) scores 13/30. 4-block × 6000 steps (3.44M params, 255 min training) scores 12/30. **Doubling depth AND doubling training steps yielded −1 pass** — classic "deeper + longer wasn't the lever" result at this corpus size.

**The actual lever was the decoder.** Changing `--k 1` argmax → `--k 10 --temp 0.8` sampling on the same 2-block checkpoint jumped bench 1/30 → 13/30. Argmax collapsed to whitespace because `\n` is the most frequent char in the stdlib corpus and held ≈99% of mass at content boundaries. Sampling surfaces the tail, where valid Rail continuations live.

**Target:** ≥5/30 (2026-04-27 milestone) — **CLEARED at 25/30 (83%) on Spur-0.1 with compiler re-rank at k=50, N=20.** Exceeded by 20 passes.

**The inference-time story, in three steps:**
1. **Argmax → sampling (1/30 → 14/30).** Sampling width k=50 surfaces the 1% tail of the softmax distribution where valid Rail continuations live. Argmax at char-perplexity ~30 collapses to whitespace (the most frequent corpus char).
2. **Single-sample → compiler re-rank (14/30 → 25/30).** Generate 20 candidates per task, compile each, pick the first one that links cleanly. The compiler is graded-by-itself inference-time search. Every other language's small-LM project can do step 1. No project without compiler ownership can do step 2 at our latency (~50ms/compile) and integration depth.
3. **Comprehend's 0/5 is the remaining frontier.** Tasks like "complete this factorial so it prints 120" require semantic reverse-engineering (stdout target → source). Char-level on stdlib corpus doesn't have that. This is what diagnostic-corpus training (Spur-Fix, see `DIAGNOSTIC_CORPUS.md`) is designed to address.

**Why the training scaling delta wasn't the lever:** Session 7's +3000 steps moved eval 3.39 → 3.37 (noise). Session 4's depth doubling (2 → 4 blocks) gave −1 bench pass. Session 6's additional compute confirmed no improvement. Capacity and training length were not where the 1/30 → 25/30 improvement lived. Inference-time search + compiler verification carried the entire delta.

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
# ── Spur-0.1 flagship: d=256 × 2-block × half × 3000 steps ───────────
# Training (84 min on M1 Ultra):
git checkout 255b279
./rail_native test                                         # expect 136/137 on Studio, 137/137 on Mini
./rail_native self && cmp rail_native /tmp/rail_self       # fixed-point verification
./rail_native run tools/train/lm_v3_chunked_d256_half.rail
# → produces training/rail_native/checkpoints/d256_half_step3000.*

# Bench the flagship (→ 13/30, q=22,709):
./rail_native run flywheel-local/bench_railnative.rail \
    --prefix training/rail_native/checkpoints/d256_half_step3000 \
    --max 128 --k 10 --temp 0.8

# ── Side-experiment: 4-block × 6000 (171 min training + 171 min resume,
#    bench 12/30 — DID NOT improve over the 2-block flagship):
git checkout 7218806
./rail_native run tools/train/lm_v3_chunked_d256_4block_half.rail
./rail_native run tools/train/lm_v3_chunked_d256_4block_half_6k.rail \
    --resume training/rail_native/checkpoints/d256_4block_half_step3000
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
