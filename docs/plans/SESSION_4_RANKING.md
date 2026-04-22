# Session 4 direction ranking

**Written:** 2026-04-21 evening, Studio docs session.
**Purpose:** after the Phase 5 composed d=256 × HalfTensor × 3000-step run lands (in flight at time of writing), which direction does Session 4 take?
**Scope:** ranking only. Each option is a hypothesis + cost + delta estimate + risk, not a plan.

Deadline context: 2026-04-27 (6 calendar days out). Session 4 runs some time 2026-04-22 through 04-24 depending on how quickly main session fills the model card and P0.3 bench row lands.

The ranking below is written BEFORE Session 3's 3000-step number is known. See the `3000-step result` section at the bottom — if the number is filled in by the time you read this, the ranking becomes a thin default that you can override based on the result's shape.

---

## The five candidates

Each ranked by a single metric: **leverage for the 2026-04-27 deadline** (defined as: probability-weighted contribution to a publishable model card + ≥ 5/30 bench + one closed flywheel round).

### Rank 1 — **Focus on bench plumbing + first real bench run**

- **Hypothesis:** the deadline's literal blocker is an un-run bench, not an under-capacity model. The d=128 × 2-block f64 model already exists and has never been benched against a Rail-corpus-trained checkpoint. The d=256 × HalfTensor result lands on top of this same bench harness. Spending Session 4 wiring the harness + running it on 2-3 checkpoints (d=128 2-block, d=128 4-block, d=256 half when it lands) gives three data points for the model card in the time one capacity experiment would take.
- **ETA:** 3-5 h (private repo sync + wire bench + run on 3 checkpoints + append rows).
- **Expected bench-score delta:** unknown because no baseline. This *creates* the baseline. P(≥5/30 on at least one checkpoint): 0.6 based on the historical peak 14/30 on some prior model state (`DEADLINE_2026-04-27_PUNCHLIST.md` §Historical bench data).
- **Risk:** private repo is on Mini; private-repo / checkpoint-format drift could eat 1-2 h. Medium. Recoverable — failures point you to the concrete thing to fix, unlike a training run that fails at step 1500.
- **Why #1:** every other option costs more and buys less for the deadline. Capacity experiments produce a number that still has to go through bench to matter. Starting with bench de-risks the deliverable.

### Rank 2 — **Train longer (6000 steps at current config)**

- **Hypothesis:** the 3000-step run is in-flight and whatever number it returns hasn't saturated. The f64 d=128 × 2-block baseline at 3000 steps was 2.87 ± 0.18; it was still descending (3.34 → 2.87 at regular intervals). If d=256 half at 3000 lands at 2.7-ish, another 3000 steps probably pushes it to 2.4-2.5. That upgrades the model card's headline from "matches baseline" to "substantively beats baseline."
- **ETA:** 1.5-2 h wall (same per-step cost, doubled steps). Cheap because the infrastructure is already working.
- **Expected bench-score delta:** small but real. Eval mean 2.5 vs 2.7 is a meaningful learnable-generalization gap, should convert to +1-2 bench points in expectation.
- **Risk:** LOW. Worst case you get diminishing returns and the model card quotes both numbers. The only real risk is GPU-time opportunity cost.
- **Why #2:** cheap, almost certain to improve the headline number, and doesn't require any new code. The only reason it's not #1 is that an unimproved model that scores 0/30 on bench still fails the deadline — so bench plumbing first.

### Rank 3 — **Scale wider (d=512 × 2-block, if RSS budget allows)**

- **Hypothesis:** d=128 → d=256 × 4 in parameters. If d=256 half eval < 2.7, the width trend continues and d=512 half gets eval < 2.3 or so. d=128 × 4-block result (2.88, tied with 2-block) confirmed depth isn't the bottleneck; all evidence points to width as the active dial.
- **ETA:** 2-3 h (clone the d=256 variant, bump d to 512, stage 10→50→500→3000).
- **Expected bench-score delta:** LARGER than Rank 2 if it works. Doubling width from 128→256 is likely to produce a bigger eval-mean drop than doubling step count. So +2-4 bench points in expectation (stretch).
- **Risk:** HIGH for RSS. At d=512, stored weights are ~7 MB (vs ~1.7 MB at d=256), and the 12-activation-per-block cache scales linearly with d — at d=512 that cache alone is ~200 MB per block × 2 blocks = 400 MB on top of weights + Adam state + scratch. Could push peak RSS past 1 GB. Also fp16 overflow risk: larger d means larger Q·Kᵀ pre-scale range; needs attention-score verification at stage 1.
- **Why #3:** highest ceiling of the capacity options, but meaningfully more failure modes than Rank 2, and (like Rank 2) doesn't ship a bench row on its own.

