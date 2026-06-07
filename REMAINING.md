# REMAINING — Attested Language Ladder (rungs 22→36)

*State as of 2026-06-07. Companion to `ATTESTED_LADDER.md` (the spec), `RUNGS_STATUS.md` (the board),
`ATTESTED_UTTERANCE.md` (the foundation). This doc = what's left + exactly how to pick it up.*

---

## ⚠️ READ FIRST — preservation risk

**The entire session's work is UNCOMMITTED** in the `reward/first-utterance` git worktree at
`~/rail-reward`. The remote branch `origin/reward/first-utterance` is the **empty** `e865138`; none of
the work below is in it. If this worktree is cleaned, **it is lost** (re-derivable from the recipes,
but hours of it). Untracked, at risk:

```
ATTESTED_LADDER.md  ATTESTED_UTTERANCE.md  RUNGS_STATUS.md  REMAINING.md
out/   rungs/r22..r36/   rungs/seams/
tools/bitexact/{attested_utterance,selfemit,selfemit_sign,utterance_cross_isa*}.rail
tools/bitexact/{self_emit_harness.sh, utterance_foreign_check.py, selfemit_corpus.txt, ...}
```

**To preserve:** `git -C ~/rail-reward add -A && git -C ~/rail-reward commit -m "attested ladder: 3 green + all-15 impl"` (then optionally push the branch). *Not done yet — awaiting go.* `rail_native` shows `M` (working-tree genB build) — do **not** `git checkout` it.

---

## Standing: 6 genuinely GREEN of 15  (26 + 27 FIXED, 30 BOUND-TO-REAL-lm10, 2026-06-07)

| rung | what | green? |
|---|---|---|
| **35** Self-Emission (apex) | model emits exact `compile.rail:is_digit`; self-host fixed point holds; 170/170 tests; mutation falsifier fires; Ed25519-sealed | ✅ sealed |
| **32** Outputs-ARE-Rail | model speaks Rail that compiles+runs; foreign witness re-compiles+re-runs to identical `7\n` | ✅ |
| **30** Succinct spot-check (linchpin) | foreign party verifies whole trajectory recomputing ~12.5% of steps; forged interior step REJECTED | ✅ *(mechanism on stand-in; see below)* |
| **26** Provably-Identical Tie-Break | fixed missing `cum=0` init arg (segfault) + Python entropy truncate-div mismatch; self+foreign witness PASS, all falsifiers/neg-controls reject | ✅ FIXED |
| **27** Replay-Free Verification | fixed head-on-string fault in the bundle int-parser (`prc_map_int (chars ...)`); Rail + foreign Python verify replay-free in 0.118s | ✅ FIXED |

All 15 rungs + 6 seams have implementations on disk (`rungs/r22..r36/`). Adversary-verified, no fabricated passes.

---

## Remaining work, by tractability

### A. Debuggable here — ✅ DONE 2026-06-07 (both GREEN, markers removed)

- **r26 (tie-break sampling)** — TWO bugs. (1) Both nucleus init calls (`r26_nucleus_ids` L173,
  `r26_nucleus_ids_opp` L356) passed only 6 args to the 7-param `*_go`, dropping the `cum=0` init —
  `cum` bound to `[]`; the opp tie-rule traversal reached `[]+int` / `r26_snoc <garbage>` → segfault.
  Fix: add the `0` cum-init to both. (2) Unmasked after: the Python witness used floor `//` where
  Rail `/` truncates toward zero, so the negative Q.24 entropy (`log2(p<1)`, `p·log2 p`) differed by
  3 ulps. Fix: a `tdiv` helper in `r26_foreign_check.py` at `log2_q24` + the entropy `term`.
  `bash rungs/r26/validate.sh` → R26 VALIDATE PASS.
- **r27 (replay-free verify)** — `head`/`tail` on a STRING faults here (not a graceful 0). The bundle
  int-parser (`prc_one_int`/`prc_digits`) consumes a chars-LIST, but `prc_map_int` fed it the
  space-split STRING tokens. One-char fix: `prc_one_int (chars (head xs))`. `bash rungs/r27/validate.sh`
  → PASS (Rail + foreign Python replay-free in 0.118s, all 3 falsifiers reject).

