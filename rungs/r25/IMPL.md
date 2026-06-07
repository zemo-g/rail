# Rung 25 — Attested Sampling (chain-seeded exact-integer categorical draw)

**Status: VALIDATE-READY (DESIGNED + complete code; not yet run — heavy build deferred to the
orchestrator per compute discipline).**

The model no longer speaks by greedy argmax. It speaks by **exact-integer categorical sampling**,
yet the utterance is still **bit-reproducible and signed**, because every draw is a deterministic
function of an RNG key committed into the chain.

---

## What this rung proves (from `ATTESTED_LADDER.md`)

> Proves the model speaks by *exact-integer categorical sampling* (not greedy), yet the utterance is
> bit-reproducible and signed because every draw is a deterministic function of an RNG key committed
> into the chain.

The floor (rung 21, `ATTESTED_UTTERANCE.md`) spoke by `lm4_argmax` — trivially deterministic. This
rung replaces that single token-choice step with a chain-seeded categorical draw and re-closes the
whole loop: Rail self-witness + a **foreign Python re-implementation** both re-derive the RNG stream,
**redraw every token**, and reproduce the signed `t_hex` bit-for-bit.

---

## How it extends the proven pipeline (verbatim reuse)

The entire lm10 transformer + attestation machinery is reused **unchanged**:

- **Transformer**: 2 stacked multi-head RoPE pre-norm blocks, exact-int Adam, gpu/cpu readout GEMM —
  every `lm4_*`, `l_*`, `rn_*`, `mh_*`, `bnd_*`, `gpu_*` helper is **copied verbatim** from
  `tools/bitexact/attested_utterance.rail` (lines 35–868, before its `main`).
- **Training**: `lm4_chain` (signed checkpoints) and `lm4_chain_d0` (the independent re-run) are
  called **identically** to the floor. Same corpus pin, same Q.24 arithmetic, same Ed25519 chain.
- **Serialization / canon**: `lm4_canon17`, `utt_ids_canon`, `bnd_wp_ser/deser` unchanged.

**Why copied inline, not `import`ed:** Rail's `import` runs `filter_exports`, which only strips
functions whose names start with `_`. It does **not** strip `main`. Importing
`attested_utterance.rail` would pull in its `main` and collide with ours. The sibling rung
`tools/bitexact/selfemit.rail` (rung 35) hits the same wall and resolves it the same way — copy the
transformer body inline, write one's own `main`. We follow that proven pattern exactly: **zero edits
to any copied function** (verified: each reused helper has exactly one definition; the new `r25_*`
functions do not collide).

The **only new code** is in the `RUNG 25 ADDITIONS` section + the new `main`:

| New function | What it does |
|---|---|
| `r25_u rng_key_hex t` | `u_t` = first 24 bits (3 big-endian bytes) of `SHA256(rng_key_hex ++ "," ++ show t)`. In `[0, 2^24)`. |
| `r25_tscale logits invtemp` | exact-integer temperature prescale: each logit → `(logit * invtemp) / S`. `invtemp = S` is identity. |
| `r25_icdf probs u bnd` | inverse-CDF walk over `l_smnorm` prefix-sums; first idx with cumsum **strict-> u** (`bnd=0`). Clamps to last idx on truncation residual. |
| `r25_draw …` | one draw: `lm4_forward` → `r25_tscale` → `l_softmax` → `r25_icdf(u_t)`. |
| `r25_gen …` | sampled generation: gcap sliding-window draws, `t` = global step 0..gcap-1. Mirrors `lm4_gen`'s window exactly. |
| `r25_ndiff …` | non-triviality witness: counts positions where the sampled token ≠ greedy argmax of the same (scaled) logits. |

---

## The soundness argument

**Reproducibility (the saying is signed and re-derivable).**
Every token is `r25_icdf(l_softmax(r25_tscale(forward(ctx), invtemp)), r25_u(rng_key, t))`. Each
input to that pipeline is deterministic and committed:
- `forward(ctx)` uses the **attested final weights** (`w_hex` in the record, re-derived by both
  witnesses from data+config+seed).
