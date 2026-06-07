# Rung 34 — Economic Stake over the Succinct Length-Proof

**Status: VALIDATE-READY (economic-stake-over-rung-30 variant — the defensible scope).**
The VDF variant is research-open; its protocol skeleton + soundness obligation are written below
but **not claimed** as achieved.

---

## What this rung proves (honest scope)

A served utterance carries an **economically-backed, succinctly-checkable** claim about its
training — **"these K training steps happened and chain correctly"** — bonded into a **slashable
stake** drawn from a real SDK credit balance. A constructed **fraud-proof** (exactly one opened
inconsistent step, checkable by any third party in **O(log N)**) is accepted by an independent
checker and **slashes** the bond; an **honest chain's bond is never slashable** (false-slash
resistance).

This is the ladder's explicit *split*, honored verbatim:

> **(1) "These K steps happened and chain correctly"** is rung 30 applied to a length commitment —
> *sound and shippable*; bond the verified step-count, slash on a found inconsistent step.
> **(2) "This cost ≥K sequential work that can't be shortcut"** is a VDF claim, and Adam-step
> sequentiality does **not** establish it.

**This file implements (1) and explicitly does NOT claim (2).** Section "The VDF extension" gives
the concrete protocol + soundness obligation for (2) as research-open future work.

---

## How it extends the proven pipeline

It reuses the **proven rung-30 protocol verbatim** (`rungs/r30/r30_protocol.rail`) — every line of
the per-step transition, Merkle DAG, Fiat-Shamir derivation, spot-check verifier, and single-opened-
step fraud-proof is copied unchanged into `r34_economic_stake.rail` with identical constants:

| Reused verbatim from rung 30 | Role here |
|---|---|
| `r30_step` (exact-int Q.24 Adam cell + bias powers, gradient-clip) | the per-step transition; state i depends on i−1 |
| `r30_leaf` / `r30_levels` / `r30_proof` / `r30_verify_path` | the streamed Merkle DAG over per-step states (O(log N) proofs) |
| `r30_chal` / `r30_chal_list` (Fiat-Shamir from the signed chain head, **no PRNG**) | the succinct spot-check challenges |
| `r30_verify_chals` (recompute only k≪K challenged steps + Merkle paths) | verifies the length-proof sublinearly |
| `r30_run` / `r30_states_of` (with the `poison_at` inconsistency injector) | builds honest + forged chains |

It also reuses the **same Ed25519/SHA-256 chain primitives** (`stdlib/sha256.rail`,
`stdlib/ed25519*.rail`) and the **same foreign-verifier substrate** (`bx12_foreign_check.py` for
`ed25519_verify` / `sha256_*`) that `lm10_foreign_check.py` / `utterance_foreign_check.py` use — so
Rail↔Python signature interop is already proven, not new here.

### New in rung 34 — the economic layer (only ~6 small functions added)

1. **`r34_length_proof k …`** — the rung-30 succinct length-proof, but the signed link **explicitly
   binds the claimed length K**: `link = genesis | R34-LEN | tag | K | root`. The bond is staked
   against *this* signed claim, so a prover cannot later equivocate on K (changing K changes the
   signed head).
2. **`r34_bond claim_head root k amount balance …`** — locks `amount` credits from a real credit
   balance against the signed length-claim; the bond record commits `(K, root, amount, prior
   balance)`, chained onto the claim head and **signed**. A bond exceeding the balance is **invalid**
   (`valid=0`).
3. **`r34_open states genesis levels idx`** — a third party builds a fraud-proof opening exactly one
   step: `[idx, pre_state, post_state, post_merkle_path, pre_merkle_path]`. O(log N) sized.
4. **`r34_check_fraud fp root sig_ok`** — the **independent O(log N) checker**: recompute the one
   transition from the opened pre-state, verify *both* endpoints (pre at idx−1, post at idx) are
   committed under the **signed** root, and declare FRAUD iff the transition is inconsistent **and**
   both Merkle paths check **and** the root is signed.