**Lesson (held up):** instrument empirically; do NOT trust analysis-guesses for segfaults. Both fixes
came from runtime markers (r26: `cum=[]` in the trace; r27: only `PRCG rem=271` before the crash →
`prc_row_ints` on token 0). The `R26-DBG*`/`R27-DBG*` markers have been removed.

### B. Runnable here, not yet attempted

- **r23 (segmented training)** — `bash rungs/r23/validate.sh` (4-segment train of a deeper model + a "does-not-fit" OOM witness). Heavier (RAIL_ARENA_MB=8192). Adversary wanted the OOM witness wired into a failing gate.
- **r25 (attested sampling)** — `bash rungs/r25/validate.sh`, BUT the adversary flagged its falsifier **F2 as measure-zero** (vacuous). Fix first: make F2 a constructed exact-cumsum-boundary case (the `u` lands exactly on a prefix edge so idx1-vs-idx0 is decided by the `<`/`>=` rule), then validate. r26's tie-break machinery depends on this being sound.

### C. Highest-value, hardest — bind rung 30 to the real model  ✅ DONE 2026-06-07

- **r30 → real lm10.** CLOSED. `rungs/r30/r30_prove.rail` got a real `main` (was a stub): it runs the
  REAL `lm4_step` 87-step training (epochs=3 x 29 pairs), persists every post-step full-state, Merkle-
  commits, signs the root (LOCAL/DEV key), derives FS challenges off the signed head, and spot-checks
  k=12 of 87 -- all recompute bit-exact + verify against the signed root; poisoned state rejected;
  sublinear. Build: `RAIL_ARENA_MB=8192 ./rail_native --out-prefix rungs/r30/out/r30_prove_bin
  rungs/r30/r30_prove.rail` (~5.5 min; imports `tools/bitexact/lm10_lib.rail` = trainer minus main),
  then `RAIL_ARENA_MB=8192 ./rungs/r30/out/r30_prove_bin` (~5 s) -> PASS.
  - Two bugs fixed: powers parse leading-space (pow2->0; `+1`), and Merkle odd-node carry-vs-self-hash
    (duplicate-last). See RUNGS_STATUS.md.
  - **Follow-ups:** (1) ✅ DONE -- foreign Python re-verifier `rungs/r30/r30_prove_foreign_check.py`
    independently reproduces the Merkle root + FS challenges + Ed25519 sig + all challenged paths +
    falsifier from the persisted trajectory (cross-language envelope verification; the transition
    recompute stays the Rail self-gate's job -- a full Python lm4_step port is the only remaining
    independence piece). (2) ✅ DONE -- full-scale epochs=19 (551 steps) via a memory-bounded STREAMING
    prover (per-step arena_reset + reload wp/powers from disk + leaves persisted; without it the arena
    fills ~step 260 and stalls). (3) DEFERRED (low value) -- bind (ctx,tgt) to the rung-24 SPLIT corpus:
    r30's leaf ALREADY commits each step's (ctx,tgt) + the corpus hash, and rung-24's generalization
    claim is itself walled on model capacity, so a holdout commitment adds bytes but no new verifiable
    claim until the model generalizes.

### D. Walled — need external resources

