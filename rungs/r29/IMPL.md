# RUNG 29 — Pi-Witness as Active Recency Oracle (separation of duties)

## The claim (from ATTESTED_LADDER.md)

> The words carry a *second* signature from a physically separate key on a separate
> machine that **independently verified recency** — not a passive co-sign, an active oracle.

**Gate.** The UTTER/recency record carries `usig` (trainer) and `wsig` (Pi) over the
**same** `(ulink, pulse_id)`; both witnesses verify both sigs against pinned pubkeys,
enforce `pk_trainer ≠ pk_witness`, and confirm the witness *itself* validated the pulse;
**PASS requires 2-of-2.**

**Falsifier.** Re-sign with the trainer key in both slots → `pk_trainer ≠ pk_witness`
fails and the witness-slot sig fails under the pinned Pi pubkey. A witness sig over a
different `pulse_id` than the link → pulse-binding fails → reject.

## What is proven here, honestly

This rung adds the **dual-signature / separation-of-duties layer** on top of the proven
attested-utterance pipeline (`ATTESTED_UTTERANCE.md`, `tools/bitexact/attested_utterance.rail`).
The proven pipeline already produces a trainer-signed `UTTER` record whose `link_hex`
(`ulink`) commits the spoken token-ids bound to the final-weights commitment. **Rung 29
binds a SECOND, independent signature to that link** under a *separate* key, where the
second signer is an **active oracle**: it re-derives and validates the recency pulse
itself, and **refuses to countersign** a pulse it cannot confirm recent.

Concretely, the canonical co-signed message reconciles the two historical formats
(`prev|UTTER|…` and `attest|v1|…|pulse_id`) into **one** that both verifiers rebuild
identically:

```
cmsg = SHA256( ulink_hex "|RECENCY|" pulse_id "|" pulse_hash )
usig = Ed25519(seed_trainer, cmsg)          -- author
wsig = Ed25519(seed_witness, cmsg)          -- SEPARATE key, only after pulse check
```

Both the Rail self-witness and the foreign (Python) witness:
1. re-derive `pulse_hash = SHA256(domain|pulse_id)` themselves (independent recency
   confirmation → pulse binding),
2. rebuild `cmsg` from the recorded `(ulink, pulse_id, pulse_hash)`,
3. verify `usig` under the **pinned** `pk_trainer` and `wsig` under the **pinned**
   `pk_witness`,
4. enforce `pk_trainer ≠ pk_witness`,
5. require **2-of-2**.

The signed record is persisted to `out/rung29_recency_chain.txt`, so an offline re-run
**never re-contacts the witness** — exactly the "persist the witness sig" requirement
from the ladder wall.

## How it extends the proven machinery (reuse, not reinvention)

- **Ed25519 sign/verify**: `stdlib/ed25519_sign.rail` (`ed25519_sign`, `ed25519_verify`,
  `ed25519_pk_from_sk`) + `stdlib/ed25519.rail` (`ed_bytes_eq`, used for constant-time
  pubkey-distinctness). All verbatim — the same primitives the proven trainer signs the
  `UTTER` link with.
- **Hashing / hex**: `stdlib/sha256.rail` (`sha256`, `sha256_hex`), `stdlib/bytes.rail`
  (`bytes_to_hex`, transitively imported via sha256). Same canon-message discipline as
  `ulink_str`/`ulink_b` in `attested_utterance.rail`.
- **Record format** mirrors the `UTTER` line so the foreign verifier parses it the same
  way `utterance_foreign_check.py` parses the `UTTER` row (whitespace-split fields,
  `# …v1` header with pinned pubkeys).
- **Foreign re-derivation** reuses `bx12_foreign_check.ed25519_verify` / `sha256_hex` /
  `sha256_bytes` — the *same* independent Python Ed25519 the existing foreign witnesses
  use. No new crypto written.

## Soundness / falsification argument

- **2-of-2 (the gate).** A record passes only if BOTH `usig` (under pinned `pk_trainer`)
  AND `wsig` (under pinned `pk_witness`) verify over the identical `cmsg`, AND
  `pk_trainer ≠ pk_witness`. Holding only one key cannot produce both — that is the
  separation of duties. (Honest threshold note from the ladder: 2-of-2 is the weakest
  threshold, so it must *earn* its rung via the active-oracle behavior below; that is
  exactly what FALSIFIER c tests.)
- **FALSIFIER a — trainer key in both slots.** Putting `usig` (a trainer sig) into the
  witness slot fails because it does not verify under the *pinned* `pk_witness`; and the
  distinctness check `pk_trainer ≠ pk_witness` independently rejects re-using one key.
  Both sub-checks are asserted (`okFalseA1`, `okFalseA2` in Rail; `false_a` in Python).
- **FALSIFIER b — wsig over a different pulse.** Because `cmsg` commits `pulse_id` (and
  the verifier rebuilds `cmsg` with the *claimed* pulse), a witness signature produced
  over a different `pulse_id` does not verify against the record's claimed pulse →
  reject. (`okFalseB` in Rail; `false_b` in Python, via the binding identity since the
  foreign side cannot sign.)
