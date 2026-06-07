# RUNG 26 — Provably-Identical Tie-Break: Nucleus & Top-k

**Status: VALIDATE-READY (Rail self-witness + foreign cross-language witness + 3 falsifiers + 2 negative controls).**
The genuinely-new sampling wall is implemented and the cross-language reproduction
+ falsification logic is *empirically verified* end-to-end in the foreign-witness
half (see "What was actually run", below). The one step deferred to the
orchestrator (per compute discipline) is the Rail compile+run itself.

---

## What this rung proves (from `ATTESTED_LADDER.md`)

> top-k and nucleus (top-p) sampling stay bit-exact reproducible across languages
> **through a sort with exact ties**, with realized diversity itself an attested,
> falsifiable quantity.

**The wall** (one genuinely new thing): the substrate has **no stable-sort
primitive**. So an explicit **total order on `(prob, token_id)`** is defined and
*proven equal in two languages on exact ties*. Top-k is the k-th largest via
repeated `max_below`. The **diversity floor** is the live tension: a memorized /
low-temperature model collapses to one sequence, so an attested Q.24
sample-entropy is committed and gated.

---

## How it extends the proven pipeline (reuse, not reinvention)

| Proven machinery | Where it came from | Reused for |
|---|---|---|
| Q.24 softmax (`l_vmax`/`l_exps`/`l_vsum`/`l_smnorm`) | rung-15 CE core in `attested_utterance.rail` | `r26_softmax_t` (with temperature prescale) |
| range-reduced fixed-point exp (`bx4_fxexp`/`bx4_exp_neg`/`bx4_exp_poly`/`bx4_pow2`) | `bx_fixed.rail` | ported **verbatim** as `r26_fxexp` (a naive Taylor series DIVERGES on the large negative args low-τ softmax produces — see "Bugs found") |
| SHA-256 counter-mode RNG `u_t = first 24 bits of SHA256(key ++ "," ++ show t)` | rung-25 mechanism (the documented PRNG-int63-overflow trap forbids an LCG) | `r26_u_t` |
| inverse-CDF walk over **integer** prefix-sums with the same normalizer z | rung-25 | `r26_walk_go` / `r26_draw` |
| SHA-256 + Ed25519 chain (`sha256`, `bytes_to_hex`, `ed25519_sign/verify`, `ed25519_pk_from_sk`) | `attested_utterance.rail` header/UTTER record | the `UTTER26` link + signature |
| canonical id serialization (`utt_ids_canon` -> t_hex) | `attested_utterance.rail` | `r26_ids_canon` / `r26_set_canon` |
| fixed-point ln kernel (`fxln` mutual-recursion pairs) | rung-15 | `r26_fxln` -> `r26_log2` for the Q.24 entropy |

The genuinely-new code is the **total order + max_below ladder + nucleus prefix +
Q.24 sample-entropy**, plus the engineered exact-tie distribution that makes the
tie rule load-bearing.

---

## The total order (the wall, made concrete)

`r26_gt p_a a p_b b -> 1` iff `(p_a,a)` ranks strictly above `(p_b,b)`:
- **primary**: larger prob ranks higher;
- **tie-break** (equal prob): **`TIE_LOW` — the smaller token_id wins**.

We never sort. Selection is by **repeated `max_below`**: starting from a ceiling
`(+inf,-1)` (modeled as prob `16777217 > 2^24`), each step returns the strict
maximum under `r26_gt` among entries the ceiling ranks above. Top-k = k steps;
nucleus = steps until cumulative Q.24 prob `>= p_threshold`.

The foreign verifier (`r26_foreign_check.py`) implements the **same** order
(`gt(...,tie_low)`), and the falsifier runs the **opposite** order
(`tie_low=False`) to prove a single token diverges on the engineered tie.

## The engineered exact-tie distribution

vocab=6, logits (Q.24) `[3.0, 1.0, 2.0, 0.5, 2.0, 1.5]`. **Tokens 2 and 4 have
identical logits -> identical Q.24 softmax probs (exact tie)**, verified live:
`p[2]==p[4]==2978585`. The nucleus threshold is pinned at the engineered boundary
`p = 5313871 (~0.317)`, where:
- under **TIE_LOW** the nucleus is **{0, 2}**,
- under **TIE_HIGH** it is **{0, 4}** — **membership differs**,

so the opposite tie-break makes a drawn token-2 become token-4 and the draw
stream diverges bit-for-bit. This is the sharpest form of the rung-26 falsifier
(prefix *membership* differs, not merely order).

---

## The gate (mirrors the ladder)

`PASS` requires **all** of:

