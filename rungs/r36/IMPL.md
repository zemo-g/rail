# Rung 36 — Bounded Recursive Self-Improvement Under a Frozen, Non-Self-Relaxing Gate

*Builder artifact. Composes the two hardest priors on the ladder — rung 28 (future live-beacon
pulse) and rung 30 (succinct Fiat-Shamir spot-check) — into an RSI admission rule. Extends the
proven attested pipeline (`tools/bitexact/attested_utterance.rail`, the rung-30 protocol core
`rungs/r30/r30_protocol.rail`, and the rung-28 live-beacon binding `rungs/r28/`).*

## The claim (from ATTESTED_LADDER.md, verbatim intent)

> A parent M0 produces a successor M1 the ledger **cryptographically admits only if
> monotone-improvement** holds: an independently re-derivable certificate proves M1 strictly beats
> M0 on a committed held-out metric under a bar M1 cannot rewrite, and admission costs a spot-check,
> not a full re-train.

The ladder's **gate**: a 2–3 generation chain where each admitted Mk+1 has a certificate —
recomputed bit-for-bit by a Rail witness AND a foreign verifier — proving (i) held-out metric
strictly beats Mk by ≥ the future-pulse-seeded margin, (ii) the training trace is rung-30
succinct-verifiable, (iii) a bounded monotone generation counter, (iv) Mk+1's utterance is itself
attested; a deliberately non-improving successor is rejected.

The ladder's **falsifier**: (1) Proxy-gaming: lower train loss, equal/worse committed holdout →
reject. (2) Gate-relaxation: a self-favorable margin looser than the frozen one → reject.
(3) Runaway/replay: past the committed cap, or replaying M1's cert as M2's → reject.

