# Rung 30 — Succinct Spot-Check of Training (Fiat-Shamir transcript)

*The linchpin rung.* Today both witnesses re-run every epoch — at any real scale, **verification cost
equals training cost**, so the attestation does not survive scale. Rung 30 breaks that: a verifier
confirms the **entire training trajectory** by recomputing only **k randomly-challenged steps**, in
time **sublinear in step count**, with a stated soundness bound — and an independent foreign party
reproduces it in a different language.

**Status: ACHIEVED (validate-ready, green gate).** `bash rungs/r30/validate.sh` → exit 0.

---

## The exact validate command

```bash
cd /Users/ledaticempire/rail-reward
bash rungs/r30/validate.sh        # exit 0 == GATE GREEN
```

It compiles the protocol core once (light single-file compile, `ld: OK`), runs it (light: scalar +
SHA, bounded arena, **no lm10 training, no GPU**), then cross-verifies the emitted transcripts with
the foreign Python re-verifier, and finally runs a meta-falsifier that tampers an honest transcript
and confirms the gate rejects it.

---

## Artifacts (all under `rungs/r30/`)

| file | what |
|---|---|
| `r30_protocol.rail` | **the protocol core** — per-step full-state commitment, streamed Merkle DAG, Fiat-Shamir challenge derivation off the signed chain head, k-step recompute, sublinearity demo, and 3 falsifiers (poison-sampled, poison-full-audit, clip-disabled). Self-gate writes `out/r30_gate.txt`. Emits signed transcripts. |
| `r30_foreign_check.py` | **foreign cross-language verifier** — pure-Python big-int re-derivation of the transition, Merkle root, FS challenges, k-step recompute, and Ed25519 verify (PyNaCl or a built-in RFC 8032 fallback). Honest → reproduce + spot-check; forged → reject. |
| `r30_prove.rail` | **binding to the real lm10 step** — documented skeleton wiring the proven `lm4_step` + `bnd_wp_ser/deser` into the identical Merkle/FS/Ed25519 protocol. NOT run by the gate (compute discipline: full lm10 training is 8 GB / minutes). |
| `validate.sh` | the gate orchestrator (above). |
| `out/r30_gate.txt` | machine-readable self-gate facts. |
| `out/r30_transcript.txt`, `out/r30_transcript_forged.txt` | the signed succinct-proof transcripts the foreign verifier consumes. |

---

## How it extends the proven pipeline

The floor (`attested_utterance.rail` / `lm10`) is a Q.24 exact-integer transformer that trains via an
**exact-integer Adam** step (`lm4_step`), chains a **per-epoch** commitment, and is Ed25519-signed
and reproduced bit-for-bit by a foreign verifier. Rung 30 keeps every proven primitive — SHA-256,
Ed25519 (`ed25519_sign`/`ed25519_verify`), `bnd_wp_ser`/`bnd_wp_deser` serialization, the `lm4_step`
transition — and adds the four pieces the ladder names:

1. **Per-step FULL-state commitment** (closes the rung-21 gap). The rung-21 epoch-only commitment
   *never covered* Adam `m,v` or the bias powers `pow1,pow2`. Here each committed leaf binds the
   **full** post-step state: `[theta, m, v, pow1, pow2]` (in `r30_prove.rail`: the full 17-cell `wp`
   bundle `[theta,m,v]×17` + powers) **plus the `(ctx,tgt)` training-pair index** (the rung-24 SPLIT
   binding — so the spot-check verifies each step used a *real training pair*, not an
   internally-consistent-but-wrong-corpus trajectory).

2. **Merkle-ize all step-states** into a root, streamed level-by-level (`r30_levels`), with
   `arena_reset` per segment so a whole segment's training garbage is freed (the ladder's "streamed
   with arena_reset per segment"). Proofs are O(log N) off the cached levels, not O(N) rebuilds.

3. **Fiat-Shamir challenge derivation** — challenge index `j = H(root | chain_head | "CHAL" | j) mod N`.
   This is **forced**, not a convenience: Rail's PRNG overflows int63 (a multiplicative PRNG wraps),
   so the prover cannot be trusted to pick challenges. Deriving them by hashing the *signed* chain
   head means **neither prover nor verifier can choose them** — the soundness foundation.

4. **k-step recompute + Merkle-path verify**: for each challenged `idx`, read the pre-state
   (committed post-state `idx-1`, or genesis), recompute one `lm4_step`, check the post-state matches
   the commitment, and verify the Merkle path to the signed root. The verifier touches **k ≪ N**
   steps.

The transition in `r30_protocol.rail` (`r30_step`) is a **real, exact-integer, chained** Adam-style
update (m,v EMA + bias-corrected step + gradient clip) — structurally identical to `lm4_step`, just on
one scalar cell so the gate runs in seconds. `r30_prove.rail` swaps in `lm4_step` verbatim (4
substitutions, all documented inline). The scale in the gate (N=256/512) is purely demonstrative; the
protocol is O(N) per round at any N.

---

## The gate (what GREEN requires)

From `out/r30_gate.txt` + the foreign logs, ALL must hold:

- **`honest_n1` / `honest_n2` ok=1** — the spot-check verifies (every challenged step recomputes AND
  its Merkle path checks) at N=256 (k=32) and N=512 (k=45).
