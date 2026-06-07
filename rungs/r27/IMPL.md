# Rung 27 — Replay-Free Verification of the *Saying*

**Status: VALIDATE-READY** (code complete; the decode-only equivalence + parser + falsifiers are
empirically validated on real lm10 dimensions without the heavy retrain — see "Evidence" below. The
one heavy step, Stage A retrain, is gated by compute discipline and run serially by the orchestrator.)

## The claim (from ATTESTED_LADDER.md, rung 27)

> A verifier confirms the model said exactly the attested words from a signed weight bundle whose
> SHA-256 **is** the ledger `w_hex`, re-running *only* the ~48 decode steps, never the training
> epochs. (~2:44 → milliseconds for the utterance.)

## Where the floor was easy, and what this rung destroys

The proven floor (`tools/bitexact/utterance_foreign_check.py`) reproduces the saying **only by
calling `rederive(...)`** — it re-runs all 19 training epochs purely to reconstruct the weights it
decodes from. That is O(epochs): at any real scale, *verification cost equals training cost*, and the
attestation does not survive scale. Rung 27 breaks that **for the decode** (training verification
stays O(epochs) until rung 30, as the ladder states).

## The soundness pivot — load *is* check

The naive fix ("just ship the weights") is unsound unless the bundle's hash *is* the chained
commitment. We make it so:

- The trainer already commits `w_hex = lm4_canon17 fwp = SHA-256( lm4_canon17_str fwp )`, where
  `lm4_canon17_str` is the **theta-only canonical preimage**:
  `cat[ canon_mat(M0), ";;", canon_mat(M1), ";;", …, ";;", canon_mat(M16) ]` over the 17 theta
  matrices (`lm4_cm` walks `lm4_thmat`, i.e. theta only — no Adam m/v).
- **The shipped weight bundle `out/weights_bundle.txt` IS that exact preimage string.** Therefore
  `SHA-256(bundle) == w_hex` *by construction*.

So "trust `w_hex`" and "load these weights" are the **same act**. The verifier:
1. hashes the bundle and compares to the ledger `w_hex` — **rejecting tampering AT LOAD, before any
   decode** (this is the earned weak-tamper insight made cryptographic: output-divergence is a *weak*
   tamper test — a hard-memorized model is robust to small nudges — so the commitment, which rejects
   *every* weight change including sub-token ones, is the guarantee);
2. parses the bundle into the 17 theta matrices (decode needs only theta — no Adam state);
3. re-runs **only** the ~48 greedy decode steps from the loaded weights, reproduces `t_hex`, and
   verifies the Ed25519 utterance signature — **zero gradient / Adam / epoch calls.**

The narrow new risk the ladder names — "`bnd_wp_deser` reload must yield a bit-identical final
logits vector" — is discharged structurally: the bundle *is* the exact theta bytes, the forward path
(`lm4_forward` / `forward`) is copied **verbatim** from the proven trainer, and the readout GEMM is
already covered bit-for-bit by rung-21's `gpu_d2_all` (that sub-claim is **not** re-opened here).

## What extends the proven pipeline (and what is reused verbatim)

| Reused verbatim | New for rung 27 |
|---|---|
| lm10 transformer forward (`lm4_block_fwd`, `mh_attn_fwd`, `attention_rope`, RMSNorm, FFN, RoPE tables, softmax) | `lm4_canon17_str` (the preimage string) + `write_file "out/weights_bundle.txt"` in the trainer |
| greedy decode (`lm4_gen` semantics → `gen_loop`) | `parse_bundle` (canon17 preimage → 17 theta matrices), Rail + Python, byte-identical rule |
| SHA-256 / Ed25519 chain, `bytes_to_hex`, `hex_to_bytes`, `ed25519_verify` | the load-step SHA check (`okLoad`) + decode-only verifier (`rung27_verify.rail` / `rung27_foreign_check.py`) |
| `utt_ids_canon`, `lm4_lastc`, `lm4_decode` | the bundle-binds self-assert in the trainer gate (`okBundleBinds`) |

