# Rail attestation threat model

Rail's motto is **"check me, don't trust me."** That is only meaningful if it says
*who could lie, what it would cost them, and what is out of scope.* This page makes
the claim falsifiable. The claim is **never** "proof of truth."

## What is signed

- **Release artifacts** — the committed seed binary and self-host artifacts
  (`tools/attest/attest_release.sh`, `release_index.rail`).
- **Self-host attestations** — that the seed reproduces itself byte-identically
  (`attest_selfhost.sh`).
- **Test-run attestations** — that the suite passed at a given revision
  (`attest_test_run.sh`).
- **(ML) per-step gradient ledgers** — on the attested-training path, each step's
  inputs/outputs are hashed and signed, so a forged gradient fails verification.

Signatures are **Ed25519**. Each attestation is anchored to a **public entropy
beacon** (`ledatic.org/entropy`) by `pulse_id`, giving tamper-evident sequencing
that no single party controls.

## Who signs, and the verifiers

- A **witness signer** holds the Ed25519 private key and signs attestations
  (`tools/attest/pi_sign_server.rail`).
- **`tools/attest/verify.rail`** re-checks signatures and hashes — the verifier is
  itself Rail.
- A **reproducibility witness** rebuilds public master from source daily and
  `cmp`s the committed seed (`com.ledatic.rail_repro_witness`), alerting on
  mismatch.
- **Anyone** can run `./verify_reproducible.sh` (see [VERIFY.md](../VERIFY.md)) to
  reproduce the seed from source on their own machine — the strongest check,
  because it does not require trusting the maintainer.

## What an undetected lie costs

> An undetected lie costs the compromise or collusion of **every independent
> verifier that actually recomputes the relevant artifact from pinned inputs under
> this contract.**

It does **not** cost "a conspiracy" in the abstract — it costs exactly the
load-bearing elements below. Naming them is the point.

### Load-bearing assumptions (compromise any one and the guarantee weakens)

- The **signer key** is not exfiltrated.
- The **build is reproducible** from pinned source + compiler + environment.
- The **verifier** (`verify.rail`, `verify_reproducible.sh`) is itself correct.
- At least one **independent** verifier recomputes — see the gap below.
- The pinned inputs (source, seed hash, data/weights for ML) are the real ones.

## Out of scope (explicitly not claimed)

- **Correctness.** Provenance ≠ correctness. A signed, reproducible result can be
  wrong. Compilation proves *accepted by the binary you run*, not *correct*.
- **Numerical truth.** A signature proves *who signed these bytes*, not that the
  number is mathematically right (see [NUMERICS.md](NUMERICS.md)).
- **Trusting-trust.** Byte-identical self-hosting does **not** prove the binary
  faithfully implements the source — a malicious seed could reproduce itself while
  miscompiling. **A Rail compiler verifying a Rail compiler is not independent.**
  Closing this needs a non-Rail check path (diverse double-compilation or an
  independent reference checker) — it is *open work*, not a current guarantee.
- **Side channels**, a compromised signing host, and supply-chain attacks upstream
  of the pinned inputs.

## The honest one-line version

Rail makes computations **reproducible and auditable** by pinning and signing
source, compiler, build products, and (for ML) per-step ledgers, anchored to a
public beacon. That makes an undetected lie *expensive and detectable* — not
impossible, and not a proof of truth.