- `invtemp` is committed in the record (and bound by the signature).
- `rng_key` is committed in the record — and is itself **chain-seeded**:
  `rng_key = SHA256(training_head ‖ "|RNGKEY|sample.v1")`, so the key is bound to the attested
  weights. A verifier recomputes it from the reproduced head and checks it equals the committed key.
- `u_t = SHA256(rng_key ‖ "," ‖ t)[0:3]` — SHA-256 counter-mode, **bit-exact and cross-ISA
  identical**. **Not a multiplicative LCG** (Rail's 63-bit tagged ints overflow — the documented
  PRNG trap whose "fix" is `awk`, which destroys determinism).

Because every input is committed/derivable and the arithmetic is exact-integer Q.24, the redraw is a
pure function of the ledger → both witnesses reproduce `t_hex` bit-for-bit. The Ed25519 signature
over `prev|USAMPLE|prompt|cwin|gcap|invtemp|ndiff|rng_key|w_hex|t_hex` binds all of it.

**The cross-language boundary contract.** The ladder warns: "the `≥` vs `>` boundary must match
cross-language or one token diverges." The canonical walk uses **strict `>`** (`bnd=0`): pick the
first index whose cumulative prefix-sum is strictly greater than `u`. `l_smnorm` uses integer
truncate-division (`(es_i * S) / z`), so `sum(l_smnorm) ≤ S`; a high `u` can exceed the final
cumsum, so the walk **clamps to the last index** (Rail: `probs == [] → idx-1`; Python:
`return len(probs)-1`). Both languages use the SAME normalizer `z` (no float re-division) and the
SAME strict-`>` + clamp. The foreign verifier reproduces the exact same integers.

**Non-triviality (not "sampling in a greedy costume").** The record commits `ndiff` = #positions
where the sampled token ≠ the greedy argmax of the SAME temperature-scaled logits. The gate requires
`ndiff > 0`. The foreign verifier **independently recomputes `ndiff`** (its own argmax, its own
draws) and asserts both `ndiff > 0` **and** `ndiff == committed`. A greedy-costume sample
(sampled==argmax everywhere) has `ndiff = 0` and fails.

---

## The gate (success criteria)

The Rail self-witness `all` and the foreign `SAMPLE-CHECK PASS` both require ALL of:

1. `okSigs` — per-checkpoint training sigs verify (floor, unchanged).
2. `okProg` — loss descent (floor, unchanged).
3. `okD0` — the independent re-train reproduces the training head bit-for-bit.
4. `okUtterSig` — the USAMPLE Ed25519 signature verifies.
5. `okUtterRepro` — re-train + **re-sample** reproduces `t_hex` bit-for-bit.
6. `okNonTrivial` — `ndiff > 0` (the sample is genuinely non-greedy).
7. Foreign witness additionally: `rngkey_ok` (key is the chain-seeded one), `ndiff_match`
   (independently recomputed `ndiff` equals committed), `utter_ok` (independent redraw → same t_hex).

---

## The falsification tests (each MUST fail the gate)

| # | Falsifier | Mechanism | Gate flag |
|---|---|---|---|
| F1 | Flip one byte of `rng_key` | A different key → different SHA-256 counter stream → redrawn ids diverge from signed `t_hex` | `okFlipKey` (Rail) / `flipkey_reject` (Py) |
| F2 | Swap the walk boundary (`≥` instead of strict `>`) | On any exact-cumsum-boundary draw a different token is chosen → ids diverge from `t_hex` | `okBoundary` / `boundary_reject` |
| F3 | Forged USAMPLE: keep `t_hex`, substitute a non-producing key | The verifier re-derives the draws **from the committed key**; a different key's redraw ≠ `t_hex` → caught | `okForgeKey` / `forgekey_reject` |
| F4 | Forged commitment: tamper `invtemp` by +1 in the link | The recorded sig is over the un-tampered link → verification of the tampered link fails | `okForgeChain` / `forge_commit_reject` |
| F5 | Greedy costume (sampled==argmax everywhere) | `ndiff = 0` → non-triviality gate fails; foreign verifier's independent argmax confirms | `okNonTrivial` / `nontrivial_ok` |
| — | LCG uniform overflows / diverges cross-ISA | Avoided by construction: SHA-256 counter-mode, never an LCG | (design-level) |

