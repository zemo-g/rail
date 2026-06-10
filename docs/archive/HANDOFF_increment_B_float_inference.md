# HANDOFF — Increment B: float-result recognition (joint inference fixpoint)

## RESOLVED by `4cf64de` — executed + independently verified 2026-05-31

**This handoff is complete. Do not re-implement.** It is kept below as the historical
diagnosis record. The task was executed in a fresh session, then independently re-verified
from source by a separate (history-carrying) session.

**What actually landed — smaller than this doc feared.** The "high-risk joint inference
fixpoint" was NOT required for the DoD repro. Phase-0 diagnosis showed Increment A
(call-site agreement) was already in place, so the only missing link was *let-local
propagation*. The realized fix is **2 additive edits** (`tools/compile.rail`):
- new helper `argf_scan_d` threads a `__vf_<name>` marker into the rmap when a let-bound
  value is provably float (`infer_ty == 2`);
- `infer_ty`'s "V" case reads that marker, so a bare local contributes FLOAT(2), not UNKNOWN(0).

Float seeds up the relu→neuron→mlp chain purely through `ty_lub(0,2)=2` (relu's `0.0`
literal): `__ret_mlp==2` → `y` earns `__vf_` → `mse y 1.0` marks `pred` `__float_` → `d*d`
takes the float-mul path. The two-pass `returns_float`/`collect_float_ret_fns` machinery was
left **untouched** — no §2.3 swap, no union fallback. The fix is strictly additive and inert
for int code (diff-fuzzer grammar unaffected).

**Independent verification (reproduced from source in a throwaway worktree — not trusted):**

| Gate | Result |
|---|---|
| Full test suite | **146/146** (exit 0) |
| `mse y 1.0` (DoD repro) | **0.015625** |
| `examples/mlp_natural.rail` | `1.125 / 0.375 / 0 / 2.75` (no regression) |
| diff-fuzzer `--seed=42 --n=20` | `20 agree / 0 divergence` |
| **Byte-identical fixed point** | committed binary self-compiles to itself; SHA-256 `b5e357706114f2106fece1e87a1b105528d9d0d5b4cf0f8cf0ac9bb751de3df1` identical on both sides |
| Regression-lock (`t140` is real) | parent `bec321f`, identical source → `5.30782934581719e+36` garbage; `4cf64de` → `0.015625` |
| Memory honesty | thesis/trap/index updated, scoped to let-local compose, explicitly note recursive-return + union-fallback were NOT done, flag `unpushed` — no overclaim |

**Verdict: correct and honest** — the scope claimed equals the scope delivered.

**Still open (out of scope here, do NOT assume done):** the recursive-float-return + `show`-on-
unboxed-float case (Phase 2 below) was deliberately not attempted; the joint fixpoint + param
V-tweak are still the path if that is ever needed.

**Finding carried forward:** the required-reading reference below,
`notes/rail-compiler-phase-design.md` §2.8, does NOT exist on `feat/type-layer` — it lives on
`feat/verifiable-language` (`337d66a`). Read it via
`git show 337d66a:notes/rail-compiler-phase-design.md`. It did not block this fix (Phase-0
diagnose-first found the smaller change empirically), but cross-branch handoff references
should be co-located or made explicit next time.

---

**Written 2026-05-30 by the type-layer session. For a FRESH dedicated session.**
This is a fixed-point-risky compiler-core change. It was deliberately NOT attempted at
marathon-tail. Read this whole doc + `notes/rail-compiler-phase-design.md` §2.8 before editing
(NOTE: that doc is on `feat/verifiable-language` @ `337d66a`, not this branch — see above).

---

## 0. One-line mission

Make a float-returning *user function's RESULT* recognized as float so it composes correctly
in later arithmetic and `show`. Concretely: make this print `0.015625`, not garbage:

```rail
relu x = if x > 0.0 then x else 0.0
neuron w1 x1 w2 x2 b = relu (w1 * x1 + w2 * x2 + b)
mlp x1 x2 =
  let h1 = neuron 0.5 x1 0.25 x2 0.0
  let h2 = neuron 0.25 x1 0.5 x2 0.0
  neuron 0.5 h1 0.5 h2 0.0
mse pred target = let d = pred - target in d * d
main =
  let y = mlp 1.0 2.0           -- y = 1.125  (forward pass ALREADY works)
  let _ = print (show_float (mse y 1.0))   -- want 0.015625; today prints 5.3e+36
  0
```

This unblocks natural ML code: `stdlib/autograd.rail` / `transformer.rail` currently box around
this with out-cells and tag-string dispatch. Increment B lets them return floats directly.

---

## 1. Starting state (verify first)

