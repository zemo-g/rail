# Open Seam — Key Rotation / Revocation

> Rotate the LOCAL/DEV signer to a production key, or retire a compromised signer, **without
> breaking the hash-chain** that already binds weights→words. The chain must stay one continuous,
> independently re-verifiable artifact across a key boundary.
>
> Cuts across rungs 28/29/33 (they *add* keys + beacons but assume one fixed signer for a run).

---

## 1. The substrate as it stands (what we're rotating around)

The whole attestation in `tools/bitexact/attested_utterance.rail` is **single-key, fixed for the
life of one run**:

- `seed = sha256 "lm10.local.ephemeral.dev.seed.v1"` ; `pk = ed25519_pk_from_sk seed`  (line 918-919)
- `genesis_hex = sha256_hex "LM10.LOCAL.BEACON.GENESIS.dev"`  (line 921)
- Every per-epoch record: `link = SHA256(prev "|" epoch "|" w_hex "|" loss)`, `sig = ed25519_sign seed link`, `prev(ckpt0)=genesis`  (lm4_ckpt, line 711-722).
- The `UTTER` record: `link = SHA256(prev "|UTTER|" prompt_hex "|" cwin "|" gcap "|" w_hex "|" t_hex)`, same `seed`  (line 959-965).
- Header pins the **one** verifier key: `# LM10v1 <pk_hex> <genesis_hex> <epochs> <chash> ...`  (line 977-980).
- The foreign verifier (`utterance_foreign_check.py:81-82`) parses `pubkey_hex = hdr[2]` **once** and checks every signature against that single `pub`.

So there is exactly one pubkey in the header, one secret behind every signature, and the genesis is a
constant. **There is no place in the format to say "from here on, a different key signs," and no record
type that authorizes such a handover.** That absence is the seam.

A naive rotation (just start signing epoch *k* with a new `seed'`) silently breaks the chain: the
foreign verifier checks record *k*'s sig against `hdr[2]` (the old `pk`), it fails, and there's no way
to tell a legitimate rotation from a forged record. Worse — a compromised old key can still sign valid
records, so "stop using it" is not the same as "the verifier now rejects it."

---

## 2. Design — a self-authorizing `ROTATE` record + epoch-keyed verification

### 2.1 The format change: one new record type, header stays back-compatible

Add a record interleaved into the existing ledger body (same `write_file "out/utterance_chain.txt"`
stream, before the `UTTER` line), emitted by a new `lm4_rotate` helper modeled on `lm4_ckpt`:

```
ROTATE <epoch_i> <new_pk_hex> <reason_code> <prev_hex> <link_hex> <sig_old_hex> <sig_new_hex>
```

