# Pillar 3 (Attested Numerics) — diagnose-first, 2026-05-31

> **Archived.** Diagnosis doc from 2026-05-31. The AD work it scopes has since
> merged to master (forward + reverse mode) — see `CHANGELOG.md`. Frozen as written.

## What Pillar 3 is (canonical, from the thesis)
Two facets:
1. **Source-to-source AD** — emit the gradient AS a re-attestable Rail program (Zygote/Dex
   model, NOT Enzyme). The moat is attestation ("the gradient is a Rail program"), not ergonomics.
2. **Deterministic-reduction GPU kernels** — bit-reproducible training as a compiler guarantee.
   Highest effort, Metal GPU. (Out of scope for a first increment.)

## State of the board (evidence, not memory)
- **A first cut already exists, but is NOT on master.** It lives on `feat/verifiable-language @ 337d66a`:
  - `tools/ad/diff.rail` (151 lines) — forward **symbolic** AD on a tiny `Expr` DSL
    (`Var/Kst/Add/Sub/Mul/Div`). `diff e i : Expr -> Expr` returns the gradient EXPRESSION.
    Validated symbolic==numerical ~1e-11; deterministic; 2nd-order free; gradient descent converges.
    Dodges the float-in-ADT trap by storing constants as int indices into a `consts` float_arr.
  - `tools/ad/revad.rail` (345 lines) — reverse-mode (Tapenade two-sweep) over a real float_arr
    MLP kernel (N=3,H=4), validated vs numerical 1e-4, bit-identical determinism.
  - `tools/attested_step.sh` / `tools/verifiable_selftest.sh` — the integrated "computation that
    proves itself" demo (all green on that branch).
- `git merge-base --is-ancestor 337d66a master` => **NO**. Current master (post PR #8) has Pillars
  1 (attest_chain) + 2 (auth Stage A+B) but **zero Pillar-3 artifacts**.
- Both existing cuts are **library/tool** implementations (interpreted Expr DSL; hand-written
  kernel). Neither is a **compiler desugar**. That is the open frontier — and the exact symmetric
  move to the Stage B win (which elevated Pillar 2 from a library oracle to a compiler desugar).

## Diagnose-first probe (the reachability gate) — GREEN
`/tmp/p3_probe.rail` on the current binary (520b6a55 = B4/Stage-B = type-layer A/A+/B + Stage B):
the SHAPE a forward-mode AD desugar would EMIT — float-scalar in/out, inline derivative with the
sum/product rule, including dead `0.0*.x` terms — compiles and runs correctly:
```
f(2)=10  analytic(2)=7  emitted(2)=7  numeric(2)=6.99999999999967  emitted(5)=13  emitted(0)=3
```
=> The type-layer merge (A/A+/B) de-risked exactly what design §2.6 promised: a synthesized
float-returning `grad_*` is correct-by-construction, no out-cell workaround. The synthesis target
is compilable on master TODAY.

## Constraints
- **Stay in the proven float envelope.** A/A+/B + Stage B are merged; `examples/mlp_natural.rail`
  + t140 + this probe prove float-scalar params/returns/compose work. BUT Phase 2 (recursive
  float-return, `show` on an unboxed float) is NOT done — keep the v1 grammar non-recursive and
  print via `show_float`.
- **Fixed-point discipline.** Any compile.rail change must hold the byte-identical fixed point
  (gen2==gen3) + 158/158 + diff-fuzzer 20/20. Same gate as B0-B4.
- **P3 is human-in-loop by design.** The phase-design doc kept the compiler tracks OUT of the
  autonomous swarm: "analysis BEFORE coding." Hence this doc + an approach decision before codegen.
- **diff.rail is the differential oracle** — exactly as Stage A authkit/authdict was Stage B's
  byte-exact oracle. Vendor it, diff the synthesized gradient against it + numerical.

## Two approaches
### Approach 1 — Compiler desugar (Stage-B-symmetric). RECOMMENDED.
The compiler recognizes a forward function `f` over float scalars and synthesizes `f__grad`
(its derivative), itself pure Rail. "The compiler EMITS the gradient as a re-attestable Rail
program, correct-by-construction." Scope v1 minimally: forward-mode, single float-scalar input,
the `+ - * /` + const grammar diff.rail already validates. Oracle = vendored diff.rail + numerical.
- PRO: the true Pillar-3 frontier; mirrors the Stage B desugar we just landed; uses the type layer
  precisely as intended; novel + thesis-defining.
- CON: touches compile.rail (fixed-point gate every increment); AD scope must be held tight (start
  scalar/forward, generalize later — same staged discipline as B0->B4).

### Approach 2 — Consolidate the existing first cut onto master.
Forward-port diff.rail + revad.rail into the tree as gated, tested components (stdlib or tools +
regression tests in the 158-suite + the attested_step demo wired to CI). No new compiler codegen.
- PRO: low risk; lands real Pillar-3 substrate + the "proves itself" demo on master + in CI; no
  fixed-point exposure.
- CON: it's the LIBRARY approach (interpreted Expr DSL), not the compiler desugar — a consolidation,
  not an advance. Doesn't extend the Stage B mechanism.

### Hybrid (my actual recommendation)
Do **Approach 1**, but vendor diff.rail as the differential oracle in the SAME commit lineage
(exactly the authkit/authdict pattern). First increment = "C0/P3-A": parse a `grad`-marked forward
scalar fn -> synthesize `f__grad` -> gate against diff.rail + numerical. Then stage upward
(multi-input, then reverse-mode at kernel scale) the way B0->B4 staged.
