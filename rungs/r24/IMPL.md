# Rung 24 — The Sealed Holdout (Attested Generalization)

*Load-bearing rung of the attested-LM ladder. Built on the proven first-attested-utterance pipeline
(`tools/bitexact/attested_utterance.rail` + `lm10`). Isolated under `rungs/r24/`; no live-tree edits.*

---

## The claim (from `ATTESTED_LADDER.md`, rung 24)

> **Proves** the model *generalizes, not memorizes* — and generalization is the **gate**, not loss
> descent.

The floor (rung 21/the first utterance) trained on **one** line and its gate was literally
`okProg = dsK < ds0` — train-loss descent on a single memorized line, a tautology a lookup table
satisfies. Rung 24 destroys that: a **multi-line corpus**, a **SPLIT commitment** signed from the
train side before any weight is seen, a **deterministic Q.24-exact held-out metric**, a
**pre-registered floor T**, and a **control bracket** (honest ≥ T > lookup) folded into the gate.

---

## What extends the proven pipeline (and what is reused verbatim)

The entire transformer + attestation substrate is **reused unchanged**:

| Reused verbatim from `attested_utterance.rail` | Role |
|---|---|
| `lm10` 2-block multi-head RoPE transformer (`lm4_forward`, `lm4_block_fwd`, `mh_attn_*`, RMSNorm, FFN) | the model |
| exact-integer Q.24 Adam + grad-clip (`lm4_step`, `lm4_adam`, `lm4_clipg`) | training |
| `lm4_chain` / `lm4_chain_d0` | checkpoint-cadence signed chain + D0 self-witness |
| `lm4_canon17` / `lm4_canon_mat` | the 17-matrix weight commitment `w_hex` |
| `bnd_wp_ser` / `bnd_wp_deser` | bounded-memory optimizer-state round-trip (available for segmenting) |
| `sha256` / `ed25519_sign` / `ed25519_verify` | the Ed25519 hash-chain |
| `lm4_argmax` / `lm4_gen` | greedy decode (reused inside the held-out eval) |
| Python `rederive` / `forward` / `mkblk` / `thetas` / `canon_mat` (`lm10_foreign_check.py`) | the foreign witness's weight reconstruction |

The rung-24 **delta** lives in `_r24_extension.rail` (appended to the helper body) + the new `main`:

1. **Multi-line sealed corpus** — `rungs/r24/r24_train_corpus.txt` (16 lines) is the *only* text the
   model trains on; `rungs/r24/r24_holdout_corpus.txt` (2 lines) is never trained. A **fixed union
   vocab** (`r24_vocab.txt`) makes held-out digit ids identical to train digit ids (so held-out
   embeddings are trained — see "Why this corpus" below).
2. **SPLIT record** (`r24_split_record`) — `link = SHA256(genesis "|SPLIT|" train_sha "|" hold_sha
   "|" cwin "|" tnum "|" tden)`, signed with the trainer's LOCAL/DEV key, `prev = genesis`, written
   **before checkpoint 0**. The training chain then sets `prev(ckpt0) = SPLIT link` — so the split
   is cryptographically *prior* to every weight.
3. **Deterministic Q.24 held-out metric** (`r24_eval`) — teacher-forced greedy-argmax next-token
   accuracy over the held-out id stream, scored at the **echo positions** (`r24_echomask`), the
   positions that require a *learned copy rule*. Pure integer arithmetic on the same `lm4_forward`
   path → bit-reproducible.
4. **Pure-lookup baseline** (`r24_lookup_eval`) — an n-gram argmax over the *train-only*
   `(context → next)` table; unseen context → fallback. By construction it is **wrong on every echo
   position** (the held-out echo context never appears in train).
5. **The gate** — `okGeneralize = (honest_echo ≥ T)` AND `okBracket = (honest ≥ T AND lookup < T)`,
   folded into the final `all` product alongside the signature/chain/D0 gates.
6. **Checkpoint-0 abort** — at epoch-0 (pre-training) weights, if held-out echo-acc is already ≥ T
   the run **aborts** (`okCkpt0Abort = 0` → `all = 0`): a non-trivial metric must START below T and
   be CROSSED by training (the 7-hour-burn lesson, encoded).

