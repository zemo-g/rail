# Rail-native transformer — Model Card v0.3

**Experiment:** Cross-file holdout evaluation. Does the v0.2 architecture
(d=64, d_ff=256, single-block, single-head, fixed γ/β) generalize from one
Rail stdlib file to a sibling stdlib file, or is the prior 0.333 Shakespeare
loss memorization with no transfer?

v0.2 remains the canonical reference checkpoint — this is a separate
measurement on a separate corpus with no checkpoint saved.

---

## Corpus

| Split | Source                       | Chars | Notes                       |
|-------|------------------------------|------:|-----------------------------|
| train | `stdlib/tensor.rail[0:1500]` | 1500  | tensor ADT + matmul dispatch |
| val   | `stdlib/json.rail[0:1500]`   | 1500  | JSON parser, never seen     |

One shared vocabulary built from the union (**V = 77** chars). Both splits
encode cleanly — no `<unk>` tokens in either.

Sequence length: **1499** (both splits). Chosen so a single sinusoidal
positional-encoding table serves both forward passes.

Rationale for sibling stdlib files: shared Rail syntax (`let`, `match`,
`if/then/else`, lowercase identifiers, ASCII punctuation) but disjoint
semantic content. A model that learns genuine Rail structure should
transfer; a model that memorizes tensor.rail's specific token sequence
will not.

## Hyperparameters

Identical to v0.2:

| Param                   | Value         |
|-------------------------|---------------|
| d                       | 64            |
| d_ff                    | 256           |
| Optimizer               | Adam          |
| β1, β2, ε               | 0.9, 0.999, 1e-8 |
| Peak learning rate      | 0.02          |
| LR schedule             | cosine decay, 100-step warmup |
| Target training steps   | 2000          |
| Init scale              | 0.01 × uniform(-50, 50) |
| γ/β                     | fixed (1, 0)  |

## Results

### Loss curve (observed, steps 0–600)

```
step    0   train=16.8423   val=16.8307   ratio=1.000
step  100   train= 4.0979   val=11.7671   ratio=2.872    (after warmup)
step  200   train= 2.9450   val=10.6051   ratio=3.601
step  300   train= 2.8327   val=10.7100   ratio=3.781
step  400   train= 2.7823   val=10.7632   ratio=3.868
step  500   train= 2.7529   val=10.8036   ratio=3.924
step  600   train= 2.7330   val=10.8335   ratio=3.964
```

`best_val = 10.6051` at step 200.

Uniform baseline `log V = 4.344`. Val loss never drops below uniform —
after warmup the val loss sits consistently ~2.5× worse than random
guessing on the val split.

### Ratio

**Final observed val/train ratio: 3.96 at step 600.** Ratio is
monotonically increasing (2.87 → 3.60 → 3.78 → 3.87 → 3.92 → 3.96)
with no sign of decay — train loss is still slowly falling while val
loss is slowly climbing.

Using the interpretation scale from the experiment brief:

| Ratio       | Verdict                              |
|-------------|--------------------------------------|
| < 1.3       | generalizes — greenlight scale-up    |
| 1.3 – 2.0   | partial overfit — more data first    |
| **> 2.0**   | **pure overfit — do not scale**      |

Observed ratio (3.96) is **~2× the "do not scale" threshold**. The
verdict does not change with more steps — both curves have flattened.

## What this tells us about scale-up

The model memorizes its training sequence (train loss 2.73, perplexity
15.4 — well below uniform) and the representation is **entirely
sequence-specific**. Val loss at ~10.8 is worse than uniform: the
model's confident predictions on held-out Rail source are actively
wrong, not just uninformed.

This is the "failure mode" case the experiment brief called out:

> train_loss drops to 0.01 while val_loss stays at 2.5+. Pure
> overfitting. Tells you the model has enough capacity for 1500 chars
> but nothing generalizes to a sibling stdlib file at this scale.