5. **`r34_settle avail_after locked fraud`** — applies the verdict: fraud ⇒ stake burned (balance
   stays debited); honest ⇒ stake released (balance recovers).

---

## The soundness / falsification argument

The economic stake is sound iff **slash-on-fraud** and **no-false-slash** both hold, and the
fraud-check is genuinely **third-party-checkable in O(polylog)** without re-training.

### Slash-on-fraud (the bond is forfeited when the claim is a lie)

A forged chain that claims K steps but contains an interior **inconsistent transition** (the
committed post-state at `poison_at` ≠ `r30_step(pre)`) is caught by opening exactly that step:

- `r34_check_fraud` recomputes `r30_step(pre, ctx, tgt, 1)` and compares to the committed post →
  **diverges** (`inconsistent=1`);
- the opened post-leaf is in the tree at `idx` (`post_in=1`) and the opened pre-leaf is in the tree
  at `idx−1` (`pre_in=1`) — both under the **same signed root**;
- ⇒ `fraud = inconsistent · post_in · pre_in · [sig_ok] = 1` ⇒ **slash**.

The check is **O(log N)**: one `r30_step` recompute + two Merkle-path verifications. No re-training,
no recompute of the other K−1 steps. **Any third party** holding the signed root and the opened
proof can run it. (This is exactly the rung-30 fraud-proof — `r30_full_audit_detects` proves the
inconsistency is *findable*; rung 34 makes finding it pay.)

### No-false-slash (an honest chain's bond is never slashable) — equally important

Four distinct attacks on the *slasher* are all rejected:

| Attack | Why it's rejected |
|---|---|
| **Open an honest step** (of either chain) | `r30_step(pre) == committed post` ⇒ `inconsistent=0` ⇒ fraud=0. The honest bond is **released** (balance recovers to `balance0`). |
| **Fabricate an inconsistent post-state** that never appeared | The tampered post-leaf is **not** in the committed tree ⇒ its Merkle path fails ⇒ `post_in=0` ⇒ fraud=0. A malicious slasher cannot manufacture evidence. |
| **Open under an unsigned root** (no authority) | `sig_ok=0` ⇒ `r34_check_fraud` returns 0 regardless of inconsistency. A slash requires a signed commitment. |
| **Over-stake** (bond > balance) | `r34_bond` sets `valid=0`; you cannot stake credits you do not hold. |

The asymmetry the rung demands — *"false-slash resistance is as important as slash-on-fraud"* — is
enforced by requiring **both endpoints committed under the signed root AND a genuine recompute
divergence**. Satisfying one without the other yields fraud=0.

### Why both endpoints must be committed (the pre-leaf check is load-bearing)

