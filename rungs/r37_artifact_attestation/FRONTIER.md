# Research Frontier — what r37 established, and the valid pathway forward

> **UPDATE 2026-06-08/09 — the "depth is the wall" conclusion below was a CONFOUND, now corrected.**
> Building the actual 2-block float RoPE model showed it trains to the copy floor (0.147) once given
> Glorot init + a non-decaying LR — the earlier plateau was bad init + cosine-LR-to-zero, not depth.
> The real wall is the memorize-vs-generalize gap (16 examples -> memorizes, 0/4). See
> **`TWO_BLOCK_FINDINGS.md`** for the full corrected picture + the grokking (weight-decay) experiment.


*2026-06-08. Written after building + running the r37 bricks (B1–B7). This is the evidence-based
research frontier the build earned, replacing the speculative "float will fix it" hypothesis.*

---

## What r37 actually established (the findings)

The r37 gate was built to test a pre-registered hypothesis: **is r24's capacity wall a numerics
problem (exact-int Q.24 brittleness) or a data problem?** Building it answered that decisively.

1. **Float trains where exact-int couldn't.** A pure-float transformer (reverse-mode autograd + Adam,
   `tools/train/lm_transformer.rail` adapted) trained the 16-line r24 corpus to **loss 0.073** —
   stable, no divergence, perfect memorization. The exact-int sweep's universal divergence under
   aggressive settings was a **numeric artifact, not a fundamental limit.** *(B1, B2.)*

2. **Float still does NOT generalize the copy rule.** On the held-out `31`/`75`, the well-trained
   float model scored **echo 1/4** — near-chance, garbled predictions (`"...(11s -- 112..."`). Same
   wall as exact-int, despite flawless training. *(B7, the deciding run.)*

3. **Naive data-scale destabilizes.** Float + the 48-line corpus (same hyperparameters) **diverged**
   to loss 7.50 (worse than uniform) — it didn't even fit the bigger data. Data-scale and
   training-scale are **coupled**: you cannot scale one without the other.

4. **The artifact-attestation frame works.** Train float → quantize to Q.24 → commit (SHA-256, sign
   pattern) → re-evaluate the Q.24 artifact → foreign-verify. *(B4, B5, B6 — demonstrated; the
   machinery is reusable the moment a generalizing model exists.)*

**The conclusion that reframes everything:** numerics is **not** the wall. A perfectly-trained model
in the trainable regime still memorizes-without-generalizing. **The wall is the
memorization↔generalization gap itself** — and it is set by *architecture × data × task*, not by the
optimizer or the number format. This narrows the search enormously.

---

## The valid frontier pathway (ranked)

### F1 — Float + RELATIVE positions (RoPE). *The highest-value next experiment.*
The copy/echo rule is intrinsically **position-relative** ("copy the digit k tokens back"). The float
model that failed (`lm_transformer`) uses **absolute** sinusoidal PE, which can only represent the
rule by memorizing absolute slots — exactly the failure observed. r24's exact-int model *had* RoPE;
the float model did not. **This is a confound we must remove before concluding anything about
architecture.** Port RoPE into the float trainer (or the float forward into r24's RoPE windowed
setup) and re-run B7. Outcome is binary and decisive:
- **Crosses ≥ 2/4** → relative position was the missing ingredient; we have a generalizing, trainable,
  attestable model → wrap it in the r37 frame → PAOS Stage-2 template is real.
- **Still ~0/4** → architecture is not it either; the wall is genuinely the data/task (F2/F3).

### F2 — Coupled data + training scale.
Scale the corpus (more distinct echo pairs → memorizing each line costs more than learning the rule)
**and** the training (more steps, a tuned/lower peak lr, longer warmup) **together**. The F-test:
does a model that *fits* a large, diverse echo corpus generalize? The naive single-knob test
diverged — this isolates whether data-scale forces the rule once training keeps up.

### F3 — Task design: make the rule the loss-minimizer.
Construct the corpus so that the *general copy* is strictly cheaper to encode than per-line
memorization (enough pairs, randomized placement, longer/variable echo distances). Generalization is
not coaxed by size alone — it emerges when memorization is no longer the path of least resistance.
This is the "grokking forcing function" framed as a data-design problem.

### F4 — The attestation payoff (already built, waiting on F1–F3).
The r37 artifact-attestation frame is **demonstrated and reusable**: train in float (trainable),
commit the Q.24-quantized weights bound to a signed data split, evaluate the held-out metric in
exact-int (cross-platform), foreign-verify the artifact. The moment F1/F2/F3 yields a *generalizing*
model, it drops straight into this frame — giving **attested trainable generalization without the
exact-int brittleness that capped r24.** This is the corrected foundation for PAOS Stage-2:
process-attestation was the wrong frame (it conscripts un-trainable numerics); **artifact-attestation
is the right one.**

