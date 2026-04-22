# Scaling position — where the Rail-on-Rail transformer sits on the growth curve

**Date:** 2026-04-22.
**Context:** at eval 3.39 and 1/30 bench on a d=256 × 4-block × 3.4M-param model, we're solidly at the "proof-of-loop" milestone. This doc captures the scaling math for the path from here to a 1-2B-param Rail-native LM on a single M1 Ultra. It exists because a future session (or whoever picks up this codebase) benefits from having the RAM / param / kernel / corpus arithmetic in one place rather than re-deriving it.

## Current observed scaling

| config | params | peak RSS | wall/3k steps |
|---|---:|---:|---:|
| d=128 × 2-block half | ~450K | 512 MB | (not run at 3k) |
| d=256 × 2-block half | 1.74M | 580 MB | 84 min |
| d=256 × 4-block half | 3.44M | 606 MB | 171 min |

**Fixed overhead baseline** (regardless of model size): ~300 MB. Components: 512 MB Rail bump arena (only partially touched; ~150 MB actually paged in for our sizes), rail_native binary + libtensor_gpu.dylib (~30 MB mapped), Metal pipeline cache + command queues (~20 MB), corpus + input/output buffers (~50 MB), OS shared frameworks + dylib pages (~50 MB).

## Per-parameter memory in training mode

| slot | bytes per param | rationale |
|---|---:|---|
| weights (HalfTensor) | 2 | fp16 storage; one cast at init |
| Adam state (m, v in f64) | 16 | 2× f64 arrays per param, 8 bytes each |
| **total** | **18** | Adam state dominates at 8× weight memory |

**The Adam-ratio is the single biggest leverage point for scale.** Moving Adam state to bf16 (two f16 arrays = 4 bytes) drops per-param footprint from 18 to 6 bytes — a 3× capacity unlock at the same RSS budget.

## Per-block activation cache (held for backward, seq=1024)

