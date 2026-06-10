# HANDOFF — Pillar 3: attested numerics (source-to-source AD)

> **Archived.** Session handoff from 2026-06-01. The work described here (and
> the reverse-mode follow-up) has since merged to master — see `CHANGELOG.md`.
> Kept as development archaeology; statuses below are frozen as written.

**Read this to resume the `#grad` / forward-mode AD work.** Companion to
`docs/archive/HANDOFF_increment_B_float_inference.md` (the float-typing
substrate this sits on).

## One-line status (verified 2026-06-01)

P3 increments **C0 -> C3 DONE**, all on branch **`feat/p3-attested-numerics`**,
**committed, NOT pushed**, local-only (no upstream). The branch is exactly **5
commits ahead of public master** (`origin/master` @ `71261fc`, the PR #8 merge):

```
710a2eb  P3 C3  -- forward-mode AD through let-bindings (DAG nodes)
99c996b  P3 C2  -- transcendentals (chain rule over unary float intrinsics)
cf098b4  P3 C1  -- multi-input forward-mode (indexed f__grad <params> __gi)
5bf9bab  P3 C0.2 -- three-witness differential oracle for the #grad desugar
ea61a48  P3 C0-A -- forward-mode AD desugar emits f__grad as re-attestable Rail
```

`origin/master` already contains `dae4985` (the P2 Stage B base these sit on),
so **pushing is trivial — no rebase**: `git push -u origin feat/p3-attested-numerics`
puts just these 5 commits atop current public master. Do that ONLY when Reilly
says push.

## The thesis (why this exists)

Pillar 3 of the verifiable-language thesis. A `#grad`-marked forward float
function `f` desugars at compile time into a **synthesized Rail function
`f__grad`** — the gradient is itself ordinary Rail source, so it is
re-compilable and **re-attestable** (same provenance machinery as any other Rail
program). "The gradient is a Rail program." The moat is attestation, not the AD
algorithm. Endgame: attested numerics under training.

## What's built (the desugar)

`#grad f` over a forward float fn `f p0 p1 .. = <body>` synthesizes
`f__grad p0 p1 .. __gi` where `__gi` is an int **selector**: the body is an
if-chain returning the directional derivative d f / d(input `__gi`) (forward-mode
= one partial per call; out-of-range selector -> `0.0`). All in
`tools/compile.rail`:

- **`grad_deriv node p scope`** (~line 2956) — the differentiator. `node` is a
  parsed AST node, `p` the param name being differentiated wrt, `scope` the list
  of let-bound tangent vars currently visible. Returns a derivative AST.
- **`grad_chain ps body idx`** (~line 3040) — builds the selector if-chain,
  seeding `grad_deriv body (head ps) []` (empty scope) per param.
- **`grad_scope_has nm scope`** — membership for the let-scope.
- **`grad_ucall fn arg = ["A",["V",fn],arg]`** — helper to emit a unary call.

### AST node shapes `grad_deriv` matches (parser output)
`["FL",s]` float lit · `["I",s]` int lit · `["V",nm]` var · `["O",op,l,r]`
binop (op in `+ - * /`) · `["A",func,arg]` curried application (`sin x` =
`["A",["V","sin"],["V","x"]]`) · `["D",nm,val,body]` single-binding `let nm = val
in body` · `["?",c,t,e]` if-expr. (`["L",...]` is a LIST literal, NOT a let —
confusingly named. `["TD",..]` is tuple-destructure let, not yet handled.)

### Rules implemented
- d(const)=0 · d(var): scope-first — let-bound -> `nm__d`, else == p -> 1.0,
  else 0.0 · d(a+b)=da+db · d(a-b)=da-db · d(a*b)=da*b+a*db ·
  d(a/b)=(da*b-a*db)/(b*b)
- **transcendentals (C2)** via chain rule on `["A",["V",fn],arg]`: sin->cos*du,
  cos->(0-sin)*du, exp->exp*du, tanh->(1-tanh*tanh)*du, sqrt->du/(sqrt+sqrt),
  log->du/arg, fneg->0-du. (sqrt uses `du/(sqrt u + sqrt u)` to avoid emitting a
  `2.0` literal — keeps the oracle's consts[0]=0/consts[1]=1 convention.)
- **let (C3)**: `["D",nm,val,body]` emits a primal binding `let nm = val` PLUS a
  tangent `let nm__d = d(val)`, then differentiates `body` with `nm` pushed on
  scope. A `let` names a SHARED subexpr (DAG node); the emitted gradient is
  exactly the inlined one, bit-for-bit. This is the gateway to reverse-mode.

## The gate (run ALL of this before any commit on this track)

1. **Self-host cycle 1** (~6-12 min): `./rail_native self` -> `/tmp/rail_self`
   (= gen1, which now CONTAINS the new AD logic). `cp /tmp/rail_self rail_native`.
2. **Test suite**: `./rail_native test` -> **162/162** (t155 `p3_grad_transcendental`,
   t156 `p3_grad_let`). ~15 min.
3. **Oracles** (fast; ALWAYS use `--out-prefix` to a unique path so you don't
   clash with the entropy beacon's `/tmp/rail_out`):
   - `./rail_native --out-prefix /tmp/rail_o1 run tools/ad/grad_oracle_test.rail` -> **8/8** (C0/C1, 3 witnesses)
   - `./rail_native --out-prefix /tmp/rail_o2 run tools/ad/grad_trans_oracle_test.rail` -> **9/9** (C2, 3 witnesses)
   - `./rail_native --out-prefix /tmp/rail_lo run tools/ad/grad_let_oracle_test.rail` -> **6/6** (C3, FOUR witnesses)
   - `./rail_native --out-prefix /tmp/rail_fz run tools/fuzz/diff_fuzz.rail --seed=42 --n=20` -> **20/20**
4. **Self-host cycle 2** (byte-identical fixed point, ~6 min):
   `./rail_native self && cmp rail_native /tmp/rail_self` -> identical (gen1==gen2).

The AD logic fires ONLY on `#grad`-marked user code, never inside compile.rail's
own compilation (it declares no `#grad` fns), so the fixed point lands cleanly.

## The witness oracles (what makes this trustworthy)

Independent cross-checks that the synthesized `f__grad` is correct:
- **synth** = the compiler's `f__grad`
- **symbolic** = `tools/ad/diff.rail` — an independent Expr DSL
  (`Var|Kst|Add|Sub|Mul|Div|Sin|Cos|Exp|Tanh|Sqrt`) with its own `diff`/`eval`.
  synth and symbolic come out **BIT-IDENTICAL**.
- **numeric** = central finite-difference, matches within ~1e-3 tol.
- **C3's 4th witness**: synth-let == synth-flat (a let-bearing fn vs its inlined
  twin) — proves let-differentiation produces exactly the flattened gradient,
  bit-for-bit, incl. the signed-zero cancellation at x=-0.5.

diff.rail discipline: floats live in `float_arr` (never ADT fields); `eval_into`
writes out[0] to dodge a recursive-float-return inference bug. Benign
`comparison '<' on int and float` warning is expected (float locals
conservatively int-tagged; codegen still emits fcmp).

## Next: C4 — true reverse-mode

C0-C3 are all forward-mode (one directional derivative per call; cost scales
with #inputs). C4 is the real prize the `let`/DAG work was paving toward:
**reverse-mode** — a `let`-bound subexpr referenced MULTIPLE times in the body
must accumulate ALL its downstream cotangents into ONE adjoint (`v_bar +=
...`), then propagate once. That's backprop. Design question to settle first:
emit a tape/Wengert list, or a closure-based pullback? Forward-mode (C0-C3)
keeps working as the differential oracle to validate reverse-mode against.

## Pointers
- Substrate: `docs/archive/HANDOFF_increment_B_float_inference.md`
- Diagnose-first is mandatory on this track (it disproved the "needs joint
  fixpoint" fear twice already) — minimal repro before big surgery; the
  bootstrap fixed point is sacred.