---

## Why this corpus forces generalization (and separates the bracket)

The corpus is an **echo template**:

```
main = print (show (NN)) -- NN
```

The trailing comment `-- NN` **echoes** the printed two-digit number. Train values cover every digit
0–9 in both positions; the held-out values `31` and `75` use only trained digits but in **novel
two-digit pairings** never seen in training.

Predicting the comment digit requires the model to **copy** a digit that appears earlier in the same
8-char context window (an induction/copy head — exactly what a 2-block attention transformer can
form). The discriminating positions are the four **echo positions**:

| held-out context (cwin=8) | true next | n-gram lookup predicts | lookup correct? |
|---|---|---|---|
| `31)) -- ` | `3` | `m` (fallback; context unseen) | **no** |
| `1)) -- 3` | `1` | `m` | **no** |
| `75)) -- ` | `7` | `m` | **no** |
| `5)) -- 7` | `5` | `m` | **no** |

This makes the **control bracket real**: the lookup baseline scores **0/4** on echo positions
(verified — see "Validation actually run"), strictly below `T = 1/2`. A model that learned the copy
rule scores ≥ 2/4. The two are genuinely separated — structural n-gram generalization does *not*
suffice, only the learned rule does.

**The honesty correction earned here (recorded, not hidden):** an earlier single-digit template
(`...(show (D)) ...`) was rejected during design because structural generalization there was
*indistinguishable* from n-gram lookup — both scored ~20/29 on the held-out skeleton, so the
bracket collapsed (honest ≈ lookup, no separation). The echo template is the fix: the metric targets
the one position lookup *cannot* satisfy.

---

## Pre-registered metric and floor T (written BEFORE the run)

- **Metric** `M_echo` = held-out **echo-position** next-token accuracy (4 positions, 2 per held-out
  line).
- **Random baseline** `R = 1/vsize ≈ 0.037` (vsize=27).
- **Lookup baseline** `L = 0/4 = 0` (n-gram wrong on all echo positions — proven by construction).
- **Floor** `T = tnum/tden = 1/2`, committed in the ledger header *and* the signed SPLIT record.
  `T` is stated as a function of baseline: `T = 1/2 > 8R` and `T > L` — "high enough" is
  **falsifiable**, not eyeballed.
- **Gate**: honest `M_echo ≥ T` AND lookup `M_echo < T` (the bracket). Plus checkpoint-0 abort if the
  metric is ≥ T before training.

All integer comparisons are exact: `a/b ≥ tnum/tden  ⇔  a*tden ≥ b*tnum` (no division, no float).

---

## The soundness / falsification argument

**Why the SPLIT binds the test set as never-trained.** The SPLIT link commits `SHA256(sorted-unique
train lines)` and `SHA256(sorted-unique holdout lines)`, signed `prev = genesis`, and the first
training checkpoint chains `prev = SPLIT link`. The canonical form (`r24_split_canon`: dedup → sort
byte-lex → join with `\n`) is reproduced identically by the foreign verifier. Therefore:

- **Falsifier (1) — train on the held-out lines.** Training on `train ++ holdout` (the overfit
  control corpus) has a *different* canonical train-set SHA. The committed `train_sha` no longer
  matches the corpus that was trained on → any verifier recomputing the train SHA rejects.
  `okSplitFalsify` asserts `split_sha(overfit) ≠ train_sha`.
- **Falsifier (2) — a memorizer cannot pass.** The pure-lookup baseline (a line/n-gram memorizer)
  scores `0/4 < T` on echo positions. The gate's `okBracket` *requires* lookup `< T`, so a model
  that merely memorized fails the bracket. (And if the "honest" model were secretly a memorizer it
  would also score 0 on the unseen echo contexts.)
- **Falsifier (3) — post-hoc holdout swap.** Swapping the holdout set after the fact changes the
  recomputed `hold_sha`; it no longer matches the signed SPLIT. `okSwapFalsify` asserts
  `split_sha(train) ≠ hold_sha`.