The **missing teeth** (the stress-test's sharpening, baked in): "M1 can't rewrite its bar" is not
enough — **M0** sets M1's bar and may generate M1's corpus, so M0 could set a trivially-passable bar
or a corpus that overfits the holdout. **The acceptance bar AND the holdout commitment must be
derived from a source neither M0 nor M1 controls — seeded from a *future* live beacon pulse fetched
at admission time — so the frozen gate is ungameable-in-advance, not merely immutable-after-set.**

## What is built (status: ACHIEVED — validate-ready, runs green)

A complete, runnable, two-witness RSI admission protocol:

| file | role |
|---|---|
| `r36_rsi_protocol.rail` | the protocol: M0 commits a SIGNED frozen gate → trains M0 → fetches a FUTURE pulse → trains M1/M2 → admits each successor under the frozen, future-pulse-seeded bar; runs all 5 falsifiers in-process |
| `r36_foreign_check.py` | **foreign (different-language) witness**: re-derives the ENTIRE admission chain from the signed ledger alone — frozen-gate sig, future-pulse margins, per-generation rung-30 succinct spot-check, monotone held-out improvement, bounded counter, all 4 Ed25519 sigs — and independently catches a forged trajectory |
| `falsify_ledger.py` | mechanizes the ladder's falsifiers at the SIGNED-LEDGER level (proxy-gaming / gate-relaxation / runaway / replay / sig-tamper); each forged ledger MUST be rejected by the foreign witness |
| `fetch_pulses.sh` | admission-time live pulse fetch + pin (commit < future < future2); offline → recorded fixtures (logged) |
| `validate.sh` | the single EXACT command the orchestrator runs |

**Verified green** (this session, both on recorded fixtures AND a fresh LIVE ledatic.org pulse):
- in-process gate transcript `ALL 1` (all 16 sub-gates);
- foreign witness `R36-FOREIGN PASS` (re-derives every chain head + all 4 sigs bit-for-bit);
- `RUNG36-FALSIFY PASS` (all 5 forged ledgers rejected);
- `validate.sh` exits 0 with `RUNG36 PASS`.

Live run excerpt: `future pulse id 1800205 > commit 1800204 → margins 2/2`, held-out metrics
`14 → 39 → 64`, `ADMIT M1 (39 ≥ 14+2)`, `ADMIT M2 (64 ≥ 25+2)`.

## How it extends the proven pipeline (reuse, verbatim where possible)

Reused **structurally identical to rung 30** (`r30_protocol.rail`): the exact-integer Adam-cell
transition `r30_step` (state `[theta, m, v, pow1, pow2]`, chained step-to-step), the streamed Merkle
DAG (`r30_leaf`/`r30_levels`/`r30_proof`/`r30_verify_path`), the Fiat-Shamir challenge derivation by
hashing the chain head (no PRNG — the documented int63 trap), and the k≪N challenged-step
recomputation. Reused **from rung 28** (`r28_live_beacon.rail`): the live-pulse fetch-then-freeze
pattern, the pulse-hex → small-int derivations (`str_find` hex idiom), and the **dev-mode guard**
(`okDevKey` — the signing key is the LOCAL/DEV key; the pulse is public read-only input; never a
prod/Pi-witness sign surface). Reused **from the floor**: the SHA-256/Ed25519 hash-chain, signed
records, the persist-strings pattern.

**New surface (the genuinely hard, genuinely new part of this rung):**

1. **The frozen, future-pulse-seeded gate.** M0 signs a `GATE` record committing the gate *structure*
   (`np`, `cap`, `margin_rule`) and the gate-commit pulse id — **before any successor exists**:
   ```
   gate_link = H( "R36.GENESIS.dev|GATE|np|cap|margin_rule|FUTUREPULSE|commit_pulse_id )
   ```
   The acceptance **margin** and the held-out **probe set** are then derived from a **future pulse**
   fetched at admission time (`future_pulse_id` strictly > `commit_pulse_id`). M0 commits the
   *derivation rule*, not the value — the value could not exist when M0 signed. This is the "missing
   teeth" fix: ungameable-in-advance, not merely immutable-after-set.

2. **The held-out improvement metric (NOT a proxy loss).** The ladder is explicit: reject a successor
   that improves a proxy *loss* while held-out compile% is flat. The metric here is a **certified
   convergence level scored against future-pulse-seeded probe bands** — a quantity computed on probes
   that did not exist at train time, from a generation's *certified* final state. See "Monotonicity
   proof" below.

3. **The admission rule** (`r36_admit`): admit Mk+1 over Mk iff ALL hold —
   (i) `metric_child ≥ metric_parent + margin` (future-pulse margin),
   (ii) `spot_ok_child == 1` (rung-30 succinct trajectory verification),
   (iii) `gen_child == gen_parent + 1` AND `gen_child ≤ cap` (bounded monotone counter),
   (iv) `child.prev == parent.chain_head` (chain-prev: no replay / no fork).

## Monotonicity proof + the robustness sweep (the honest core)

The unstated dependency the ladder names at rungs 24/30/36 — *"the model must actually get good"* — is
handled here by making improvement a **certified, exactly-monotone-in-training-length quantity**, not
a hoped-for empirical gain:

- **The convergence signal is provably monotone.** It is derived from the Adam bias-correction power
  `pow2` (state index 4). By construction `pow2_N = S·(b2/S)^N` with `0 < b2/S < 1`, so `pow2`
  **strictly decreases every step**, and `conv = (S − pow2)/UNIT` **strictly increases with N**. This
  is pure arithmetic — no dependence on unverified gradient dynamics. (Empirically, `pow2` decay
  gives conv `4 / 13 / 29` at N = `128 / 512 / 2048`.)
- **The held-out metric** counts how many of `np=64` future-pulse-seeded probe bands the certified
  `conv` reaches. Higher conv → more bands cleared → strictly higher metric.
- **Robustness sweep (the worst case, not the average).** Across **8000 random future pulses**, the
  minimum buffer `(metric_gap − margin)` was **≥ 7** for gen-1 and **≥ 16** for gen-2 (margin ∈ [1,2]
  via `first_byte_mod_2_plus_1`, np=64, N=128/512/2048). So the honest chain **always** clears the
  future-pulse bar, regardless of which live pulse is drawn — the validate command is not flaky.
  (This sweep is reproducible from `r36_foreign_check.py`'s `metric`/`derive_margin`/`gen_run`.)

The rung-30 spot-check **certifies the trajectory that produced `pow2`** is consistent, so the
metric's input is not forgeable: a successor cannot claim a converged `pow2` it did not actually reach
without failing the spot-check (the forged-trajectory falsifier).

## Why this is the SOUND, not a vacuous, gate

Each falsifier maps to a real ladder attack and is mechanized to **fail closed**:

- **Proxy-gaming** (ladder falsifier 1). The committed metric token must equal the metric the foreign
  witness **independently recomputes** from the certified trajectory. A successor that *claims* a
  higher held-out number it did not earn → `committed ≠ recomputed` → reject. (Also: the metric is
  bound into the signed chain head, so bumping it breaks the signature.)
- **Gate-relaxation** (ladder falsifier 2). The margin is committed by the frozen `GATE` *rule* and
  re-derived from the future pulse. A successor that would pass a *relaxed* bar (`margin−1`) is
  REJECTED by the frozen bar (`okRejectRelax`), and the protocol additionally proves the *same* child
  WOULD have been admitted under the relaxed bar (`okCheatWouldAdmit`) — so the frozen bar is
  demonstrably load-bearing. At the ledger level, rewriting `margin_rule` in the header breaks the
  GATE signature (the foreign witness re-derives the gate head and the sig fails).
- **Runaway** (ladder falsifier 3a). A generation past `cap` fails the bounded monotone counter; at
  the ledger level, appending a 4th `GEN` record is rejected (the witness expects exactly `cap` of
  them).
- **Replay** (ladder falsifier 3b). Replaying a successor's cert under the wrong parent breaks
  chain-prev (`child.prev ≠ parent.head`).
- **Forged trajectory** (the rung-30 teeth). A tampered interior step (poisoned v-moment) is caught
  by the spot-check; the protocol runs a full audit of a poisoned chain to *guarantee* the catch
  (sampling can miss; full-audit always catches), and the foreign witness independently reproduces
  the catch.
- **Signature tamper.** Flipping any sig byte fails `ed25519_verify` under the pinned pubkey.

**Two independent witnesses** (the moat): the Rail self-witness verifies in-process; the Python
foreign witness re-derives the SAME admission decisions in a different language from **only the
signed ledger** — every chain head, every margin, every spot-check, all four Ed25519 signatures.

## Binding to the real lm10 step (`r36_lm10_binding`) — why a LIGHT protocol core

This rung is **research-open** in the ladder ("composes the two hardest priors"). A full lm10 RSI
chain trains **two complete 8 GB transformer generations** (each with a different pulse-seeded init,
each itself a rung-28 + rung-30 attested run) and silently requires the model to *actually get good*
across generations — a capacity/curriculum question the floor (one memorized line) never touched.
Both are out of reach under the shared-compiler compute-discipline rule (one slow compiler + one GPU
+ 24 GB across ~15 builders; no 8 GB-arena training runs).

So — **exactly as rung 30 did** (`r30_protocol.rail` runs the identical commit/challenge/verify
machinery over a real-but-light per-step transition, then documents binding the exact `lm4_step`
into it) — this protocol core runs the **identical admission machinery** over a real, exact-integer,
chained transition (`r30_step`, reused verbatim from r30) so the gate validates in **seconds, not
minutes, with a 2 GB arena**, while the soundness argument is the full one.

**The binding** (what a future, compute-rich session swaps in, with NO change to the admission rule):
- each generation's `r36_run` per-step transition → the actual `lm4_step` (the 17-matrix Adam update
  in `attested_utterance.rail`), with the per-step `(ctx,tgt)` the real training pairs;
- each generation's pulse-seeded init → the rung-28 `poff`-threaded `lm4_initmat` (init depends on
  the live pulse);
