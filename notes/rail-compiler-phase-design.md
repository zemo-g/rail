# Rail Compiler — Next-Phase Design Spec (high-risk items, OUT of the build swarm)

*Status: DESIGN ONLY. 2026-05-30. No code touched. Companion to `rail-pillars-design-2026-05-30.md`
(Pillar 2 = `auth` types) and `rail-innovation-thesis-2026-05-30.md` (the checked type layer as the
"one mechanism unlocks four limitations" substrate).*

Two deliberately-deferred compiler tracks, each specced concretely enough for one careful serial
session. Both obey the hard constraint that `tools/compile.rail` is **LLM-maintained and must stay
simple** — incremental, additive, no big-bang rewrite — and both obey the **>=2-cycle byte-identical
fixed-point** bootstrap discipline (per the repo `CLAUDE.md` bootstrap table).

All line refs are against `tools/compile.rail` @ `feat/verifiable-language` (HEAD `692bb9a`, 7050
lines, 141 tests). Grounding evidence (reproduced live this session, ARM64 macOS / Studio):

| Probe | Source | Observed | Correct | Meaning |
|---|---|---|---|---|
| single-arg float, `show_float` | `half x = x /. 2.0; show_float (half 8.0)` | `4` | `4` | OK (d8 path delivers raw bits) |
| **2-arg arith float** | `mul2 a b = a *. b; show_float (mul2 3.0 4.0)` | `4.94e-324` | `12` | **arith-float-param miscompile (UNFIXED)** — `a`,`b` read as tagged ints |
| **recursive float ret, `show_float`** | `rec_half n x = if n<=0 then x else rec_half (n-1) (x/.2.0); show_float (rec_half 3 8.0)` | `1` | `1.0` | **recursive float-return not inferred** — value int-truncated |
| **recursive float ret, `show`** | same, `show (rec_half 3 8.0)` | **segfault** | `1.0` | cross-fn float-return gap + recursion |

`4.94065645841247e-324` is the denormal you get when a tagged-int bit pattern is reinterpreted as an
IEEE double — the signature of "float param read through the int ABI."

---

# TRACK 1 — P2 Stage B: the `auth`/`unauth` compiler desugar

## 1.0 What already exists (build ON it, don't redo)

Stage A is **landed on this branch**: `tools/auth/authkit.rail` (Merkle membership) and
`tools/auth/authdict.rail` (string-keyed BST). They prove the λ• construction works in pure Rail with
zero compiler change. The shapes Stage B must AUTO-GENERATE are exactly the hand-written functions in
`authkit.rail`:

```rail
type Tree = | Tip s | Bin l r
proj_of t = match t                        -- shallow projection (children -> digests)
  | Tip s   -> cat ["T:", s]
  | Bin l r -> cat ["B:", digest l, ":", digest r]
digest t = sha256_hex (proj_of t)
prover_fetch  t path proof = match t ...    -- holds full tree, snoc projection to proof
verifier_fetch expected path proof = ...    -- holds only root digest, pop+check, navigate by digest
```

Stage A is the **executable spec / test oracle** ("Ideal"). Stage B's correctness bar: for every
`auth`-typed program, the generated Prover/Verifier must produce byte-identical proofs + identical
accept/reject decisions to a hand-written Stage-A encoding of the same logic. The Stage A files are
already the differential reference — wire them into the regression harness (see 1.7).

## 1.1 Surface syntax (minimal, parseable with the existing lexer)

`auth` is a **field modifier on ADT constructor fields** plus two **primitives**. No new keyword in
expression position beyond two ordinary-looking calls:

```rail
type tree = | Tip s | Bin (auth tree) (auth tree)   -- `auth` wraps a field's type
-- auth_make : t -> Auth t      construct/wrap a node (Prover: (digest,val); Verifier: digest)
-- unauth    : Auth t -> t      open a node — THE ONLY place proof I/O happens
fetch idx t = match idx, unauth t           -- written ONCE
  | [],     Tip a    -> a
  | (L::r), Bin l _  -> fetch r l
  | (R::r), Bin _ rt -> fetch r rt
```

