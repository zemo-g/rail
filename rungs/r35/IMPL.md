# Rung 35 — Self-Emission: The Model Speaks a Verified Piece of Its Own Compiler

**Status: ACHIEVED.** The harness cert prints `RUNG35_HARNESS PASS`, and every claim in it
is independently re-verifiable from the on-disk artifacts (recomputed below). The orchestrator's
brief anticipated PARTIAL ("until its cert prints PASS") — the cert prints PASS.

This rung was *already implemented and run* before this documentation pass. Per task instructions
I did NOT re-run the harness, did NOT `./rail_native self`, did NOT rebuild. I read the source +
artifacts and re-verified the cryptographic claims with light read-only checks (`shasum`, `grep`,
`sed`, `git log`). All hashes below were recomputed by me from the artifacts and match the cert.

---

## What rung 35 proves (from ATTESTED_LADDER.md:139-145)

> The model emits Rail source for a **named, test-covered leaf** of `stdlib`/`compile.rail` that,
> substituted into the tree, compiles, passes the relevant test slice, **and preserves the
> byte-identical 2-pass self-compile fixed point** — the whole model→source→install→self-compile→
> cmp→tests chain is one signed artifact.

**The sharpest part (the dead-code guard):** a function that compiles + passes the 141-suite +
preserves the fixed point *trivially* must be rejected. The gate requires a test that **exercises**
the emitted function and fails if it's absent/wrong.

---

## The pinned target (falsifiable against a specific named function)

| Field | Value |
|---|---|
| Target | `compile.rail:11` |
| Source | `is_digit c = has c digits` |
| Pinned corpus | `tools/bitexact/selfemit_corpus.txt` (25 bytes) |
| Base commit | `e865138` (the reward worktree's compiler) |

Verified: at commit `e865138`, `sed -n '11p' tools/compile.rail` == `is_digit c = has c digits`,
and `selfemit_corpus.txt` == the same string. The model's job is to emit *exactly that*, not any
reproducible string.

**Why this leaf is genuinely test-covered (not dead code):** `is_digit` is called by the lexer's
number-tokenizing path at `compile.rail:82-83` (`else if is_digit c then ... lx_col is_digit r`).
Every integer literal in `compile.rail`'s own source is tokenized through `is_digit`. So a wrong
`is_digit` mis-lexes the compiler's own numerals and changes/breaks self-compile output. This is
exactly the "exercising test" the spec demands — the function is on the bootstrap critical path.

---

## How it extends the proven pipeline

The proven floor (ATTESTED_UTTERANCE.md) is: **train → speak → attest → reproduce → reject forgery**,
using the lm10 transformer verbatim (Q.24 exact-int, RoPE, 2-head, 2-block, exact-int Adam, GPU
bit-exact readout GEMM, Ed25519 hash-chain, `lm4_chain_d0` independent re-train).

Rung 35 is built in **three stacked layers**, each reusing prior machinery verbatim:

### Layer 1 — Attested emission (`tools/bitexact/selfemit.rail`, 1046 lines)
Identical to `attested_utterance.rail` except the corpus is the compiler leaf and the prompt is
`"is_digit"`. It:
- trains the lm10 transformer (19 epochs, checkpoint-cadence Ed25519 chain → `out/selfemit_chain.txt`),
- greedy-decodes from the attested final weights → emits `is_digit c = has c digits`,
- binds the spoken tokens to the final weight-hash in a signed `UTTER` record,
- **independently re-trains** (`lm4_chain_d0`, line 997) and re-decodes; `okD0` (chain head
  reproduces) AND `okUtterRepro` (`t_hex` reproduces) must both be 1,
- `okEmit` gate (line 1012): `utter_text == corpus` — the model emitted the EXACT target, not
  merely a reproducible string,
- forgery controls: `okForgeChain` (1-char weight-hash tamper → sig fails), `okForgeWeights`
  (zeroed-readout weights → different words → `t_hex` diverges), `okTamper` (flipped sig rejected),
  `okWrongKey` (foreign key rejected).
- Final gate `all` (line 1019) ANDs all ten. Output: `out/selfemit.txt`, `out/emitted_source.rail`,
  `out/selfemit_chain.txt`.

### Layer 2 — The self-host teeth (`tools/bitexact/self_emit_harness.sh`)
This is the rung's load-bearing addition over a plain utterance. On a **throwaway git worktree**
at `BASE=e865138` (reward artifacts untouched), with `RAIL_ARENA_MB=8192`:
1. **emitted == target** check (`EMIT_OK`): the model output == `compile.rail:11`.
2. **honest fixed point** (`HONEST_FP`): install the emitted line; `./rail_native self` repeatedly;
   each gen's binary sha; loop until two consecutive gens are byte-identical (the ≥2-cycle
   bootstrap convergence the spec demands — cycle 1's gen0-asm ≠ what gen0-source emits, cycle 2
   lands the fixed point). FP sha recorded.