1. **exact tie load-bearing** — `p[2] == p[4]` (the tie is real, not incidental).
2. **top-k bit-exact** — Rail `tk_set` hash + `tk_thex` draw stream == foreign.
3. **nucleus bit-exact** — Rail `nuc_set` hash + `nuc_thex` draw stream == foreign.
4. **diversity floor (high-τ)** — the realized **top-k(4)** draw spread
   `Htk > 1.0 bit` (Q.24 `> 16777216`). *(A 2-token nucleus caps at exactly 1
   bit, so the diversity claim is carried by the ≥3-token top-k spread — measured
   `Htk = 1.9356 bits`.)*
5. **single-sequence collapse (τ→0)** — at `τ = 0.05` the nucleus collapses to a
   single token (`distinct == 1`), so the realized sequence is unique.
6. **knob moves the distribution** — `H(high-τ) > H(low-τ)` (the temperature knob
   demonstrably changes realized diversity).
7. **UTTER signature verifies** — the `UTTER26` link (mode params + `tk_set` +
   `nuc_set` + both t_hexes + `Htk` + `H`) is Ed25519-signed and verifies under
   the pinned pubkey.

The `UTTER26` record **commits the mode params + a Q.24 sample-entropy** exactly
as the ladder demands (`Htk` = diversity, gated above the floor; `H` = nucleus
entropy, tracks the knob).

## The falsifiers (each can fail; verified that they DO fail)