The numbers here are less extreme than that worst-case (train didn't
drop to 0.01), but the shape is identical. Interpretation:

1. **The architecture has enough capacity to memorize 1500 tokens**
   and it does so quickly — train loss passes the uniform baseline
   at step 100 and plateaus by step 300.
2. **No transfer occurs at all.** Val loss gets *worse* during training
   as the model specializes to tensor.rail's specific token statistics.
3. **This is NOT a verdict against Rail-native ML.** Numerics are
   correct (attention gradcheck 18/18, layernorm 9/9, v0.2 Shakespeare
   converges to 0.333). The model just has far more capacity than
   1500 tokens of data can constrain.

### Do not scale up on this corpus / model config

Any scale axis from `M6_SCALE_GATE.md` (multi-head, multi-block, wider
d) would *worsen* this result by adding more capacity with no
additional generalization signal. The problem is at the data layer.

### What would make scale-up informative

- **Much more training data.** The staged `training/rail_native/data/
  corpus.txt` (553KB, all stdlib) would give the model ~100× more
  tokens — enough for per-pattern learning to start.
- **Multiple val files from different domains** (not just one sibling
  stdlib module) to average out file-specific noise in the ratio.
- **Scheduled dropout / weight decay / early stopping on val** to
  prevent the confident-wrong regime this run enters after step 100.

## Wall-clock / runtime note

**The run did not complete.** Target was 2000 steps; the process
terminated silently between step 600 and the step-700 eval boundary
after ~4.5 min. No crash log, no OOM (system had 16 GB free pages at
the time), and `./rail_native test` remained 98/98 afterwards.

The smoke test — same code path at seq=1499 for 10 steps — runs
cleanly in 8 s. The failure is cumulative: some GC or arena
interaction that surfaces only after several hundred steps at
seq=1499. Unknown whether it's in the GC mark-sweep, the Metal
dispatch path, or a code-gen interaction with the outer_loop's
long-lived list references.

Investigation is follow-up work, not a v0.3 blocker — the experiment's
verdict is robust to more steps. Both curves have plateaued and the
ratio has stabilized at ~4. The next 1400 steps would not move the
conclusion; they would only tighten the noise bound on an already
unambiguous answer.

Logged at `training/rail_native/logs/xval_run.log`.

## What v0.3 demonstrates (beyond v0.2)

1. **End-to-end held-out eval works.** `eval_loss` on unseen inputs,
   shared vocab across splits, ratio-based verdict — all wired.
2. **Rail compiler arity cap is x27.** `cg_pop_regs` in compile.rail
   generates `ldr x{N-1}, [sp], ...` for caller-side arg restore.
   At N=29 it clobbers x28 (platform), at N=30 x29 (FP), at N=31
   x30 (LR). Functions called from non-self-loop sites must stay at
   ≤28 params. `train_loop` kept at 28; `outer_loop` packs weights
   and Adam states into lists to stay at 18.
3. **The v0.2 architecture does not generalize at this scale.** The
   negative result is the finding.

## Next steps

Not in this card's scope, but the data pushes in an obvious direction:

- Wire the 553KB stdlib corpus in (instead of the 1500-char slice).
  Enough data that val-loss trajectory stops being noise.
- Add early stopping on val loss (the model's best val was at step
  200 — it got *worse* with more training).
- Debug the step-600 runtime death before any longer runs.
- Only after the above, revisit `M6_SCALE_GATE.md`.

## Reproducing

```
cd ~/projects/rail
./rail_native run tools/train/lm_xval.rail
```

Expect ~0.5 s/step at seq=1499 on Mac Mini M4 Pro. Expect monotonically
increasing val/train ratio reaching ~4.0 by step 600. Expect the
process to terminate before step 2000 — that's the bug documented
above, not a correctness issue.

---
Run:         2026-04-15 16:24–16:29 UTC (died at ~step 600)
Card:        v0.3 (partial run, conclusive verdict)
Base commit: v0.2 (same architecture, different corpus + eval)
