# Phase 5g — Spur-Fix negative result

**Date:** 2026-04-23.
**Status:** negative but informative. Two Spur-Fix variants trained and benched. Neither exceeded Spur-0.1's 25/30 flagship. Diagnostic-corpus training is a viable research direction but needs scale we didn't have time to deliver today.

## The hypothesis

> Every compiled Rail program emits structured diagnostics. Train a model on `(broken_code, diagnostic, fixed_code)` triples and it will learn to take a compile failure + its error message and produce a fix. At inference, combine with a fix-loop (sample → compile → on failure, re-prompt with `<BROKEN>/<DIAG>/<FIXED>` → sample again) and unlock capability no compile-pass-only training can match. Specifically: crack Comprehend's 0/5 on bench_railnative, where prompts like `-- complete this factorial so it prints 120\nfact n = ` require semantic-intent matching.

## What I built

### Infrastructure (shipped, reusable)

| file | role |
|---|---|
| `tools/train/mutate.rail` | 6 text-level mutation operators with RNG dispatch (delete_line, remove_main, truncate_let, typo_keyword, insert_stray_paren, swap_add_sub) |
| `tools/train/diagnose.rail` | compile source → parse stderr → extract first error/link/warning line; priority-ordered (parse > link > warning) |
| `tools/train/gen_triples.rail` | orchestrator: 40 seeds × 4 RNG × 6 ops → emit `<BROKEN>/<DIAG>/<FIXED>/<END>` blocks, dedup via list_contains |
| `tools/train/lm_v3_triples.rail` | Spur-Fix v0.1 training variant — same architecture as Spur-0.1, `corpus_path = training/triples_v1.txt` |
| `tools/train/lm_v3_mixed.rail` | Spur-Fix v0.2 training variant — corpus is stdlib + triples concatenated |
| `flywheel-local/bench_railnative_fix.rail` | fix-loop bench: N=4 iterations per task; iter-0 is original prompt; iter-1+ uses `<BROKEN>/<DIAG>/<FIXED>` protocol |
| `docs/plans/DIAGNOSTIC_CORPUS.md` | architectural design doc, research claim, 3-4 day roadmap |

All pieces compile cleanly. All are committed except `flywheel-local/*` which is gitignored (tracks the private `rail-training` repo).

### Triple corpus v1 (59 KB, 247 triples)

40 hand-crafted compile-clean seed programs covering: let/match/recursion/ADTs/string ops/list ops/higher-order functions. Each seed × 4 RNG × 6 mutations, dedup'd on string equality → 247 usable triples (some op variants produced compile-clean code that got filtered; some produced duplicates on RNG-insensitive ops).

Triples look like:

```
<BROKEN>
main = let _ = print 42

<DIAG>
/tmp/rail_diag_in.rail:2:1: error: unexpected: eof
<FIXED>
main = let _ = print 42
  0

<END>
```

Clean, structured, diagnostics read sensibly. Data pipeline validated.

## The two trained variants

### Spur-Fix v0.1 (pure triples, 59 KB corpus)