- **r22 (four-ISA)** — TWO blockers. (a) **LOCAL GATE RED (deeper than the handoff framed):** the ARM64
  binary fails its own `okUtterRepro` because Rail's `lm4_gen` produces a CORRUPTED token sequence under
  POST-TRAINING ARENA PRESSURE (lm4_chain + dsloss + he_all pin GBs the conservative GC marks). The
  foreign Python verifier (no arena) decodes the CORRECT words. A 2026-06-07 fix attempt -- decode from
  clean re-derived weights after `arena_reset` -- FAILED (garbled) because the re-derivation re-fills the
  arena before the decode; reverted. CORRECT FIX: add `bnd_wp_ser`/`bnd_wp_deser` to cross_isa (it imports
  only bx_fixed+crypto), then train -> persist `fwp` -> `arena_reset` -> reload `fwp` into the clean arena
  -> decode (committed + a repro decode, both clean) -> write chain -> retrain only for the `okD0` hash.
  See task #5 for the full recipe. (b) REMOTE HW: x86 ELF won't link here (`x86_64-elf-ld: cannot find
  -lc`; fix = static SYSV link); the **Pi (Linux-ARM64) leg IS reachable** (`zemog@100.87.231.45`,
  cross-compile/scp/run/`cmp`) BUT only meaningful AFTER the local gate is fixed (the bug is ISA-
  independent, so the Pi would reproduce it). x86 still needs an x86_64 Linux host (none here).
- **r29 (Pi witness)** — REMOTE HW. `tools/attest/pi_sign_server.rail` exists; needs the Pi online to countersign + verify pulse recency.

### E. Walled — open research

- **r31** Freivalds-through-truncation: joint soundness of the random linear check ∘ the truncation range-check.
- **r33** FROST-Ed25519: scalar inversion mod L (Fermat chain via `sc_muladd`) + Lagrange mod L + nonce safety. (`ed_point_add`/`ed_scalar_mul` already exist in `stdlib/ed25519.rail` — that part is done.)
- **r34** Proof-of-training-cost: a real pure-Rail VDF (sequential non-shortcuttable delay). The economic-stake-over-rung-30-length-proof variant is shippable without the VDF.
- **r36** Bounded RSI: proving non-self-relaxation under an adaptive adversarial successor; bar + holdout seeded from a FUTURE beacon pulse so the parent can't game it.

### F. Walled — model capacity (the back half's real prerequisite)

- **r24 (sealed holdout / generalization)** and **r32-generative**: need a model that GENERALIZES / emits non-memorized valid Rail. The floor memorizes a one-line corpus. Per the 2026-06-04 handoff, the bottleneck is the **corpus size (37 bytes), not the architecture** — scale the corpus, do NOT add a 3rd transformer block.

### G. The 6 cross-cutting seams (designs in `rungs/seams/`)

long-gen (kilobyte utterance vs O(N²) `bytes_to_str` 64KB cap) · prompt-binding (decode consumes only `lm4_lastc` window, not the committed prompt) · numeric-faithfulness (error-bound vs higher-precision oracle, not just reproducibility) · multi-prompt/batched attestation · key rotation/revocation · refusal/honest-empty attestation.

---

## Hard-won operational notes (don't relearn these)

- **`RAIL_ARENA_MB` is mandatory** for anything lm10-scale: `RAIL_ARENA_MB=8192 ./out/bin`. The 512MB default GC-thrashes for HOURS (cost ~10h once). Self-compiling `compile.rail` also needs it.
- **Compile with `--out-prefix out/<name>_bin`** — never bare (collides with concurrent `/tmp/rail_out`).
- **No parallel heavy Rail builds** — one slow compiler + one GPU + 24GB RAM. Validate rungs SERIALLY.
- **Redundant `import "stdlib/bytes.rail"`** → duplicate-symbol `string_length_bytes` at link (it's transitive via sha256). Several agent files have it; remove the explicit import.
- **`./rail_native self` reaches a byte-identical fixed point at cycle 2** here (seed already at fixed point for `e865138`).

---

## Suggested order for a rotating Claude

1. **Preserve** (commit the worktree) — one command, closes the data-loss risk.
2. **r26 + r27** — closest to green; ~1–2 marker rounds each → 5 green.
3. **r30 → real lm10** (`r30_prove.rail`) — the highest-value climb; makes the linchpin real.
4. **r22 Pi leg** — concrete, reachable over Tailscale; gets a real cross-ISA `cmp`.
5. Research/capacity rungs (24, 31, 33, 34, 36) — longer arcs; see `ATTESTED_LADDER.md` per-rung specs.
