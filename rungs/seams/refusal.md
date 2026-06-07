# Open Seam — Refusal / Honest-Empty Attestation

*Cross-cutting seam #6 of the attested-LM ladder. Establishes the design, gate, and falsifier on
the actual `attested_utterance.rail` / `lm10` substrate. No heavy builds run; this is the skeleton +
the proof obligations the implementation must satisfy.*

---

## The claim

Today the ledger can only commit a **confident saying**: the `UTTER` record signs `t_hex` =
SHA-256 of the greedy-decoded token list. There is no honest way for the model to say *"I don't
know"* and have that refusal be **as attestable** as a confident answer. That is exactly backwards
for Ledatic's no-synthetic-evidence ethos (`feedback_no_synthetic_evidence.md`): an honest empty
state must win, and here it cannot even be *expressed* in the chain.

**This seam attests that the model CORRECTLY refused** — returned a calibrated honest-empty answer on
an out-of-distribution (OOD) prompt — **with the same cryptographic force** as a confident
utterance, and the gate falsifies *both* directions of dishonesty:
1. a model that **fabricates** a confident answer on a prompt it should refuse (the synthetic-evidence sin);
2. a model that **lazily refuses** a prompt it can actually answer (refusal as a free pass).

The bound is no longer just *weights ↔ words*. It is **weights ↔ {words, OR the attested decision
that there are no honest words}**.

---

## Why the floor cannot express this (grounding in the substrate)

In `tools/bitexact/attested_utterance.rail`:

- `lm4_gen` (line 832) **always** runs `gcap` forward passes and `lm4_snoc`s `gcap` argmax tokens.
  There is no exit. The model is structurally incapable of abstaining.
- `lm4_argmax` (line 831) picks the top index **unconditionally** — it never inspects *how
  confident* that pick is. A near-uniform logit vector and a peaked one both emit a token with equal
  authority.
- The `UTTER` line (line 965) commits `prompt_hex / cwin / gcap / w_hex_final / t_hex`. There is no
  field for "decision = REFUSE" and no committed evidence of *why*.
- The only out-of-corpus control in the file is `okForgeWeights` (line 975): a *zeroed-readout*
  forge that collapses argmax to token 0. That proves wrong weights → wrong words. It does **not**
  prove the model knows the difference between a prompt it learned and a prompt it didn't.

So refusal is not a knob to add to `lm4_gen`; it is a new **decision layer** plus a new **ledger
record type** plus a new **falsifier class**, all of which must stay Q.24 exact-integer and
bit-reproducible by the foreign witness.

---

## Concrete design on this substrate

### 1. A deterministic, attestable abstention decision (the heart)

Refusal must be a **function of the model's own logits**, computed in Q.24 exact integers, so the
foreign verifier in `utterance_foreign_check.py` can recompute it bit-for-bit. It must **not** be a
string match on the prompt (that would be a hardcoded whitelist, not a model decision; and per the
loaded-vertical rule, whitelists belong to *architecture*, but here the falsifiable quantity is
*calibration*, which must come from the logits).

Reuse the existing exact softmax already in the file — `l_softmax` (line 199) gives a Q.24
probability vector; `l_vmax` (line 195) gives the peak in Q.24. Define a **confidence score** per
generation step entirely from integers already on the hot path:

```
-- top1 prob in Q.24 (16777216 == 1.0). Reuse l_softmax / l_vmax verbatim.
ref_conf logits = let sm = l_softmax logits in l_vmax sm
```

A step **abstains** iff `ref_conf logits < tau` where `tau` is a Q.24 confidence threshold
**committed in the chain before decode** (it is a header/UTTER field, not a runtime free variable —
this is what makes the falsifier bite). A whole-utterance decision = REFUSE iff the **first** decode
step abstains (the model has nothing confident to even begin saying); ABSTAIN-MID is the longer,
deferred variant (see Out of scope).

Why top-1 prob and not entropy: entropy needs `fxln` over the full vector (slower, and the
range-reduction in `fxln` already exists but adds surface for cross-ISA drift). Top-1 prob is a
single `l_vmax` over an already-normalized vector — minimal new arithmetic, and the `≥` vs `>`
boundary is the *only* new cross-language agreement point (mirror the `lm4_argmax` strict-`>`
convention from line 829 so ties resolve identically; document it like the foreign verifier already
documents argmax at line 41).

### 2. The honest-empty output is a *fixed, content-free sentinel*

