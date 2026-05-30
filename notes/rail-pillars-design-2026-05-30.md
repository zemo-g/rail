# Rail Verifiable-Language Pillars — Design Specs

*Status: design (NOT implementation). 2026-05-30. Companion to `rail-innovation-thesis-2026-05-30.md`.*
*Grounded in the real Rail APIs (survey: agent ac0e3f39d6ddc1fed). Constructions: λ• (a0675ed64f67d012f), S2S-AD (ac54acb96f74d1f04).*

Design rule throughout: **lean on what Rail already has; each pillar has a library-first /
minimal-scope path so we validate before touching the self-hosting compiler.**

---

## Pillar 1 — `rail attest`: reproducible-build attestation + transparency ledger

### What already exists (so we EXTEND, not duplicate)
`tools/attest/attest.rail` already: sha256(file) → GET beacon `/entropy/pulse` → POST Pi signer
`fleet0:9102/sign` → writes a `ledatic.attestation` **v1** JSON. `verify.rail` re-checks it, and
**the verifier is itself Rail** (extracts the Ed25519 pubkey from PEM, rebuilds the canonical
message, `ed25519_verify`). Canonical signed msg: `attest|v1|<digest>|<pulse_id>|<value_hex>|<witnessed_at>`.
Records live at `releases/<tag>/`, `builds/<sha>/`, `selfhost/<sha>/`.
**Gap:** there is NO append-only hash-chained ledger here — sequencing is only "dated latest
pointers" + the beacon pulse. (The real hash-chain exists only as the Studio-only `/lab` JSONL.)

### The innovation
Promote attestation from *per-artifact signatures* into a **first-class, append-only,
hash-chained, publicly-verifiable ledger**, and add the record type only Rail can produce:
**the self-compile fixed point.**

### Surface
```
rail attest <artifact>        # wraps attest.rail (existing)
rail attest selfhost          # THE flag-plant: compile compile.rail twice,
                              #   assert gen2==gen3 byte-identical, record it
rail attest test              # attest a 142/142 test-pass
rail verify <record>          # existing single-record verify (Rail)
rail verify --chain           # NEW: walk the chain — every sig + every prev_hash link,
                              #   optionally re-run the fixed-point check live
```

### Refinement (from reading the real code): chain as a SEPARATE layer, v1 untouched
`attest.rail`'s witness is signed by the **Pi** over the canonical message
`attest|v1|<digest>|<pulse_id>|<value_hex>|<witnessed_at>`. Changing that message would touch the
live Pi signer + invalidate every existing attestation. So the ledger is a **separate chaining
layer OVER unchanged v1 attestations** — backward-compatible; zero change to `attest.rail`,
`verify.rail`, or the Pi.

**Chain entry** (new, additive): `{ seq, prev_hash, kind, entry_digest, beacon:{pulse_id,value_hex}, sig, pk }`
- `entry_digest` = sha256 of the wrapped v1 attestation file (for `selfhost`, of the source+binary
  evidence). `prev_hash` = sha256 of the previous entry's canonical line.
- Canonical signed line: `chainv1|<seq>|<prev_hash>|<kind>|<entry_digest>|<pulse_id>`.
- The wrapped v1 attestations stay exactly as-is (Pi-signed, `verify.rail`-compatible).
- `kind` ∈ `{artifact, selfhost-fixedpoint, test-run, release}`.

**`selfhost-fixedpoint`** entry: `entry_digest = sha256("selfhost|" + source_sha256(compile.rail) +
"|" + binary_sha256(rail_native))` — "this binary IS the byte-identical fixed point of this source,"
signed + beacon-anchored. **No other language can sign that claim.**

### Chain file + verifier
Append-only JSONL (one entry/line), linked by `prev_hash`. `rail verify --chain` (pure Rail):
`ed25519_verify` each `sig` over its canonical line, check each `prev_hash == sha256(prev line)`,
confirm `seq` + beacon pulses monotone. Publish head at `ledatic.org/attest/chain/head` + `/<seq>`.

### Spike note (offline, no live surface)
The first spike signs entries with a **LOCAL ed25519 test key** (`stdlib/ed25519_sign.rail`), NOT
the live Pi (`feedback_manual_run_signs_real_chain`). It proves chain + sign + verify +
tamper-reject offline; wiring to the Pi signer + the v1 wrap + publish comes after.

