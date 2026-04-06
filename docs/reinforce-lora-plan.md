# REINFORCE on Gemma LoRA — Scoping Plan

**Status:** SCOPING (no code yet). 2026-04-06.

The bet: replace `flywheel/train_cuda.py`'s cross-entropy LoRA fine-tune
with REINFORCE on compile-pass reward. The same training signal that
drove `s0_pcfg`'s 20-int PCFG from 46% → 92% strict pass rate, applied
to the existing 4B-param LLM that currently sits at 14/30 (46%) on the
README benchmark.

If the bet pays off, the bench could move 14/30 → 20+ on the same data.
If it doesn't, we learn something about why mimicry-vs-truth-seeking
breaks at LLM scale even with a perfect oracle.

This is a half-day spike. Razer-side. Don't start it without reading
this doc first.

---

## Why this bet

Today's session shipped `s0_pcfg` and proved one thing very crisply:

> A 20-rule PCFG with REINFORCE on compile-pass reward reaches 92%
> strict compile rate in 30 ticks, while a 7.9M-param transformer
> trained from scratch on 3.5M tokens via cross-entropy hits 0/30.
> Same compiler oracle. Different training signal. 1000× compute
> ratio. Infinite quality ratio.

The Gemma flywheel currently uses cross-entropy on harvested code. Same
mimicry objective that failed for the rustane experiments. The LoRA is
training to *look like* the harvested programs, not to *write programs
that compile*.

What's different at LoRA scale:
- The base model is already trained on millions of programs from many
  languages. It already knows "programs end with closing braces" in a
  general sense.
- The LoRA is small (4B base, ~50M LoRA params). Capacity is fine.
- The training data is curated and verified.
- **But the objective is still wrong.** Cross-entropy says "match the
  harvested distribution." It doesn't say "produce compilable programs."

So the bet is: keep everything else, change the loss function. Instead
of token-level cross-entropy on harvested code, do REINFORCE-style
policy gradient on the LoRA's output, with reward = compile pass.

---

## What "REINFORCE on Gemma LoRA" actually means

The math, briefly:

```
For each training step:
  1. Sample K programs from policy π_θ (the current LoRA model)
  2. For each program p_i:
     - Compute reward r_i ∈ {0, 1} (compile + run + no errors)
  3. Compute baseline b = mean(r_i)  -- variance reduction
  4. Compute gradient:
     ∇_θ J(θ) = Σ_i (r_i - b) · ∇_θ log π_θ(p_i)
  5. Apply gradient: θ ← θ + lr · ∇_θ J(θ)
```

In code: instead of `cross_entropy(model_logits, harvested_tokens).backward()`,
we do `(reward - baseline) * log_prob(generated_tokens).sum().backward()`.

For each sampled program, we already have the log-probabilities of every
token from the forward pass. Multiply by the per-program reward
(broadcast), sum, backprop. That's it. The rest of the LoRA training
infrastructure (Adam, LR schedule, gradient checkpointing) is unchanged.

The simplification I'm proposing: **REINFORCE, not PPO.** PPO has a
value network and clipping; both add complexity and memory. REINFORCE
is the simplest possible form: weighted log-prob gradient. Start there.
Add PPO only if REINFORCE-with-baseline shows promise but is too noisy.

---

## What needs to change

| File | Change |
|---|---|
| `flywheel/train_cuda.py` | Add `--reinforce` mode that uses policy-gradient loss instead of cross-entropy. Reuses the same model loading, LoRA wrapping, and Adam config. |
| **NEW** `flywheel/reward_fn.py` | Compile-and-run a generated program via subprocess to `rail_native run`, return 1.0/0.0. Same strict-mode logic as `tools/railml/eval_compile.py` (catch parse errors that exit 0). |
| **NEW** `flywheel/reinforce_loop.py` | Outer loop: load model → sample K programs at temperature T → compute rewards in parallel → compute log-probs → policy gradient update → repeat. |
| `flywheel/train_cuda.py` | Add a `--bench-after` flag that runs `flywheel/bench.rail` post-training and logs the score to `interventions.jsonl`. |
| `tools/train/run_training.sh` | Add a `REINFORCE_MODE=1` env var that switches the per-round path from harvest-based SFT to generate-based REINFORCE. Off by default. |
| **NEW** `flywheel/interventions.jsonl` events | `reinforce_step` (per gradient update), `reinforce_eval` (per bench run). |

