# Open Seam — Numeric Faithfulness at Scale

*Cross-cutting seam for the attested-LM ladder (rungs 22→36). Not numbered: it cuts across every
rung that deepens the Q.24 transformer. Design grounded in the live substrate — established
2026-06-06, the day after the first attested utterance landed.*

---

## The gap, stated precisely

The first attested utterance proved **bit-exact reproducibility**: `attested_utterance.rail`'s Q.24
transformer and `utterance_foreign_check.py` produce the *same* token-ids, because the foreign
witness re-implements the **same** fixed-point algorithm. Read the two oracles side by side:

- Rail (`lm10_attested_train.rail:275`): `fxm a b = (a * b) / 16777216` — one truncate-divide by `2^24` per multiply.
- Python (`bx4_foreign_check.py:td`): `q = abs(a)//abs(b); return -q if signs differ else q` — the *same* truncate-toward-zero.
- Both call the **identical 8-term** `exp_poly`, the **same** `RMS_EPS = 16777`, the **same** `LN2_q = 11629080`.

So the foreign check is a **reproducibility oracle, not a faithfulness oracle**. It can never fire on
the question this seam owns: *does Q.24 track the real-number computation the model is supposed to be
doing?* Every `/ 16777216` discards up to `2^24 - 1` units; an 8-term `exp_poly` is a *truncated*
series; `fxln` is a 2-step range-reduction + bounded mantissa poly; `RMS_EPS` is a hardcoded
`~0.001`. Each is a **deterministic, reproducible, bounded approximation** of a transcendental. The
errors are real, and the ladder's own roadmap names the danger (ATTESTED_LADDER.md, seam #3):

> *"Deeper-exact could be exactly-**wrong**."*

Two implementations agreeing bit-for-bit on a wrong answer is a *stronger* failure than disagreement,
because the cryptographic chain certifies it as correct. As rungs 23/30/35 deepen the net (≥4 blocks,
d≥32, ctx≥32, K up to 8192 per `r4_overflow_audit.rail`), the per-layer truncation error **composes
through depth**. Nothing in the chain today bounds that composition. This seam closes it.

**What this seam is NOT:** it is not the *overflow* question (`r4_overflow_audit.rail` already proves
the 2-limb superaccumulator holds the sum *exactly* vs an int63 wrap — that is exactness of the
*sum*). Faithfulness is the orthogonal axis: even with an exact accumulator, the `/2^24` truncation
and the polynomial approximations make the *result* a faithful-but-inexact image of the reals. r4
gives us the exact-sum primitive we build the oracle ON; it does not answer faithfulness.

---

## Design on THIS substrate

**Core move: attest a per-layer error bound against a higher-precision oracle, not bit-reproduction
of the same precision.** Three concrete pieces, all in pure Rail, all foreign-cross-checked.

### 1. The higher-precision oracle (Q.48, in-substrate)

