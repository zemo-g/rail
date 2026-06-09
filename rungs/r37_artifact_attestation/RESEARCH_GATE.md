# Research Gate r37 — Attested Generalization via ARTIFACT-Attestation (float training)

*Created 2026-06-08, out of the r24 capacity-wall finding. This is a falsifiable research gate, in
the style of the attested ladder (22–36): a pre-registered claim + controls + falsifiers + a binary
green criterion. It resolves WHY r24 can't go green and proposes the regime that can.*

---

## What the r24 sweep proved (the motivation)

r24 ("the model GENERALIZES is the gate") stayed at **0/4 held-out echo** across a controlled 10-way
sweep — capacity (d=16, d=32), heads (4), learning rate (4×), readout width (256), data (48 lines),
training length (120 ep), and combinations. Full-sequence accuracy CLIMBED with scale (19→37/54) but
held-out echo never moved off 0. **Every aggressive lever DIVERGED** (full-acc collapsed to 1–4/54).

That divergence shape is the tell: it is not a scale deficit, it is a **brittle numeric regime**.

## The root cause, named

The exact-integer Q.24 regime is *why the model is attestable* — deterministic, bit-exact,
cross-platform reproducible; it is the basis of r24's D0 self-witness and the whole ladder's
process-reproduction. It is **also** why it can't train: no gradient headroom, unstable under any
real optimization. **Attestability-of-process and trainability are in direct tension.** Demanding
bit-exact reproduction of every training step conscripts exact-int and caps generalization at the
memorization floor.

## The reframe: attest the ARTIFACT, not the PROCESS

| | r24 (process-attestation) | r37 (artifact-attestation) |
|---|---|---|
| Claim | "this exact bit-for-bit computation produced W" | "signed W, bound to committed train-only split S, generalizes ≥ T, memorizer-separated" |
| Forces | exact-int Q.24 (D0 reproduces every step) | nothing — training regime is free |
| Training | exact-int (brittle) | **float** (can form the copy circuit) |
| Cross-platform | training trajectory bit-exact | the *metric on the committed weights* (eval is exact-int) |

**Kept:** the SPLIT commitment + its falsifiers (train-on-holdout, post-hoc swap), the control
bracket (lookup < T ≤ honest), signed weights, a deterministic held-out metric, the ckpt-0 abort.
**Lost:** cross-platform bit-exact reproduction of the *training trajectory*.
**Gained:** float training → the model can actually generalize → the gate can go green.

## Architecture (the key trick: train float, EVAL exact-int)

1. **SPLIT commitment** — verbatim from r24: `SHA(train)`+`SHA(holdout)`, signed, `prev=genesis`,
   written BEFORE any weight. Falsifiers F1 (train-on-holdout → SHA≠) and F3 (swap → SHA≠) survive.
2. **Float training** — train the lm10 transformer in Rail native float (d-registers; `stdlib/
   autograd.rail` + `transformer.rail` + `optim.rail`). Deterministic on the *training platform*
   (fixed seed, fixed op order, no parallel nondeterminism).
3. **Weight commitment** — freeze final weights → canonical serialization (Q.24 quantization of the
   float weights) → SHA-256 + Ed25519 sign. **The signed weights are the attested artifact.**
4. **Held-out metric via EXACT-INT eval** — score held-out echo accuracy with an exact-integer Q.24
   forward pass on the *quantized committed weights* (reuse `r24_eval`). The eval is cheap,
   deterministic, and cross-platform reproducible — even though TRAINING was float. This is the hinge.
5. **Foreign verifier** — independent re-impl loads the signed weights, re-runs the exact-int
   held-out eval, confirms echo ≥ T + bracket — WITHOUT reproducing the float training. It attests
   the ARTIFACT's property cross-platform.

## The gate (GREEN = all)

- `okGeneralize` : held-out echo ≥ T (= 1/2) — the thing r24 could not reach
- `okBracket`    : lookup < T ≤ honest (a memorizer fails by construction)
- `okSplitSig` + `F1` + `F3` : data provenance (signed split; train-on-holdout & swap rejected)
- `okWeightSig`  : final-weights Ed25519 signature verifies
- `okDeterminism`: same-platform re-train reproduces the signed weights (the "float D0" — pinned
  seed + op order → bit-identical; this is the *weaker, honest* substitute for cross-platform D0)
- `okForeign`    : foreign verifier reproduces the held-out metric on the signed weights bit-for-bit
- `okCkpt0Abort` : pre-training echo < T (non-trivial metric — the 7-hour-burn lesson, kept)