- `link = SHA256(prev "|ROTATE|" show epoch_i "|" new_pk_hex "|" reason_code)`  — `cat [...]` then `sha256`, identical idiom to `ulink_str` at line 959.
- `sig_old = ed25519_sign seed_old link`   — the **outgoing** key endorses its own successor (this is what keeps the chain continuous: the old key *vouches* for the new one, so the handover is itself attested under the key the verifier already trusts at that point).
- `sig_new = ed25519_sign seed_new link`   — the **incoming** key proves possession (no one can install a pubkey they don't hold the secret for; defeats "rotate to an attacker-chosen key the attacker can't actually sign with").
- `reason_code` ∈ {`dev2prod`, `scheduled`, `compromise`} — a fixed ASCII enum (ASCII-only-in-`.asciz` rule honored; no em-dashes, plain tokens).
- `prev` chains onto the prior record's `link_hex` exactly like every checkpoint, so the DAG stays unbroken.

The header **does not change shape** (back-compat with the existing foreign parser): `hdr[2]` stays
the *genesis* pubkey (key in force at `epoch 0`). The verifier learns later keys from the ROTATE
records themselves — the chain is self-describing.

### 2.2 The verification rule: "active key" walks forward with the chain

Both witnesses (Rail self-witness re-run + `utterance_foreign_check.py`) change from "verify all sigs
against the one header key" to a **single forward pass that tracks the active pubkey**:

```
active_pk = header_pk            # = hdr[2], the genesis/epoch-0 key
for each record in body order:
    if record is CKPT or UTTER:
        require ed25519_verify(active_pk, link, sig)          # current key signed it
    if record is ROTATE:
        require ed25519_verify(active_pk, link, sig_old)      # OLD key endorsed the handover
        require ed25519_verify(new_pk,   link, sig_new)       # NEW key proved possession
        active_pk = new_pk                                    # advance the active key
require chain prev-links are contiguous (already enforced)
```

This is ~15 lines added to each verifier. It needs no new crypto — only the `ed25519_verify` /
`ed25519_sign` / `sha256` / `bytes_to_hex` already imported (lines 39-41), and `ed_point_add` /
`ed_scalar_mul` already in `stdlib/ed25519.rail` (per CLAUDE.md, do not rebuild). The Rail trainer
emits ROTATE via a `lm4_rotate` clone of `lm4_ckpt`; mind the **>=30-arg cliff** and the **self-loop
cross-dep miscompile** — keep the rotate emitter a flat non-self-recursive helper (it's called once),
and if it must thread state alongside `lm4_chain`, split into a mutual-recursion pair rather than
adding args to the existing 24-arg `lm4_chain`.

### 2.3 Two rotation modes, one mechanism

- **dev→prod rotation (`dev2prod` / `scheduled`):** insert a ROTATE record at the boundary epoch. The
  old (LOCAL/DEV) key signs `sig_old`; the prod key signs `sig_new`. Records after it verify under prod.
  The DEV key is then discarded. Crucially the *whole* run — including the dev-signed prefix — stays
  verifiable forever, because the verifier walks the active key forward. Honors the standing rule:
  **LOCAL/DEV keys never touch a prod sign surface** — the prod key is only ever introduced *as data*
  (its pubkey + a possession sig); dev key signs locally; no dev secret is exported.

- **compromise / revocation (`compromise`):** semantically different and the harder half. A ROTATE
  with `reason_code=compromise` declares the old key burned **as of `epoch_i`**. The verifier's rule
  becomes: records authored by the compromised key *after* the ROTATE epoch are **rejected** (an
  attacker who holds the burned secret can still produce valid `ed25519_verify` sigs, but the chain
  has already moved `active_pk` past it, so those forgeries don't chain — they'd have to fork before
  the ROTATE, which the contiguous-prev requirement plus the live-beacon anchor (rung 28) timestamps
  against). The genuinely open piece: a compromised key could **forge a ROTATE itself** (it still
  holds `seed_old`, so it can produce `sig_old`). The honest defense is **out-of-band root anchoring**
  — see §4 limit (b); the in-substrate MVP records the compromise but a same-key self-rotation by the
  attacker is the residual hole we label honestly rather than paper over (enough-for-now threat model).

---

## 3. Gate (PASS criteria — concrete, runnable, no heavy build here)

Build an isolated variant `tools/bitexact/attested_rotation.rail` (clone of `attested_utterance.rail`,
its own `--out-prefix out/rot_bin`, `RAIL_ARENA_MB=8192`) that trains the same lm10, inserts a ROTATE
record at a mid-run epoch (dev→prod), and signs the final UTTER under the **new** key. PASS requires
**all** of:

1. **Chain stays continuous across the boundary.** The Rail self-witness re-run reproduces the training
   head AND the `UTTER` `t_hex` bit-for-bit *through* the rotation (same `head_link`/`ulink_hex` invariants
   that pass today at lines 985-999), proving the ROTATE record didn't perturb the weight→word binding.
2. **Forward-key verification passes both ways.** The foreign `utterance_foreign_check.py` (extended with
   the §2.2 active-key walk) verifies: pre-rotate records under the genesis key, the ROTATE record under
   *both* old (`sig_old`) and new (`sig_new`) keys, post-rotate + UTTER records under the new key —
   `chain_ok = True`, `sig_ok = True`, `utterance_ok = True`. The Rail witness reports the same verdict.
3. **The dev secret is never the prod secret and never exported.** Assert `pk_old != pk_new`; the prod
   key enters the run only as `new_pk_hex` + a possession sig (no prod `seed` printed/written).

## 4. Falsifier (must FAIL — the controls that make it real)

1. **Forged successor (no possession).** A ROTATE whose `sig_new` is from a *different* key than
   `new_pk_hex` (rotate to a pubkey you don't hold) → the `new_pk` possession check rejects. (Built like
   the existing `seed2 = sha256 "lm10.other.key"` wrong-key control at line 930-932.)
2. **Unauthorized handover (no endorsement).** A ROTATE missing/wrong `sig_old` (some key tries to insert
   itself without the outgoing key's blessing) → the old-key endorsement check rejects. This is the core
   "you can't hijack the chain" property.
3. **Stale-key acceptance after rotation.** A CKPT/UTTER record *after* the ROTATE epoch signed by the
   **old** key → rejected, because `active_pk` has advanced. (Directly falsifies the "rotation that
   doesn't actually retire the old key" failure mode.)
4. **Tampered ROTATE payload.** Flip one char of `new_pk_hex` (à la the `w_hex_forged = cat ["0", ...]`
   control at line 967) → both `link` and the recorded sigs diverge → `link_ok=False` → reject. Mirrors
   the existing `okForgeChain` probe (line 968-970).
5. **Genesis-key replay past the boundary.** Re-present a pre-rotate record's sig as a post-rotate record
   → contiguous-prev + active-key walk both reject.

**Known limits (labeled honestly, not papered over):**
(a) MVP rotation is *announced in-band* — it depends on the old key being honest at the moment of the
planned rotation; a key compromised *before* a scheduled rotation is the §2.3 residual hole.
(b) True revocation of a self-rotating attacker needs an **out-of-band root of trust** (the rung-28 live
beacon as an external timestamp the attacker can't predate, or a separately-held root key that endorses
key-set changes). That is the production hardening, scoped as roadmap — the in-substrate piece here is
the self-authorizing ROTATE record + forward-key verification, which is shippable and falsifiable today.

## 5. Artifact

This file. The buildable variant is `tools/bitexact/attested_rotation.rail` (clone + `lm4_rotate`
helper + extended `utterance_foreign_check.py` active-key walk) — **not built in this pass** (heavy
lm10 train, multi-GB arena). Reuse the lm10 transformer + `lm4_ckpt`/`lm4_chain`/`lm4_chain_d0`
verbatim; the only net-new code is the ~15-line ROTATE emit/verify on each side.
