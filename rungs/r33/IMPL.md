# RUNG 33 — k-of-n Threshold-Signed Utterance (FROST-Ed25519, in-substrate)

**Status: VALIDATE-READY.** The threshold-crypto layer is implemented in pure Rail on top of the
proven Ed25519 primitives, and the construction is independently confirmed correct against the
proven RFC-8032 `ed25519_verify` (see *Evidence*). The orchestrator runs `validate.sh` serially to
land the green gate (one fast crypto-only compile — **no lm10 re-train**).

---

## What this rung proves (the claim from the ladder)

> The utterance carries a **single** Ed25519 signature verifiable under **one** group pubkey,
> produced by a k-of-n threshold of independent fleet keyholders, with **no party ever holding the
> group secret** — vanilla `ed25519_verify` accepts it; no minority can forge it.

Concretely: a **2-of-3 FROST-Ed25519** ceremony over the **pulse-anchored utterance link** produces
a 64-byte signature `(R_enc ‖ S)` that the **UNMODIFIED** `stdlib/ed25519.rail:ed25519_verify`
accepts under the group public key `A = [s]B` — even though no single signer ever holds `s`. Any
2-of-3 subset reconstructs a sig valid under the same `A`; a minority (k-1) cannot.

## How it extends the proven pipeline

The proven `tools/bitexact/attested_utterance.rail` signs the utterance with **one** key:

```
usig = ed25519_sign seed ulink_b 32        -- ulink_b = sha256(canonical UTTER record)
uok  = ed25519_verify pk ulink_b 32 usig
```

Rung 33 **replaces that single line** with a threshold ceremony over the **same 32-byte message**
`ulink_b`, yielding a sig that the same `ed25519_verify` accepts under the **group** pubkey:

```
gsig = frost_2of3_sign s a1 ulink_b pulse32     -- 2-of-3 over the SAME message
gok  = ed25519_verify A_group ulink_b 32 gsig   -- UNMODIFIED verifier, group pk
```

Everything below `ulink_b` (the lm10 transformer, the `lm4_chain` training, `bnd_wp_ser/deser`,
`lm4_chain_d0` re-run, the `w_hex`/`t_hex` commitments) is **untouched and reused verbatim**. This
rung is the signing *layer*; it is therefore validated **without re-running lm10** (a deliberate
compute-discipline choice — the same separation `rung 29` uses). The driver `frost_main.rail` signs
a **self-contained pulse-anchored message of the identical shape** as `ulink_b` (a `sha256` of a
canonical `RUNG33|UTTER|<pulse_hex>|…` record). The drop-in composition into the full pipeline is a
two-line edit at `attested_utterance.rail:962` (swap `usig`/`uok` for `gsig`/`gok`, record the group
pk in the header).

## Reuse — proven machinery used verbatim

| From | Used for | Status |
|---|---|---|
| `stdlib/ed25519.rail` | `ed_scalar_mul`, `ed_point_add`, `ed_point_new`, `ed_point_copy`, `ed_encode`, `ed_decode`, `ed_b_bytes` | unchanged |
| `stdlib/ed25519.rail` | **`ed25519_verify`** — the gate target | **unmodified** |
| `stdlib/ed25519_scalar.rail` | `sc_muladd`, `sc_reduce`, `sc_l_bytes`, `sc_bn_*` bignum limbs | unchanged |
| `stdlib/sha512.rail` | `sha512_bytes`, `sha_copy_bytes` | unchanged |
| `stdlib/sha256.rail` / `stdlib/bytes.rail` | `sha256`, `bytes_to_hex`, `hex_to_bytes` | unchanged |
| `tools/bitexact/bx12_foreign_check.py` | the proven RFC-8032 `ed25519_verify` + curve ops, reused by the foreign witness | unchanged |

## What this rung BUILDS (the ladder's named wall)

The ladder's stress-test corrected an over-claim: `ed_point_add`/`ed_scalar_mul` already exist, so
"point addition from scratch" is **not** the wall. The genuine frontier, all in `frost.rail`:

- **(a) scalar arithmetic mod L** — `sc_mul`, `sc_add`, `sc_neg`, `sc_sub`, `sc_eq`, `sc_is_zero`,
  built on the existing `sc_muladd`/`sc_reduce`/bignum limbs.
- **(b) scalar INVERSION mod L** — `sc_inv` via **Fermat** `a^(L-2) mod L`: square-and-multiply
  over the 256 bits of `L-2` (LE constant `ebd3f5…10`, verified `== (L-2)` in `validate.sh`/notes),
  ~256 squarings + ~128 multiplies through `sc_mul`. This is the *confirmed-absent* piece — stdlib
  had only the field inverse mod `p`, never the scalar inverse mod `L`. Implemented as a single
  self-tail-recursive driver (`sc_inv_iter`) because **Rail does not TCO mutual recursion** and a
  256-deep call stack must collapse to a loop — same pattern as the proven `ed_sm_iter`.