## Honest scope (pre-registered, not hidden)

PROVES: the signed weights, bound to a committed train-only split, generalize (memorizer-separated),
and the metric is independently re-verifiable. DOES NOT PROVE: the exact float training trajectory
cross-platform (only same-platform determinism). **This is the deliberate trade** — artifact-
attestation buys trainability at the cost of cross-platform *process* reproduction. For a
*generalization* claim, the artifact's property + data provenance is sufficient and honest.

## Build plan (bricks — each independently RUN, not just compiled; r24 lesson)

- **B1** Float forward of lm10 (port `lm4_forward` to float, or wire `stdlib/transformer.rail`).
  Smoke: **run** a forward, assert finite outputs. (Do not stop at "it compiled.")
- **B2** Float autograd + Adam. Smoke: loss descends AND full-acc climbs **past** the exact-int
  ceiling (~37/54) — the first evidence float helps at all.
- **B3** Same-platform determinism: re-run training → bit-identical weights (pin seed + op order).
- **B4** Quantize-and-commit: float weights → Q.24 canonical → SHA + sign; round-trip test.
- **B5** Exact-int held-out eval on committed weights (reuse `r24_eval`); confirm deterministic and
  within tolerance of the float eval.
- **B6** Foreign Python verifier: load signed weights, exact-int eval, confirm echo + bracket.
- **B7** Wire the gate. **The deciding run:** does the FLOAT model cross held-out echo ≥ T?

## Success criterion (pre-registered, falsifiable BOTH ways)

GREEN if the float-trained, exact-int-evaluated model reaches **held-out echo ≥ T = 1/2** on the SAME
sealed holdout (`31`,`75`) while lookup stays 0/4, AND the foreign verifier reproduces it.

- **If float CROSSES T** → numerics was the wall. r24's capacity question is answered (the regime,
  not the size) AND we have a new attestation frame that actually permits a green. This becomes the
  template for PAOS Stage-2 attested training.
- **If float ALSO stays at 0/4** → a deeper, equally-valuable finding: the wall is the **data
  distribution** (16 train lines too few to force a copy rule), not numerics or scale. The next gate
  is then data-scale (force the induction rule with a much larger, more diverse echo corpus), and we
  will have *eliminated* numerics + scale + tuning as the cause.

Either outcome is decisive and advances the [[paos-specialist-models]] thesis. The 10-sweep
eliminated scale/tuning; this gate isolates (or confirms) numerics; the fallback isolates data.

## Files (to be built)

- `rungs/r37_artifact_attestation/float_train.rail` — B1–B3 float trainer
- `rungs/r37_artifact_attestation/commit_and_eval.rail` — B4–B5 commit + exact-int eval
- `rungs/r37_artifact_attestation/r37_foreign_check.py` — B6
- `rungs/r37_artifact_attestation/r37_gate.rail` + `validate.sh` — B7
- Reuses verbatim: the r24 SPLIT record, echo mask, lookup baseline, corpora (`31`,`75` holdout).

---

## GATE CLOSED — 2026-06-09 (scaled instance)