The compiler emits `fetch__prove` (holds tree, returns `(result, proof)`) and `fetch__verify`
(holds root digest + proof, returns `result` or `error`). The Ideal lowering `fetch__ideal` is just
the source with `unauth`/`auth_make` as identity — a free test oracle.

### Why `auth` parses today with near-zero lexer risk
`pvariants`/`count_params` (lines 481-495) build each variant as `[ctor, idx, arity]` by **counting
`id` tokens** after the constructor name. `auth tree` is two `id` tokens — today that would over-count
arity (auth=1 field, tree=1 field → arity 2). So the ONLY parser change is: in `count_params`,
recognize the literal identifier `auth` as a *field-type modifier* that consumes the FOLLOWING type
token and contributes ONE field of kind=authenticated, rather than counting as its own field.

## 1.2 Compile.rail hook points (functions + line refs)

| # | Hook | Line(s) | Change |
|---|---|---|---|
| H1 | `count_params` | 491-495 | When `cv ts == "auth"`, skip it, consume next `id` as the field's auth-type; return arity unchanged-per-field but record a **per-field auth bitmask** alongside the count. |
| H2 | `pvariants` / `ptype` | 481-489 / 474-479 | Thread the per-field auth mask into the variant tuple: `[ctor, idx, arity, authmask, fieldtypes]` (additive — extra tuple slots; existing `head/head·tail/head·tail·tail` readers untouched). |
| H3 | `ctor_arities` | 2522-2530 | Unchanged for arity encoding; ADD a sibling pass `collect_auth_types decls` producing a global `authtype_table` (ctor -> authmask + child type name) consumed by projection synthesis. |
| H4 | NEW `synth_proj_fn` + `synth_digest_fn` | insert near 2530 | Structurally emit `proj_of_<TY>` and `digest_<TY>` AST (or asm-via-source) from `authtype_table`: plain fields copied, `auth σ` fields replaced by `digest_<σ> child`. Mirror `authkit.rail`'s `proj_of`/`digest` exactly. |
| H5 | NEW `lower_auth_fn` (the duplicator) | insert near `compile_func` 2611 | For each user fn that mentions `unauth`/`auth_make` (detected by an `fn_uses_auth bd` walk modeled on `is_self_rec` line 2072), emit THREE renamed clones: `<fn>__prove`, `<fn>__verify`, `<fn>__ideal`, each with `unauth`/`auth_make` rewritten per role. |
| H6 | `cg` A-handler | 1316-1344 | Recognize `auth_make` and `unauth` as builtins dispatched by the **current lowering mode** (a marker `__auth_mode` in `env`: 1=prove, 2=verify, 3=ideal). No new runtime asm — they lower to existing `cat`/`sha256_hex`/list-snoc/pop calls. |
| H7 | `get_arities` | 2309-2319 | Register the synthesized `proj_of_*`, `digest_*`, and the `__prove/__verify/__ideal` clones in the arity map (3 user-fn entries per auth fn) so call sites resolve. |

`__auth_mode` rides in `env` exactly like `__self_lbl`/`__nregs` (line 2627, 2631) — a `cons (key,val)`
the duplicator sets per-clone. `cg`'s A-handler reads it with `efind` (the established pattern).

## 1.3 The transformation (per role)

Threading a **proof-stream buffer** = thread an extra accumulator param, identical to how
`authkit.rail`'s `prover_fetch ... proof` carries `proof`. The duplicator rewrites each clone's
signature to add a trailing `__proof` param and rewrites `unauth`/`auth_make`:

**Prover** (`__auth_mode=1`): an `auth τ` value at runtime is the pair `(digest, full_value)`.
- `auth_make v` → `(digest_<τ> v, v)` (build node, precompute its digest).
- `unauth x` → `let __proof = snoc __proof (proj_of_<τ> (snd x))` then return `snd x`. **Append.**
- Return type becomes `(result, __proof)`.