- **FALSIFIER c — active oracle refuses a stale pulse.** This is what makes the witness
  an *oracle* rather than a rubber stamp. `r29_witness_validate_pulse` enforces a recency
  window (`pulse_id ≥ wmin`); a stale id yields a **zero non-signature** (honest refusal),
  which cannot verify, so 2-of-2 fails. (`okWitnessRefused` + `okFalseC` in Rail.)
- **FALSIFIER d — tampered pulse_hash.** The record's `pulse_hash` is *not trusted*: each
  verifier re-derives `SHA256(domain|pulse_id)` itself; a tampered hash diverges from the
  re-derivation → reject. (`okFalseD` in Rail; `false_d` in Python.)
- **Dev-mode guard.** The only domain ever signed against is the LOCAL pulse domain
  (`…PULSE.dev`, contains no `PROD` marker); `okDevMode` asserts it. This honors the hard
  rule: **never mint against the live witness key / live beacon** in a demo.

## Honest scope / what this is NOT (the real wall)

The ladder's wall is twofold. **(1) The crypto/protocol** — distinct keys, one canonical
co-signed message, active recency check, persisted witness sig — is what this rung
implements and verifies end-to-end in two languages. **(2) The physical deployment** —
the *actual* Linux-ARM64 cross-compiled signer running on a 416MB Pi Zero over HTTP
(`tools/attest/pi_sign_server.rail`, which "has never seen an utterance"), through the
duplicate-symbol cross-compile wall — is a fleet/hardware operation, **not** something to
fabricate. This rung does **not** claim a live Pi countersigned over the wire; it claims,
and proves runnably, the **separation-of-duties cryptographic layer** with a logically
separate witness key + independent pulse validation + persisted countersignature. Wiring
that exact `cmsg`/`wsig` through the real `pi_sign_server.rail` POST `/sign` path on the
deployed Pi is the named remaining gap (see below) — the protocol it would carry is
already fixed and verified here.

Also: like rung 28, the pulse here proves **not-before** (posterior to a witnessed value),
not elapsed wall-time. The LOCAL dev pulse stands in for the live `/entropy/pulse/<id>`;
when rung 28 lands the live fetch, `r29_pulse_hash` is the single point to swap (its
output is the only pulse fact `cmsg` commits).

## Files

| File | Role |
|---|---|
| `rungs/r29/rung29_dual_sign.rail` | Rail self-witness: two keys, witness validates recency, co-signs over canonical `cmsg`, runs all 4 falsifiers, persists `out/rung29_recency_chain.txt`, prints PASS/FAIL |
| `rungs/r29/rung29_foreign_check.py` | Foreign (Python big-int Ed25519) re-verifier: re-derives pulse, rebuilds `cmsg`, checks 2-of-2 + distinctness + binding + falsifiers a/b/d |
| `rungs/r29/validate.sh` | Orchestrates compile → run → foreign-verify; exit 0 = PASS |

## EXACT validate command

```bash
cd /Users/ledaticempire/rail-reward && bash rungs/r29/validate.sh
```

This compiles the dual-signer (fast, default arena — **no transformer training, no
8GB arena, no `self`**), runs it (Rail self-witness gate), and re-verifies the persisted
record in Python. Exit 0 only if **both** witnesses agree and **every** falsifier rejects.

### Optional deeper variant (composes with the proven utterance run)

To bind the witness signature to the **real** trainer `ulink` instead of the dev stand-in,
first produce the proven ledger, then point the dual-signer at its `UTTER` link. The
co-signing logic is identical; only the bound `ulink_hex` source changes. This is left as
the documented compose step (it requires the heavy `RAIL_ARENA_MB=8192 ./out/utter_bin`
run, deliberately *out of scope* for the fast validate per compute discipline):

```bash
# (heavy — run serially, not in a swarm)
./rail_native --out-prefix out/utter_bin tools/bitexact/attested_utterance.rail
RAIL_ARENA_MB=8192 ./out/utter_bin            # writes out/utterance_chain.txt + out/u_ulink.txt
# then read out/u_ulink.txt as the ulink to co-sign (see "compose step" in the .rail header)
```

## Remaining gap to a fully green ladder-29

1. **Live Pi over the wire.** Carry this exact `(cmsg)` through `pi_sign_server.rail`'s
   POST `/sign` on the deployed Linux-ARM64 Pi (duplicate-symbol cross-compile must be
   resolved; the server must accept the `cmsg` digest + `pulse_id` + return `wsig`). The
   protocol is fixed; this is fleet/hardware work, gated by `feedback_manual_run_signs_real_chain`
   (dev-mode guard before touching the real witness key).
2. **Live pulse fetch (rung 28 dependency).** Replace `r29_pulse_hash`'s LOCAL derivation
   with the real `/entropy/pulse/<id>` over the pure-Rail TLS stack. Single swap point.
3. **Compose with the real `ulink`** (the optional variant above) so the second signature
   binds the *actual* trained utterance, not the dev stand-in — a serial heavy run.