**Scope note (honest):** the criteria above were written for the original d=8 r24 instance
(holdout `31`,`75`, T=2/4). They are scored here against the **scaled instance that actually
took the wall**: d=64/d_ff=256/lr=0.003, windowed data-scale forcing over 9,984 distinct
4-digit numbers, 16-number sealed holdout, metric = held-out echo digits /64. Same gate
*shape*, larger honest instance (see TWO_BLOCK_FINDINGS.md B' and the bracket correction).

| Criterion | Verdict | Evidence |
|---|---|---|
| okGeneralize | **PASS** | foreign-reproduced **62/64** ≥ T′=55 (twins A+B both; `out/run_A.log` FINAL) |
| okBracket | **PASS** | strongest lookup memorizer = exactly **48**/64 (`r37_lookup_baseline.py`); 48 < T′=55 ≤ 62. Old T=48 did NOT separate — corrected, T′ embedded in signed msg |
| okSplitSig (F1/F3) | **PASS** | train/holdout SHAs pre-registered + in signed msg; verifier re-derives both; split is a complete 10,000-number partition, 0 overlap |
| okWeightSig | **PASS** | ALL 93,696 Q.24 weights committed (14 tensors, canonical order) → SHA `b033287e…d9b` in signed msg; v1 partial commit (3,456) superseded |
| okDeterminism | **PASS** | twin runs A (repo) + B (isolated mirror) → byte-identical artifact SHA; loss bit-identical to 15 digits through training |
| okForeign | **PASS** | `r37_foreign_check_v2.py` (numpy float64) re-implements the forward and re-derives **62/64 from the committed weights alone** + verifies Ed25519 (RFC 8032 reimpl), msg_sha, both split SHAs, full-artifact SHA, 93,696 count, fixed ln_g/ln_b |
| okCkpt0Abort | **PASS** | ckpt-0 abort control wired in pipeline (smoke-proven 2026-06-09); aborted run publishes nothing |

**Signature:** Ed25519 **dev key** (`pk 079ad478…4e02`, seed = sha256 of a local dev string —
NEVER the prod Pi-witness surface; okDevKey scoping per rung-ladder convention).
Msg: `r37|v2|train=f9ec1b1a…|holdout=893f259d…|weights=b033287e…|metric=62/64|T=55|order=…|q=Q.24|pulse_pre=1905363|pulse_post=1906779`
Sig `fab5b5ef…bd06`, self-verify 1, foreign-verify PASS. Record: `out/r37_attestation.txt`.

**Outcome (per the decision table above):** float CROSSES T — numerics was the wall for
*trainability*; capacity (d=64) + data-scale forcing were the gates for *generalization*.
The artifact-attestation frame (train float → quantize Q.24 → commit ALL weights → sign →
foreign re-derive) is hereby the **PAOS Stage-2 template**, realized end to end.

**Roadmap remainder (not gate-blocking, recorded honestly):** ~~exact-int Q.24 *forward* for
eval~~ (**DONE — v3 below, 2026-06-09 same day**); prod-witness counter-signature (rung 29
wall); cross-ISA foreign run (rung 22 wall).

---

## v3 ADDENDUM — okForeign upgraded float-empirical → integer-deterministic (2026-06-09)

v2's okForeign rested on numpy float64 argmax *empirically* matching Rail's float forward on
this artifact — a different libm/BLAS could in principle flip a borderline argmax. v3 removes
float from the verification path entirely: **`eval=xint-q24-v1`** (normative spec:
`r37_xint_spec.md`) makes the metric a **deterministic integer function of (committed weights,
committed splits, spec constants)** — Q.24 fixed-point, truncating division, integer layernorm/
RoPE/softmax via the proven `tools/bitexact` primitives (bx4 fxexp/sin/cos/reduce2pi, bx7
fxsqrt). RoPE tables are *derived*, not committed (pure integer function of the spec).

| v3 evidence | Result |
|---|---|
| Rail evaluator (`r37_xint_eval.rail`, pure Rail, 0.63s) | **62/64** |
| Python verifier (`r37_foreign_check_v3.py --forward-only`, pure int, no numpy) | **62/64** |
| Full 559-char prediction trace SHA-256, cross-language | **IDENTICAL** `7169ef76…c741e2` — every argmax decision matches, not just the 64 scored digits |
| Overflow audit (every accumulator + fxsqrt arg, sum-of-\|terms\| bound) | max_acc_bits = **60** < 62 → Rail int63 provably cannot wrap on this artifact |
| Metric continuity | xint 62/64 == float 62/64 (quantized-eval semantics preserve the result exactly) |

**Signed message (v3)** adds `pred=<sha>` — the signature binds the ENTIRE eval output trace,
so "metric reproduced" is a corollary of "output reproduced":
`r37|v3|train=f9ec1b1a…|holdout=893f259d…|weights=b033287e…|metric=62/64|pred=7169ef76…|T=55|order=…|q=Q.24|eval=xint-q24-v1|pulse_pre=1908326|pulse_post=1908329`
— dev key `079ad478…4e02` (same dev-key discipline), msg_sha `0bdfec86…a3e6`, self-verify 1.
Record: `out/r37_attestation_v3.txt`. Wrapper: `r37_attest_v3.sh` (pulse sandwich brackets the
eval; fail-loud cross-witness gate requires Rail==Python on metric AND pred SHA before signing).
Foreign verification: `R37_FOREIGN_V3=PASS` — 12/12 (sig + splits + artifact + exact-int metric
+ pred trace + bracket + overflow bound + max_acc_bits echo).

**Status of the three eval grades:** float forward (training-time, v1/v2) → grid-aligned float
(v2 faithfulness check) → **exact-int (v3, canonical)**. The float metric remains the
training-time result; the v3 metric is the machine-checkable one any implementation reproduces
bit-for-bit. The artifact-attestation triad is now fully realized: **train float → attest
weights → eval exact-int.**