### Build order (low risk; reuses sign path, Rail verifier, sha256, ed25519, beacon, the bootstrap)
1. v1→v2 schema: add `seq`/`prev_hash`/`kind` + extend the canonical message in `attest.rail`/`verify.rail`.
2. `rail attest selfhost` record type (the flag-plant).
3. Chain append + `verify --chain` walker (port `/lab` pattern).
4. Public chain-head endpoint.

### Risk: lowest of the three. It's mostly formalizing + chaining what already runs.

---

## Pillar 2 — `auth` types: authenticated data structures (λ• model)

### Mechanism (POPL'14 λ•, re-grounded VeriAuth CCS'25)
One source, written over a normal recursive type but with sub-references marked `auth τ`. The
compiler emits **two specializations of the same code** — **Prover** and **Verifier** (and a free
**Ideal** = the spec, a test oracle). Identical control flow; only `auth`/`unauth` differ.

- **shallow projection** of a value = identity on plain parts, each nested `auth σ` replaced by its
  32-byte digest (`sha256` of *its* projection).
- **Prover**: an `auth τ` value is `(digest, full_value)`. `unauth` **appends the projection to the
  proof stream** and returns the value.
- **Verifier**: an `auth τ` value is *just the digest*. `unauth` **pops the head of the proof
  stream**, checks `sha256(head) == digest`, returns the reconstructed node (else fails).
- **Security**: a malicious prover that makes the verifier accept a *wrong* answer must exhibit a
  **hash collision** → infeasible under sha256. The verifier holds only a constant-size root digest
  + a streaming cursor.

### Surface (Rail)
```rail
-- `auth` as a field modifier on ADT fields:
type tree = | Tip s | Bin (auth tree) (auth tree)

-- two primitives:
--   auth_make : t -> Auth t      (construct/wrap a node)
--   unauth    : Auth t -> t      (open a node; the only place proof I/O happens)

fetch idx t = match idx, unauth t          -- written ONCE
  | [],     Tip a    -> a
  | (L::r), Bin l _  -> fetch r l
  | (R::r), Bin _ rt -> fetch r rt
```
The compiler emits `fetch_prove` (holds the tree, returns `(result, proof_list)`) and
`fetch_verify` (holds only the root digest + proof_list, returns `result` or fails).

### Compiler vs library (the split that keeps it tractable)
- **Library half (Rail already has it):** `sha256`/`sha256_hex`, a per-type serializer, and an
  append/pop proof-stream buffer (a Rail list). No language support needed.
- **Compiler half (the genuinely new part):** (1) recognize `auth τ`; (2) auto-synthesize each
  type's shallow-projection serializer structurally from its ADT definition (children→digests —
  the AST already carries the structure); (3) emit Prover + Verifier (+ Ideal) lowerings of every
  function; (4) thread the proof-stream so prover-append order == verifier-pop order.

### Staging (validate semantics BEFORE compiler codegen)
- **Stage A — library-first (no compiler change):** Atkey's "ADS as a library, for free" — encode
  Prover/Verifier/Ideal as three explicit instances over a writer/reader-style `return`/`bind` in
  pure Rail. Costs explicit plumbing, but **proves the construction works in Rail** with zero
  compiler risk. Ship the Merkle-dictionary example here first.
- **Stage B — language feature:** the compiler desugar that makes the plumbing implicit, so `fetch`
  reads like ordinary code. This is the flagship novelty.

### Worked check (Stage A target): Merkle membership
`fetch [R;L] t`: Prover emits proof `[Bin(h2,h3), Bin(h6,h7), Tip(s2)]`, result `s2`. Verifier holds
root `h1`: pop `Bin(h2,h3)` check `==h1`; pop `Bin(h6,h7)` check `==h3`; pop `Tip(s2)` check `==h6`;
return `s2`. `O(log n)`, verifier state constant.

### Risk: medium. Stage A is pure library (safe). Stage B is real codegen but self-contained
(desugar + duplicate), no GPU/circuits. Watch: projection synthesis may want a little of the
incremental type layer (field types) — but ADT defs already carry it.

---

## Pillar 3 — attested numerics: source-to-source AD + deterministic kernels

### Mechanism (Tapenade two-sweep, store-all — suits Rail's "arrays-not-closures")
Each differentiated `f` becomes two GENERATED Rail functions:
- `f_fwd(inputs) -> (outputs, tape)` — runs the primal AND appends needed intermediates to a
  **pre-sized `float_arr` tape**, indexed by a **compile-time slot counter** (no closures, no
  dynamic alloc).