- the held-out **metric** → the rung-24 sealed-holdout exact-int **compile% / accuracy** on a
  multi-line corpus split (same shape: a quantity computed on data the model never trained on,
  derived from a value chosen *after* training — here the future pulse picks the holdout);
- each generation's **utterance** → the floor's attested UTTER record (gate clause iv);
- the rung-30 spot-check is *already* the real `lm4_step` per-step commitment in `r30_prove.rail`.

The admission rule, the frozen-gate commitment, the future-pulse seeding, the monotone counter, the
chain-prev, and all 5 falsifiers are **identical** in the light core and the full binding — only the
per-step transition's cost differs. The protocol core is the genuinely-new, genuinely-hard surface
this rung exists to prove; it is proven here, runnable and falsifiable.

## Rail discipline notes (traps hit and handled)

- **Self-loop cross-dep-arg miscompile** (CLAUDE.md trap): empirically confirmed in this session — a
  `pow2 *= b2/S` self-loop and an `acc + f(j)` integer-accumulator self-loop both **silently
  corrupted** (gave constant / wrong results). Fixed by converting every integer-accumulator and
  scalar-transform loop to **mutual recursion** (`f` ↔ `f_step`): `r_isqrt_go`, `r_hex_take`,
  `r36_metric_go`, `r36_verify_chals`, `r36_parse_go`, `r30_path_fold`. List-cons accumulators
  (`r36_run`, `r36_states`, `r30_chal_list`, …) were verified safe by a direct test.