When the decision is REFUSE, the model emits **no generated tokens**. The honest-empty answer is a
fixed sentinel string committed once in the header (e.g. `REFUSE_SENTINEL = "<<honest-empty>>"`,
ASCII-only per the `.asciz` rule). Its commitment is `e_hex = sha256_hex REFUSE_SENTINEL`. There is
**no** `t_hex` over fabricated tokens — that is the whole point: the chain commits the *absence* of a
confident saying, not a manufactured one.

### 3. A new ledger record: `REFUSE` (sibling of `UTTER`)

Mirror the `UTTER` construction (lines 956-965) exactly, swapping the spoken commitment for the
refusal evidence so the link is reconstructible by the foreign witness:

```
-- decision committed: c_hex = SHA-256 of "REFUSE|tau|conf0|gcap" canonical decision tuple
-- conf0 = ref_conf (forward of prompt seed)   -- the Q.24 top-1 prob that fell below tau
ref_link_str = cat [head_link, "|REFUSE|", prompt_hex, "|", show cwin, "|",
                    show tau, "|", show conf0, "|", w_hex_final, "|", e_hex]
ref_link_b   = sha256 ref_link_str
rsig         = ed25519_sign seed ref_link_b 32      -- same LOCAL/DEV key path as usig
```

Ledger line: `REFUSE prompt_hex cwin tau conf0 w_hex e_hex prev_hex link_hex sig_hex`. It chains onto
`head_link` exactly as the `UTTER` record does, and `prev = head` is checked identically.

Committing `conf0` (the actual top-1 probability) is load-bearing: it lets the verifier confirm the
refusal was **earned by the logits** (`conf0 < tau`), not asserted. A refusal whose committed
`conf0 ≥ tau` is self-contradictory and must be rejected.

### 4. The OOD prompt is committed by the *train-side SHA only*

So "this prompt is genuinely out of corpus" is provable, the refusal-prompt's `prompt_hex` is
checked against the corpus tokenization the way rung 24 commits its SPLIT: the verifier confirms the
refusal prompt's first OOV character maps to **no** in-corpus vocab token, OR (simpler first cut)
that the refusal prompt is a held-out line whose SHA is **not** in the committed corpus SHA set.
First cut on the one-line corpus: an OOD prompt is one containing a character absent from `vocab`
(`str_find c vocab == -1`), which the model provably never saw — a clean, foreign-checkable OOD
witness with no new corpus machinery.

### 5. Foreign witness extension (`utterance_foreign_check.py`)

The Python re-verifier already re-derives weights and re-runs the decode. Add a `REFUSE`-record
branch that:
- re-runs `forward` on the refusal prompt's seed window,
- recomputes `conf0` from its own softmax + max (independent reimplementation of `ref_conf`),
- asserts `conf0 < tau` (decision earned), `conf0` matches the committed value bit-for-bit,
- reconstructs `ref_link_str`, verifies `rsig` under the ledger pubkey,
- and **independently** confirms the in-corpus control prompt would NOT have abstained
  (its recomputed `conf0_pos ≥ tau`).

---

## The gate (must pass)

A single run produces a chain with **both** record types and the gate ANDs:

| flag | meaning |
|---|---|
| `okRefSig`     | the `REFUSE` record's Ed25519 sig verifies under the ledger pubkey |
| `okRefEarned`  | committed `conf0 < tau` AND `conf0` == verifier-recomputed top-1 prob (refusal earned by the logits, not asserted) |
| `okRefChain`   | `REFUSE.prev == training head_link` (chains like `UTTER`) |
| `okRefOOD`     | the refusal prompt is provably OOD (contains a vocab-absent char) — the verifier reproduces this |
| `okAnswerKept` | the **in-corpus** prompt still produces a confident `UTTER` whose `conf0_pos ≥ tau` (refusal didn't eat real answers) |
| `okRefReproduce` | foreign witness re-derives `conf0`, the decision, `e_hex`, and the link bit-for-bit |

Calibration is **stated as a function of vocab**, mirroring rung 24's `T`-as-a-function rule: `tau`
must sit strictly between the random-baseline top-1 prob (`16777216 / vsize`, what an untrained model
gives) and the trained in-corpus `conf0_pos`. A `tau` outside that band is a rigged gate and the
run must abort at decision time (the define-success-before-training discipline).

---

## The falsifier (must be able to FAIL — both directions)

A rung without a falsifier is not a rung. This seam needs *two*, because dishonesty here is
two-sided:

**F1 — Fabrication (the synthetic-evidence sin).** Force the decision layer to emit a confident
`UTTER` on the OOD prompt anyway (set `tau = 0`, or bypass `ref_conf` and let `lm4_gen` run as
today). The verifier recomputes `conf0` for the OOD prompt, finds `conf0 < tau_committed`, and the
record is an `UTTER` not a `REFUSE` → the chain attests a confident answer the logits did not
support → **gate fails** (the committed-`conf0`-vs-decision check contradicts). This is the
honest-empty-state rule made cryptographic: a fabricated answer on an unknown prompt is *rejectable*.

**F2 — Lazy refusal (refusal as a free pass).** Force a `REFUSE` record on the **in-corpus** prompt
(`tau` set absurdly high, e.g. `16777217 > 1.0`, so even a peaked logit abstains). The verifier
recomputes `conf0_pos` for the in-corpus prompt, finds `conf0_pos ≥ tau_honest` would have held, and
`okAnswerKept` fails → a model that refuses everything cannot pass. This forecloses "refuse always"
as a trivial 100%-honest strategy.

**F3 — Forged decision evidence.** Tamper the committed `conf0` (or `tau`, or `e_hex`) by one digit
while keeping `rsig` → the reconstructed `ref_link_str` changes → `rsig` fails to verify → reject.
Mirror of the existing `okForgeChain` control (line 970): the cryptographic commitment, not output
divergence, is the guarantee.

Each falsifier flips exactly one knob and the gate that exists for it must drop to 0.

---

## Rail traps this implementation will hit (pre-flighted)

- **No short-circuit (`&&`/`||`).** The two-sided gate (`okRefEarned` needs `conf0 < tau` AND a hash
  equality) must be nested `if/then/else`, not `&&`. See `lm4_clipg` (line 611) for the nested
  pattern already in-file.
- **`ref_conf` is pure list arithmetic** — `l_softmax` + `l_vmax` are already in the file and already
  foreign-mirrored; no new self-loop accumulator, so the self-loop cross-dep-arg miscompile is
  dodged for free.
- **`tau` / `conf0` are Q.24 immediates threaded as runtime values**, exactly like `s` and `isd`
  (lines 879-884) — never a big literal in comparison-operand position (the documented assemble
  failure). Seed them via `arr_set` / `arr_get` if they ever exceed the safe immediate range.
- **ASCII-only sentinel** (`REFUSE_SENTINEL`) since it flows into `.asciz` via the ledger.
- **Arena discipline**: the extra OOD forward pass is one `lm4_forward`; bracket the
  in-corpus-vs-OOD probe pair in `arena_mark`/`arena_reset` like `lm4_emit_all` (line 851) if it
  grows.
- **`tau` band check abort** is computed pre-decode → integer immediates, like the tamper/wrong-key
  probes at lines 922-932.

---

## Out of scope (named, not hidden — deferral with evidence)

- **Mid-sequence abstention** ("answered 3 tokens then honestly stopped") needs a per-step exit in
  `lm4_gen` and a variable-length `t_hex` — that collides head-on with seam #1 (long/variable-length
  generation, the O(N²) `bytes_to_str` cap). First cut decides at step 0 only. Verified by reading
  `lm4_gen` (line 832): it has no early-exit and adding one is the variable-length-generation seam,
  not this one.
- **Refusal for *safety/harm* reasons** (vs *epistemic* "I don't know"). This seam attests epistemic
  honest-empty only. Loaded-vertical refusals are an architectural-whitelist concern
  (`feedback_loaded_vertical_design.md`), a different mechanism, deliberately not conflated.
- **Calibration *quality*** (is `tau` well-chosen across many prompts?) overlaps seam #3 (numeric
  faithfulness at scale) and the rung-24 holdout. This seam proves the decision is *attestable and
  earned*, not that the model's calibration is *good* — the honest framing.

---

## Artifact

This file is the skeleton. The implementation lands as a `tools/bitexact/attested_refusal.rail`
variant of `attested_utterance.rail` (REFUSE record + `ref_conf` + the two-sided gate) plus a
`refusal_foreign_check.py` branch in the existing verifier. Reuse the `lm10` transformer
(`lm4_forward`, `l_softmax`, `l_vmax`, `ed25519_*`) verbatim; the new surface is ~40 lines of
decision + record + gate code, mirroring the `UTTER` block (lines 949-975) exactly.
