# The Verifiable Language — Project Index

*Branch: `feat/verifiable-language`. Started 2026-05-30.*

**Vision:** make Rail *the verifiable language* — attestation as a first-class property, on a
self-hosting, byte-reproducible toolchain (the compiler attests itself attesting). The
language-level expression of "physicify"; the substrate for PAOS.

- Thesis: `notes/rail-innovation-thesis-2026-05-30.md`
- Pillar design specs: `notes/rail-pillars-design-2026-05-30.md`

## Pillars + status

| Pillar | What | Status |
|---|---|---|
| **P1** Attestation ledger | append-only, Ed25519-signed, hash-chained ledger over the v1 attestations | **LANDED** `tools/attest/attest_chain.rail` — selfhost/append/verify + `selfcheck` (PROVEN byte-identical fixed point). offline/local-key |
| **P2** `auth` types | authenticated data structures (λ• model): a value carrying proof of its derivation | **LANDED** Stage A `tools/auth/authkit.rail` (Merkle: prove / verify-from-root-only / tamper-reject) |
| **P3** Attested numerics | source-to-source AD; the gradient is itself a re-runnable Rail program | **LANDED** first cut `tools/ad/diff.rail` (Expr→Expr AD; validated vs numerical ~1e-11; deterministic; **2nd-order AD free**; AD-driven gradient descent converges to the minimum) |
| **Demo** | a computation that proves itself (compose P1+P2+P3) | **GREEN** `tools/verifiable_selftest.sh` (deterministic P3 result → P1 chain → verify) |

## How to run

```bash
# P1 — attestation ledger (env: CHAIN_FILE, CHAIN_KEY = 64-hex ed25519 seed)
./rail_native run tools/attest/attest_chain.rail selfhost
./rail_native run tools/attest/attest_chain.rail append <file>
./rail_native run tools/attest/attest_chain.rail verify
# P2 / P3
./rail_native run tools/auth/authkit.rail
./rail_native run tools/ad/diff.rail
# all pillars + the "computation that proves itself" composition
bash tools/verifiable_selftest.sh
```

## Roadmap / follow-ups (the live-surface ones need care)

- **P1:** `verify --deep` (re-run `./rail_native self`, byte-compare → proven fixed point) ·
  Pi-witness signing · beacon `pulse_id` anchoring · publish chain head at `/attest/chain/`.
- **P2:** Stage B = compiler desugar (`auth`/`unauth` two-mode codegen) so the plumbing is implicit.
- **P3:** full transformer AD · deterministic Metal reduction kernels · attested training.
- **Substrate:** incremental checked type layer (dissolves the float-arg class; AD/precise-GC correctness).

## The unifying demo (north star)

A computation that proves itself: P3 produces a bit-reproducible gradient/result → recorded as a
P1 chain entry (beacon-anchored) → over P2-authenticated inputs. A result that arrives with a
public, replayable, tamper-evident proof of exactly how it was derived — end to end, one toolchain.