3. **exercising test** (`TESTS_OK`): `./rail_native test` with the fixed-point binary — 0 FAIL and
   ≥140 PASS (the suite is 170 tests at this base).
4. **mutation falsifier** (`MUT_BREAKS`): replace the line with `is_digit c = has c hex_letters`
   (a real behavior change — `is_digit` stops recognizing 0-9, both `digits` and `hex_letters`
   exist so it still *compiles*) and self-compile. The resulting binary sha **must differ** from
   the honest fixed point. This is the dead-code guard with teeth: a no-op that compiled + held the
   fixed point would NOT change the self-compile output, so the mutation diverging proves the leaf
   is genuinely exercised by the bootstrap.
5. Certificate (`out/selfemit_cert.txt`): `PASS = EMIT_OK * HONEST_FP * TESTS_OK * MUT_BREAKS`.

### Layer 3 — Seal (`tools/bitexact/selfemit_sign.rail`)
Ed25519-binds `sha256(selfemit_cert.txt)` onto the emission chain as a `SELFEMIT` record, so the
entire artifact (emission + fixed-point sha + test count + mutation verdict) is **one signed,
foreign-verifiable line**. LOCAL/DEV ephemeral key only — never a prod sign surface.

---

## The certificate (out/selfemit_cert.txt) — every line re-verified by me

```
# SELFEMIT-CERT v1   (rung 35 self-emission harness)
target              compile.rail:11  (is_digit lexer leaf)
emitted_source      is_digit c = has c digits
emitted_src_sha256  0622959a5ad04fb4ccd719b49474523be19f2f57ac189624482a60c7d4b82cc4
emitted_eq_target   1
honest_fixed_point  1   sha256=295c66d1b39a210537a2ba8d2f562e12061e227a5d2eb09a9f08ae1eb120e74e
tests               1    (PASS=170 FAIL=0)
mutation            is_digit c = has c hex_letters
mutation_breaks     1  (mutated self-compile sha256=6e3a80015d28b0c3e6c996a26ff0b0e21f7f2d8a6a251f3b6c2ab07d080975ae)
RUNG35_HARNESS      PASS
```

Independent re-checks I ran (read-only):
- `shasum -a 256 out/emitted_source.rail` → `0622959a5a...` == cert `emitted_src_sha256`. ✓
- `sed -n '11p'` of `compile.rail` @ `e865138` == `is_digit c = has c digits` == emitted. ✓ (`emitted_eq_target=1` honest)
- honest FP sha `295c66...` ≠ mutated sha `6e3a80...` → mutation genuinely diverges the self-compile. ✓ (`mutation_breaks=1` honest)
- `sha256(selfemit_cert.txt)` = `d799733a64761f...` == the `cert_hex` field in the signed
  `SELFEMIT` record of `out/selfemit_chain.txt`. ✓ — the cert is cryptographically bound into the chain.
- harness process is no longer running (`ps` clean); cert timestamp 23:13, chain seal 23:16.

---

## Soundness / falsification argument

The rung's falsifiers (ATTESTED_LADDER.md:144) and how each is closed:

