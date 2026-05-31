# Stage B (Pillar 2: `auth`/`unauth` desugar) — Grounded Implementation Plan

> PLAN ONLY. No compiler edits made. This re-grounds the design spec against the
> merged compiler so a future session can execute without re-tracing.
> Source spec: `git show 337d66a:notes/rail-compiler-phase-design.md` Track 1 (§1.0-1.8).
> Substrate: the type-layer (Increments A/A+/B) is MERGED to master -- see `TYPE_CORE_PLAYBOOK.md`.
> Grounded live 2026-05-31 against `tools/compile.rail` @ 7192 lines (merged-master line).

## 0. Goal (one sentence)

The compiler auto-generates the Prover / Verifier / Ideal clones of an `auth`-typed
program, so a single `fetch` written ONCE produces byte-identical proofs and identical
accept/reject decisions to the hand-written Stage A oracle (`authkit.rail`).

`auth` is a field modifier on ADT constructor fields + two primitives:
```rail
type tree = | Tip s | Bin (auth tree) (auth tree)
-- auth_make : t -> Auth t      (Prover: (digest,val) ; Verifier: digest)
-- unauth    : Auth t -> t      THE ONLY place proof I/O happens
fetch idx t = match idx, unauth t | [], Tip a -> a | (L::r), Bin l _ -> fetch r l | ...
```
Compiler emits `fetch__prove` / `fetch__verify` / `fetch__ideal`.

## 1. Branch setup (the one decision — RESOLVED for this plan)

Stage A oracle files live ONLY on `feat/verifiable-language` (NOT merged). The type-layer
substrate is on master. Stage B needs BOTH. Plan = branch off master, bring just the 2
oracle files (do NOT merge all of vlang -- keeps P1/P3 first-cuts off public master):

```bash
git checkout -b feat/p2-auth-stage-b origin/master
git checkout feat/verifiable-language -- tools/auth/authkit.rail tools/auth/authdict.rail
# PRE-FLIGHT (before any compiler edit): prove the oracle runs on the master line.
./rail_native run tools/auth/authkit.rail     # must succeed (imports sha256 from stdlib, present)
./rail_native run tools/auth/authdict.rail    # must succeed
./rail_native test                            # 146/146 baseline
```
authkit.rail = 86 lines (Merkle membership), authdict.rail = 176 lines (string-keyed BST).
They are the executable spec / differential oracle; Stage B's correctness bar is byte-identical
proofs to these.

## 2. Hook points — RE-GROUNDED to current `compile.rail` (was 337a, now 7192 lines)

Parser hooks are UNCHANGED by the merge (the type-layer added float-inference code ~2530-2611,
shifting codegen hooks down but renaming nothing). Re-grounding is mechanical.

| # | Hook | Fn | Design ref (337a) | CURRENT line | Change |
|---|---|---|---|---|---|
| H1 | parse `auth` field modifier | `count_params` | 491-495 | **491** (unchanged) | `cv ts == "auth"` -> skip, consume next `id` as auth-type, record per-field auth bitmask |
| H2 | thread auth mask into variant tuple | `pvariants`/`ptype` | 481/474 | **481 / 474** (unchanged) | additive tuple slots `[ctor,idx,arity,authmask,fieldtypes]`; existing head/tail readers untouched |
| H3 | global auth-type table | `ctor_arities` | 2522 | **2641** (+119) | ADD sibling pass `collect_auth_types decls` -> `authtype_table` (ctor -> mask + child type) |
| H4 | synth projection serializers | NEW `synth_proj_fn`/`synth_digest_fn` | insert ~2530 | insert near **2641** | emit `proj_of_<TY>`/`digest_<TY>` from `authtype_table`; mirror `authkit.rail` exactly |
| H5 | the duplicator | NEW `lower_auth_fn` | near `compile_func` 2611 | near **2730** | for each fn using `unauth`/`auth_make` (walk modeled on `is_self_rec`), emit 3 clones `__prove`/`__verify`/`__ideal` |
| H6 | recognize `auth_make`/`unauth` builtins | `cg` A-handler | 1316-1344 | `cg`@**1390** (+74) | dispatch by `__auth_mode` env marker (1=prove/2=verify/3=ideal); lower to existing `cat`/`sha256_hex`/snoc/pop. LOCATE the exact A-arm at impl time |
| H7 | register synthesized fns in arity map | `get_arities` | 2309 | **2323** (+14) | 3 user-fn entries per auth fn so call sites resolve |

Supporting anchors (grounded):
- `__auth_mode` rides `env` exactly like `__nregs` (@**2748**) / `__self_lbl` (@**2752**) -- `cons (key,val)`, read with `efind`.
- `auth_make`-in-verifier escape hatch: the existing link-fail `bl _RAIL_UNDEFINED_IDENT_...` (design @1435) -- emit it so it fails LOUDLY at link, never silent garbage, until Track 2 type-checks it.
- Test insertion: after `t140` @**4315**; assertion `total == 146` @**4337**, print `"/146"` @**4336**.

## 3. Staging (B0 -> B3) — each independently revertable, each fully gated

| Stage | Hooks | Cycles | Ships | Gate |
|---|---|---|---|---|
| **B0** parser-only | H1/H2 | 1 | nothing (auth ignored, behaves as plain ADT) | `auth`-typed decl compiles + round-trips as plain ADT; 146/146 unchanged; fixed point |
| **B1** projection synth | H3/H4 | 2 | derived Merkle digests | generated `digest_Tree root` == hand-written `authkit` digest, BYTE-EQUAL (pin the literal hex) |
| **B2** the duplicator | H5/H6/H7 | 2 | prove/verify | `fetch__prove`/`fetch__verify` reproduce Stage A proof + accept/reject; 3 tamper cases REJECT |
| **B3** authdict regression | (reuse) | 1 | generalization proof | same against the asymmetric BST (string-keyed, length-prefixed) |