The whole spike fits in ~300 lines of new Python plus ~50 lines of edits
to `train_cuda.py`. The Rail side doesn't change at all.

---

## Phases (small → big, abort early if anything looks wrong)

### Phase 0 — Read this doc (5 min)
You're doing it.

### Phase 1 — Razer environment check (15 min)
Before writing any code:
- SSH to Razer (`ssh Detro@100.109.63.37`)
- Verify `flywheel/train_cuda.py` still loads the 4B base model + the
  current adapter (`training/adapters_4b_v5_mlx/`)
- Verify `nvidia-smi` shows the 8 GB VRAM free
- Verify `pip list | grep -E "trl|peft|bitsandbytes"` (TRL is optional;
  we can do REINFORCE without it but it makes life easier)

**Abort if**: TRL is not installed and pip install fails. Falling back
to manual gradient code is doable but doubles the spike time.

### Phase 2 — Reward function in isolation (30 min)
Write `flywheel/reward_fn.py`:
```python
def compile_reward(program_text: str) -> float:
    """1.0 if rail_native run produces no error markers, else 0.0.
    Same strict-mode logic as tools/railml/eval_compile.py."""
    # write to /tmp/, subprocess to rail_native, scan stdout for errors
```
Test it on:
- 10 known-good Rail programs from `training/self_train/harvest.jsonl`
  (assistant content). Expect 10/10 reward = 1.0.
- 10 deliberately broken programs (truncated, missing brackets).
  Expect 10/10 reward = 0.0.

**Abort if**: the reward function is unreliable on the gold set. Don't
proceed until reward = 1.0 on every known-passing program. **The reward
function is the experiment.** Get this part right or nothing else works.

### Phase 3 — Generate-and-score sanity check (30 min)
Load the current LoRA-fine-tuned model. Generate 50 programs at T=0.7.
Score them with `compile_reward`. Print: pass count, mean reward, sample
of 3 passing + 3 failing programs.

Expected baseline based on Gemma's 14/30 bench: maybe 5-15 of 50 pass?
Anywhere in 10-30% range is fine — we just need *some* gradient signal.

**Abort if**:
- Pass rate is 0/50 → reward is too sparse for REINFORCE; need a denser
  signal (curriculum, partial credit, prefix rewards)
- Pass rate is 50/50 → already maxed out; no room for REINFORCE to add
  value; the bench is the wrong metric

### Phase 4 — One REINFORCE step on the existing LoRA (1 hr)
The actual experiment. Keep the existing LoRA frozen as a reference.
Load it again as the trainable policy. Run ONE REINFORCE update:
1. Sample 32 programs at T=0.7
2. Compute rewards (32 numbers in {0, 1})
3. Compute mean reward as baseline
4. Compute log-prob of each generated sequence
5. Loss = -mean((reward - baseline) * log_prob)
6. `loss.backward()` then `optimizer.step()`
7. Re-sample 32 programs, score, log mean reward

If mean reward goes UP after one step, the gradient direction is right.
If it goes down or stays flat, something is wrong (debugging branch).

**Abort if**: mean reward doesn't move (likely numerical issue, baseline
wrong, or LoRA isn't actually receiving gradient).

### Phase 5 — 100 REINFORCE steps + bench (2 hrs)
Now do it for real. Save the LoRA every 10 steps. Bench the best
checkpoint against the existing 14/30 baseline using the existing
`flywheel/bench.rail`. Log the final score to `interventions.jsonl` as
a `reinforce_eval` event.

**Success criterion**: bench ≥ 16/30. Anything above 14/30 is a positive
signal that REINFORCE works at LLM scale on this task.
**Failure criterion**: bench ≤ 12/30. The reference LoRA is being
damaged by the gradient updates (too high lr, too noisy reward).