A naive checker that only verifies the *post*-state is in the tree would let an attacker pair a
genuine committed post with a **fabricated pre-state** chosen so that `r30_step(fabricated_pre) ≠
post` — a false fraud. Requiring the **pre-state also be the chain's own committed leaf at idx−1**
(`pre_in`) closes this: the attacker can't substitute a pre-state the prover never committed.
(idx=0's pre is the public genesis state, trusted by construction.)

### The composed economic guarantee

The bond is slashable **iff** a single-step fraud-proof exists, **iff** the rung-30 length-proof is
violated at some step. So the stake is an economic backstop on the *exact* claim the succinct
length-proof certifies: an adversary who wants the stake back must have honestly run all K steps.
The succinct spot-check (k≪K challenges, <25% of K, sublinear) gives the *probabilistic* deterrent
*before* a dispute; the fraud-proof gives the *deterministic* slash *during* a dispute.

**Honest residual (named, not hidden):** like rung 30, a *single*-step tamper escapes a *single*
round of k random spot-checks with probability `(1−1/K)^k` (≈0.91 for K=512, k=46). The economic
layer changes the game: the spot-check is the cheap pre-screen, but **the slash is driven by the
deterministic fraud-proof, not the sampled spot-check** — any honest party who recomputes and finds
*one* bad step (rung-30's `r30_full_audit_detects`, an O(N) audit any challenger can run once a
dispute is on the table) can slash. The stake makes that O(N) audit *worth running*. This is the
standard optimistic-rollup posture: cheap to assert, cheap to spot-check, expensive-once to fully
audit, and the bond pays for the audit.

---

## The gate (what PASS asserts) — `rungs/r34/out/r34_gate.txt: ALL 1`

1. `okHonestSpot` — the honest K-step length-proof verifies via k=46 spot-checks (sig + Merkle + recompute).
2. `okBudget` — spot-check touches <25% of K (sublinear).
3. `okHonestBond` — the honest bond is valid (stake ≤ balance) and signed.
4. `okNoFalseSlash` + `okBalRecovered` — opening an honest step does **not** slash; the stake is released; final balance == `balance0`.
5. `okFraudConfirmed` + `okSlashed` + `okStakeBurned` — the forged chain's single-step fraud-proof is confirmed, the bond is slashed, final balance == `balance0 − stake`.
6. `okNoSlashHonestStep` — opening a non-poisoned step of the forged chain is **not** fraud.
7. `okNoFabricatedSlash` — a tampered post-state not in the signed tree is **not** fraud.
8. `okOverStakeInvalid` — a bond exceeding the balance is invalid.
9. `okNoSlashUnsigned` — a slash under an unsigned root is rejected.

`all = product of all nine`. The Rail run prints `PASS:` and writes `ALL 1` iff all hold.

## The falsifiers (things that MUST fail)

- A forged chain (one inconsistent step) whose stake is **not** slashed → gate fails (`okSlashed=0`).
- An honest chain that **is** slashed by an opened honest step → gate fails (`okNoFalseSlash=0`).
- Fabricated fraud evidence accepted → gate fails (`okNoFabricatedSlash=0`).
- A slash accepted under an unsigned root → gate fails (`okNoSlashUnsigned=0`).
- The foreign Python checker re-deriving a **different** verdict (root mismatch, sig fail, fraud
  verdict disagreement) → `R34-CHECK FAIL`, exit 1.

The falsifier the ladder names — *"a ledger claiming K steps but computed with <K/10 real work
(reused trajectory, or parallel-fabricated states that don't chain) must be rejected"* — is exactly
the forged-chain path: a fabricated/reused state that doesn't chain produces an inconsistent
transition `r30_step(pre) ≠ post` at the seam, opened in O(log N) and slashed. (Note: this rejects
*non-chaining* fabrication. It does **not** by itself reject a *correctly-chained but cheaply-
recomputed* trajectory — that is the VDF gap, scoped out below.)

---

## The foreign cross-language witness — `r34_foreign_check.py`

An independent Python (big-integer) re-implementation that does **not trust the Rail prover's
states**. It:

1. re-runs the entire K-step `r30_step` trajectory from scratch (pure Python `idiv` truncating
   division matching Rail `/`), for **both** the forged (poisoned) and honest chains;
2. rebuilds the whole Merkle DAG and re-derives the signed roots; checks they match the transcript;
3. verifies the Ed25519 claim signature over the length-binding link under the re-derived pubkey;
4. confirms the opened endpoints in the proof equal its own recomputed states;
5. **re-derives the fraud verdict**: FRAUD on the poisoned step (→ slash, balance `−stake`),
   NO-FRAUD on every honest open (→ release, balance recovers), and reproduces all four slasher-
   soundness falsifiers.

It reuses `bx12_foreign_check.ed25519_verify / sha256_*` — the **same** primitives the proven
`lm10_foreign_check.py` uses, so the Rail-signs / Python-verifies interop is inherited, not new.

A self-contained sanity run of the checker's **core logic** at small N (no Rail involved) was
executed during construction and all of: determinism, forged≠honest root, fraud@poison, no-fraud@
honest, no-slash@fabricated, no-slash@unsigned, and Merkle-path round-trip — passed. (The full
signature-verify step requires the Rail-emitted transcript, produced under serial validation.)

---

## The VDF extension (research-open — NOT claimed)

To upgrade claim (1) → claim (2) *"this cost ≥K non-shortcuttable sequential work"* one must
interpose a **genuine** iterated-delay function whose length is **tied to** the step count, and
**bound its parallel-shortcut resistance**. Concrete skeleton:

- **Per-step delay tag.** After step i produces post-state `s_i`, compute a sequential hash chain
  `h_i = SHA256^T( h_{i-1} || ser(s_i) )` for a fixed iteration count T (an iterated-SHA-256 delay).
  Commit `h_i` in the leaf alongside the state. The final `h_K` is the VDF output.
- **Length-tied.** The number of sequential SHA-256 invocations is exactly `T·K`, so the delay is
  provably linear in the claimed step count — you cannot claim K without doing `T·K` sequential
  hashes.
- **Spot-checkable.** A challenger opens a random `i` and recomputes `h_i` from `h_{i-1}` (committed
  at i−1) in T hashes — O(T) per challenge, same Fiat-Shamir derivation as rung 30.
- **The soundness obligation (the hard part, unproven here):** bound `Pr[an adversary with P-way
  parallelism produces a valid h_K in < T·K/σ sequential time]`. Iterated SHA-256 is *believed*
  sequential but is **not** a proven VDF (no known parallel-shortcut, but also no lower bound); a
  *rigorous* VDF needs a function with a proven sequentiality gap (e.g. repeated squaring in a group
  of unknown order — Wesolowski/Pietrzak). Porting such a group to exact-integer Rail (RSA modulus
  or class group) and proving the shortcut bound is the research-open frontier. **Until that bound
  is written and the shortcut resistance argued, claim (2) is NOT established** — which is precisely
  why this rung ships (1) and labels (2) honestly.

---

## EXACT validate command (the orchestrator runs this serially)

```bash
bash rungs/r34/validate.sh
```

It compiles once (no self-host, `RAIL_ARENA_MB=2048` — light, no 8GB training run), runs the
prover+verifier+slasher once, asserts `rungs/r34/out/r34_gate.txt` contains `ALL 1`, then runs the
foreign Python checker over `rungs/r34/out/r34_fraudproof.txt`. **GREEN** iff the Rail run exits 0
with `ALL 1` AND the foreign checker prints `R34-CHECK PASS` and exits 0.

## Files

- `rungs/r34/r34_economic_stake.rail` — prover + succinct length-proof verifier + bond + independent slasher + 6 falsifiers.
- `rungs/r34/r34_foreign_check.py` — foreign cross-language re-derivation of the fraud verdict.
- `rungs/r34/validate.sh` — the serial green-gate runner.
- `rungs/r34/out/r34_gate.txt`, `rungs/r34/out/r34_fraudproof.txt` — emitted at run time.

## Honest limitations

- **Scope is claim (1)** — economic stake over the rung-30 *length* proof. Claim (2) (true VDF /
  non-shortcuttable work) is **not** proven; the skeleton above is research-open.
- **In-process states.** Like the rung-30 protocol core, the verifier/slasher receive the committed
  state list in-process. A fully decoupled third-party slasher reads only the signed root + the
  O(log N) opened proof — the `r34_check_fraud` interface already takes exactly `(fraud_proof, root,
  sig_ok)`, so the decoupling is mechanical (persist the opened proof, which `r34_fraudproof.txt`
  already does, and which the foreign checker already consumes independently).
- **LOCAL/DEV keys only.** Never a prod sign surface or live pulse — mirrors the proven pipeline.
- **Light transition.** Like rung 30, the per-step transition is the structurally-identical *light*
  `r30_step` (one Q.24 Adam cell), not the full 17-matrix lm10 step, so the gate validates in
  seconds. Binding to the real `lm4_step` is the same wiring rung 30 documents (`r30_prove.rail`);
  the economic layer is agnostic to which transition fills the DAG.