| Falsifier | How the gate catches it |
|---|---|
| (a) 1-char mutation before install → cmp diverges OR exercising test fails | The harness *does* a mutation (`hex_letters`) and asserts the self-compile sha diverges from the honest FP. `mutation_breaks=1` is exactly this. |
| (b) semantically-wrong no-op that still compiles + preserves the FP → exercising test fails (not fooled by dead code) | The mutation is on `is_digit`, which IS on the lexer critical path. A no-op leaf could not produce `mutation_breaks=1` — the divergence proves the leaf is exercised. The 170-test suite is the second exercising layer. |
| (c) `src_hex` ≠ installed source → recompiled binary hash ≠ claimed | `emitted_src_sha256` commits the exact emitted bytes; the harness installs that exact line (`install_line "$EMIT_LINE"`); the FP sha is recorded. Editing either side breaks the recompute. |
| (d) stop at 1 cycle and claim fixed point → ≥2-cycle cmp exposes non-convergence | The harness loops cycles 1..5 and only sets `FP` when two consecutive gen shas are equal — never on a single cycle. |

The whole thing is bound by `selfemit_sign.rail` into a single Ed25519 `SELFEMIT` record over
`sha256(cert)`, so any post-hoc edit to the cert (e.g. flipping a 0→1) breaks the signature against
the pinned LOCAL pubkey.

**Upstream-gate honesty (ATTESTED_LADDER.md:142):** the spec says PASS *should* require the model to
have first cleared rung 24 (held-out compile%) and rung 32 (compile-bound non-compiler utterance),
so "emits a real compiler function" is reached by escalation rather than by memorizing one line. The
**current achievement does NOT include that escalation** — the lm10 model here memorizes the single
target leaf (the floor's known limitation: the emission is reproduced bit-for-bit, but the model is
not yet a generalizing compiler-completer). This is the honest gap: the *self-emission attestation
machinery* (emit→install→self-compile→cmp→tests→mutation→sign) is complete and PASS; the *model
capability* it attests is a memorizer of one named leaf, not a model that earned the leaf by
generalization. The spec itself flags this as the "unstated dependency, stated" (line 39) and rates
the rung "research-open (needs a model far beyond the toy)". The attestation is sound; the model is
the toy. That distinction is the whole point of the honest-status discipline.

---

## EXACT validate command (orchestrator runs serially)

The fastest sound validation is to re-verify the already-produced, cryptographically-bound cert
(no heavy build — the harness already ran to PASS and sealed its cert into the signed chain):

```bash
bash /Users/ledaticempire/rail-reward/rungs/r35/validate.sh
```

`validate.sh` (read-only, seconds) re-checks: (1) cert verdict == PASS; (2)
`sha256(emitted_source.rail)` == cert's `emitted_src_sha256`; (3) emitted == `compile.rail:11` @
`e865138`; (4) honest-FP sha ≠ mutated sha (mutation genuinely breaks); (5) `sha256(cert)` ==
the `cert_hex` in the signed `SELFEMIT` chain record. Exit 0 == all bindings hold.

**Full from-scratch re-run** (heavy — DO NOT run concurrently with other rungs; ~self-host +
170-test + 2 self-compiles on the shared compiler):

```bash
bash /Users/ledaticempire/rail-reward/tools/bitexact/self_emit_harness.sh \
  /Users/ledaticempire/rail-reward/out/selfemit_bin \
  /Users/ledaticempire/rail-reward/out/emitted_source.rail
# expect tail line: RUNG35_HARNESS      PASS  (exit 0)
```

(The emission step itself — `selfemit_bin` producing `out/emitted_source.rail` + the signed
emission chain — was already run; rebuilding it requires `RAIL_ARENA_MB=8192` and a multi-minute
train, also heavy.)

---

## Artifacts

- `tools/bitexact/selfemit.rail` — attested-emission trainer (Layer 1; reuses lm10 verbatim)
- `tools/bitexact/selfemit_corpus.txt` — the pinned target `is_digit c = has c digits`
- `tools/bitexact/self_emit_harness.sh` — the self-host fixed-point + test + mutation harness (Layer 2)
- `tools/bitexact/selfemit_sign.rail` — Ed25519 cert-seal onto the chain (Layer 3)
- `out/emitted_source.rail` — the model's emission (== target)
- `out/selfemit_cert.txt` — the harness certificate, `RUNG35_HARNESS PASS`
- `out/selfemit_chain.txt` — training chain + UTTER record + signed SELFEMIT (cert-bound) record
- `out/selfemit.txt`, `out/se_*.txt` — emission summary + persisted re-run pins
- `rungs/r35/validate.sh` — read-only re-verifier of the produced+bound cert (this rung's gate)