**Verifier** (`__auth_mode=2`): an `auth τ` value is *just the digest* (constant size).
- `auth_make v` → `digest_<τ> v` is NOT available (verifier has no `v`); instead the verifier never
  *constructs* — it only *navigates*. `auth_make` in verifier-reachable code is a type error caught by
  the type layer (Track 2). For the read-only λ• core (`fetch`), `auth_make` appears only in
  builder code, never in verifier paths.
- `unauth x` (x = a digest) → `if __proof==[] then error "exhausted" else let pj=head __proof;
  rest=tail __proof; if sha256_hex pj != x then error "digest mismatch" else <reconstruct node from
  pj>; __proof:=rest`. **Pop + check.** Reconstruction parses `pj` back into a constructor whose
  sub-`auth` fields are the sub-digests embedded in `pj` (exactly `authkit.rail`'s `dl`/`dr`
  extraction).

**Ideal** (`__auth_mode=3`): `unauth x = x`, `auth_make v = v`. The source runs unmodified — the
free oracle. No proof param threaded (or threaded and ignored).

**Order invariant (the crux):** the duplicator preserves source evaluation order, so Prover-append
order == Verifier-pop order **by construction** — both clones share identical control flow; only the
`unauth` body differs. This is the λ• guarantee and the reason the two clones must be generated from
ONE traversal, never hand-paired. The Stage A files already exhibit the matched order; Stage B must
not reorder match arms or `let` sequencing during cloning (a pure alpha-rename + local body swap).

## 1.4 Projection serializer synthesis (H4 detail)

From `authtype_table[ctor] = (authmask, [childtypes])`, emit `proj_of_<TY>` as a `match` over the
type's constructors (the AST shape `cg_arms` at 1664 already compiles). For each constructor:
- emit a tag prefix (`cat ["<ctorname>:", ...]`),
- plain field `f` → append a **length-prefixed** encoding of `f` (use `authdict.rail`'s
  length-prefix framing — it already solved ambiguous-bytes for arbitrary key/value contents),
- `auth σ` field `c` → append `digest_<σ> c`.

Length-prefix framing is mandatory (see `authdict.rail` commit `692bb9a`: unambiguous hashed bytes for
arbitrary contents). Do NOT use the bare `:`-join of `authkit.rail` for the general case — it was fine
for fixed leaf shapes but collides on payloads containing `:`.

`digest_<TY> t = sha256_hex (proj_of_<TY> t)` — one line, mirrors `authkit.rail:digest`.

## 1.5 Staging (validate each layer before the next)

- **B0 (parser only, 1 cycle):** H1/H2 — parse `auth τ` fields, thread the mask, **emit nothing new**.
  Verify: an `auth`-typed `type` decl compiles and behaves as a plain ADT (auth ignored). 141/141
  unchanged. This isolates lexer/parser risk to one cycle with zero codegen.
- **B1 (projection synthesis, 2 cycles):** H3/H4 — generate `proj_of_*`/`digest_*`. Verify the
  generated `digest_Tree` of the `authkit.rail` sample tree == the hand-written `digest` root
  (byte-equal). No duplication yet.
- **B2 (the duplicator, 2 cycles):** H5/H6/H7 — emit `__prove`/`__verify`/`__ideal`. Verify
  `fetch__prove`/`fetch__verify` reproduce `authkit.rail`'s proof + accept/reject, AND the three
  tamper cases (swapped leaf, forged root, wrong-value) still REJECT.
- **B3 (authdict, regression):** run the same against the `authdict.rail` BST shape — string-keyed,
  length-prefixed — to prove the synthesis generalizes past the binary tree.

Each stage is independently revertable; B0/B1 ship value (derived Merkle digests) even if B2 slips.

## 1.6 Keeping the byte-identical fixed point intact