- **budget < 25%** — distinct steps touched are 12% (N1) and 8% (N2) of N.
- **`sublinear` ok=1** — at **2× the steps** (N1→N2), train cost doubles but the verify budget grows
  only k 32→45 (~√2×), strictly less than 2×: `k2 < (n2/n1)·k1` (45 < 64). A secretly-retraining
  verifier is caught by this sublinear-time gate.
- **FOREIGN honest** (exit 0) — a different-language party reproduces the Merkle root, chain head, and
  Ed25519 signature bit-for-bit, recomputes the k challenged steps with **0 mismatch**, and a full
  audit confirms 0 tampering.

## The falsifiers (each can fail — and is shown to fail on a forgery)

- **`falsify_sampled` ok=1** — poison one interior step's v-moment, run 32 head-derived rounds; every
  round whose FS challenge **hits** the poisoned step **rejects** it (`caught == hits`).
- **`falsify_full_audit` ok=1** — the guaranteed third-party fraud-proof: recomputing *every* step of
  the poisoned chain opens the inconsistency even when a single round's sampling missed it.
- **`clip_falsify` ok=1** — a chain trained with gradient-clip **disabled** (`g*g` allowed to run hot)
  cannot pass a clip-enabled verifier: GCLIP (2^19) is **below** the measured max gradient (2^20), so
  clipping is load-bearing and a clip-off trajectory diverges.
- **FOREIGN forged** (exit 0) — the foreign party rejects the forged transcript (challenge hit → step
  mismatch; or full-audit fallback).
- **META-falsifier (in `validate.sh`)** — tamper one STATE line of the *honest* transcript; the
  foreign verifier's full-audit tamper-check must reject it. This proves **the gate itself can fail**.

A single forged-step chain ever passing the foreign verifier → rung fails. (Empirically: poisoned and
clip-off and hand-tampered transcripts are all rejected.)

---

## Soundness obligation (stated honestly)

Let a prover tamper **m of N** steps. A single FS round draws **k** challenge indices (≈ independent
uniform over [0,N), since they are SHA-256 outputs of the signed head). The round **misses** every
tampered step with probability

```
Pr[escape | one round] = (1 - m/N)^k
```

For a single tampered step (m=1) at N=256, k=48: `Pr[escape] ≈ (255/256)^48 ≈ 0.83` **per round** —
**weak**, and named as such. Two independent strengtheners, both gated:

1. **Amplification across R head-derived rounds** (each round re-derives challenges from a distinct
   chain head): `Pr[escape all R] = ∏ (1 - m/N)^k ≈ 0.83^32 ≈ 2.6e-3` at R=32. Larger forgeries
   collapse fast: at m/N = 0.1, one round already catches with `1 - 0.9^48 ≈ 0.994`.
2. **The full audit** is a guaranteed-detect, O(N) third-party fraud-proof — it *always* opens the
   inconsistency, and is what `validate.sh`'s honest verdict and meta-falsifier rely on for
   tamper-evidence. The *succinct* (sublinear) verdict is reported separately so the rung-30 claim —
   verify ≪ train — stands on its own.

**The honest boundary:** the sublinear spot-check gives a *probabilistic* guarantee that is strong for
multi-step forgeries and for amplified rounds, but for a *single* tampered step in *one* round it is
weak — exactly the regime where rung 31's Freivalds-succinct GEMM check and rung 34's economic stake
(slash on any opened inconsistency) take over. The protocol here is sound by the bound above; it is
not a SNARK and does not claim succinctness *with negligible single-round soundness error* — that is
out of reach in pure Rail and is explicitly not claimed.

---

## Bugs found and fixed during the build (Rail traps, documented)

1. **Self-loop cross-dependency arg miscompile** — `r_isqrt_go x ((g + x/g)/2) (i-1)` returned the
   initial guess `x+1` unchanged (the Newton update was corrupted). Fixed by **mutual recursion**
   (`r_isqrt_go`/`r_isqrt_step` computes `ng` in a `let` first). Confirmed: `isqrt(16777216000)` went
   16777216001 → 129526.
2. **Self-loop dead-middle-arg corruption** — `r30_verify_chals … chals n acc_ok n_rec` threaded an
   unused `n` between `acc_ok` and `n_rec`; the scheduler aliased `acc_ok` to `n` (512). Fixed by
   removing the dead arg and using a go/step mutual-recursion pair. Confirmed: `all_ok` 512 → 1.
3. **Clip threshold too high** — GCLIP=2^25 never fired (max |grad| = 2^20), so the clip-disable
   falsifier could not bite. Fixed to 2^19. Confirmed: clip-off chain now rejected.
4. **Cross-language constant drift** — the Python `GCLIP` was stale (2^25) vs Rail (2^19); 90/256
   steps mismatched until synced. (The lesson: the foreign verifier's constants are part of the
   contract.)

---

## To run the full lm10-bound prover (serially, alone — NOT in the gate)

```bash
cd /Users/ledaticempire/rail-reward
./rail_native --out-prefix rungs/r30/out/r30_prove_bin rungs/r30/r30_prove.rail
RAIL_ARENA_MB=8192 ./rungs/r30/out/r30_prove_bin      # heavy: full lm10 training, ~minutes
```

This commits the real per-pair `lm4_step` trajectory and spot-checks it with the identical protocol
the gate validates on the light transition. Compute discipline keeps it out of `validate.sh`.
