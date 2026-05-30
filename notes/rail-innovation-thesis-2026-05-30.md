# Rail Innovation Thesis — "The Verifiable Language"

*Status: research + plan (NOT implementation). 2026-05-30.*
*Inputs: codebase survey + external SOTA (attestation; AD/GPU) + Rail ethos/direction memory.*

## TL;DR

Rail will not win on speed or ergonomics — JAX, Julia, and Mojo own those and are years
ahead. Rail's one defensible, unclaimed frontier is being the only **self-hosting,
byte-reproducible toolchain where attestation is a first-class language primitive** —
closing the verification surface top-to-bottom (the compiler attests itself attesting).
This is the "physicify" thesis expressed *as a language*, and it is exactly the substrate
PAOS needs. Three independent research threads converged on this.

## What NOT to chase (grounded in SOTA, so we don't waste the run)

- **General zkVM** (RISC Zero, SP1/Succinct, Jolt) — an unwinnable arms race needing GPU
  clusters + circuit expertise. None is self-hosting; they bolt ZK onto a RISC-V backend.
- **TEEs** (SGX/TDX/SEV/TPM) — trust-eroding (DDR5 interposer attacks, tee.fail 2025) and
  hardware-root-of-trust is *precisely what physicify rejects*. Useful only as the foil:
  TEEs say "trust this chip"; Rail says "verify this computation."
- **CompCert-grade formal verification** — decades of Coq/HOL; not LLM-maintainable.
- **AD/GPU for ergonomics** — Swift-for-TensorFlow built genuine language-level `@differentiable`
  and still died: no painpoint pulled users off Python. Lesson: **Rail's AD must be motivated
  by a property libraries can't give — attestation — not ergonomics.**

## The position nobody else holds

zkVMs aren't self-hosting. Verified compilers (CompCert/CakeML) aren't crypto-attested.
Authenticated-data-structure research (λ•) isn't productized. Rail already owns the rarest
asset of all: a **byte-identical 2-pass self-compile fixed point** + a Rail-native Ed25519
hash-chain + entropy-beacon anchoring. No incumbent has all three. The innovation is to turn
that asset into a *language feature*, not a deploy script.

## Three pillars (staged; each kept LLM-maintainable per the simplicity ethos)

### Pillar 1 — Reproducible-build attestation + transparency ledger  *(ship-first, low risk)*
Formalize the existing byte-identical fixed point into `rail attest`: a signed, append-only
(Rekor-style) provenance record — "this source → these exact bytes, at beacon pulse N."
- **Novel/defensible:** most languages can't make the reproducibility claim at all
  (non-deterministic toolchains); Rail already nails the hard part.
- **Effort:** low — mostly exposing + signing what already exists (fixed point + ed25519 + beacon).
- **Payoff:** establishes the "verifiable language" position publicly; immediately demonstrable.

### Pillar 2 — `auth`-typed authenticated data structures  *(flagship novelty)*
A type annotation `auth τ` from which the compiler **auto-derives** a prover (emits hash
proofs as it computes) and a verifier (re-checks against a digest) — the λ• model
(Miller/Hicks; logical-relations re-grounding CCS'25). Built on Rail's existing hash/Ed25519 stdlib.
- **Novel/defensible:** "a value carrying cryptographic evidence of how it was derived" as a
  first-class type — essentially nobody ships this. Research-proven, productization unclaimed.
  The deepest fit with "the work proves itself."
- **Fit-to-ethos:** a self-contained source-to-source transform — no GPU, no circuits, no full
  type system required. LLM-tractable.
- **Effort:** medium; needs a focused design pass on Rail syntax/semantics + the prover/verifier split.

### Pillar 3 — Attested numerics: deterministic kernels + source-to-source AD  *(the PAOS payoff)*
(a) Extend the existing fusion DAG so kernels emit in a **fixed, attested reduction order**
(RFA-style binned/deterministic accumulation) → bit-reproducible training as a *compiler
guarantee*. (b) Source-to-source reverse-mode AD on Rail's own IR (Zygote/Dex model — NOT
Enzyme, which needs LLVM type analysis) that emits the gradient **as a Rail program that
re-runs and re-attests**.
- **Novel/defensible:** no one owns codegen + AD + attestation in one self-hosting toolchain.
  "The gradient is itself a re-attestable Rail program" *is* the PAOS thesis (outputs are Rail,
  numerics verifiable).
- **Effort:** high — the endgame, not the start. Today's autograd is a string-tape library + 2
  hardcoded fused kernels; this generalizes both. Do on Studio's GPU.

## Enabling substrate (incremental, NOT a big-bang rewrite)

A checked type layer promoted from the **existing** forward-inference (`__float_`/`is_int`/
`is_float` already feed codegen + precise GC). The codebase survey's headline: *"one mechanism
unlocks four limitations"* — it dissolves the multi-arg float-param miscompile (today's
recurring papercut; only the comparison case is fixed as of `d653a72`), segfault-on-type-error,
and makes AD + precise-GC correct-by-construction. Also unblocks first-class capturing closures
+ float-self-loop TCO (removing workarounds that ripple through the whole ML stdlib).
**Do it incrementally where Pillars 2/3 demand it** — the compiler is LLM-maintained; avoid a
massive refactor.

## Recommended sequencing

1. **Pillar 1** — establish the position; low risk, high signal.
2. **Pillar 2** design pass → prototype `auth` types (the flagship novelty).
3. **Type-layer increments** as Pillars 2/3 require.
4. **Pillar 3** — attested numerics, the PAOS endgame, on Studio.

**First concrete step (still design, not build):** a focused design doc for the `rail attest`
ledger format AND the `auth`-type semantics/syntax.

## Risks / unknowns

- `auth`-type ergonomics on a weak type system may force some type-layer work earlier.
- Deterministic GPU reduction may cost throughput (binned accumulation) — acceptable for
  *attested* training, but measure it.
- "Verifiable language" is a positioning bet — it needs a killer demo to land (e.g., an attested
  model-training run whose gradient is a re-runnable, re-attestable Rail program).

## Resources

- Studio M1 Ultra 64GB for Pillar 3 GPU/AD.
- Existing assets: stdlib ed25519/hash, the JIT DAG matcher + MSL emitter, autograd/transformer/
  optim/checkpoint, the fixed-point bootstrap, the live attestation chain + beacon.
- Resumable research agents: a0432f6f467f961f9 (codebase), ab9137de7a64920e6 (attestation SOTA),
  ac08e780efbf0aae4 (AD/GPU SOTA).

## Key references

- Authenticated Data Structures, Generically (λ•) — cs.umd.edu/~mwh/papers/gpads.pdf;
  Logical Relations for Verified ADS, CCS'25 — iris-project.org/pdfs/2025-ccs-veriauth.pdf
- CompCert (compcert.org), CakeML (cakeml.org) — verified compilers (correctness ≠ attestation)
- SLSA / Sigstore / Rekor v2 — reproducible-build provenance + transparency log
- Enzyme (arxiv 2010.01709), Zygote.jl, Dex (parallelism-preserving AD), Futhark, Triton, TVM, Halide
- RepDL (bit-reproducible training), "Optimistic Verifiable Training by Controlling Hardware
  Nondeterminism" (arxiv 2403.09603)