- H1-H7 are **source-logic-only** (parser branches + new emit functions that produce asm-via-source
  strings using EXISTING runtime helpers `sha256_hex`/`cat`/`snoc`/list ops). Per the bootstrap table,
  source-logic edits are **1-cycle** to take effect. BUT B1/B2 introduce **new emitted call patterns**
  (calls to synthesized `digest_*`/`__prove` fns), which the table classifies as needing **2 cycles**
  to bake, then a **3rd cycle to prove gen2==gen3**.
- **No new `rt_*` runtime asm constants** — this is the discipline that keeps it 2-cycle not "data
  section bug" territory (`CLAUDE.md` DATA SECTION BUG note). `auth_make`/`unauth` MUST lower to
  existing primitives; do not add `_rail_auth_*` runtime symbols.
- ASCII-only in any synthesized `.asciz` (tag prefixes like `"B:"`, `"T:"`) — already satisfied.
- Procedure each stage: edit → `./rail_native self` → `cp /tmp/rail_self rail_native` →
  `./rail_native test` (must hold) → `./rail_native self && cmp rail_native /tmp/rail_self` twice
  (gen2==gen3==gen4). Diagnostic ladder: `grep <synthesized-symbol> /tmp/rail_self.s` to confirm the
  running compiler emits it (step 2 of the CLAUDE.md diagnostic pattern).

## 1.7 Tests to add (in `run_tests`, line 3987+; bump the `/141` assertion at 4194)

1. `t_auth_parse` — `auth`-typed ADT compiles + round-trips as plain ADT (B0 gate).
2. `t_auth_digest` — generated `digest_Tree root` equals a hard-coded sha256 of the known projection
   (B1 gate; pin the literal hex so a projection-format regression is caught).
3. `t_auth_prove_verify` — full Merkle fetch: prove then verify accepts, value correct (B2 gate).
4. `t_auth_tamper` — swapped-leaf proof REJECTS (security gate; assert `is_error`).
5. `t_auth_forged_root` — wrong root REJECTS.
6. `t_auth_dict` — authdict BST lookup accepts + wrong-key REJECTS (B3 gate, generalization).

Plus a **CI differential**: a `tools/test/` script that runs `authkit.rail`/`authdict.rail` (Stage A
oracle) and diffs their proof bytes against the Stage-B-generated equivalents — this is the
"prover-append == verifier-pop" guard at the system level.

## 1.8 Risks

- **Match-arm reordering during cloning** would silently break the order invariant → proofs mismatch
  but tests might pass on symmetric trees. Mitigation: clone is a strict alpha-rename + body swap, and
  t_auth_dict uses an ASYMMETRIC structure where order matters.
- **`auth_make` in a verifier path** is undefinable (no value to hash). For the read-only λ• core it
  never occurs; flag it as a type error in Track 2 rather than emitting garbage. Until Track 2 lands,
  emit a `; ERROR auth_make in verify mode` asm comment + `bl _RAIL_UNDEFINED_IDENT_...` (the existing
  link-fail escape hatch at line 1435) so it fails loudly at link, never silently.
- **Projection ambiguity** on payloads containing the delimiter — already mitigated by mandatory
  length-prefix framing (1.4).
- Risk overall: **medium**, and lower than the thesis estimated because Stage A is already proven and
  becomes the oracle.

---

# TRACK 2 — Incremental checked TYPE LAYER

## 2.0 Principle: promote, don't rewrite

Today's forward inference (`is_int`/`is_float` lines 891/933, the track-B `__ret_` fixpoint
2347-2496, `mark_int_params`/`mark_float_params` 2120-2225) feeds **codegen + precise GC** and emits
**warnings only**. The thesis headline: *one mechanism unlocks four limitations.* This track does the
MINIMAL promotion that (a) dissolves the float-arg miscompiles, (b) turns the worst type errors into
clean diagnostics instead of segfaults, (c) makes recursive float-return inference correct — WITHOUT a
general Hindley-Milner pass. Each item is a self-contained increment behind its own regression test.