Main contributors per block:
| tensor | size | precision |
|---|---:|---|
| attention score matrix | `seq² × 2` = 2.1 MB | half |
| h_gate / h_up / h_act / h_gate_silu | `4 × seq × d_ff × 2` | half |
| x / ln1 / q / k / v / attn_val / x_attn / ln2 | `8 × seq × d × 2` | half |
| h_gate_sig (SwiGLU's gate-sigmoid output) | `seq × d_ff × 8` | f64 (one of the few held f64 tensors) |
| rstd1 / rstd2 (RMSNorm inverse-stds) | `2 × seq × 8` | f64 |

Approx. per-block: `2·seq² + 88·d·seq` bytes.

| d | per-block cache | notes |
|---:|---:|---|
| 256 | ~25 MB | current |
| 512 | ~47 MB | 2× |
| 1024 | ~92 MB | 4× |
| 2048 | ~182 MB | 8× |
| 4096 | ~366 MB | 16× |

## Projected configs at increasing RSS budgets

Using weights + Adam + n_blocks × cache + 300 MB baseline, with 13·d² ≈ params/block:

| config | params | weights | adam | cache (total) | est. peak RSS |
|---|---:|---:|---:|---:|---:|
| d=256 × 4-block (shipped) | 3.4M | 7 MB | 55 MB | 100 MB | 606 MB (measured) |
| d=512 × 8-block | ~28M | 56 MB | 450 MB | 380 MB | ~1.2 GB |
| d=1024 × 12-block | ~164M | 330 MB | 2.6 GB | 1.1 GB | ~4 GB |
| d=2048 × 16-block | ~830M | 1.7 GB | 13 GB | 2.9 GB | ~18 GB |
| d=2560 × 20-block | ~1.7B | 3.4 GB | 27 GB | 4.5 GB | ~35 GB |
| **d=3072 × 16-block** | **~2.0B** | 4.0 GB | 31 GB | 4.3 GB | **~40 GB** |
| d=3584 × 20-block | ~3.3B | 6.6 GB | 53 GB | 6.1 GB | ~66 GB |
| d=4096 × 24-block | ~5.0B | 10 GB | 80 GB | 8.8 GB | ~99 GB |

**The Studio's comfortable ceiling: ~2B parameters at ~40-45 GB RSS.** This is GPT-2 XL scale (1.5B params, the largest open model of 2019). The 128 GB unified memory accommodates this with headroom for the OS, intermediate tools, and IDE work. Going past ~2B hits 50%+ memory pressure which degrades Metal command-buffer scheduling.

## What needs to ship before those configs become practical

### Arena bump (~30 min)

Rail's bump allocator is hardcoded to 512 MB in `tools/compile.rail`:
```
.quad _rail_heap + 536870912
```
(see `data_section_asm`, line ~3475). Allocations past 512 MB fall back to malloc, which works but loses arena_reset speed — bad for training's hot path. Fix: bump to 4 GB or 8 GB (the zerofill grows to match; no runtime cost for unused memory). One constant edit + self-compile + test suite run to verify fixed point.

### Checkpoint resumption CLI (shipped this session)

`load_half_model_into` + `load_adam_states_into` + `meta_step` are already in `stdlib/checkpoint.rail` (Session X). Wiring them into the training file's `main` is ~20 lines (now in `tools/train/lm_v3_chunked_d256_4block_half_6k.rail`, commit pending).

Unlocks multi-day training runs. A 2B-param training at d=3072 × 16-block × 30K steps at ~20 s/step would be ~7 days. Without resumption, one machine crash = restart from step 0. Critical for anything past ~half-a-day of training.

### bf16 / fp16 Adam state (~2-3 days)

Largest memory unlock. The design:
- Replace `AdamState m v step_arr` with `HalfAdamState m_half v_half step_arr`.
- Keep a rolling f32 scale factor per tensor to avoid fp16 underflow in m/v accumulation.
- Modify `adam_update_raw` to cast m/v to f32 at read, compute in f32, cast back to half at write.

Saves 12 bytes/param. At 2B params: **saves 24 GB** — the difference between "fits comfortably" and "at capacity" on the Studio.

Risk: fp16 Adam has known drift issues. Mitigations: bf16 instead of fp16 (wider exponent, narrower mantissa — better for gradient accumulation), or hybrid (m in fp16, v in f32). Need empirical validation at d=512 scale before committing to 2B.

### Gradient checkpointing (~1 week)

Current design caches 12 tensors per block through backward. At d=2048 × 16 blocks, cache alone is ~3 GB. Gradient checkpointing drops all cache, re-runs forward during backward — trades ~30-40% extra compute for ~60% cache reduction.

Implementation:
- `m_block_fwd_nocache` variant that returns only x_out, no cache.
- `m_block_bwd` needs to accept (x_in, w_block) and re-run forward internally before running backward.
- Training loop uses checkpointed version; inference uses existing nocache path.

Payoff: d=3072 × 16 blocks fits in ~25 GB instead of ~40 GB, opening room for longer seq or larger d.

### BPE tokenization (~1 week)

The repo has `tools/train/bpe_rail.rail` as untracked WIP. Character-level at V=130 is a 5-10× data disadvantage vs subword tokenization:
- Char-level: each token = 1 char, ~4:1 expansion over byte stream.
- BPE: typical tokens = 3-4 chars, ~1:1 with bytes.
- Same training budget (2048 seq × 30K steps) teaches 3-4× more "content" at BPE.

More importantly, BPE tokens carry semantic units (`fact`, `match`, `| Some x`) that char-level has to learn from scratch. Empirically, BPE cuts eval perplexity by ~30% at the same model size on the same raw data.

### Kernel fusion (~2-3 weeks)

Each Metal kernel dispatch carries ~50µs latency. At d=3072 × 16 blocks × 9 matmuls/block = 144 matmul dispatches/step. Dispatches alone: 7.2 ms/step, dwarfed by matmul compute at this size but becomes dominant at d≤512.

Two optimizations:
- **RMSNorm + matmul fusion** — combine the RMSNorm kernel with the following matmul's "write result into x" step, eliminate one dispatch and one full tensor read per op.
- **Flash-attention style** — fuse attention score + softmax + V-multiply into one kernel that streams through seq² / tile-size tiles without materializing the full score matrix.

Payoff: 2-3× training throughput at d ≥ 1024. At d=3072 × 16-block × 30K steps, cuts wall from ~7 days to ~2-3 days.

## The corpus bottleneck

Chinchilla scaling (DeepMind 2022): a K-param model is optimally trained on ~20K tokens. For a 2B model: **40B tokens**.

At 130-char vocab char-level:
- 40B tokens = 40B characters = **40 GB corpus**.

All publicly available Rail code worldwide: ~10 MB. **We are 4000× short.**

Two paths to close the gap:

### Path A — Self-training flywheel

The premise that gives Rail its unique scaling argument. Skeleton exists: `tools/train/self_train.rail` has `harvest_snapshot`, `harvest_rollback`, `harvest_ab_gate`. The loop:
1. LLM generates Rail.
2. Rail compiler (self-hosted) grades: compile-pass harvested.
3. New passes join the training corpus.
4. Periodically retrain.
5. `harvest_ab_gate` compares retrained model's bench score against the prior checkpoint; rolls back if worse.

**Empirically unproven.** A <1/30 model can't bootstrap anything — its output is near-zero compile-pass. The flywheel only makes sense after the model reliably produces compile-passes (targets ≥5/30 to ≥10/30 baseline). Getting there needs Path A to produce ~1 MB of harvested Rail across multiple quality gates → retrain → grade cycle. That's the 3-4 month story.

### Path B — Transfer learning

Pre-train on ~20 GB of general code (Python, C, Haskell, OCaml) to teach "program" as a concept, then fine-tune on Rail. Breaks the self-hosting purity claim (training data isn't self-generated), but most realistic path to a useful Rail-writer.

Risk: loses the "Rail-on-Rail" defensibility that is the entire project's unique claim.

### Path C — Synthetic augmentation

Grammar-based synthesis of valid Rail programs from an AST grammar. Not self-referentially generated by the model, so no quality cap. 10 MB of Rail source can generate ~1 GB of grammatically-valid variants via random AST sampling. Quality is lower (the grammar doesn't produce semantically meaningful programs) but volume helps for early training where pattern shape matters more than content.

## What's already on the positive side of the ledger

1. **Right architecture.** Llama/Mistral shape. No refactor needed as we scale.
2. **HalfTensor infrastructure complete.** ADT, 5 kernels, pack/unpack, matmul_half. Scales to arbitrary `d`.
3. **Generic N-block infer harness.** Handles 2, 4, 16, 64 blocks via `(n_weights-2)/9`. No code change to bench larger models.
4. **Checkpoint save/load shipped.** Format-agnostic to weight count. Bench pipeline already ingests our format.
5. **Compile-verified training.** The single claim no other language's small-LM project can make; scales with model size (the claim is about the substrate, not the model).
6. **Self-training primitives exist.** Need wiring, not invention.

## The honest scaling narrative

We are **at step 1 of a 10-step scale-up**. Step 1 (this session, Session 4+5+6) is "prove the loop works at minimal scale." The loop works. Bench score is low but that's a scale problem, not a loop problem.

Step 2-4 are engineering (arena, resume, bf16 Adam, gradient checkpoint, BPE, kernel fusion) — adds up to ~4-6 weeks of focused work. Doable by one person. The skeleton and architecture are already in place; these are feature adds, not rewrites.

Step 5-8 are capacity (160M → 500M → 1B → 2B). Each 3-5× increase in size. Each needs an overnight-to-multi-day training run with its own data + hyperparameter validation.

Step 9-10 are corpus growth via flywheel (the unproven step). Starts at ~10 MB stdlib, targets 10+ GB of high-quality auto-harvested Rail.

**Realistic 12-month roadmap from today:**
- **Month 1:** arena bump + resume CLI (done/shipping) + bf16 Adam → train d=512 × 8-block.
- **Month 2-3:** gradient checkpointing + BPE → train d=1024 × 12-block (~160M params, first "actually useful" Rail LM).
- **Month 4-5:** kernel fusion + optimization sweep → retrain at 160M with 2-3× throughput.
- **Month 6-8:** flywheel closed-loop runs weekly; corpus grows 500 KB → 50 MB. Train d=2048 × 16-block (~830M).
- **Month 9-12:** d=3072 × 16-block at ~2B params. Multi-day training. Flagship Rail-on-Rail.

**The 2026-04-27 deadline is about Step 1.** Session 4+5+6 are the demonstration-of-concept. The scale-up story is what comes after, and this doc exists to make sure whoever picks it up has a roadmap rather than a starting point.

## Specific numbers to validate at each scale jump

| at this scale | the numbers that validate it |
|---|---|
| d=512 × 8-block (~28M) | eval < 2.0 on held-out stdlib; bench ≥3/30; peak RSS < 1.5 GB |
| d=1024 × 12-block (~164M) | eval < 1.5; bench ≥8/30; peak RSS < 5 GB |
| d=2048 × 16-block (~830M) | eval < 1.2; bench ≥15/30; peak RSS < 20 GB; wall < 24h per 10K steps |
| d=3072 × 16-block (~2B) | eval < 1.0; bench ≥20/30; peak RSS < 50 GB; wall < 72h per 10K steps |

Anything not meeting these thresholds at its scale = something upstream (corpus, init, hyperparams) needs work before the next scale-up.

---

The ceiling isn't compute or RAM. It's corpus. Everything else is engineering.