B0/B1 ship value (derived digests) even if B2 slips. Isolate lexer/parser risk to B0's single cycle.

## 4. The transformation (per role) — condensed from §1.3, the crux

A clone adds a trailing `__proof` accumulator param (exactly like `authkit`'s `prover_fetch ... proof`):
- **Prover** (`__auth_mode=1`): `auth_make v` -> `(digest_<t> v, v)` ; `unauth x` -> `let __proof = snoc __proof (proj_of_<t> (snd x))` then `snd x`. Returns `(result, __proof)`.
- **Verifier** (`=2`): an `auth t` value IS just the digest. `unauth x` -> pop head of `__proof`, `if sha256_hex pj != x then error "digest mismatch"`, reconstruct node from `pj` (sub-`auth` fields = embedded sub-digests). `auth_make` in a verifier path is undefinable -> H6 escape hatch (never occurs in the read-only `fetch` core).
- **Ideal** (`=3`): `unauth x = x`, `auth_make v = v`. Source runs unmodified -- the free oracle.

**Order invariant (why one traversal, never hand-paired):** the duplicator is a STRICT alpha-rename
+ local `unauth`/`auth_make` body swap. It must NOT reorder match arms or `let` sequencing. Then
prover-append order == verifier-pop order BY CONSTRUCTION. This is the lambda-dot guarantee.

**Projection framing (H4):** length-prefixed encoding (authdict.rail's framing, commit `692bb9a`),
NOT the bare `:`-join of authkit (collides on payloads containing `:`). `digest_<TY> t = sha256_hex (proj_of_<TY> t)`.

## 5. Tests (add after t140; 146 -> 152 over the stages)

| Test | Stage gate | Asserts |
|---|---|---|
| `t_auth_parse` | B0 | auth-typed ADT compiles + round-trips as plain ADT |
| `t_auth_digest` | B1 | generated `digest_Tree root` == hard-coded sha256 of the known projection (pin hex) |
| `t_auth_prove_verify` | B2 | full Merkle fetch: prove then verify accepts, value correct |
| `t_auth_tamper` | B2 | swapped-leaf proof REJECTS (`is_error`) |
| `t_auth_forged_root` | B2 | wrong root REJECTS |
| `t_auth_dict` | B3 | authdict BST lookup accepts + wrong-key REJECTS (asymmetric -> order guard) |

Bump `total == N` + the `"/N"` print per stage (B0:147, B1:148, B2:151, B3:152). Plus a `tools/test/`
CI differential: diff Stage-B proof bytes vs the Stage A oracle (system-level prover==verifier guard).

## 6. Fixed-point discipline (non-negotiable — from the playbook §4)

- **Source-logic-only. NO new `rt_*` runtime asm.** `auth_make`/`unauth` MUST lower to existing
  `sha256_hex`/`cat`/`snoc`/list primitives -- this keeps it 2-cycle, not DATA-SECTION-BUG territory.
- B0 = 1 cycle. B1/B2 introduce new emitted call patterns -> 2 cycles to bake + a 3rd to prove gen2==gen3.
- Per stage: `./rail_native self` (bg) -> `/tmp/rail_self test` -> install -> `self` x2 -> `cmp` byte-identical -> diff-fuzzer `--seed=42 --n=20` 20/20. NEVER ship a failing gate (`git checkout -- rail_native` + revert).
- ASCII-only in any synthesized `.asciz` (tag prefixes `"B:"`,`"T:"` -- already satisfied).
- Diagnostic ladder: `grep <synthesized-symbol> /tmp/rail_self.s` confirms the running compiler emits it.

## 7. Risks (from §1.8 — medium overall, lower than the thesis estimated, because Stage A is the oracle)

- **Match-arm reordering during cloning** silently breaks the order invariant (proofs mismatch, but
  symmetric trees might still pass). Mitigation: strict alpha-rename + body swap; `t_auth_dict` uses an
  ASYMMETRIC structure where order matters -> catches it.
- **`auth_make` in a verifier path** is undefinable. Never occurs in read-only lambda-dot core; until
  Track 2 type-checks it, emit the H6 link-fail escape so it dies loudly, never silently.
- **Projection ambiguity** on delimiter-containing payloads -> mitigated by mandatory length-prefix framing (H4).
- **The one I'd watch:** H4/H6 must reuse the EXACT byte framing of the Stage A oracle, or the B1
  byte-equal gate fails for a benign formatting reason. Pin the oracle's projection bytes first, then synth to match.

## 8. Out of scope here (do NOT pull in)

- Track 2 Increment C (graceful type-error diagnostics) -- the read-only `fetch` core doesn't need it.
- Merging vlang's P1/P3 first-cuts to master -- separate decision.
- A general Hindley-Milner pass -- explicitly not the move (thesis "promote, don't rewrite").

## 9. Pointers

- Full design (cross-branch): `git show 337d66a:notes/rail-compiler-phase-design.md` §1 (Track 1), §2.8 (type-layer correction)
- Type-layer substrate + the method/discipline: `notes/TYPE_CORE_PLAYBOOK.md`
- Stage A oracle (the spec to match): `tools/auth/authkit.rail`, `tools/auth/authdict.rail` (on `feat/verifiable-language`)
- Campaign + endgame: memory `rail-innovation-thesis-verifiable-language`, `paos-specialist-models`