## 2.1 The model to copy: d653a72 (comparison-float-param fix)

Branch `fix/float-user-fn-compare`, commit `d653a72`, fixed the COMPARISON case by extending
`param_is_float` (line 2160): when a param is an operand of a comparison whose OTHER operand is
unambiguously float, mark it `__float_`. Its safety argument is the template for 2.2:

> `int_param < 0.0` is ALREADY mishandled today (the FL literal forces the native-float path, which
> reinterprets the int's tag bits as a double), so marking here cannot break a currently-correct mixed
> pattern. By contrast `0.0 +. int_param` IS correct via runtime mixed-promotion, which is why
> arithmetic-sibling marking stays omitted.

That commit is NOT merged into `feat/verifiable-language` (this branch is at 141 tests; d653a72 adds
t136 → 142). **Increment 0 of this track is to cherry-pick / re-apply d653a72 here** so the comparison
case and the arithmetic case land coherently with one fixed-point cycle.

## 2.2 Increment A — dissolve the ARITHMETIC-float-param miscompile (the unfixed case)

**Bug (reproduced 1.0):** `mul2 a b = a *. b` → `mul2 3.0 4.0` prints `4.94e-324`. `param_is_float`
deliberately omits the arithmetic-sibling rule (lines 2139-2148) because `0.0 +. tagged_int` is a
LEGITIMATELY mixed pattern that the runtime `r_op_tag` path + `_rail_add` mixed stubs handle
correctly. So you cannot blindly mark `a` float on seeing `a *. <float>`.

**Why d653a72's trick does NOT directly transfer:** for comparison, `int < 0.0` was *already* broken,
so marking was free. For arithmetic, `0.0 +. int` is *already correct*, so marking would BREAK it.

**The minimal correct rule — whole-call-site agreement, computed in the existing fixpoint:**
A param `p` of fn `f` is float **iff EVERY call site passes an unambiguously-float argument in p's
position**. This is the analysis `param_is_float`'s comment (lines 2145-2147) explicitly defers
("whole-program analysis: every call site passes a float in arg N"). Implement it as a SECOND
fixpoint table alongside the existing `__ret_` one, NOT a new framework:

- **New table `__argf_<fn>_<i>`** (1 = arg i is float at all sites, 0 = not-all-float/unknown),
  computed by a fixpoint identical in shape to `fixpoint_rmap` (2487): walk every `A` call node in
  every body; for callee `f` arg `i`, lub the arg's `infer_ty` (2394 — already returns 2 for float)
  across sites. Seed all `__argf_*` = unknown; a single non-float (or unknown) site demotes the slot.
- **Hook:** in `compile_func` (line 2626) after `mark_float_params`, ALSO mark `p` as `__float_` when
  `__argf_<fn>_<idx>(p) == FLOAT`. This is additive — it only ever ADDS marks the conservative pass
  missed, and only when *provably* every site is float, so the `0.0 +. int` caller (which passes an
  int → demotes the slot to not-all-float) is never mismarked.
- `infer_ty` already exists and already classifies FL/arith-with-float as 2; reuse it verbatim for arg
  typing. The fixpoint driver, `ty_lub` (2347), `rmap_set` (2453) are all reusable.

**Safety:** because the rule fires ONLY on unanimous-float call sites, it cannot break a mixed
`0.0 +. int` caller (that caller's int arg demotes the slot). It strictly shrinks the unfixed-bug
surface; it cannot expand a correct case into a wrong one. This is the same monotonicity property that
made d653a72 safe, established by call-site agreement instead of by "already-broken."

**Test:** `t_arith_float_2arg` — `mul2 a b = a *. b; show_float (mul2 3.0 4.0)` → `12`. Plus a
NEGATIVE guard `t_mixed_promo_preserved` — `addk x = 0.0 +. x; show_float (addk 5)` must still work
(asserts the int-arg caller is NOT mismarked).

## 2.3 Increment B — recursive float-return inference (the segfault + truncation)

**Bug (reproduced 1.0):** `rec_half n x = if n<=0 then x else rec_half (n-1) (x/.2.0)`. With
`show_float` → prints `1` (truncated); with `show` → segfault.

**Root cause:** `collect_float_ret_fns` (line 2322) is a **two-pass, NOT a fixpoint** (called twice at
2312-2313: pass1 with `[]`, pass2 with pass1's result). `returns_float` (1985) on the recursive branch
hits `rf_has self fret_list` — in pass1 `fret_list` is empty so the self-call returns false; the
function only qualifies if its NON-recursive branch independently proves float. For `rec_half` the
base-case branch is `x` (a bare `V` → `returns_float` returns false at line 1989), so even pass2 never
marks it. Hence no `__float_ret_rec_half`, the param `x` isn't float-marked, and the result is treated
as a tagged int → truncation / segfault when `show` dereferences it.

**The minimal fix — make float-return a real fixpoint, exactly like `__ret_`:** the track-B machinery
(`infer_return_types` 2494, `fixpoint_rmap` 2487, `infer_ty` 2394) ALREADY computes a precise
return-type tag where **2 == FLOAT** and ALREADY handles recursion via the fixpoint (mutual-rec test
i4 passes). The float-return markers `__float_ret_*` are computed by the inferior two-pass path purely
for historical reasons. **Increment B = derive `__float_ret_<fn>` from the track-B rmap result instead
of from `collect_float_ret_fns`:**

- In `get_arities` (2309-2319), after `infer_return_types` produces `ret_markers`, synthesize the
  float-return markers from it: for every `__ret_<fn> == 2`, emit `__float_ret_<fn>`. Replace the
  `mk_fret_markers (collect_float_ret_fns ...)` feed (2312-2314) with this derivation.
- This is a NET SIMPLIFICATION (deletes the redundant two-pass `collect_float_ret_fns` /
  `returns_float` / `rf_all_arms` / `rf_has`, lines 1982-2023 + 2321-2337) — fits the "stay simple"
  mandate. The fixpoint already converges recursion (budget 8, settles in 2-3).
- For `rec_half`: track-B infers the `?` node's type as `ty_lub(base, recur)`. Base `x` is `V`
  (type 0/unknown), recur is `A rec_half` (looked up in rmap). Fixpoint iteration: start unknown;
  the `x/.2.0` arg makes the recursive-call return lub with float once the param-return coupling is
  seen. **Caveat:** `infer_ty` on a bare `V` returns 0 (unknown), and on the `?` does `ty_lub(0, 2)=2`
  — so the fixpoint DOES reach 2 for `rec_half` provided the recursive call's return resolves to 2.
  This is the standard fixpoint and converges; the two-pass version simply gave up too early.

**Then the param follows:** once `__float_ret_rec_half` exists, the SECOND-order issue is the param
`x` on the base branch. Increment A's `__argf_` table handles this: `rec_half`'s own recursive call
passes `x/.2.0` (float) in arg position 1, so `__argf_rec_half_1 = FLOAT` → `x` marked `__float_`.
A and B compose: B fixes the return tag, A fixes the param tag, together they dissolve the recursive
case. **Land A before B and test B with both `show_float` AND `show`.**

**Tests:** `t_rec_float_ret_showf` (`show_float (rec_half 3 8.0)` → `1`... NO — must assert the float
prints WITH decimal; pin expected to the `show_float` rendering, which for 1.0 is `1` in this build's
`%g` format — so instead assert a value that disambiguates: `rec_half 3 9.0` → `1.125`). And
`t_rec_float_ret_show` (`show (rec_half 3 9.0)` → `1.125`, the segfault gate — must not crash).

## 2.4 Increment C — eliminate segfault-on-type-error (graceful diagnostics)

**Today:** `head []`/`tail []` are safe (return 0/[]), but arithmetic-on-string, calling a non-fn, and
the float/int ABI mismatches above **segfault** (CLAUDE.md "Runtime Safety": "Other type errors ...
may still segfault"). The forward-inference pass already DETECTS most of these (it emits warnings).

**Minimal promotion — a `--check` gate, warnings stay default:** do NOT make inference hard-error by
default (that would break the LLM-generates-then-compiles self-train loop, which tolerates messy
intermediate code). Instead:

- Add a compile flag `check` (sibling to `test`/`self`/`x86`/`linux` in the CLI dispatch — find the
  arg dispatch near `self_compile`/`run_tests` entry). In `check` mode, the EXISTING warning sites are
  promoted to errors that print `file:line:col: error: <type msg>` and halt cleanly (the clean-halt
  path already exists for parse errors — reuse it).
- For the two highest-value runtime traps, add a CHEAP guard in codegen rather than full type proof:
  arithmetic O-handler heap fast-path already routes mixed/heap operands to `_rail_add` etc.; extend
  the `_rail_*` arithmetic stubs' non-numeric branch to call a `_rail_type_error` that prints a
  message + `_exit(1)` instead of dereferencing. This converts "arith on string" from segfault to a
  one-line diagnostic. (This is a runtime-asm change → **2-cycle**, and the ONLY runtime change in
  this track — gate it behind its own commit + fixed-point verification.)

**Tests:** `t_check_flags_type_error` — `./rail_native check` on a known-bad snippet exits nonzero with
an `error:` line (no segfault). `t_arith_string_graceful` — `1 + "x"` traps with a message, exit 1,
not signal 11.

## 2.5 Staging + bootstrap discipline

| Inc | Edit class | Cycles | Gate |
|---|---|---|---|
| 0 (cherry-pick d653a72) | source logic | 1 (+verify 2-3) | t136 passes, 142/142 |
| A (`__argf_` fixpoint) | source logic | 1 (+verify) | t_arith_float_2arg, t_mixed_promo_preserved |
| B (float-ret from rmap) | source logic (net delete) | 1 (+verify) | t_rec_float_ret_show* |
| C (`check` flag) | source logic | 1 | t_check_flags_type_error |
| C (runtime type-error stub) | **runtime asm** | **2** (+verify 3) | t_arith_string_graceful |

Order: **0 → A → B → C-flag → C-runtime**, each its own commit with its own fixed-point check. A and B
MUST land in that order (B's param fix depends on A's `__argf_`). Never batch — the simplicity mandate
means each increment must be independently revertable, and the >=2-cycle rule means a runtime change
(C) must be isolated so a fixed-point failure is unambiguous.

Per-increment procedure (CLAUDE.md "Modifying the Compiler"): edit → `self` → install → `test` →
`self`+`cmp` x2. After A/B, run the **diff fuzzer** (`tools/fuzz/diff_fuzz.rail`) which catches silent
miscompilation via two-path differential eval — exactly the failure mode a float-marking bug would
produce. After every increment run the full `./rail_native test` AND the self-host fixed point (the
repo-wide rule), plus `tools/lint/check_quirks.rail` Q003 (unwrapped float-return) on the stdlib ML
modules that previously needed the out-cell `float_arr` workaround.

## 2.6 What this UNLOCKS (why it's the substrate, not a papercut fix)

Per the thesis "one mechanism unlocks four": A+B together remove the out-cell `float_arr` workaround
that ripples through `stdlib/transformer.rail` / `autograd.rail` (recursive float helpers currently
forced to write into a caller-provided `out` array because they can't return floats). That directly
de-risks **Pillar 3** (source-to-source AD): a generated `grad_*` function that RETURNS a float (or a
float through a recursive accumulator) becomes correct-by-construction instead of needing the workaround.
The `__argf_`/`__ret_`-as-FLOAT precision also tightens the precise-GC slot map (the `__ty_` markers at
line 1561 + `compute_fn_slot_bits` 2607) — fewer conservatively-scanned slots. And C's clean
diagnostics make the self-train compile-as-oracle loop report type errors as data instead of crashes.

## 2.7 Risks

- **Increment A monotonicity** depends on `infer_ty` returning UNKNOWN (0), never a false FLOAT, for
  ambiguous args — verified: `infer_ty` on `V` is 0, on int-arith is 1; it only returns 2 with an
  explicit float. The negative test `t_mixed_promo_preserved` is the guard.
- **Increment B fixpoint non-convergence** on pathological mutual float recursion — bounded by the
  existing budget-8 cap (returns last rmap, conservative). Worst case a float return stays unknown →
  reverts to today's behavior (no regression), never a wrong mark.
- **Increment C runtime stub** is the only fixed-point hazard; isolate it, expect cycle-1 to differ,
  confirm gen2==gen3 (the documented runtime-asm 2-cycle pattern).
- Track overall: **low-medium**. Increments 0/A/B are source-logic-only (1-cycle, fully reversible);
  only C touches runtime asm.

---

## 2.8 VERIFIED CORRECTION (2026-05-30, after reading the rmap machinery)

Increment B as written above is **WRONG on convergence** — verified by reading
`infer_ty`/`infer_call_ty`/`refine_rmap` (compile.rail ~2388-2491). For
`rec_half n x = if n<=0 then x else rec_half (n-1) (x /. 2.0)`:
- the then-branch `x` is a bare `V` → `infer_ty` returns **0/UNKNOWN** (line 2418: V is always 0);
- the else-branch is `A rec_half ...` → `infer_call_ty` returns `__ret_rec_half` from the rmap,
  which starts 0 and never rises — the float-ness lives in the recursive call's **argument**
  (`x /. 2.0`), and `infer_call_ty` does NOT propagate arg types into the return.

So the fixpoint settles at `__ret_rec_half = 0`. Deriving `__float_ret_` from `__ret_==2` therefore
does **not** mark rec_half float (B fails its own target), AND the rmap is more conservative on
param-return/recursion than the current two-pass, so a blind swap risks **regressing** functions the
two-pass marks. **Do not implement B as a simple swap.**

The real recursive-float-return fix is JOINT (more than a "net deletion"):
1. **A** (`__argf_` call-site agreement) marks the param `x` as `__float_` — rec_half's own recursive
   call passes `x /. 2.0` (float) in arg 1, so `__argf_rec_half_1 = FLOAT`.
2. **Extend `infer_ty`'s "V" case** (line 2418): a var marked `__float_` (look it up in `ar`/env)
   contributes **2**, not 0. Then the then-branch `x` → 2, the lub → 2, `__ret_rec_half` → 2, and the
   `__float_ret_` derivation works.
3. Keep the existing two-pass as a **union fallback** (mark float if EITHER the two-pass OR the rmap
   says so) so no currently-marked function regresses.

Net: B is not standalone; sequence it as a rider on A + the `infer_ty` V-tweak + the union guard, and
gate on the full 142-test suite + the diff-fuzzer. (This correction is the kind of analysis the
compiler tracks need BEFORE coding — exactly why they were kept out of the autonomous swarm.)

# Cross-cutting

- Both tracks are **additive** to the env-marker + arity-map machinery already in `compile.rail`; neither
  introduces a new IR or a general type system. They reuse `efind`/`cons` env markers, the `fixpoint_rmap`
  shape, `infer_ty`, `ty_lub`, and the existing clean-halt + link-fail escape hatches.
- **Sequencing across tracks:** land Track 2 Increment A+B FIRST (they're low-risk source-logic fixes
  that also make Track 1's `auth_make`-in-verify-path a clean type error rather than a runtime guess,
  and de-risk Pillar 3). Then Track 1 Stage B on top of the proven Stage A oracle.
- **The fixed point is the product** (`rail-pillars-design` Pillar 1): every increment in both tracks
  must end at a byte-identical 2-pass self-compile, or it does not ship.