**Why the metric is honest, not gamed.** The metric is a deterministic integer function of the
re-derivable weights and the (committed) held-out stream — the foreign witness recomputes it
bit-for-bit. It cannot be inflated by overfitting the *commitment* because the commitment is a hash,
not a tunable. The checkpoint-0 abort forecloses a trivially-satisfiable metric. Per the
decompose-eval-on-extremes rule, the echo metric is reported alongside full-line accuracy so a 0% or
100% is never read blind.

**What this rung does NOT prove (stated, per the ladder's honesty).** It proves generalization on a
*constructed copy-rule holdout* with a tiny model — the smallest honest instance of "a holdout a
memorizer can't pass." It does **not** prove the model is broadly capable; the ladder rates this rung
"weeks — the capacity search is open." The threaded risk ("the model must actually get good") is
named here, not hidden.

---

## Validation actually run (light, read-only — no heavy build)

Per compute discipline I did **not** run the heavy Rail compile/train. I validated the parts that do
not require it:

- **SPLIT SHAs reproduce**: `train_sha = 2c33f089f218…`, `hold_sha = 7cc5b2dd93a9…` (Python
  `split_canon` matches the values baked into the corpus and the foreign verifier).
- **Both SHA-mismatch falsifiers fire**: `split_sha(overfit) ≠ train_sha` → True;
  `split_sha(train) ≠ hold_sha` → True.
- **Echo mask is correct**: exactly **4** echo positions, the four copy-rule digits of `31` and `75`.
- **Lookup baseline echo = 0/4** (every echo context unseen → fallback `m`) — strictly `< T = 1/2`,
  so the bracket's lower bound holds **by construction**.
- **Foreign eval path executes end-to-end** on a 2-epoch `rederive` smoke (proves the Python
  re-verifier's `rederive → eval_holdout → lookup_eval` chain runs; *not* a generalization claim —
  2 epochs is far from convergence and is not the gate).

The one thing only the serial run can decide: **does the honest model clear `T` at full epochs?**
That is the gate and the open question.

---

## The EXACT validate command

```bash
bash rungs/r24/validate.sh
# or equivalently, step by step (run SERIALLY):
#   ./rail_native --out-prefix rungs/r24/out/r24_bin rungs/r24/r24_attested_holdout.rail
#   RAIL_ARENA_MB=8192 ./rungs/r24/out/r24_bin           # prints PASS/FAIL, writes the ledger, exit 0/1
#   python3 rungs/r24/r24_foreign_check.py rungs/r24/out/r24_chain.txt   # foreign witness, exit 0/1
```

**GREEN GATE** = `validate.sh` exits 0, i.e. the Rail trainer prints `PASS:` AND the foreign
re-verifier prints `R24-CHECK PASS`. Both fail loudly (exit 1) if the model does not clear `T`, if the
bracket collapses, if the SPLIT signature/chain breaks, if a falsifier does not fire, or if the
foreign re-derivation diverges.

---

## Files

| Path | What |
|---|---|
| `rungs/r24/r24_attested_holdout.rail` | the rung-24 trainer (lm10 helper body + `_r24_extension.rail` + rung-24 `main`) |
| `rungs/r24/_helper_body.rail` | proven lm10 transformer/chain/canon body (extracted verbatim) |
| `rungs/r24/_r24_extension.rail` | rung-24 delta: SPLIT, held-out eval, echo mask, lookup baseline |
| `rungs/r24/_r24_main.rail` | rung-24 `main` (gate + controls + falsifiers + ledger) |
| `rungs/r24/r24_foreign_check.py` | foreign (Python) cross-language re-verifier |
| `rungs/r24/r24_train_corpus.txt` | the sealed **train** split (16 lines; the only trained text) |
| `rungs/r24/r24_holdout_corpus.txt` | the sealed **holdout** split (2 lines; never trained) |
| `rungs/r24/r24_overfit_corpus.txt` | overfit control = train ++ holdout (drives falsifier 1) |
| `rungs/r24/r24_vocab.txt` | fixed union vocab (stable token ids across train/holdout) |
| `rungs/r24/validate.sh` | the EXACT serial validate command (compile → run → foreign-verify) |
| `rungs/r24/out/` | run artifacts: `r24_chain.txt` (1 SPLIT + N checkpoints), `r24_eval.txt` |