Plus the floor's `okTamper` (flipped sig rejected) and `okWrongKey` (foreign key rejected) carry
over unchanged.

---

## The genuinely open risk (named, not hidden)

Per the ladder: rung 25 "needs rung 24's non-degenerate distribution." This model **memorized a
1-line corpus**, so its logits are very peaked. The non-triviality gate (`ndiff > 0`) is the only
part that depends on the distribution actually being non-degenerate.

**Mitigation in this rung:** a HIGH sampling temperature (`invtemp = 1677721 ≈ S/10`, temp ≈ 10×)
flattens the distribution toward uniform so that across `gcap = 48` SHA-seeded draws many land off
the argmax → `ndiff > 0`. **This value is believed-sufficient, not builder-measured** (compute
discipline forbids the heavy training run). The attestation is **sound at any temperature** — only
the `ndiff > 0` gate cares about the value.

**If the validate run reports `ndiff == 0`:** lower `invtemp` further (the file comments name
`838860 ≈ S/20`; in the limit `invtemp → small` approaches a uniform draw, where `ndiff > 0` is
near-certain over 48 steps). This is a one-line edit (`let invtemp = …`) followed by a re-run; the
soundness argument and falsifiers are unchanged. The proper long-term fix is rung 24's multi-line
corpus, which yields a non-degenerate distribution at moderate temperature.

---

## How to validate (the EXACT command the orchestrator runs serially)

```bash
bash /Users/ledaticempire/rail-reward/rungs/r25/validate.sh
```

`validate.sh` (run from anywhere; it `cd`s to the repo root) does three serial steps and exits 0 iff
**both** witnesses PASS:

1. **Compile** `rungs/r25/attested_sampling.rail` with an isolated out-prefix →
   `rungs/r25/out/r25_bin` (avoids colliding with `/tmp/rail_out` and other concurrent builders).
2. **Run the Rail self-witness** with `RAIL_ARENA_MB=8192` (lm10 needs a multi-GB arena; the 512MB
   default GC-thrashes forever). Requires its `PASS:` line and exit 0.
3. **Run the foreign Python verifier** `python3 rungs/r25/sampling_foreign_check.py
   rungs/r25/out/sampling_chain.txt`. Requires `SAMPLE-CHECK PASS` and exit 0.

Expected runtime: comparable to the floor (~2–3 min for the Rail run — same training; sampling adds
two extra gcap-step decode passes + a few falsifier redraws; the foreign verifier re-derives the
full training in Python big-ints, a few seconds).

---

## Artifacts

| Path | What |
|---|---|
| `rungs/r25/attested_sampling.rail` | the trainer + sampler + attestation (lm10 body verbatim + `r25_*` additions + new `main`) |
| `rungs/r25/sampling_foreign_check.py` | the foreign cross-language re-verifier (independent inverse-CDF redraw + independent argmax) |
| `rungs/r25/validate.sh` | the serial two-witness gate (the orchestrator's entry point) |
| `rungs/r25/out/sampling_chain.txt` | (produced by the run) signed ledger: 19 checkpoints + 1 USAMPLE record |
| `rungs/r25/out/sampling.txt` | (produced by the run) the sampled words + tokens + rng_key + invtemp + ndiff + t_hex |

---

## Light checks already performed (no heavy build)

- Every reused helper (`lm4_forward`, `lm4_argmax`, `l_softmax`, `lm4_chain`, `lm4_chain_d0`,
  `lm4_canon17`, `utt_ids_canon`, `lm4_blk0_of`, …) has exactly one definition in the assembled file;
  the new `r25_*` functions have no name collisions.
- Exactly one `main`; all 8 imports present.
- `str_sub`, `char_from_int`, `sha256`, `arr_get`, `bytes_to_hex` confirmed as builtins/stdlib
  available to the file. (`str_len` does **not** exist — the F1 nibble-flip uses fixed offsets on the
  known-64-char hex key instead.)
- `validate.sh` passes `bash -n`.
- `sampling_foreign_check.py` passes `py_compile`, imports cleanly against the existing
  `lm10_foreign_check` / `bx4_foreign_check`, and `r25_u` / `r25_icdf` spot-tests behave correctly
  (deterministic, in-range, correct inverse-CDF index selection).