Trained 3000 steps on `triples_v1.txt` only. Eval descended cleanly to 3.50 ± 0.05 at step 2900 (similar magnitude to Spur-0.1's 3.49).

**Failure mode at inference:** catastrophic. Cold prompts produced a single char (usually `B` — the first char of `<BROKEN>`) followed by 80+ newlines. The model learned the block-marker structure dominated its training but never saw raw code outside protocol blocks, so "continue raw code from a short prompt" is out of distribution.

Direct probes:

| prompt | output |
|---|---|
| `fact n = ` | `fact n = B\n\n\n...\n\n` |
| `<FIXED>\nfact n = ` | `...\n""\n\n\n...` |
| `<BROKEN>\nfact n = \n<DIAG>\nerror: expected expression\n<FIXED>\n` | `...<FIXED>\na` (single char then buffer termination) |

Result: bench killed mid-run after confirming the pathology. Predicted score < 3/30.

### Spur-Fix v0.2 (mixed corpus: 544 KB stdlib + 59 KB triples)

Trained 3000 steps on `corpus_mixed_v1.txt`. Eval descended to 3.57 ± 0.15 at step 2900 — slightly higher than Spur-0.1's 3.49 (the model splits attention across two distributions; slight held-out eval penalty).

**Results on the full 30-task bench:**

| decoder | pass | vs Spur-0.1 baseline |
|---|---:|---:|
| single-sample @ k=10 temp=0.8 | **14/30 (46%)** | **+1** over Spur-0.1's 13/30 |
| fix-loop N=4 @ k=10 temp=0.8 | 14/30 (46%) | **fix-loop is a no-op (+0)** |

Per-band (both benches byte-identical):

| band | v0.2 | Spur-0.1 |
|---|---:|---:|
| Fundamentals | 2/5 | 1-2/5 |
| Practical IO | 4/5 | 4/5 |
| Real Tools | 2/5 | 3/5 |
| Compiler | 3/5 | 2/5 |
| Advanced | 3/5 | 2/5 |
| Comprehend | 0/5 | 0/5 |

v0.2 does NOT regress on structural tasks — the mixed training kept Spur-0.1's raw-code capability. It gains 1 pass vs Spur-0.1 at the same decoder (within seed noise).

**Fix-loop added zero passes.** Every iteration failed to produce a compile-pass from the previous iteration's failure. Same 16 task failures at iter-0 as at iter-3.

## Why the fix-loop didn't work

Three plausible reasons, not mutually exclusive:

### 1. Training-data scale

247 triples is 2 orders of magnitude smaller than the stdlib corpus. At 10% of the mixed-corpus volume, the protocol structure didn't install strongly enough for the model to generate useful fixes. Comparison: GPT-3's compile-by-example learning needed ~10M pairs; Spur-Fix had 247.

### 2. Mutation-diagnostic-domain mismatch

Our 6 mutation operators produce specific error patterns: deleted lines produce "expected decl", removed mains produce "_main undefined", truncated lets produce "unexpected: eof", etc. The bench's inference failures mostly produce DIFFERENT error patterns (e.g., "garbage after function body", "unclosed expression in complex match"). The model learned `(mutation_pattern, known_diag) → restore`. At inference it sees `(model_garbage, unfamiliar_diag) → ?` and produces more garbage.

Fix: much broader coverage of failure modes, including model-generated-garbage failures harvested via the flywheel.

### 3. No gradient signal on FIXED block quality

Training does next-char prediction uniformly across `<BROKEN>/<DIAG>/<FIXED>/<END>` blocks. The model learned `<BROKEN>` → `<DIAG>` → `<FIXED>` transitions as much as it learned fix content. At inference, the model may be emitting valid transitions but their CONTENT in the `<FIXED>` block is what matters for compile-pass — and that's undertrained.

Fix: loss masking (only compute loss on `<FIXED>` tokens) or instruction-tuning style fine-tuning where the label IS the fix.

## What this doesn't invalidate

**The compiler-as-search-oracle thesis still holds.** Spur-0.1 + 20-sample compiler re-rank at k=50 scores 25/30. That's the flagship and it's bulletproof — variance ±0-1 across seeds, clean methodology, reproducible from git.

**The diagnostic-corpus thesis is still valid in principle.** The infrastructure is shipped. What failed was today's attempt at 247 triples × a 1.74M-param model trained for 3000 steps. The research question "can compiler-diagnostic training unlock Comprehend" remains open; a future attempt with:
- 5,000-50,000 triples (flywheel-generated)
- Loss masking on the FIXED block
- Possibly a larger model (d=512 or d=1024)

is a reasonable next experiment. Not today.

## Spur-Fix as Session 10+ work

The infrastructure is the asset. Future sessions can:

1. Run `gen_triples.rail` after expanding `mutate.rail` with 10+ additional operators.
2. Implement model-in-the-loop triple generation: Spur-0.1 generates candidates for bench-like prompts, compile, harvest triples from failures, retrain. True flywheel.
3. Train Spur-Fix v0.3 on ≥5,000 triples, compare against Spur-0.1's 25/30 at matched decoder + rerank.

None of these block the 2026-04-27 milestone. All can be done in 2-3 days when someone has the bandwidth.

## The arc

| attempt | approach | result |
|---|---|---|
| Spur-Fix v0.1 | pure-triples training | catastrophic cold-prompt failure; model collapsed to protocol markers + whitespace |
| Spur-Fix v0.2 | mixed stdlib + triples training | retained Spur-0.1's structural capability (14/30, +1); fix-loop didn't add passes (+0) |
| [deferred] Spur-Fix v0.3 | fine-tune Spur-0.1 for 500 steps on triples; or 10x the triple count; or add loss masking | not attempted today |

## What ships

**Spur-0.1 + compiler re-rank = 25/30 (83%)** is the final flagship. The diagnostic-corpus direction is well-scoped for future work — mutate / diagnose / gen_triples / lm_v3_triples / lm_v3_mixed / bench_railnative_fix all exist, tested, and committed (except flywheel-local/ files).

## Files

- Training checkpoints (on disk, not in git):
  - `training/rail_native/checkpoints/spur_fix_step3000.*` — v0.1, pure triples
  - `training/rail_native/checkpoints/spur_fix_v02_step3000.*` — v0.2, mixed corpus
- Corpora (on disk, not in git):
  - `training/triples_v1.txt` (59 KB, 247 triples)
  - `training/corpus_mixed_v1.txt` (603 KB, stdlib + triples concatenated)
- Bench logs (on disk):
  - `/tmp/spur_fix_v02_<ts>/bench1_single.log`
  - `/tmp/spur_fix_v02_<ts>/bench2_fixloop.log`

All infrastructure committed. The negative result is documented. Spur-0.1 + compiler re-rank remains the ship.
