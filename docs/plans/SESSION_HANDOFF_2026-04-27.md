# Session handoff — 2026-04-27 (cancel mid-queue)

**Status:** v0.4 queue was launched but cancelled mid-variant-A by user request before any v0.4 checkpoint completed. All training-script + harvester infrastructure built, compiled, and on disk. Spur-0.1 (25/30) remains the shipped flagship.

## What this session shipped (assets, not weights)

### 1. Mutation pipeline 6 → 18 ops
`tools/train/mutate.rail`. New ops:
- Lexer-level: `mut_unclosed_string`, `mut_drop_open_paren`, `mut_bracket_mismatch`
- Identifier: `mut_typo_stdlib`, `mut_typo_keyword_more`, `mut_partial_rename`
- Typecheck: `mut_wrong_arity`, `mut_type_mismatch`
- Match-syntax: `mut_drop_arrow`, `mut_drop_pipe`
- ADT: `mut_bad_ctor_name`
- Comparison: `mut_swap_eq_assign`

All rng-sensitive (multi-site rng-pick). Ops 8 (drop_open_paren) and 14 (bad_ctor_name) iterated once after smoke-test showed initial drop_close_paren / inject-into-ctor variants produced compile-clean code (no diag).

### 2. Seed corpus 40 → 120 programs
Extracted from `gen_triples.rail` into its own library `tools/train/seeds.rail` to break a main-collision import cycle. New seeds in 5 coverage groups (15 string-heavy / 20 multi-arm-match / 15 ADT-heavy / 15 == comparisons / 15 arithmetic chains). All 120 verified compile-clean via `/tmp/verify_seeds.rail` (rebuild from this file's commit if needed). `seed_104` needed restructuring — two top-level functions with identical `if X then K else 0` body share `.Learly_0` assembly label and break compile.

### 3. Triple corpus 247 → 2,357 (9.5×)
`training/triples_v2.txt` = **2,357 triples / 709 KB** at `n_rng_per_seed=12`. Diagnostic distribution: 27% link / 26% parse-rp / 24% expected-decl / 13% parse-eof / 4% match-syntax / 3% typecheck-WARNING (new class — was 0 in v1) / 2% kw / <1% eq.

### 4. Mixed corpus
`training/corpus_mixed_v3.txt` = stdlib (544 KB) + triples_v2 (709 KB) = **1.25 MB**. Built via `cat`. Used by all v0.4 variants.

### 5. Loss-masked training infrastructure
`tools/train/lm_v3_mixed.rail` extended:
- `build_loss_mask` walks the corpus, marks stdlib region (before first `<BROKEN>`) as 1.0 + each `<FIXED>...<END>` content as 1.0.
- `m_ce_loss_masked` / `m_ce_grad_masked_loop` apply per-position mask and renormalize by sum-of-mask.
- `sample_chunk` now slices a per-chunk mask Tensor in addition to labels.
- `batch_ctx` extended from 6 → 8 entries (`mask_global` at idx 6, `mask_chunk` at idx 7).

**Build pitfall**: `length (chars haystack)` per-iteration on a 1.25 MB string is O(n²) and hung an overnight smoke at 407 CPU minutes. Fixed via `find_from_text needle haystack hl from_pos` wrapper that hoists `hl` once, then a self-recursive `find_from_loop needle nl haystack hl pos` does the inner walk.

### 6. v0.3 trained ckpt (negative; documented)
`training/rail_native/checkpoints/spur_fix_v03_step3000` exists. Bench result: **6/30 (20%)** = REGRESSION vs v0.2's 14/30. Per-band: Fund 1, IO 2, Tools 1, Compiler 2, Advanced 0, Comprehend 0. Diagnosis in `spur_fix_negative.md` memory: full-strength mask (BROKEN/DIAG=0.0) at LR=0.02 × 3000 steps over-rotated weights toward FIXED-block-tail patterns; cold-prompt generation collapses to char + multi-newline.

### 7. Three v0.4 training variants (built, compiled, untrained)
- `tools/train/lm_v3_softmask.rail` — variant A: BROKEN/DIAG mask=0.3 (was 0.0). Soft-mask preserves protocol-context learning. ckpt → `spur_fix_v04a_softmask_step3000`.
- `tools/train/lm_v3_finetune.rail` — variant B: load Spur-0.1 ckpt + fine-tune 500 steps × LR=0.005 with full mask. Instruction-tune analog. ckpt → `spur_fix_v04c_finetune_step500`. Uses `load_half_model_into` + `load_adam_states_into`.
- `tools/train/lm_v3_nomask.rail` — variant C: mask=1.0 everywhere; isolates corpus-expansion effect from masking effect. ckpt → `spur_fix_v04b_nomask_step3000`.

All three compile clean. Each produces a distinct ckpt name + log path so they don't clobber each other.

### 8. Queue runner
`tools/train/run_v04_queue.sh` — runs A → bench → B → bench → C → bench, tees boundary lines to `/tmp/spur_fix_v04_queue.log`. Each variant runs ~85 min A + ~14 min B + ~85 min C = ~3.4h total. Wrap with `nohup` + detach.

### 9. Teacher harvester (validated end-to-end)
`tools/train/harvest_teacher.rail` — Qwen 3.6 35B at `10.42.0.2:8081`, model id `~/models/Qwen3.6-35B-A3B-8bit`. Reads `triples_v2.txt`, prompts teacher for each (broken, diag) pair, validates fix compiles, emits new triples to `training/triples_harvested_v1.txt`. Smoke-validated: 200 input → 16 kept (8% novel-fix rate). Uses curl + jq + perl pipeline (mirrors stdlib/llm.rail). MLX is bound to a Mini-network IP not localhost.

`cli_args` is NOT a real Rail builtin — `parse_max_arg` returns the `200` default. Patch by hardcoding or shelling `echo $MAX` before extending.

## To resume tonight's work

The fastest path:
```bash
nohup ~/projects/rail/tools/train/run_v04_queue.sh > /tmp/spur_fix_v04_runner.out 2>&1 & disown
```

Then watch boundaries:
```bash
tail -F /tmp/spur_fix_v04_queue.log
```

When the queue completes, bench results land in `/tmp/spur_fix_v04{a,b,c}_bench.log`. Compare per-band against:
- Spur-0.1 single-sample @ k=10: **13/30** (FUND 2, IO 4, Tools 3, Comp 2, Adv 2, Comprehend 0)
- Spur-Fix v0.2 single-sample @ k=10: **14/30** (FUND 2, IO 4, Tools 2, Comp 3, Adv 3, Comprehend 0)
- Spur-Fix v0.3 single-sample @ k=10: **6/30** (FUND 1, IO 2, Tools 1, Comp 2, Adv 0, Comprehend 0)

**Success criteria** (from session prompt):
- ≥1/5 Comprehend on any v0.4 variant = validates the diagnostic-corpus thesis at this scale
- ≥14/30 total on a masked variant = masking is at minimum non-harmful when calibrated
- ≥17/30 on v0.4c (no-mask) = corpus expansion alone helps

## Known gotchas (verified this session)

1. **O(n²) hang from `length (chars haystack)` in self-recursive helpers.** Hoist into outer wrapper, pass length as inner-loop param.
2. **Symbol-clash on identical `if X then K else 0` bodies.** Differentiate the else clause when two such functions live in the same file.
3. **Print buffering through stdbuf-oL pipelines via tee/tail.** The compiled binary's `print` calls only show in the file when buffer flushes (4 KB) or process exits. Read the file directly, don't trust tail.
4. **`cli_args` is not a Rail binding.** Use shell or hardcode.
5. **MLX teacher is bound to 10.42.0.2 not localhost.** stdlib/llm.rail's hardcoded localhost: URL won't reach it; either ssh-tunnel or write a custom curl.
6. **Bench's `gen_bin` compile races with concurrent rail_native invocations.** Currently retried up to 5×; safe to run alongside a single training process but not alongside another bench.

## What NOT to attempt without re-checking

- **Don't re-run v0.3 with the existing recipe.** It's a documented negative.
- **Don't try N=300 Comprehend rerank on Spur-0.1 again** — already done (Phase 5h.1, 0/5 across 1,500 samples). Confirmed structural ceiling.
- **Don't push variants without comparing against v0.2's 14/30 baseline.** That's the floor for "the corpus or recipe didn't actively hurt."