The trainer (`rung27_train.rail`) is `attested_utterance.rail` with **exactly two additions**: the
`lm4_canon17_str` factoring (so `lm4_canon17 = sha256_hex ∘ lm4_canon17_str`), and writing the
bundle + a self-assert that `SHA-256(bundle) == w_hex`. Nothing about training, the chain, the
signatures, or the existing gates changed.

### The canon boundary subtlety (caught + fixed)

Each `canon_mat` already ends with its last row's terminating `;`, so a `";;"`-join produces `";;;"`
at every matrix boundary. The robust parse rule (used **identically** in Rail and Python): split the
whole bundle on `;` → each non-empty token is a row (space-split into signed ints); an **empty token
closes the current matrix**. Verified to round-trip all 17 matrices (W1 64×64, W2 21×64, E 21×8, the
1-row gammas, FFN 32×8 / 8×32, including 2^40 negatives).

## Gate

`okLoad` (SHA(bundle)==w_hex) · `okUtter` (decode-only t_hex == ledger t_hex) · `okLink` ·
`okSig` (Ed25519 over the reconstructed link) · provably zero grad/Adam · foreign decode wall-clock
**< 5 s** · two independent witnesses (Rail self-witness + foreign Python).

## Falsifiers (each must make the gate FAIL)

1. **Tamper one Q.24 cell of the bundle** → its SHA ≠ `w_hex` → **load rejects before any decode**
   (`okFalsLoad` in Rail; `fals_load_reject` in Python; *and* an explicit shell-level Stage B3 that
   feeds a byte-flipped bundle and asserts the foreign verifier exits non-zero).
2. **Ship correct weights but a hand-edited `t_hex` tape** → the redraw from the real loaded weights
   contradicts the tape → reject (`okFalsTape` / `fals_tape_reject`).
3. **Forged signature byte** → RFC 8032 verify rejects (`fals_sig_reject`, foreign).

## Files

- `rung27_train.rail` — proven trainer + bundle emission (Stage A; heavy, run once).
- `rung27_verify.rail` — Rail replay-free self-witness (decode-only; `RAIL_ARENA_MB=2048`).
- `rung27_foreign_check.py` — foreign (Python) replay-free witness; imports **only** forward-path
  symbols (no `rederive`/`step1`/Adam); asserts wall-clock < 5 s and bundle-hash == ledger w_hex.
- `validate.sh` — the full gate.

## Evidence already produced (no heavy build)

- `parse_bundle` (the verifier's own code, imported from `rung27_foreign_check.py`) **reconstructs
  all 17 matrices AND both block bundles EXACTLY** on the real lm10 shapes.
- **Decode from the parsed/loaded weights produces a bit-identical `t_hex` to decode from the
  original weights** — the core rung-27 claim, validated on real lm10 dims with the real `forward`.
- Both bundle-tamper and forged-tape falsifiers trip correctly.
- The Rail parser logic was transcribed to Python and round-trips identically (byte-parity with the
  Python parser).

## EXACT validate command (orchestrator runs serially)

```bash
bash /Users/ledaticempire/rail-reward/rungs/r27/validate.sh
```

Exit 0 with final line `PASS` == rung achieved. Stage A skips the retrain if
`out/weights_bundle.txt` already binds (its SHA equals the ledger `w_hex`), so re-validation after the
first run is the fast decode-only path the rung is about.

## Honest scope

- Bounds the **decode** only; training verification stays O(epochs) until rung 30 (stated in the
  ladder, not a defect).
- LOCAL/DEV keys + LOCAL genesis only — never a prod sign surface (inherited from the floor).
- The decode-only equivalence and falsifiers are validated; the only step not yet executed here is
  Stage A's heavy retrain (compute discipline), which the proven floor already runs green — the new
  trainer differs from it only by the two additive bundle lines.