### Phase 6 — Decision point (15 min)
Three outcomes:

**Win (≥16/30)**: schedule a longer run (1000 steps), document the
hyperparameters, write up the methodology. Becomes the new flywheel
training mode.

**Tie (13-15/30)**: not conclusively better. Try one more iteration with
a different lr or a denser reward (e.g., partial credit for "syntax
clean but runtime error"). If still inconclusive, parking the
experiment is acceptable — we tried.

**Loss (≤12/30)**: REINFORCE-on-LLM doesn't work in this setup. The
likely reasons (rank ordered):
1. Reward is too sparse (binary at program level, not token level)
2. Sample variance dominates the gradient signal
3. LoRA capacity isn't where the bottleneck is — base model
   doesn't have enough Rail-specific knowledge to be steerable
4. Bench is a bad proxy for compile pass rate (wrong metric)

In all three cases, **write up the result in `docs/reinforce-lora-result.md`**.
This is research; the negative result is also valuable.

---

## Risks + mitigations

### Risk 1: Razer 8 GB VRAM is too tight for REINFORCE
PPO needs ~3× the memory of SFT (policy + value + reference). REINFORCE
needs ~2× (policy + reference). If 4B base + LoRA already uses 6 GB for
SFT, REINFORCE might OOM.

**Mitigation**: use the same QLoRA 4-bit quantization as the existing
`train_cuda.py`. Generate at batch=1, accumulate gradients over 32
samples. Free intermediate activations aggressively. If still OOM, drop
to a 1.5B model first to validate the method, then scale back to 4B.

### Risk 2: Compile reward is too sparse for the gradient
Binary reward at the program level means most steps see 0/32 or
maybe 1/32 successes. Gradient direction is dominated by noise.

**Mitigation**:
- Start at T=0.5 (more peaked, higher pass rate, lower variance)
- Use the **harvested data as a warm start** — the policy already
  produces some passing programs from cross-entropy training
- Add a **shaped reward**: 0.5 for "compiles but runtime crash", 1.0
  for "compiles + runs". The classification logic from
  `self_train.rail`'s `verify` function already exists (lines 109-129).

### Risk 3: TRL might not support QLoRA + REINFORCE out of the box
Most TRL examples use PPO + LoRA but not QLoRA (4-bit). Mixing 4-bit
weights with policy gradient might break.

**Mitigation**: write the gradient code by hand. PyTorch's autograd
handles this fine. The hard part is the per-token log-prob extraction,
which is just `model(input_ids).logits.log_softmax(-1).gather(...)`.
~50 lines without any TRL dependency.

### Risk 4: The reward function false-positives
`rail_native` exits 0 on parse errors. Already burned 1/30 → 0/30 in
the rustane eval pipeline today. The strict-mode fix is in
`tools/railml/eval_compile.py` lines 55-79. Mirror it exactly in
`flywheel/reward_fn.py`. **Test on known-bad inputs before training.**

### Risk 5: The parallel session shipping commits to self_train.rail
Sessions are actively committing to self_train infrastructure. If this
spike modifies `self_train.rail`, race risk.

**Mitigation**: don't touch `self_train.rail` at all. Add the REINFORCE
mode as a separate `flywheel/reinforce_loop.py` that calls `train_cuda.py`
with new flags. Wire it into `run_training.sh` only via a new env var
(`REINFORCE_MODE=1`) that's off by default.

---

## What we're NOT doing in this spike

- Training a new model from scratch (s0_pcfg already proves the principle
  at small scale)
- Replacing the existing flywheel (REINFORCE mode is opt-in)
- Touching the harvest pipeline (REINFORCE doesn't write to harvest;
  it's a separate training mode)
- PPO (start with REINFORCE; only escalate if REINFORCE works but is
  too noisy)
- Cross-language transfer (Rail only)
- Multi-GPU (Razer is single GPU)

---

## Estimates (honest)

| Phase | Time | Confidence |
|---|---|---|
| 0. Read this doc | 5 min | 100% |
| 1. Environment check | 15 min | 90% (Razer SSH sometimes flaky) |
| 2. Reward function | 30 min | 85% (might need to debug rail_native subprocess timing) |
| 3. Sanity check | 30 min | 70% (depends on Razer stability) |
| 4. One REINFORCE step | 1 hr | 60% (most likely to hit a numerical bug) |
| 5. 100 steps + bench | 2 hrs | 50% (could explode, could OOM) |
| 6. Decision + writeup | 15 min | 100% |
| **Total worst case** | **~5 hrs** | |
| **Total best case** | **~2 hrs** | |

The 50% confidence on Phase 5 is the real number. This is a research
spike, not engineering. **Expect to learn something either way.**

---

## What I'd want to see before starting

1. The Razer SSH session is alive (`ssh Detro@100.109.63.37 'nvidia-smi'`)
2. The current LoRA adapter still loads cleanly:
   `python3 flywheel/train_cuda.py --load-only`
3. The 14/30 baseline is still reproducible — run `flywheel/bench.rail`
   once and confirm we're at the same starting point as the README
4. Free `~/projects/rail` disk for new checkpoints (REINFORCE will
   want to save every 10 steps × 100 steps = 10 checkpoints × ~50 MB
   = ~500 MB)
5. The intervention ledger is up to date so we can compare before/after
   reinforce_eval events

---

## Open questions for whoever runs this

1. Should the reference policy (KL anchor) be frozen, or should it
   slowly track the trained policy? Frozen is simpler. Tracking gives
   PPO-like stability. Default to frozen.

2. Should we use the existing `self_train.rail`'s `verify` function for
   classification (syntax / type / linker / runtime / pass) and shape
   the reward accordingly, or just binary pass/fail? Shaped is better
   for variance but adds debugging surface. Default to binary; escalate
   to shaped only if Phase 4 fails.

3. Should the harvest pipeline ingest REINFORCE-improved programs as
   well? In principle yes — they're verified. In practice, run G6
   (s0_pcfg cross_feed) is already producing 60+ verified programs
   per round. Adding REINFORCE-generated ones is a noise issue, not a
   signal issue. Default to no.

4. What's the kill criterion if REINFORCE is making the model
   measurably worse? The bench dropping below 12/30 for two
   consecutive evals. Roll back to the pre-REINFORCE checkpoint and
   declare the spike a learn.

---

## Why this might actually work

The reason s0_pcfg's REINFORCE worked so dramatically (46% → 92% in
9 seconds): the reward was *reliable* (compiler is perfect), the
policy was *small* (20 weights), and the search space was *narrow*
(20 grammar rules).

At LLM scale, the reward is still reliable (same compiler), but the
policy is huge and the search space is essentially infinite. Direct
analogy is broken.

What's NOT broken: the **information content** of one compile pass /
fail signal is the same at any scale. The question is whether the
LLM's gradient can use that information without being drowned by the
8B-param search space.

The bet is yes — because the LoRA is small (50M params) and starts
from a model that already produces *some* passing programs. We're not
asking the model to learn to write programs from scratch. We're asking
it to *increase the probability mass on the programs it already
sometimes generates that compile*. That's a small move, not a big one.
A few thousand REINFORCE updates should suffice.

If that's right, the bench moves measurably in Phase 5. If it's wrong,
the bench stays flat or drops, and we learn that LLM-scale RL on
binary compile rewards needs a denser signal.

Either way, this is the most leveraged single experiment available
right now.

---

## Owner

Whoever picks this up next. Don't start without reading the whole
doc. Don't push REINFORCE checkpoints over the existing
`training/adapters_4b_v5_mlx/` — save them to
`training/adapters_4b_reinforce_<date>/` to keep the rollback path
clean.

The s0_pcfg side of the same hypothesis is shipping continuously via
`run_training.sh` (G5 in 34a19d9). That side is small-scale and proven.
This doc is the other side — the same idea, scaled up to where the
real benchmark lives.