- Machine: the type-layer work lives in `~/projects/rail` (this checkout). `hostname` to confirm
  which machine if it matters; the binary is per-machine.
- Branch: **`feat/type-layer`**, HEAD should be **`ee25340`**. Verify:
  ```bash
  cd ~/projects/rail && git log --oneline -6 && git status -s
  ```
  Expect (newest first): `ee25340` MLP proof · `f042b6b` A+ int-param · `f6231c8` A arith-param ·
  `d653a72` comparison-param · then off `master 548dcd7`.
- `./rail_native test` must be **145/145** and `./rail_native self` byte-identical before you start.
  If not, STOP and reconcile — do not build on a broken base.

### What is ALREADY solved (do not redo)
Float **parameters** are handled. The `__argf_` whole-call-site analysis (in `compile.rail`, search
`argf_key` / `arg_join` / `collect_argf` / `mark_argf_params`) marks a param `__float_` if every call
site passes a float, `__int_` if every site is int. The 5-float-param MLP **forward pass runs
correctly** (`examples/mlp_natural.rail` → `mlp(1.0,2.0)=1.125`). The remaining gap is purely about
recognizing a float **RESULT / let-local**, not params.

---

## 2. The diagnosis (keystone lines — traced, verified)

The forward pass works only because each `wi * xi` has a float weight that triggers the `use_float`
codegen path; the input's bits are already float so `fmov` is correct. It is **luck of operand
order**, not real type knowledge. The compiler does NOT know `mlp` returns a float. So:

- `returns_float` (**`compile.rail:1985`**) — the two-pass float-return detector — returns **false
  for the "V" case (`:1989`)**. A bare param (`relu`'s `x` in `if x>0 then x else 0.0`) never counts
  as float, so `relu` is not float-returning → `neuron` isn't → `mlp` isn't → no `__float_ret_`.
- `infer_ty` (**`:2411`**), `infer_call_ty` (**`:2391`**), `refine_rmap` (**`:2478`**),
  `infer_return_types` (**`:2511`**) have **no awareness** of (a) which params are `__float_`-marked,
  (b) which user fns return float, (c) which let-locals are float.
- So at `mse y 1.0`: `y` (a let-local bound to `mlp …`) infers as UNKNOWN → `__argf_mse_0` demotes →
  `mse`'s `pred` is unmarked → the let-local `d = pred - target` is not recognized float → `d * d`
  takes the integer path → garbage.
- The runtime `_rail_add` tag-dispatch (**`:2849`**) already promotes mixed int+float **for BOXED
  values** (heap tag #6). That is why `t106` passes. It does NOT help the unboxed register fast-path,
  which is where this lives. (This is why a blanket runtime LSB check is unsound here — odd-mantissa
  unboxed floats look like tagged ints. Static inference is the right tool.)

**`notes/rail-compiler-phase-design.md` §2.8 already proved the NAIVE sequential version (just derive
`__float_ret_` from the rmap) does NOT converge.** The float-ness lives in the recursive call's
ARGUMENT, not the return. The real fix is a JOINT fixpoint. Do not re-derive this — it cost a trace.

---

## 3. The plan

### Phase 0 — diagnose the exact failing inference (do this FIRST, ~30 min, no codegen change)
Don't trust this doc's model blindly. Instrument: for the repro above, find the *first* inference
that returns the wrong type. Candidates, in order:
1. Does `let d = pred - target` mark `d` float at codegen when `target` is `__float_` but `pred` is
   not? Check `is_float` on a mixed O-node + the let-binding float-marking in `compile_func`. **There
   may be a targeted fix here that is much smaller than the full fixpoint.** Try the minimal repro
   `f a b = let d = a - b in d * d ; main = print (show_float (f 1.125 1.0))` on the current binary —
   if THAT already works, the problem is purely `y`/`pred` not being float; if it fails, fix the
   mixed-O let-local marking first (smallest possible win).
2. Then the `__float_ret_` chain (relu→neuron→mlp) so `y` is known float.

**Prefer the smallest change that makes the repro pass. Expand to the full fixpoint only if needed.**

### Phase 1 — the joint fixpoint (if Phase 0 shows it's required)
Thread float-awareness through `infer_ty` via the rmap (reuse the existing `efind`/marker style):
1. **`infer_ty` "V" case**: return `2` if `efind (cat ["__vf_", name]) rmap == 2`.
2. **`infer_ty` "D"/"TD" (let) case**: infer the bound value's type; if `2`, recurse into the body
   with `("__vf_"+boundname, 2)` consed onto `rmap`. (Check whether D is currently traversed at all.)
3. **`refine_rmap`**, per fn `F`: before inferring `F`'s body, cons `("__vf_"+param, 2)` for each
   param with `__argf_F_<i>==2`. (Needs `__argf_` present in `ar` during the rmap pass.)
4. **`get_arities` two-phase** (search `infer_return_types` call site):
   - `ret0 = infer_return_types decls base_ar`  (prelim, no argf)
   - `argf = collect_argf decls (append ret0 base_ar) ret0 []`
   - `ret1 = infer_return_types decls (append argf base_ar)`  (refine_rmap now seeds `__vf_`)
   - `__float_ret_` markers = names with `__ret_==2` in `ret1`, **UNIONed** with the legacy
     two-pass `collect_float_ret_fns` (so NOTHING that worked before regresses).
   - If a single extra phase doesn't converge the mlp chain, iterate to a fixpoint — the lattice is
     monotone (marks only ever get ADDED), so it terminates. Bound the loop defensively.
5. **`returns_float` "V" case** (`:1989`) may then be redundant, OR mirror it: make it consult the
   same `__vf_` set if you keep it.

### Phase 2 — `show` on an unboxed float (stretch)
With `__float_ret_` set, `show (mlp …)` could route to `show_float` when `is_float(arg)`. Today it
segfaults. Optional; only if cheap.

---

## 4. Non-negotiable discipline (the fixed point is sacred)

After ANY `compile.rail` edit:
```bash
cd ~/projects/rail
./rail_native self            # ~4-5 min -> /tmp/rail_self   (run in BACKGROUND; you'll be notified)
/tmp/rail_self test           # 145/145 (+ your new test) BEFORE installing
# only if green:
cp /tmp/rail_self rail_native && ./rail_native self            # cycle 2
cp /tmp/rail_self /tmp/gen2 && cp /tmp/rail_self rail_native && ./rail_native self   # cycle 3
cmp /tmp/gen2 /tmp/rail_self  # MUST be byte-identical (gen2==gen3)
./rail_native test            # 145/145 (or 146 with the new test)
./rail_native run tools/fuzz/diff_fuzz.rail --seed=42 --n=20   # 20 agree / 0 divergence
```
- **NEVER install/commit a binary that fails any gate.** If a gate trips, `git checkout -- rail_native`
  and revert the source edit. You never ship a broken fixed point — that is the one inviolable rule.
- Source-logic edits take effect in 1 cycle but need cycles 2+3 to PROVE the byte-identical fixed
  point. See the bootstrap-cycle table in `CLAUDE.md`.
- Run the ~5-min self-compiles in the BACKGROUND (`run_in_background: true`) with a timing note, so
  they don't look frozen. You are auto-notified on completion — don't poll/sleep.
- Add a regression test in the `run_test` block (search `t139`): e.g. `t140 float_result_compose`
  = the `mse`/`f a b = let d = a-b in d*d` repro → expected output. Bump the `/145` count + the
  `total == 145` assertion + the `s11` sum line (add `+ (if t140 then 1 else 0)`).

## 5. Gotchas (earned, don't relearn)
- ASCII-only inside any string literal that flows to `.asciz` (no em-dash/curly quotes). Comments OK.
- DATA SECTION BUG: new data-section labels may not propagate in 1 cycle — see `CLAUDE.md`.
- The float param-handling trap memory: `~/.claude/projects/-Users-ledaticempire/memory/feedback_rail_float_user_fn_args.md` (now records A/A+ FIXED).
- Diff fuzzer is int-only grammar — it guards against int-path regressions, not float correctness;
  the explicit float tests are your float guard.
- Don't reintroduce float_arr/out-cell workarounds in the test — the point is that natural code works.

## 6. Definition of done
- The `mse` repro prints `0.015625`; `examples/mlp_natural.rail` still prints `1.125`/`0.375`.
- New regression test green; **145(+1)/145(+1)**; **byte-identical fixed point (gen2==gen3)**;
  diff-fuzzer 20/20.
- Commit on `feat/type-layer` (specific files: `tools/compile.rail`, `rail_native`, the test is in
  compile.rail). Push only with the user's OK (this session pushed each increment after gates green).
- Update the trap memory + `memory/rail-innovation-thesis-verifiable-language.md` (the "NEXT GAP"
  section) to mark Increment B landed.

## 7. Pointers
- Design + corrected analysis: `notes/rail-compiler-phase-design.md` (§2.8).
- Thesis/status memory: `memory/rail-innovation-thesis-verifiable-language.md` (KEYSTONE LINES section).
- This session's commits: `d653a72`, `f6231c8` (A), `f042b6b` (A+), `ee25340` (proof).
- Proof artifact to keep green: `examples/mlp_natural.rail`.
- The `__argf_` machinery you build on: search `compile.rail` for `arg_join`, `collect_argf`,
  `mark_argf_params`, `argf_scan`.