The substrate already has the exact-sum primitive — the 2-limb superaccumulator
(`r4_norm/r4_add/r4_acc_a/r4_acc_b`, `gpu_recon`'s `hi*2^31+lo`) — and a true bignum module
(`stdlib/bignum_n.rail`: `bn_new/bn_uadd/bn_mod_*/bn_cmp`). Build an **independent Q.48 oracle**
(`F_HI = 48`, scale `2^48`) that recomputes the *same forward pass* the Q.24 trainer ran, but:

- multiplies at `2^96` intermediate and truncates by `2^48` (24 more fractional bits → ~2^24× finer);
- evaluates `exp`/`tanh`/`gelu`/`ln` with **more series terms** at Q.48 (e.g. 16-term `exp_poly`
  instead of 8) — a genuinely better approximation, not the same one rescaled;
- carries sums in the 2-limb accumulator (`r4_acc_*`) so the oracle's *own* sum is exact.

This is the analog of `r4`'s `fref` ground-truth move (`int_to_float sumAB /. 8.0`) but lifted from
one dot to the whole forward pass and from f64 to Q.48 — deliberately **not f64**, because f64 drops
the mantissa past `2^53` (the exact wall `r4`/rung-22 already flagged for the Metal path), so a f64
oracle would itself be unfaithful at the depths this seam cares about. The oracle is `gcap=48`-step
decode only (not training) — cheap.

### 2. The faithfulness metric (deterministic, exact-integer)

For each layer ℓ in the forward decode, compute the Q.24-vs-oracle deviation on the layer's output
activations, projected to a common scale:

```
err_ℓ = max_i | upscale(q24_out[i], 24→48) - oracle48_out[i] |     -- in Q.48 units, exact integer
```

`upscale` is a pure shift (`* 2^24`), so the comparison is exact-integer (no float, no new rounding).
Define `EMAX = max over ℓ of err_ℓ` and `EDEPTH = (err at final block) / (err at block 0)` — the
**error-growth ratio through depth**, the quantity the seam exists to bound. Both are committed as
exact integers (Q.48 units), so they are bit-reproducible like every other ledger field.

### 3. The chain commitment + gate (extends the existing record)

The current link is (`attested_utterance.rail:715`):
`link = SHA256(prev "|" epoch "|" w_hex "|" loss)`. Add a sibling **FAITH record**, chained after the
final checkpoint and before/alongside the UTTER record, committing:

```
FAITH | prev_hex | w_hex | oracle_cfg_hex | EMAX | EDEPTH | bound_T | bound_R
oracle_cfg_hex = SHA256(canonical(F_HI=48, exp_terms=16, ln_terms, RMS_EPS_48, depth, dims))
```

signed with the LOCAL/DEV key exactly as `lm4_chain` signs checkpoints. `bound_T` (absolute) and
`bound_R` (growth-ratio) are **pre-registered floors written before the run** (per the project's
define-success-before-training rule + ATTESTED_LADDER rung-24's "strict eval before the run"). A
companion `lm10_faith_check.py` (sibling to `lm10_foreign_check.py`) independently rebuilds the Q.48
oracle in Python big-ints, recomputes `EMAX`/`EDEPTH`, and verifies they match the committed values
AND clear the bounds.

**Why this is faithfulness, not reproducibility:** the foreign witness now runs a *different
precision* (Q.48, 16-term) than the trainer (Q.24, 8-term). The two are NOT supposed to be
bit-identical to each other — they are supposed to be *close*, and the gate asserts the closeness is
within a pre-registered bound. That asymmetry is the whole point.

### Rail traps respected (from CLAUDE.md / the lm10 lineage)

- **Q.48 accumulators overflow int63** → use the proven 2-limb path (`r4_acc_a/r4_acc_b`,
  mutual-recursion to dodge the self-loop cross-dep-arg miscompile, exactly as lm10 does).
- **≥30-arg cliff** → oracle forward bundles configs positionally (the lm10 "17-config bundle"
  pattern) so no fn exceeds the arity cliff.
- **`s = 16777216` literal in comparison-operand position fails to assemble** (lm10 comment ~line
  155) → keep `2^48` and `2^24` constants in multiply/divide operand position only; route comparisons
  through helper vars.
- **PRNG / randomness** → no RNG needed here; metric is deterministic. (Contrast rung-30, which needs
  SHA-derived challenges.)
- **bump-arena giant-string cap** → the oracle decode is `gcap=48` only; the per-layer dump uses
  `arena_mark`/`arena_reset` per layer if width grows (the rung-23 discipline).
- **ASCII-only in `.asciz`** → FAITH record uses `|`-delimited ASCII like the existing link string.

---

## Gate

A deepened config (≥4 blocks OR d≥32/ctx≥32 — the rung-23 scaling regime, where compounding actually
bites) trains and decodes; the run emits a signed FAITH record. **PASS requires ALL of:**

1. **Bound met:** committed `EMAX ≤ bound_T` AND `EDEPTH ≤ bound_R`, with `bound_T`/`bound_R`
   pre-registered (committed to the chain *before* training, e.g. seeded into genesis) so they cannot
   be fit to the result post-hoc.
2. **Oracle is genuinely higher-precision (non-vacuity):** the gate asserts the Q.48 16-term oracle
   disagrees with a Q.24 8-term *re-run* on ≥1 activation by > 1 Q.24 ulp — proving the oracle is a
   real refinement, not Q.24 in a costume. (Mirrors rung-25's "non-triviality witness" and rung-22's
   "must include ≥1 hard edge" discipline.)
3. **Foreign agreement on the metric:** `lm10_faith_check.py` independently rebuilds the Q.48 oracle,
   recomputes `EMAX`/`EDEPTH` bit-for-bit equal to the committed integers, and re-checks the bounds.
4. **Depth-monotone control:** the same metric run at depth 2 vs depth ≥4 shows `EMAX` grows but
   stays ≤ `bound_T` — demonstrating the bound holds *as depth grows*, which is the seam's literal
   claim. A bound that only holds at depth 2 is a fail.
5. Existing gates unaffected: D0 whole-run reproduction, per-checkpoint sigs, and UTTER `t_hex` still
   pass (the FAITH record is additive, chained, signed).

The asymmetry vs the existing foreign check is the load-bearing design choice: the foreign witness
runs *more precision than the trainer* and PASSES on *bounded disagreement*, not bit-equality.

---

## Falsifier (a forged input the gate MUST reject)

The seam is real only if a faithfulness failure that the *reproducibility* check passes is caught
here. Four concrete forges, each must fail:

1. **Silently-wrong-but-reproducible deepening.** Replace the 8-term `exp_poly` with a **3-term**
   truncation (still deterministic, still bit-reproducible Rail↔Python under the *old* check — the
   foreign check re-implements whatever poly it's told to, so `utterance_foreign_check.py` would
   PASS). The Q.48 16-term oracle exposes the larger error: `EMAX > bound_T` → FAITH gate rejects.
   **This is the seam's whole reason to exist** — a change invisible to bit-exactness, fatal to
   faithfulness.
2. **Post-hoc bound fitting.** Set `bound_T` *after* seeing `EMAX` (loosen it to just clear). Because
   the bound is committed before training (chained into genesis / a pre-run record), the recomputed
   pre-run commitment ≠ the signed one → reject. (Same shape as rung-24's SPLIT-before-checkpoint-0.)
3. **Fake oracle (oracle == trainer).** Ship a "Q.48 oracle" that is actually Q.24 upscaled by a
   shift (so `EMAX = 0` trivially). Non-vacuity gate #2 fails: the oracle must disagree with a Q.24
   8-term re-run by > 1 ulp, and a shifted-Q.24 oracle disagrees by exactly 0 → reject. The committed
   `oracle_cfg_hex` (F_HI=48, exp_terms=16) is also re-derived by the foreign checker, which runs the
   *actual* 16-term path; a mislabeled config → recomputed `EMAX` ≠ committed → reject.
4. **Tamper one committed metric integer.** Flip one nibble of the committed `EMAX` → its inclusion
   in the FAITH link changes the SHA → signature fails under the pinned pubkey (the rung-21 weak-vs-
   strong-tamper insight: the commitment, not output-divergence, is the guarantee).

The decisive falsifier is #1: it is precisely a chain that the **existing** attestation (bit-exact
reproducibility) would certify as correct, and which this seam's higher-precision oracle proves is
unfaithful. If that case ever passes the FAITH gate, the seam has failed.

---

## Relationship to the numbered rungs

- **Builds on r4 / rung-22:** uses the 2-limb superaccumulator (exact sum) as the oracle's arithmetic
  floor; faithfulness is the orthogonal axis r4 does not touch.
- **Co-requisite with rung-23:** the deepened config that makes compounding bite is rung-23's scaling
  regime; this seam is the *reason* to care that deeper is correct, not just resumable.
- **Distinct from rung-30:** rung-30 makes verification *cheap* (spot-check); this seam makes it
  *meaningful* (faithful). Orthogonal — a sublinear spot-check of an unfaithful trajectory is fast
  certification of a wrong answer. Ideally rung-30's challenged steps also re-check the FAITH metric.
- **Feeds rung-35 (PAOS):** "deeper-exact could be exactly-wrong" is fatal when the output *is* Rail
  that must compile — an unfaithful logit picks the wrong token picks invalid source. Faithfulness is
  upstream of compile-bound utterance.

This is the bf16-stable-to-10k / f64-truth-line IP (memory: rail-bf16-stable-10k, rail-f64-truth-line)
lifted into the attestation: not "we found a stable regime" but "the ledger **proves** the regime
stayed faithful as depth grew, and a foreign party in higher precision confirmed the bound."
