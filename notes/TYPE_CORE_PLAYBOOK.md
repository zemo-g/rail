# Rail Type-Core Playbook

> The canonical playbook for type-layer / verifiable-language compiler work.
> Distilled from the float-type-inference arc (2026-05-22 .. 2026-05-31).
> Companion to `HANDOFF_increment_B_float_inference.md` (the per-increment detail)
> and memory `rail-type-core-arc`. This file is the durable, repo-pinned version.

## 0. Position (verified live 2026-05-31 -- re-verify before trusting)

The arc is DONE and SHIPPED. The float-type-inference work (Increments A / A+ / B)
is merged to master -- mainline, not a branch experiment.

- PR #7 MERGED to `master` (merge commit `a55e4fa`); all 7 commits
  `d653a72`..`dcf255f` are on `origin/master`.
- 146/146 tests; byte-identical fixed point (self-compile SHA-256
  `b5e357706114f2106fece1e87a1b105528d9d0d5b4cf0f8cf0ac9bb751de3df1`).
- Independently reproduced from source in a throwaway worktree -- not trusted.

Re-verify:
```
git merge-base --is-ancestor dcf255f origin/master && echo merged
./rail_native test                                   # 146/146
cp /tmp/rail_self /tmp/g2 && ./rail_native self && cmp /tmp/g2 /tmp/rail_self
```

## 1. What we built -- one sentence

Float scalars now work as ordinary user-function PARAMETERS and RESULTS, so
natural ML code compiles correct and unboxed:

```rail
let y = mlp 1.0 2.0      -- forward pass: 5-float-param neurons, ReLU, NO boxing
mse y 1.0                -- composes the float RESULT -> 0.015625
```

Before the arc this segfaulted (arity >= 4) or printed `5.3e+36` garbage.
Proof artifact kept green: `examples/mlp_natural.rail` (segfaults on master
`548dcd7`, runs correct on the merged line).

## 2. Why it carries weight -- the strategic spine

Type-core is NOT a feature. It is the FLOOR the verifiable-language thesis stands on.

- Pillar 2 (`auth`-typed authenticated data structures -- the flagship novelty)
  needs sound type-marking to desugar prover + verifier.
- Pillar 3 (attested numerics / source-to-source AD) needs float-typing solid to
  emit a gradient that is itself a re-attestable Rail program.
- PAOS (attested specialist models) is the endgame: Stage 3 = model outputs ARE
  Rail. That only closes if the compiler's float path is trustworthy.

Keystone. Everything verifiable-language and PAOS leans here.

## 3. The method that won -- the repeatable playbook (the heart)

This generalizes to ALL high-stakes compiler-core work. The arc beat the design's
own "high-risk surgery" framing TWICE by holding one discipline:

1. **Diagnose-first (Phase 0) before surgery.**
   Run the minimal repro on the CURRENT binary before the big change. Both A+ and
   B were planned as joint-fixpoint surgery; both times Phase-0 showed the hard
   part was already done. B collapsed to 2 additive edits, not a fixpoint.

2. **Smallest change that makes the repro pass.**
   Expand to the full fixpoint ONLY if Phase 0 proves it's needed. The B fix is
   strictly additive and inert for int code (diff-fuzzer grammar unaffected).

3. **The bootstrap fixed point is sacred.**
   Every increment ended byte-identical (gen2==gen3). Never gamble it at
   marathon-tail -- that is why B was handed to a FRESH session, not rushed.

4. **Verify by reproduction, not trust.**
   Checking another session's compiler work = isolated worktree -> rebuild from
   source -> run ALL gates yourself -> before/after on the PARENT commit to prove
   the new test locks a real fix -> read the memory edits for honest scoping.
   Grep the diff for REMOVED functions first (clears the wrong-swap trap).

## 4. The non-negotiable gate -- every `compile.rail` edit

```
./rail_native self                      # background; ~4-5 min; auto-notified
/tmp/rail_self test                     # 146/146 (+ your new test) BEFORE install
cp /tmp/rail_self rail_native && ./rail_native self                                 # cycle 2
cp /tmp/rail_self /tmp/gen2 && cp /tmp/rail_self rail_native && ./rail_native self  # cycle 3
cmp /tmp/gen2 /tmp/rail_self            # MUST be byte-identical (gen2==gen3)
./rail_native run tools/fuzz/diff_fuzz.rail --seed=42 --n=20  # 20 agree / 0 divergence
```

NEVER install/commit a binary that fails a gate. On any trip:
`git checkout -- rail_native` and revert the source edit. One inviolable rule.

## 5. Next plays -- clear triggers

Thesis rule: take type-layer increments ONLY where Pillars 2/3 demand it. Do not
gold-plate the type layer for its own sake.

- **[next] Pillar 2 Stage B** -- `auth`/`unauth` two-mode desugar. Leans directly
  on this float/type marking being solid. Most likely next pull.
- **Pillar 3** -- source-to-source AD emitting the gradient AS a re-attestable Rail
  program + deterministic-reduction Metal kernels (on Studio). PAOS endgame;
  highest effort.
- **Phase 2 (ONLY if a pillar demands it)** -- recursive-float-return + `show` on
  an unboxed float. Deliberately NOT done; STILL SEGFAULTS, do not assume it works.
  This is the genuine joint fixpoint + `infer_ty` "V" param-tweak (design §2.8).

## 6. Mechanism recap (so you don't re-trace it)

Two return-type mechanisms coexist in `tools/compile.rail`:
- structural path: `returns_float` -> `__float_ret_` (V-case returns false);
- lattice path: `infer_ty` / `refine_rmap` / `fixpoint_rmap` -> `__ret_<fn>`,
  tags 0=unknown / 1=int / 2=float / 3=heap.

Increment B works purely via `ty_lub(0,2)=2`: relu's `0.0` literal seeds float
through relu -> neuron -> mlp, so `__ret_mlp==2`. New helper `argf_scan_d` threads
a `__vf_<name>` marker when a let-bound value is provably float (`infer_ty==2`);
`infer_ty`'s "V" case reads it. So `y` is seen float -> `__argf_mse_0` marks `pred`
`__float_` -> existing Increment-A codegen makes `d*d` a float-mul. The two-pass
`returns_float`/`collect_float_ret_fns` was left untouched (no §2.3 swap, no union
fallback). Inert for int code (no `__vf_` ever set on the int path).

## 7. Pointers

- Per-increment detail + verification table: `notes/HANDOFF_increment_B_float_inference.md`
- Design + corrected analysis (cross-branch): `git show 337d66a:notes/rail-compiler-phase-design.md` (§2.8)
- Trap origin + workarounds: memory `feedback-rail-float-user-fn-args`
- Broader campaign: memory `rail-innovation-thesis-verifiable-language`; endgame `paos-specialist-models`
- Two clones: `~/projects/rail` (working) ; `~/projects/rail-https` (the "before" binary, master `548dcd7`)