---

## What this does to the PAOS thesis

[[paos-specialist-models]] / [[attestation-trainability-tension]]: the moat was always "attested +
specialist." r37 sharpens it to **"attested + *generalizing*"** — and shows the two are separable
problems with separate solutions:
- *Attested* is solved (artifact-attestation, demonstrated here).
- *Generalizing* is the open frontier (F1–F3), and it is an architecture/data/task problem, **not** a
  numerics or attestation problem.

The strategic payoff of building r37: we stopped turning the wrong knobs. Ten exact-int experiments
eliminated scale/tuning; the float build eliminated numerics; the frontier is now a *small, sharp*
set of experiments (relative-position architecture first) rather than an open field.

## Status of the r37 bricks
- B1 float forward ✓ · B2 float train (loss 0.073) ✓ · B7 deciding run (echo 1/4) ✓
- B4 Q.24 commit ✓ (demo subset) · B5 Q.24-eval hinge ✓ · B6 foreign verifier ✓ · B3 determinism ✓
- Files: `float_lm.rail` (trainer+attest), `float_lm_big.rail` (data-scale), `r37_foreign_check.py`,
  `RESEARCH_GATE.md` (the spec), this `FRONTIER.md`.

---

## Frontier EXECUTION results (2026-06-08, ran the experiments)

| Experiment | Config | Train loss | Held-out echo | Reading |
|---|---|---|---|---|
| baseline | float, abs-PE, 16 lines | 0.073 | 1/4 | memorizes, no generalization |
| **F2** data-scale | float, abs-PE, **48 lines** (fit) | 0.34 | **0/4** | more data did NOT force the rule |
| F1 RoPE (in-place) | float, RoPE, 16 lines | 9–13 (broken) | 0/4 | in-place mutation of GPU-matmul output = bug |
| F1 RoPE (fixed) | float, **non-in-place RoPE**, 16 lines | 0.78 | 0/4 | RoPE trains (slower); 1-block insufficient |
| **rope4** | float, RoPE, **48 lines, 6000 steps** | 0.65 | **0/4** | 1-block can't fit OR generalize — depth is the wall |

**What the frontier execution established:**
1. **Numerics is not the wall** — float trains where exact-int diverged (confirmed twice).
2. **Data-scale ALONE does not generalize** — F2 fit 48 forcing examples (loss 0.34) yet scored
   **0/4** on the holdout. A model with absolute PE memorizes whatever it is given; more examples
   just mean more memorization, because absolute PE retrieves by position, not by a relative copy.
3. **Architecture is implicated** — absolute PE provably cannot represent the position-relative copy.
   RoPE is required. (And the RoPE float wiring has a real gotcha: `rope_apply` mutates the
   GPU-matmul output in place; the GPU path doesn't see it. Non-in-place rope (`rope_copy`) fixes it
   — a reusable lesson for any in-place op after a GPU matmul.)
4. RoPE trains but **slower** (0.78 vs 0.07 at equal steps) and a **single block** does not form the
   copy/induction circuit on small data.

**DECISIVE conclusion (rope4 confirmed it):** the wall is **induction DEPTH**. A copy/induction
head is *classically a two-layer circuit* — a previous-token head in layer 1 feeding an induction
head in layer 2. **Every model in this whole arc that was trainable was 1-block** (the only 2-block
model, r24's lm10, was exact-int and untrainable — it diverged). rope4 is the proof: RoPE (correct
relative position) + forcing data (48 examples) + long training (6000 steps), on a single block,
**not only failed to generalize (0/4) but failed to even fit (loss 0.65)** — a single block has no
second layer to compose the copy. Numerics, position-encoding, and data-amount were each eliminated
in turn; what remains, and what NONE of the trainable experiments had, is **depth**.

The one config with all the right ingredients — **float (trainable) + ≥2 blocks (induction depth) +
RoPE (relative position) + data scaled past memorization capacity** — was never tested (the float
trainer is 1-block; r24's 2-block was un-trainable). That is the exact next experiment, and it is a
*scale* build, not a bug-fix: a 50K-param model memorizes ~hundreds of lines, so "forcing" needs
data ≫ that, plus the second block, plus commensurate training. The proven artifact-attestation
frame (B3–B6) wraps it the moment it generalizes — that is the corrected foundation for PAOS Stage-2.

**Durable engineering lesson:** in-place tensor ops after a GPU-dispatched matmul silently no-op on
the GPU side — use copy-then-mutate. (Saved to memory.)