- `f_bwd(tape, out_bars) -> in_bars` — walks ops in **reverse (LIFO)**, **accumulating** adjoints
  into a second `float_arr` (`bar[i] += ...`).

Replaces today's `autograd.rail` string-tape (which dispatches on tag strings *because closures
segfault*) with generated source — no runtime tape interpretation.

### Transformation rules (core set)
| primal | fwd records | reverse emits (accumulate) |
|---|---|---|
| `c = a + b` | — | `ā += c̄ ; b̄ += c̄` |
| `c = a - b` | — | `ā += c̄ ; b̄ -= c̄` |
| `c = a * b` | `a,b` | `ā += c̄*b ; b̄ += c̄*a` |
| `c = a / b` | `a,b` | `ā += c̄/b ; b̄ += -c̄*a/(b*b)` |
| `let x = e in body` | `x` | reverse body, then e seeded with `x̄` |
| `f(a,b)` 1st-order | push to callee tape segment | `f_bwd(seg, c̄)`, scatter `ā,b̄` |
| `if p then A else B` | record branch taken (flag) | reverse only taken branch |
| `for i in 0..n` over arrays | per-iter intermediates at stride `base+i*K` | reverse `i=n-1..0` |

Invariants: adjoints **accumulate** (value used twice → two contributions); strict LIFO; loop tape
is fixed stride `K` (one `arena_mark`/`arena_reset` per differentiated call).

### Surface
```
rail diff loss            # emits loss_fwd, loss_bwd, grad_loss as Rail SOURCE to a .rail file
```
`grad_loss(params) -> float_arr` calls fwd then bwd with `out_bar = 1.0`. The gradient is **itself a
Rail program** — compiles via `rail_native`, JITs to Metal through the SAME `jit_match`/`jit_emit`
path as hand-written kernels, and is diff/fixed-point-checkable.

### Minimal first scope
IN: first-order named fns; `Float`/`float_arr` params; the four arithmetics + `float_arr_get/set`;
`let`; `if` over float preds; straight-line; **bounded `for i in 0..n`** (the matmul/rmsnorm/silu/
MHD-stencil shape). DEFER: higher-order/closures, general recursion, unbounded/data-dependent loops,
sum-type `match`, checkpointing (ship store-all first), transcendentals beyond `exp`/`sqrt`/`tanh`.

### Deterministic reduction → attested training (where P3 meets P1)
Reverse accumulation is the only place float ordering matters. Generate `f_bwd` (and its emitted
Metal reduction kernels) with **one fixed reduction order — never nondeterministic atomics**.
Identical order ⇒ identical roundings ⇒ **bit-identical gradients across runs and fleet nodes**.
That determinism makes each gradient/step **hashable** → Ed25519-sign + beacon-anchor it → a record
in the Pillar-1 chain. **Attested training: reproducible by construction, verifiable not asserted.**

### First cut + the killer demo
1. `rail diff` a single kernel (layer-norm or a 2-layer MLP fwd) → generate grad → check vs
   `ag_grad_check` (autograd.rail already has numerical grad-check) → confirm bit-identical across 2 runs.
2. **Demo:** train a tiny model; each step's gradient is a generated Rail program, bit-reproducible,
   signed + chained in the Pillar-1 ledger. This is the demo the whole thesis needs.

### Risk: highest; the endgame. Stage behind P1 (the ledger it writes into) and a usable P3 first
cut. Benefits from the incremental type layer for ergonomics but the float-only minimal scope ships
without it.

---

## How the three compose (the unifying demo)

A **training run that proves itself**: Pillar 3 produces bit-reproducible, attested gradient steps;
Pillar 1's hash-chained ledger records each step (anchored to beacon pulses); Pillar 2's `auth` types
authenticate the training corpus + model weights so a verifier can confirm *which* data produced
*which* update — without holding the data, only digests. The output — a trained model — arrives with
a public, replayable, tamper-evident proof of exactly how it was derived, end to end, in one
self-hosting toolchain. That is "physicify" as a language, and the literal PAOS substrate.

## Recommended first concrete step (still design/prototype, not full build)
- **P1:** smallest + highest-signal — extend the schema to v2 + ship `rail attest selfhost`. Plants the flag.
- **P2:** **Stage A library prototype** of the Merkle example (validates λ• in Rail, zero compiler risk).
- **P3:** `rail diff` on ONE kernel + grad-check + bit-reproducibility check.
Each is a contained spike that de-risks its pillar before committing to the language-level build.
