# Neural MHD surrogate — rollout baseline

**Harness:** `tools/plasma/neural_mhd_rollout.rail`
**Model:** `tools/plasma/neural_mhd_lib.rail` — MLP 30 -> 32 (ReLU) -> 6, 1190 params
**Truth:** 32x32 Orszag-Tang, Lax-Friedrichs, gamma = 5/3
**Measured:** 2026-08-30. Runs in ~3.5 s (trains, then rolls out).

## What is measured

The surrogate is fed **its own output** each step and compared against the
solver. Relative L2 per field and aggregate; the aggregate is one ratio over
all six fields, not a mean of six ratios, because a mean lets a well-predicted
field mask a collapsed one.

## Baseline

| step | aggregate rel-L2 | total mass drift |
|---|---|---|
| 1 | **0.4934** | 1.55% |
| 5 | 0.4777 | 1.28% |
| 10 | 0.4588 | 1.01% |
| 20 | 0.4226 | 0.62% |
| 40 | 0.3635 | **0.23%** |

Per-field at step 1:

| rho | mx | my | bx | by | energy |
|---|---|---|---|---|---|
| 0.133 | **1.011** | **1.000** | **1.011** | **1.000** | 0.052 |

Aggregate crosses 1%, 5% and 10% at **step 1**. There is no tracking horizon.

## The verdict

**Single-step aggregate error is 49.3%.** The four signed fields (mx, my, bx,
by) sit at rel-L2 ~ 1.0, which is what you get when a model predicts a
near-constant zero for a zero-mean field. It learned rho (13%) and energy (5%)
and nothing else. Those two dominate the MSE it was trained on, so the training
loss looked healthy the whole way down.

The aggregate *falls* over the rollout, 0.493 -> 0.364. That is not the model
improving. The diffusive LxF truth is decaying toward the same mean the
collapsed model already sits at, so the two converge without the model ever
having learned anything.

## Where the folklore came from — the part worth keeping

The claim in circulation was **"0.5% single-step error, +/-3.2% over 200
steps"**. The archived write-up
(`docs/archive/neural-plasma-engine.md`) shows what the second number actually
was: a table of **total mass** over 200 autoregressive steps, oscillating
within 3.2% of truth. That measurement was correct. It was simply promoted
into a claim about the whole state, which it cannot support.

The two columns in the baseline table above show why, directly. At step 40:

- aggregate state error **36.4%** — the solution is unusable
- total mass drift **0.23%** — the diagnostic looks excellent

**Total mass is a sum over cells, so errors cancel inside it. Aggregate L2 is
a norm, so they do not.** A model can hold a conserved scalar to a fraction of
a percent while every field it is made of is wrong. Conservation diagnostics
are necessary and nowhere near sufficient, and this is the cleanest
demonstration of that in the estate.

Same shape as two other findings from the same day: the exp02 Vortex Quality
score followed an analytic term rather than the simulation it claimed to rank,
and `mk_max_div_b` worked for months because comparison survived a type
confusion that arithmetic did not. In all three, a summary statistic was
trusted past what it could carry.

## Reproduce

```bash
cd ~/projects/rail
./rail_native run tools/plasma/neural_mhd_rollout.rail
```

## History

A session on 2026-06-21 built an equivalent harness and reached the same
verdict: single-step 0.493, signed fields collapsed. That harness was never
committed and is gone from every clone; only prose in a handoff file survived.
This rebuild independently reproduces its headline number to three significant
figures (0.4934 against 0.493), which is a decent check on both.

It is committed this time. A falsification with no reproducible artifact
behind it decays back into folklore, which is exactly how the original claim
got into circulation.

## Not done

- **Weight persistence.** The June session wired checkpointing; this rebuild
  retrains each run (3.5 s, so it is not yet worth the complexity).
- **The residual variant.** June measured delta-prediction at 35x better
  single-step (49% -> 1.4%) but unstable under feedback, blowing past 700% by
  step 150. Not rebuilt here. If it is rebuilt, it must be measured on *this*
  harness so the numbers are comparable.
- **Any claim that this model is useful.** It is not. What is useful is the
  harness.