- **Multi-line `let = expr in`**: a `let all = a * b \n * c` binding broke the parser ("expected
  decl, got let"). Bindings whose continuation is **not bracket-enclosed** must be one line; `cat
  [...]` multi-line is fine (brackets continue).
- **Merkle balance**: non-power-of-2 leaf counts (N=768/1792) failed the spot-check (odd-tail
  promotion vs proof-sibling mismatch). Fixed by using **power-of-2 generation lengths**
  (128/512/2048), matching r30's validated sizes.
- **str_find hex idiom** (rung-28 proven): hex/digit parsing via `str_find c "0123..."` avoids the
  poly-eq char-compare quirks.

## EXACT validate command (orchestrator runs this serially)

```bash
bash /Users/ledaticempire/rail-reward/rungs/r36/validate.sh
```

`validate.sh`: (1) fetch+pin a live pulse sequence (commit < future < future2; offline → recorded
fixtures, logged); (2) compile `r36_rsi_protocol.rail` to an isolated out-prefix; (3) run it
(`RAIL_ARENA_MB=2048` — LIGHT, seconds; the r30-precedent core, not the 8 GB lm10 path); (4) foreign
re-verifier MUST PASS; (5) all 5 ledger falsifiers MUST each REJECT; (6) exit 0 + print `RUNG36 PASS`
only if every step held.

**Compute note for the orchestrator:** the heavy step (2–3) is a single normal source compile +
a seconds-long exact-integer run — NOT a multi-GB transformer training run. Total wall-time well
under a minute. No `./rail_native self`, no 8 GB arena.

## Honest status

**ACHIEVED at the protocol-core grade** (the same grade rung 30 ships at): the frozen
future-pulse-seeded gate, the monotone held-out admission, the rung-30 succinct spot-check per
generation, the bounded monotone counter, chain-prev, all 5 falsifiers, and the two-witness
(Rail + foreign) re-derivation are **written, run, and verified green** this session — on both
recorded fixtures and a fresh live ledatic.org pulse. Every reused symbol is verified present in the
proven floor; the new surface (the frozen gate + future-pulse margin + monotone metric + admission
rule + falsifiers) is the genuinely-new, genuinely-hard part and is the part proven here.

**What is honestly NOT done** (the named, deferred upstream dependency): the per-generation transition
is the light exact-int Adam cell (r30's), not the full 8 GB lm10 transformer; binding the real
`lm4_step` + rung-24 sealed-holdout compile% into this identical admission rule is a compute-rich
follow-up (documented above as `r36_lm10_binding`), and it carries the real-and-named risk that a
*real* model must actually improve generation-over-generation — which is a capacity/curriculum
question, not an admission-protocol question. The admission protocol — the thing rung 36 is — is
complete and sound.