- **(b′) Lagrange interpolation mod L** — `frost_lagrange2 xi xj = xj · (xj − xi)⁻¹ mod L`, using
  `sc_inv`. This is what lets *any* 2-of-3 subset reconstruct the same group secret-in-the-exponent.
- **(c) deterministic pulse-derived nonces** — `frost_nonce = sc_reduce(SHA-512(domain ‖ share ‖
  pulse ‖ msg))`. Binding the **share** (distinct per signer) + **pulse** (live beacon, here a DEV
  stand-in) + **message** means: the same signer never reuses a nonce across distinct (pulse,msg),
  and two signers never collide — defusing the catastrophic Ed25519 nonce-reuse footgun **and**
  making the ceremony **byte-reproducible** (the gate's re-run requirement).
- **(d) the binding/challenge hash bit-identical to the verifier** — `frost_challenge =
  sc_reduce(SHA-512(R_enc ‖ A_enc ‖ msg))` is *exactly* `ed25519_verify`'s `k`. (Verify feeds the
  raw 64-byte hash to `[k]A`; sign uses the reduced 32-byte scalar. Since `A = [s]B` has order
  dividing `L`, `[k]A = [k mod L]A`, so the produced sig verifies under the **unmodified** verifier.)

## The math (why the single group sig verifies)

Trusted-dealer Shamir over a degree-(t−1)=1 polynomial `f(x) = s + a₁·x mod L`; share for signer
`i` is `shᵢ = f(i)`; group pk `A = [s]B`. For the chosen set S (e.g. {1,2}):

```
rᵢ = frost_nonce(shᵢ, pulse, msg)         (deterministic)         Rᵢ = [rᵢ]B
R  = Σ Rᵢ,   R_enc = encode(R)
c  = challenge(R_enc, A_enc, msg)
λᵢ = Lagrange coeff of i over S            (mod L)
zᵢ = rᵢ + c·λᵢ·shᵢ mod L                   (= sc_muladd (c·λᵢ) shᵢ rᵢ)
S  = Σ zᵢ mod L
sig = R_enc ‖ S
```

Because `Σ λᵢ·shᵢ = f(0) = s` (Lagrange interpolation at 0) and `Σ rᵢ = r`:

```
S = r + c·s   ⟹   [S]B = [r]B + [c]·[s]B = R + [c]A
```

which is **exactly** the Ed25519 verification equation `[S]B == R + [c]A`. No signer ever computes
`s`; it only ever appears in the dealer setup. ∎

## Soundness obligations (honest)

1. **Trusted dealer vs DKG.** The demo uses a trusted dealer to split `s` (a setup artifact). The
   *per-sign* trust model is already correct — no signer holds `s` at sign time, proven by the
   foreign check's "signs from shares only" test. **Production replaces the dealer with a
   Pedersen/FROST DKG** so `s` is never materialized anywhere; this is a setup-phase swap that does
   not change the per-sign protocol or the verifier. Documented, not hand-waved.
