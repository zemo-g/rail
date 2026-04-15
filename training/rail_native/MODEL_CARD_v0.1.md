# Rail-native transformer — Model Card v0.1

First artifact from the Fork B pipeline. Rail compiler + `stdlib/autograd.rail`
+ `stdlib/tensor.rail` Metal dispatch training a transformer from scratch
to near-memorization on a 383-char Shakespeare excerpt.

## Architecture

Single-block pre-norm transformer. Single-head attention. Fixed
LayerNorm γ=1, β=0.

- Embedding dim (d):       **64**
- Feed-forward dim (d_ff): **256**
- Vocab size (V):          27 characters (Shakespeare excerpt)
- Sequence length:         382
- Attention heads:         1
- Blocks:                  1
- Total trainable params:  ~6k (V·d + 4·d² + 2·d·d_ff + d·V)

## Corpus

`corpus 0` inline in `tools/train/lm_transformer.rail` — 383 chars of
"To be or not to be, that is the question..." Shakespeare excerpt.
No held-out split (all data is training data).

Pivot to `training/rail_native/data/corpus.txt` (553KB Rail stdlib)
queued in the next workflow.

## Hyperparameters

| Param                   | Value        |
|-------------------------|--------------|
| Optimizer               | Adam         |
| β1, β2, ε               | 0.9, 0.999, 1e-8 |
| Peak learning rate      | 0.02         |
| LR schedule             | cosine decay with 100-step warmup |
| Training steps          | 2000         |
| Init scale              | 0.01 × uniform(-50, 50) → ~N(0, 0.29²) |
| Weight decay            | none         |
| Gradient clipping       | none         |

`init_weight` uses a deterministic hash, not a PRNG (seed-indexed
scatter). Reproducible across runs.

## Training dynamics

Arena mark/reset at the top of each training step — intermediate
tensors from forward/backward don't accumulate across iterations.

### Loss curve (selected)

```
step    0   loss=15.24   lr=0
step  100   loss= 3.31   lr=0.020       (after warmup)
step  200   loss= 1.96                  (already beats v2.4 attn-only baseline 2.62)
step  400   loss= 1.37
step  600   loss= 0.96
step  800   loss= 0.68
step 1000   loss= 0.53
step 1200   loss= 0.45
step 1400   loss= 0.38
step 1600   loss= 0.35
step 1800   loss= 0.34
step 1990   loss= 0.333
final       loss= 0.333
```

Perplexity at final ≈ 1.39 — the model is near-memorization of the
training corpus.

### Baselines (same corpus)

| Baseline                                | Loss  |
|-----------------------------------------|------:|
| Uniform over vocab (log V)              | ~3.30 |
| v2.3 bigram baseline                    |  2.10 |
| v2.4 attention-only (no FFN, no LN)     |  2.62 |
| v2.5 pre-norm (d=16, 2000 steps)        |  2.10 |
| **v0.1 (d=64, 2000 steps, this card)**  | **0.333** |

d=64 beats the prior d=16 ship point on the same data by 6.3× less
loss and converged in the same number of steps.

## Wall-clock

- Wall time:  ~20 minutes on Mac Mini M4 Pro (24GB)
- CPU time:   ~10 minutes (~50% utilization — GPU-bound)
- Memory:     peaked at 58% (13.8GB) before GC; floor after sweep
              ~13%. Arena + conservative mark-sweep GC working.

## Hardware / Metal dispatch

All matmuls route through `stdlib/tensor.rail:gpu_matmul_dispatch`
→ `tgl_matmul_f64` in `tools/metal/libtensor_gpu.dylib` (Metal
compute kernels). At d=64, matmul sizes are:

- Attention Q/K/V projections: (382, 64) @ (64, 64)
- Attention output projection: (382, 64) @ (64, 64)
- Output head:                 (382, 64) @ (64, 27)
- FFN layer 1:                 (382, 64) @ (64, 256)
- FFN layer 2:                 (382, 256) @ (256, 64)

These sizes cross the CPU/Metal crossover (~128×128 per
`tensord_scale_bench`), so Metal dispatch earns its keep.

## Limitations

1. **Memorization, not generalization.** No held-out split; loss 0.333
   means the model learned the specific 383-char corpus. Meaningful
   only as a correctness signal (full-stack Rail ML works end-to-end).
2. **No checkpoint persistence.** Weights are discarded at process
   exit. `stdlib/checkpoint.rail` exists but isn't wired in yet.
3. **No sample generation.** Forward pass runs only on the training
   input. Need an inference/autoregressive-sampling code path.
4. **Single block, single head.** v2.12 shipped multi-head but it's
   not exercised in `lm_transformer.rail`.
5. **LayerNorm γ/β fixed.** `ln_g` and `ln_b` aren't trained.
6. **Char-level tokenization.** No BPE.

## What this card demonstrates

The Rail compiler + autograd + Metal dispatch can train a real
transformer to memorization on a real dataset. All numerics are
correct (attention gradcheck 18/18, layernorm gradcheck 9/9).
Metal is on the hot path. Training is deterministic and
reproducible.

This is the "Rail runs on Rail" endgame — nothing external
orchestrated this run. No Python. No PyTorch. No MLX.

## Reproducing

```
cd ~/projects/rail
./rail_native run tools/train/lm_transformer.rail
```

Expect loss 0.333 ± 0.01 at step 1990. Expect 15-25 min wall time.

## Next milestones

1. Sample generation + greedy completion of 40 tokens
2. Pivot corpus to Rail stdlib (553KB, already staged)
3. Checkpoint save/resume
4. Eval split + val loss
5. 24h launchd soak

See `FORK_B_PLAN.md` for the broader plan.

---
Trained:    2026-04-15
Commit:     0c0a65c (v2.21.0)
Card version: v0.1
