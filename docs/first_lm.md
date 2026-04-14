# First LM trained in Rail — v2.3.0 proof

Rail's v2.3 training stack — **Adam optimizer + cosine LR schedule + grad
clipping + checkpoint save/load + char-level tokenizer** — composes end
to end on a real language-model objective.

## Architecture

Char-level bigram MLP, trained on a 383-character Shakespeare excerpt.

```
char_id  →  one_hot(V=32)  →  Linear(V→32)  →  ReLU  →  Linear(32→V)  →  softmax  →  next_char
```

Vocab built directly from the corpus via `build_vocab` in
`stdlib/tokenizer.rail`.  Weights initialised deterministically from a
pattern hash; no randomness.  Metal GPU dispatches every matmul, relu,
and softmax.

## Training setup

| Knob | Value |
|---|---|
| Corpus | 383 chars (`tools/train/lm_shakespeare.rail:corpus`) |
| Vocab size V | 32 |
| Samples N | 382 (one bigram window per adjacent char pair) |
| Hidden H | 32 |
| Optimizer | Adam (β1=0.9, β2=0.999, ε=1e-8) — `stdlib/optim.rail` |
| LR schedule | `cosine_decay` with warmup=20, peak_lr=0.05 |
| Steps | 200 |
| Backward | Manual (cross-entropy+softmax fused, ReLU backward, matmul↔transpose) |

## Loss curve

```
step 0    lr=0.000   loss=15.02
step 20   lr=0.050   loss=5.71       ← end of warmup, peak LR
step 40   lr=0.0485  loss=2.77
step 60   lr=0.0442  loss=2.32
step 80   lr=0.0375  loss=2.20
step 100  lr=0.0293  loss=2.16
step 120  lr=0.0207  loss=2.13
step 140  lr=0.0125  loss=2.11
step 160  lr=0.0058  loss=2.10
step 180  lr=0.0015  loss=2.10
final              loss=2.097
uniform baseline    log(V) = 3.466
```

Final loss 2.10 vs uniform 3.47 means the model has picked up real
bigram statistics — about 0.64 nats of information per character above
the uniform prior.

## Checkpoint round-trip

Save → reload → re-evaluate produces **bit-identical loss**
(`2.09735897476822` in both cases).  Four tensors persisted as
`/tmp/rail_lm_ckpt.{manifest,0.f32,1.f32,2.f32,3.f32}`.

## Run it

```bash
cd ~/projects/rail
./rail_native run tools/train/lm_shakespeare.rail
```

## What this proves

1. `stdlib/optim.rail::adam_update_raw` drives every Adam step on GPU —
   one fused Metal dispatch per parameter tensor per step.
2. `cosine_decay` integrates cleanly with a training loop; linear
   warmup → half-cosine decay to zero with no knobs outside of
   `(warmup, max_steps, base_lr)`.
3. `stdlib/tokenizer.rail` produces round-trip-exact encode/decode on
   the corpus and the training loop consumes its integer IDs directly.
4. `stdlib/checkpoint.rail` serializes a list of Tensors as a text
   manifest + per-tensor f32 blobs, reloads them into fresh tensors
   whose forward pass matches the original to machine precision.

## What this does NOT prove yet (gated on v2.3+)

- **Sampling / generation** — see `tools/train/lm_generate.rail`
  (task 5 in the v2.3 queue) for argmax / top-k / temperature.
- **Long-context perplexity** — context length here is 1.  A sliding
  window variant on this same stack would be ~10 lines; left as a
  v2.3.1 cleanup.

## v2.4 follow-up — single-head causal transformer

`tools/train/lm_transformer.rail` extends this stack to a real
transformer:  embedding → sinusoidal PE → causal self-attention →
output projection.  Attention backward composes from existing
primitives (matmul, transpose, `tgl_softmax_backward_f64`,
`tensor_scale`) — **no new kernels required**.  Embedding gradient is
just `X^T @ dX_pe` because the embedding is implemented as a one-hot
matmul, so the matmul backward already does the scatter-add for free.

Math is verified by `tools/train/attention_gradcheck.rail` —
finite-difference gradcheck on dQ, dK, dV passes 18/18 to f32
tolerance.

Trains end to end on the same 383-char Shakespeare excerpt:

| Run | Final loss | vs uniform (3.47) | vs bigram (2.10) |
|---|---|---|---|
| 300 steps, d=16, no LN, no residual | **2.62** | beats | does not beat |

The transformer beats the uniform baseline but plateaus above the
bigram baseline.  Closing that gap is gated on v2.5 work — layernorm
forward+backward, residual connection (verified hurts without LN), and
an FFN block.  Scope held to "single-head attention works end to end"
for v2.4.