- **F1 — opposite tie-break** (the ladder's primary falsifier): the verifier runs
  `TIE_HIGH` on the engineered exact-tie distribution → nucleus `{0,4}` ≠ `{0,2}`
  → redrawn stream diverges from the committed `nuc_thex` → reject.
- **F2 — mislabeled temperature**: recompute entropy under `τ = 1.0` instead of
  the committed `τ = 4.0` → `H' ≠ committed H` → a record claiming `τ=4.0` while
  actually `τ=1.0` fails.
- **F3 — forged commitment**: flip the tie rule `TIE_LOW→TIE_HIGH` in the signed
  link → the recorded Ed25519 sig no longer verifies → reject.

Plus two **negative controls** in `validate.sh` that prove the verifier is not a
rubber stamp:
- **A**: a one-nibble-tampered `nuc_thex` → foreign witness exit 1.
- **B**: a ledger whose nucleus was built with `TIE_HIGH` but **labeled
  `TIE_LOW`** and signed with the real key → the verifier's `TIE_LOW`
  reproduction yields `{0,2}` ≠ the ledger's `{0,4}` → `nucleus membership
  reproduced = False`, `nucleus draw stream reproduced = False` → exit 1. *This is
  the proof that the tie rule is genuinely enforced: a verifier ignoring the tie
  rule would wrongly accept this.*

---

## Soundness / falsification argument

- **Bit-exactness across languages** rests on (a) the **same** Q.24 truncating
  arithmetic on both sides (softmax via the proven range-reduced `bx4` exp;
  integer prefix-sums with one normalizer; the SHA-256 counter RNG), and (b) the
  **same explicit total order**, including the exact-tie direction. There is no
  float and no library sort anywhere in the path, so there is no source of
  cross-language drift. The `≥` (`cum >= pthr`) and `<` (`up < nxt`) boundary
  conventions are pinned identically in Rail and Python.
- **The tie rule is load-bearing, not decorative**: negative control B is a
  fully-signed ledger that differs from the honest one *only* in the tie
  direction used to build the nucleus, and it is rejected. So "two languages
  agree on exact ties" is a claim that can be, and is, falsified by a wrong tie
  rule.
- **Diversity is an attested, falsifiable quantity**: `Htk`/`H` are committed
  into the signed link, recomputed by the foreign witness, and gated. F2 shows a
  mislabeled temperature is caught because the committed entropy contradicts the
  verifier-recomputed entropy under the claimed τ.
- **Scope (honest)**: this rung validates the sampling wall on a **fixed
  engineered distribution**, deliberately decoupled from the multi-GB lm10
  training run (compute discipline: one shared compiler/GPU/24GB across many
  builders). The per-step recompute in the full pipeline is the *same* machinery
  — `r26_softmax_t (logits_t)` per decode step — and the integration point is one
  line: replace the fixed `logits` with `lm4_forward(...)` per step and thread
  the chain head as `rng_key`. That integration inherits rungs 21/25's proven
  training+RNG chain unchanged; what rung 26 adds and proves is the tie-break +
  top-k + nucleus + entropy layer, which is exactly the new wall.

---

## What was actually run (HONEST evidence)

Per compute discipline I did **not** run the heavy Rail build. I **did** run the
full foreign-witness + falsifier + negative-control chain against a fixture
ledger produced by the **same reference math** (the fixture/foreign-check share
one definition of softmax/order/draw/entropy, and a separate Rail emit is what
makes it cross-language):

```
fixture: top-k [0,2,4,5]  nucleus [0,2]  nucleus_opp [0,4]
         Htk=32473436 (1.9356 bits)   H=16729923 (0.9972 bits)
foreign witness (honest ledger):
  exact tie load-bearing                 = True   (p[2]==p[4]==2978585)
  top-k membership reproduced            = True
  nucleus membership reproduced          = True
  top-k draw stream reproduced (t_hex)   = True
  nucleus draw stream reproduced (t_hex) = True
  top-k diversity entropy Htk reproduced = True
  sample-entropy H reproduced            = True
  diversity floor (Htk > 1 bit)          = True
  single-sequence collapse (tau->0)      = True
  knob moves (H_high > H_low)            = True
  UTTER Ed25519 sig verifies             = True
  F1 opposite tie-break diverges         = True
  F2 mislabeled-tau caught               = True
  F3 forged commitment rejected          = True
  -> R26-FOREIGN PASS (exit 0)
negative controls:
  tampered nuc_thex                      -> exit 1 (rejected)
  TIE_HIGH-built / TIE_LOW-labeled       -> exit 1 (rejected; membership {0,2}!={0,4})
```

The Ed25519 sign+verify in the fixture/checker is a real RFC-8032 reference
implementation, independent of the Rail one.

### Bugs found and fixed while building this (real engineering, not boilerplate)

1. **Naive Taylor `exp` diverges** for the large negative args low-temperature
   softmax produces (logit/τ before max-subtract). Fixed by porting the proven
   range-reduced `bx4_fxexp` (ln2 argument reduction) verbatim. *Symptom before
   fix: at τ=0.05 the lowest-logit token got prob 0.94 — backwards.*
2. **`fxln` up/down-shift direction** was inverted in the first foreign-check
   draft (infinite loop for `x < 1.0`, i.e. probabilities). Fixed to match the
   Rail `r26_ln_up` (decrement k while `m < s`) / `r26_ln_dn` (increment k while
   `m >= s2`) semantics.
3. **2-token nucleus caps entropy at exactly 1 bit**, so the diversity floor had
   to be carried by the ≥3-token **top-k** spread (`Htk`), not the nucleus —
   reflected in the gate.

### Rail-discipline guards applied (from CLAUDE.md / memory)

- **self-loop cross-dep-arg miscompile**: `r26_fxexp_*`(removed), `r26_maxbelow_*`,
  `r26_maxbelow_opp_*` use **mutual-recursion `_a/_b` pairs** (and `r26_ln_*` is
  the proven mutual-recursion ln kernel). Accumulator loops whose recursive args
  do not cross-reference another updated arg (`r26_topk_go`, `r26_nucleus_go`,
  `r26_draws_go`, `r26_walk_go`, `r26_entropy_go`, `r26_pow2_go`) are left as safe
  direct self-loops.
- **no large literal in comparison position** — `16777216` only ever appears in
  multiply/divide operands; gate thresholds (`Hfloor`) are `let`-bound runtime
  values; `16777217` (`+inf` ceiling) only appears as a call **argument**.
- **≤ 7 args per function** (cliff is ≥30); **`main` is the last decl**;
  **ASCII-only** inside emitted strings.
- static cross-check: every `r26_*` referenced is defined; no dead code; all
  stdlib entry points (`sha256`/`bytes_to_hex`/`ed25519_*`) resolve through the
  imports; parens/brackets balance.

---

## EXACT validate command (orchestrator runs this serially)

```bash
bash /Users/ledaticempire/rail-reward/rungs/r26/validate.sh
```

It (1) compiles `rungs/r26/tiebreak_sampling.rail` with an isolated out-prefix,
(2) runs it under `RAIL_ARENA_MB=512` and requires `PASS` + a produced ledger,
(3) runs the foreign cross-language witness `r26_foreign_check.py` on the ledger
(must `R26-FOREIGN PASS`), and (4) runs both negative controls and requires the
foreign witness to **reject** each. Prints `R26 VALIDATE PASS` and exits 0 iff
every step holds.

## Files

| File | Role |
|---|---|
| `tiebreak_sampling.rail` | Rail self-witness: total order, max_below ladder, top-k, nucleus, SHA-counter RNG draw, Q.24 sample-entropy, UTTER26 sign, F1/F2/F3 — produces `out/r26_chain.txt` |
| `r26_foreign_check.py` | foreign cross-language witness (independent Q.24 math + RFC-8032 Ed25519 verify) — reproduces + verifies + catches F1/F2/F3 |
| `r26_fixture_gen.py` | TEST-ONLY fixture: emits a ledger by the same reference math + a reference Ed25519 sign, so the foreign witness can be exercised without the heavy Rail build (the real cross-language proof is Rail-emit / Python-verify at validate time) |
| `r26_neg_tiehigh.py` | negative-control B generator (TIE_HIGH-built, TIE_LOW-labeled forgery) |
| `validate.sh` | the gate the orchestrator runs |
