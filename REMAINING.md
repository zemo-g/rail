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

## Standing: 3 genuinely GREEN of 15

| rung | what | green? |
|---|---|---|
| **35** Self-Emission (apex) | model emits exact `compile.rail:is_digit`; self-host fixed point holds; 170/170 tests; mutation falsifier fires; Ed25519-sealed | ✅ sealed |
| **32** Outputs-ARE-Rail | model speaks Rail that compiles+runs; foreign witness re-compiles+re-runs to identical `7\n` | ✅ |
| **30** Succinct spot-check (linchpin) | foreign party verifies whole trajectory recomputing ~12.5% of steps; forged interior step REJECTED | ✅ *(mechanism on stand-in; see below)* |

All 15 rungs + 6 seams have implementations on disk (`rungs/r22..r36/`). Adversary-verified, no fabricated passes.

---

## Remaining work, by tractability

### A. Debuggable here — 1–2 bisection rounds each (→ likely 5 green)

Both compile clean, segfault at runtime, **precisely localized** (debug `print` markers still in the source):

- **r26 (tie-break sampling)** — crash isolated to the **F1 opposite-tie-break path**, `rungs/r26/tiebreak_sampling.rail` lines 438–440 (`r26_nucleus_ids_opp` → `r26_nucleus_opp_go` → `r26_maxbelow_opp`/`r26_gt_opp`, OR `r26_draws` on its result). Ruled OUT: empty-set (returns -1 gracefully), infinite-loop (would hang not crash), big-literal-arg (let-bound), arena. **Next:** add markers after line 438 (`nucHi_opp`) and 439 (`drawsNucHi_opp`) to split which of the three calls dies; read `r26_maxbelow_opp_a/_b` (327–347) + `r26_gt_opp` (323) for the trap. Validate: `bash rungs/r26/validate.sh` (RAIL_ARENA_MB=512, no training — fast).
- **r27 (replay-free verify)** — binding **already PROVEN** (`SHA(bundle)==ledger w_hex`, trainer side green); crash isolated to **`prc_group`** token-grouping (271 tokens), `rungs/r27/rung27_verify.rail`. Ruled OUT: cross-dep reorder (tried mutual-rec AND self-loop+let), prc_semi_split (prints `tokcount=271` fine), depth, sha256(bundle). **Next:** bisect by token — make `parse_bundle` group only the first N tokens (e.g. `lm4_take toks 50`) and binary-search the crashing token; inspect `prc_row_ints`/`prc_one_int` on that token's content. Validate: `bash rungs/r27/validate.sh`.

**Lesson (apply here):** instrument empirically; do NOT trust analysis-guesses for segfaults (3 plausible agent fixes compiled but didn't resolve). Remove the `R26-DBG*`/`R27-DBG*` markers once fixed.

### B. Runnable here, not yet attempted

- **r23 (segmented training)** — `bash rungs/r23/validate.sh` (4-segment train of a deeper model + a "does-not-fit" OOM witness). Heavier (RAIL_ARENA_MB=8192). Adversary wanted the OOM witness wired into a failing gate.
- **r25 (attested sampling)** — `bash rungs/r25/validate.sh`, BUT the adversary flagged its falsifier **F2 as measure-zero** (vacuous). Fix first: make F2 a constructed exact-cumsum-boundary case (the `u` lands exactly on a prefix edge so idx1-vs-idx0 is decided by the `<`/`>=` rule), then validate. r26's tie-break machinery depends on this being sound.

### C. Highest-value, hardest — bind rung 30 to the real model

- **r30 → real lm10.** Today's green is the succinct-verify **mechanism** on a STAND-IN transition (`r30_protocol.rail`). The skeleton `rungs/r30/r30_prove.rail` wires the real `lm4_step` + `bnd_wp_ser/deser` full-state (θ,m,v,pow1,pow2) into the identical Merkle/FS/Ed25519 protocol but is **not run** (full lm10 training is 8 GB / minutes). **To close:** run `r30_prove.rail` end-to-end so the spot-check verifies the ACTUAL transformer's training, and bind each step's `(ctx,tgt)` to the rung-24 SPLIT corpus (so it certifies "this corpus was trained," not just internal consistency). This is the real linchpin.

### D. Walled — need external resources

- **r22 (four-ISA)** — REMOTE HW. x86 ELF won't even link here (`x86_64-elf-ld: cannot find -lc`; fix = static SYSV link like the aarch64 path). The **Pi (Linux-ARM64) leg IS reachable** over Tailscale (`zemog@100.87.231.45`): cross-compile (`rail_native linux`), scp, run, 2-way `cmp` with the ARM64-Mac chain. x86 still needs an x86_64 Linux host (none here; no qemu, Rosetta runs Mach-O not ELF).
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