### Rank 4 — **Improve training signal (harvest-gated corpus, better init)**

- **Hypothesis:** The Rail stdlib corpus (544 KB) is enough to converge on but not enough to generalize well. A harvest-gated corpus (compiled-passing generations from self_train) would be higher-quality + larger. Separately, Kaiming-scaled init already unblocked the 2.22 plateau; one more init study (layer-wise scaling, or small-σ γ init) could buy another eval point.
- **ETA:** 4-8 h. Harvest assembly: 2-3 h. Re-train on gated corpus: 2-3 h. Init study: 2-3 h. More if any piece unearths a bug.
- **Expected bench-score delta:** potentially large on corpus (model sees more diverse code → better generalization → better bench on code-adjacent questions), but the signal is indirect. Probably +2-5 bench points on success, 0 if the harvest is too small / too biased.
- **Risk:** MEDIUM-HIGH. This is a research direction, not a deliverable. It's where most of the marginal value lives *past* the deadline, but it's not the right place to spend Session 4 when the deadline is 3-4 days out.
- **Why #4:** best long-term investment but wrong time. Defer to the week of 2026-04-28.

### Rank 5 — **Scale deeper (d=256 × 4-block)**

- **Hypothesis:** d=256 × 2-block wins; depth compounds on top of width. 4-block at d=128 didn't help (tied with 2-block), but that was at a width where width itself was the bottleneck. At d=256, depth might finally matter.
- **ETA:** 3-4 h (~2× per-step cost of 2-block, same 3000 steps, same staging).
- **Expected bench-score delta:** small and speculative. The d=128 4-block-vs-2-block experiment says depth didn't help at that width; at d=256 it might, but the prior should be "probably not much."
- **Risk:** MEDIUM on RSS (half the risk of d=512 because d is unchanged, but 2× the weight count), LOW on numerics (same precision substrate as Session 3).
- **Why #5:** lowest expected value of the five. The "depth doesn't help" experiment (PHASE_2B_RESULT... nonexistent but visible in the handoff as "0b35676  docs: Session A Phase 2b result — 4-block × d=128 × 3000 steps") is recent and pointed. Don't re-run a variant of the same experiment.

---

## Summary table

| rank | option | ETA (h, realistic) | Δ bench (expected) | risk | deadline leverage |
|---:|---|---:|---|---|---|
| 1 | Bench plumbing + first bench run | 4 | sets the baseline | medium | **HIGHEST** |
| 2 | Train longer (6000 steps) | 2 | +1-2 | low | high |
| 3 | Scale wider (d=512) | 3 | +2-4 | high (RSS / overflow) | high if works |
| 4 | Better training signal | 6 | +2-5 (noisy) | medium-high | low (wrong time) |
| 5 | Scale deeper (d=256 × 4-block) | 3.5 | 0-1 | medium | low |

## Recommendation

**If the 3000-step result lands ≥ 2.7 (i.e. doesn't cleanly beat baseline):** Rank 2 + Rank 1 composed. Kick off a 6000-step run on the same d=256 half config during Session 4, and use the wall-time to do bench plumbing + first bench row. Two deliverables in parallel, no GPU contention for the plumbing work.

**If the 3000-step result lands in (2.5, 2.7):** Rank 1 alone is enough. The headline number is already good; the deadline needs a bench row to go with it. Don't gamble on Rank 3.

**If the 3000-step result lands < 2.5:** Rank 1 again, but more confidently. The model card headline is already past the stretch target; all that's left is bench.

**If the 3000-step result fails (NaN / OOM / divergence):** Rank 1 becomes forced. Debug Phase 5 in Session 5 or later; Session 4 still needs to produce a bench row against whatever checkpoint *does* exist (d=128 2-block f64 baseline at minimum).

## 3000-step result (fill when known)

- Eval mean @ 3000: **TBD**
- Peak RSS: **TBD**
- Wall-time: **TBD**
- NaN/Inf observed: **TBD**
- Recommendation above that applies: **TBD**

---

Leverage-for-deadline is the only ranking metric here. Post-deadline the ranking reverses in places (Rank 4 becomes Rank 1 for the week after; Rank 1 becomes steady-state work). This doc is scoped to the 2026-04-27 horizon.
