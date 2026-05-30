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
| **P1** Attestation ledger | append-only, Ed25519-signed, hash-chained ledger over the v1 attestations | **LANDED** `tools/attest/attest_chain.rail` (selfhost/append/verify, offline/local-key) — `verify --deep` in progress |
| **P2** `auth` types | authenticated data structures (λ• model): a value carrying proof of its derivation | **building** Stage A library `tools/auth/authkit.rail` |
| **P3** Attested numerics | source-to-source AD; the gradient is itself a re-runnable Rail program; deterministic kernels | **building** first cut `tools/ad/diff.rail` |
| **Demo** | a computation that proves itself (compose P1+P2+P3) | pending |

## How to run

```bash
# P1 — attestation ledger (env: CHAIN_FILE, CHAIN_KEY = 64-hex ed25519 seed)
./rail_native run tools/attest/attest_chain.rail selfhost
./rail_native run tools/attest/attest_chain.rail append <file>
./rail_native run tools/attest/attest_chain.rail verify
# P2 / P3 — see tools/auth/ and tools/ad/ (added as they land)
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