2. **Deterministic-nonce variant.** This is the single-round FROST-with-deterministic-nonces form,
   sound for a **fixed signer set** with pulse-bound nonces (the binding factor is `(share,pulse,
   msg)`). It is **byte-reproducible**, which the gate requires. The interactive two-round FROST
   (per-signing random commitments + binding factors) defends against concurrent-session
   subtleties; that hardening is roadmap (cross-cuts seam #5, key rotation), not a v1 prereq.
3. **`[k]A = [k mod L]A`** relies on `A` having order dividing `L`. `A = [s]B`, `B` has order `L`,
   so this holds; `ed25519_verify`'s small-subgroup check on `A` further guards it.

## The gate (from the ladder) — how each clause is met

| Ladder clause | Where met |
|---|---|
| 2-of-3 ceremony (≥… independent keyholders) over the pulse-anchored link | `frost_2of3_sign`, message = pulse-anchored `sha256` |
| 64-byte sig the **unmodified** foreign `ed25519_verify` accepts under the group pk | `okGroup` (Rail) + foreign check #1 (Python, proven RFC-8032 verifier) |
| re-runs to a **byte-identical** sig from same shares + pulse-derived nonces | `okDet` (Rail) + foreign check #3 (byte-for-byte) |
| **any** 2-of-3 reconstruct the same group sig | `okPair13`, `okPair23`, `okSameGroup` (Rail) + foreign check #4 |

## The falsifiers (from the ladder) — each must REJECT

| Falsifier | Rail gate | Foreign gate |
|---|---|---|
| only k−1 shares → reconstruction fails → sig rejects | `okMinorityFails` | #6a |
| tamper one partial pre-aggregation → aggregate fails verify | `okTamperPartial` | #6b |
| "k=2" reusing one node's key twice → caught by distinct-pubkey | `okDistinct` + `okDupFails` | #6c |
| one-bit flip of the sig → reject | `okBitflip` | #6d |
| wrong message → reject | `okWrongMsg` | #6e |
| `sc_inv` correctness `a·a⁻¹ ≡ 1 mod L` | `okInv` | (implicit: foreign reproduces the sig) |

The Rail gate is the product of all clauses + falsifiers (`all = …`); a single failure → exit 1.
The foreign verifier ANDs all 13 checks; a single failure → exit 1, "FOREIGN FAIL".

## Cross-ISA / heterogeneous silicon

The ceremony arithmetic (point/scalar ops, SHA-512, the FROST scalar algebra) is **pure integer +
byte-array** — no float, no Metal, no platform FFI — so it links on ARM64, x86_64-ELF, and
Linux-ARM64 exactly like the rung-22 `utterance_cross_isa.rail` chain. The clause "heterogeneous
signers reproduce identical link bytes before signing" is **inherited from rung 22**: the
deterministic nonces and challenge are SHA-512 over the canonical `(R_enc, A_enc, msg)` bytes, which
rung 22 already proves are byte-identical across ISAs. A non-Mac signer is therefore a
recompile-and-run of `frost.rail` on that target; the foreign Python check is itself the
"different-language, different-machine" witness for the validate gate. (Running three live ISAs is a
fleet-deployment step, documented; the in-substrate crypto that makes it possible is what this rung
delivers and validates.)

## Files

- `frost.rail` — the FROST-Ed25519 threshold layer (scalar mod-L algebra, `sc_inv`, Lagrange,
  pulse nonces, the ceremony). Reuses all curve/bignum primitives verbatim.
- `frost_main.rail` — driver: runs the 2-of-3 ceremony, the gate (`ed25519_verify` under group pk),
  all falsifiers, writes `frost_ledger.txt`.
- `frost_foreign_check.py` — foreign cross-language verifier (reuses the proven RFC-8032
  `ed25519_verify`); verifies the sig, reproduces it byte-for-byte from shares with **no group
  secret at sign time**, re-runs every falsifier.
- `frost_ledger_reference.txt` — a reference ledger produced by the **validated Python ceremony**
  (identical pulse/msg/group_pk/sig the Rail build will emit); lets the foreign check be exercised
  green **before** the heavy compile, and is what the *Evidence* below was run against.
- `validate.sh` — the serial green-gate command.

## EXACT validate command (what the orchestrator runs)

```bash
bash rungs/r33/validate.sh
```

It (1) compiles `frost_main.rail` (one fast crypto-only compile, default arena, isolated
out-prefix), (2) runs it (Rail self-witness — gate + all falsifiers, writes `frost_ledger.txt`),
(3) re-verifies with the foreign Python witness. GREEN GATE = Rail prints `PASS` (exit 0) **and**
the foreign verifier prints `FOREIGN PASS` (exit 0). Either failing fails the rung.

To re-exercise only the foreign verifier against the reference ledger (no Rail build):

```bash
python3 rungs/r33/frost_foreign_check.py rungs/r33/frost_ledger_reference.txt
```

## Evidence already produced (no heavy build)

The FROST construction was validated **against the proven RFC-8032 `ed25519_verify`** (the exact
verifier the Rail code uses, reused from `tools/bitexact/bx12_foreign_check.py`):

- 2-of-3 `{1,2}`, `{1,3}`, `{2,3}` ceremonies → **all verify under the single group pubkey**
  `20c4960200b156bfab1a9d54d1e7e37023b3112f1830ef575aa238cd52e1a856`.
- k−1 (solo), tampered partial, bit-flip, wrong-message → **all reject**.
- `frost_foreign_check.py` run against `frost_ledger_reference.txt` → **FOREIGN PASS**, all 13
  checks OK (including byte-for-byte reproduction from shares with `s` absent at sign time).
- `L-2` LE constant and the 23-byte nonce domain confirmed exact.

The Rail `frost.rail` performs *these same operations* using the proven `ed_scalar_mul`/
`ed_point_add`/`sc_muladd` primitives plus the new `sc_inv`/`sc_mul`/Lagrange — so the Rail run is
expected to emit a ledger identical to the reference, which the foreign verifier reproduces.

## Honest remaining gap

The one thing **not yet run** is the Rail compile+execute of `frost_main.rail` (deferred to the
orchestrator per compute discipline — the shared compiler must not be thrashed by ~15 concurrent
agents). Two residual risks are therefore Rail-toolchain-level, not cryptographic: (1) a Rail parse
quirk in the new module (mitigated by following the proven `ed_sm_iter` self-recursion shape and the
attested-utterance import pattern verbatim), and (2) `sc_inv`'s ~380-`sc_mul` cost per call over
~5 ceremonies (bounded, sub-second, default arena — but unmeasured on this exact build). The crypto
is proven; the residual is "does this specific .rail compile and run clean," which the validate
command settles in one pass.
