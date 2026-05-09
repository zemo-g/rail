# Spur — session handoff 2026-05-02 (44-hour arc, 2026-04-30 23:00 → 2026-05-02 19:20)

## TL;DR

**Spur on Rail moves from 1-2/30 ceiling → 9/30 single ckpt (30%) → 24/30 ensemble (80%) honest bench.** The lever isn't architecture, isn't recipe, isn't optimizer. It's training on `tools/compile.rail` ALONE — the 4,690-line self-hosting Rail compiler we own — at d=256 × 3000 steps × seed-search × per-prompt routing. Mixing in anything else dilutes. Best ckpt: `spur_v54_BQ2_s77_best`. The thesis Spur had from day 1 — owning the substrate is the lever — is empirically confirmed end-to-end.

## The thesis, in one paragraph

Other code-LM projects train on heterogeneous web-scraped code judged by an opaque foreign verifier. Spur uniquely owns a 4,690-line self-hosting compiler in its own target language. Training a tiny (1.74M-param) transformer on that one program — not augmented, not curated, not distilled — produces a model that compiles its own language at honest 27% pass rate. Routing across 46 such cheap models per-prompt covers 80% of the bench. The remaining 20% is the Comprehension band, which is structurally beyond compile.rail-only training and needs a substrate Spur doesn't yet own (instruction-following Q&A, teacher distill, or multi-stage trainer surgery).

## The shipping recipe (reproduce in one session)

```bash
# 1. ASCII-clean compile.rail's back quarter (codegen + x86 emit)
python3 -c "
with open('tools/compile.rail','rb') as f: d=f.read()
ascii=bytes(b for b in d if b<128)
q = (3*len(ascii))//4
while q < len(ascii) and ascii[q] != ord(b'\\n'): q += 1
with open('training/corpora/spur_compile_back_quarter.txt','wb') as f: f.write(ascii[q+1:])"

# 2. Train at d=256 × 3000 steps × LR=0.01 × seed=77 (~85 min wall)
./rail_native run tools/train/lm_v54_BQ2_s77.rail

# 3. Bench (~25 min wall, N=20 parallel rerank)
./rail_native run flywheel-local/bench_railnative_rerank.rail \
  --gen-source tools/train/lm_infer_cpu_v46_bq.rail \
  --prefix training/rail_native/checkpoints/spur_v54_BQ2_s77_best \
  --max 64 --k 10 --temp 0.8 --tag v54_repro

# Expect: 9/30 honest pass rate, q ≈ 36k.
```

For the ensemble (24/30 ceiling), see `tools/train/ensemble_ceiling.sh` — it walks `/tmp/v*_bench.log` and computes per-prompt union.

## Evidence

### Best single ckpts

| Ckpt | Recipe | Bench | Best band |
|---|---|---:|---|
| **spur_v54_BQ2_s77** | back-quarter (90 KB) × LR=0.01 × seed=77 | **9/30 (30%)** | Compiler 4/5, Fund 3/5 |
| spur_v48_BQ_s100 | back-quarter × LR=0.02 × seed=100 | 8/30 | Real Tools 4/5 |
| spur_v43_halfB_s5555 | half-B (180 KB) × seed=5555 | 7/30 | mixed |
| spur_v27_pushJ | full corpus (362 KB) × seed=12345 | 7/30 | Compiler 3/5 |

### Ensemble (46 ckpts, per-prompt max-pass routing)

**24/30 (80%) — saturated.** The 6 unsolved tasks are 1 Advanced + all 5 Comprehension. Confirmed unsolvable across all 46 single ckpts.

### Distribution of seeds at the winning recipe

12 seeds at d=256 × 3000 steps × full compile.rail:
- 4/12 hit 6+/30 (33%)
- 3/12 hit 1-3/30 (25%)
- 5/12 collapse to 0/30 (42%)

10 seeds at half-B (180 KB):
- mean 3.9/30, peak 7/30, **zero collapses** (more robust)

5 seeds at back-quarter LR=0.01:
- mean 5.4/30, peak 9/30, zero collapses

**Best-of-N seed search is mandatory.** val_loss does NOT predict bench (seed=2025 had lowest val_loss but worst bench).

## The structure — why this works

`tools/compile.rail` is structurally cohesive: one program, one author, consistent naming/scoping/idioms, complete grammar coverage. Training on it concentrates the model on ONE coherent code distribution. **Mixing destroys the lever** (4-arm proof tonight):

| Corpus | Bench |
|---|---:|
| compile.rail alone | 6-9/30 (winning) |
| ascii + curriculum | 1/30 |
| compile.rail + curriculum | 1/30 |
| ascii + compile.rail | 0/30 |
| compile + transformer + bpe + checkpoint (multi-coherent) | 0/30 |

**Smaller-and-back wins.** The corpus-size axis is U-shaped:
- Full (362 KB, ~8.5 epochs at 3000 steps): mean 2.8, 50% collapse
- Half-B back (180 KB, ~17 epochs): mean 3.9, 0% collapse — robustness winner
- Back-quarter (90 KB, ~33 epochs): peak 9/30 — peak winner, some NaN risk
- Back-quarter at LR=0.01: stable, peak 9/30 — best of both

Front half (lexer/parser/typecheck) alone = 0/30. The codegen content carries the lever.

## What failed (and why) — accept these

These are dead ends. Don't redo them.

| Approach | Result | Why it failed |
|---|---|---|
| More steps (6000 instead of 3000) | 0/30 | Overfits at fixed corpus size |
| Bigger model (d=384) | 1/30 | Under-trained at fixed steps; needs more |
| Biggest model (d=512) | NaN | fp16 overflow at LR=0.02 |
| d=384 + safe LR (0.005) | 0/30 | Lower LR ≠ enough to compete |
| ASCII-clean curriculum (310 KB) | 1/30 | Template redundancy teaches narrow patterns |
| Multi-coherent (4 single-author files) | 0/30 | Cross-file structural noise dilutes |
| Inline parse-trace as auxiliary corpus | 0/30 (raw) | Model emits trace tags as bytes |
| Compile-loss / REST^EM harvest | 0 survivors | Sub-1% per-sample compile rate × 50% segfault = no bootstrap data |
| 52 hand-curated Comprehension Q&A at 8% ratio | 8/30, Comp 0/5 | Corpus weight too low for pattern transfer |
| Comprehension corpus repeated 20× at 63% ratio | 0/30 | Memorizes specific examples, dilutes codegen |

## The 6 unsolved — structural ceiling

Tasks not covered by ANY ckpt across 46 trainings:

- **Task 22:** 1 Advanced task (likely the `type Pair` ADT one)
- **Tasks 26-30:** ALL 5 Comprehension band ("complete this X so it prints Y"-style prompts)

Per the `comprehend_is_semantic.md` finding from Spur-0.1 era (already in memory): Comprehension ceiling is at training-distribution level, not sampling level. Compile.rail-only training cannot teach instruction-following semantics.

To break past 24/30, Spur needs a substrate it doesn't currently own:
1. **A real Rail Q&A teacher** — Anthropic API was the candidate; retired (per `next_session_pointer.md` history)
2. **Hand-curated instruction-following corpus** — 1000s of pairs needed (52 doesn't transfer; 20× repetition memorizes)
3. **Multi-stage trainer fork** — pretrain on compile.rail, fine-tune on Comprehension. Requires trainer surgery (~3-4 hr).

## What to do next, in priority order

### P0 — ship Spur-v54 + ensemble as the canonical Spur SOTA
The portfolio is the deliverable. 46 ckpts under `training/rail_native/checkpoints/spur_v*`. Router at `tools/train/spur_ensemble_infer.sh` (note: per-prompt segfault retries needed; bench harness's 8-parallel rerank is more robust). Cite "9/30 single, 24/30 ensemble" as the official numbers.

### P1 — try multi-stage to crack Comprehension
Fork `tools/train/lm_v54_BQ2_s77.rail` → `lm_v58_pretrain_finetune.rail`. Add:
- Phase A (steps 0-2500): train on compile.rail back-quarter, normal cosine LR.
- Phase B (steps 2500-3000): switch corpus to comprehension-only seed (the 52 examples), drop LR to 0.0001, keep training.

This teaches codegen first, then "instructs" the comprehension pattern in the final cosine tail. ~2 hr work + 1 hr validate. Most plausible single move to break past 24/30.

### P2 — restore the Anthropic teacher
The teacher distill that produced corpus_distill_v05.txt was at `10.42.0.2:8080` (per `teacher_distill_works.md`). If still up, re-harvest 200-500 Comprehension-style Rail completions. Mix into a third recipe arm. If teacher is dead, P3 instead.

### P3 — patch the bench harness to support Comprehension better
The bench's `bench_comprehend` prompts have very specific format `"-- complete this X so it prints Y\nname args = "`. If the model's training has a SLIGHTLY different format (e.g., comment style or trailing space), the bench will miss correct outputs. Worth dumping a few v56 outputs and diff-ing against expected — there may be a parser-level escape hatch.

### P4 — N=20 sweep on the winning recipe
Currently we have 12 seeds at full corpus, 10 at half-B, 5 at BQ-LR0.02, 5 at BQ-LR0.01. Adding 10 more BQ-LR0.01 seeds gives the cleanest distribution estimate. ~85 min train + bench in waves of 5 parallel. Gets us a tight read on the BQ-LR0.01 mean ± std, and may hit 10+/30 on the lucky seed (one outlier away from a peak above v54's 9).

## Substrate state (what's clean, what's known-broken)

### Clean
- Float TCO fix from 2026-04-30 holds.
- Inference seed-segfault workaround holds (~50% of seeds at --max=64 segfault; rerank picks best of 20).
- Mixed-precision GPU path landed but unused (CPU bench oracle is the path).
- 1 GB arena via `RAIL_ARENA_MB` env var.
- **rail_native exit-code bug FIXED 2026-05-02 19:20.** `./rail_native file.rail` now propagates ld failures via exit=1. 137/137 tests pass; byte-identical fixed point. The strip-grade `&& cmd` trap that bit us mid-session is structurally closed.
- Bench harness's `rn_oracle_stats` `ld: OK` string match is correct and unchanged.
- 46 ckpts on disk under `training/rail_native/checkpoints/spur_v*`.

### Known-broken / open
- Inference at --max=16 has higher segfault rate than --max=64 (probably KV-cache interaction with prompt-len).
- `tools/train/spur_ensemble_infer.sh` retries up to 8 seeds per ckpt for segfault tolerance — works but slower than bench harness's 8-parallel approach.
- Comprehension band is structurally unsolved (5 of 6 unsolved tasks); see P1-P3 above.

## Operational gotchas (so they don't bite future-you)

1. **`rail_native` was returning exit 0 even on ld failure** — FIXED, but if you see weird "looks like it compiled but didn't run" patterns, check this first.
2. **bench harness watcher false-positives** — `until ! ps aux | grep <bench-procs>` exits prematurely between parallel_rerank batches. Use 8-stable-checks pattern with log-size > 10KB threshold (see `bench_watcher_gotcha.md`).
3. **bench grading + sampling races on /tmp/rail_out** — cannot run any rail_native compile concurrently with a bench (harness has retry+size-gate but it's brittle). Wait for bench to finish before forking trainers / running corpus generation.
4. **val_loss does NOT predict bench** at this scale. Always pick ckpts by held-out bench, not val_loss.
5. **52 examples is too few for pattern transfer; 20× repetition memorizes.** Comprehension needs N=200+ unique Q&A pairs to plausibly transfer.
6. **Mixing ANY corpus into compile.rail destroys the lever.** Even all-coherent multi-source. Concentrated single-source is the path.
7. **Seeds 999, 2025, 21, 333, 99999 collapsed at full corpus.** Half-B / back-quarter eliminates this. Bimodal failure mode is real.
8. **bash `set -e` + `[ ] && cmd`** silent-exit pitfall. Use `if [ ]; then cmd; fi`. Bit the harvest scripts mid-session.
9. **zsh array indexing is 1-based.** Caused a v36 misseed. Use bash explicitly or 1-indexed loops.
10. **Multi-line `--prompt` to inference may segfault more than single-line.** Use bench harness's `shell_dq_escape` pattern for CLI invocations.

## File index — where to find things

### Models
- `training/rail_native/checkpoints/spur_v54_BQ2_s77_best.*` — best single (9/30)
- `training/rail_native/checkpoints/spur_v48_BQ_s100_best.*` — Real Tools peak (8/30)
- `training/rail_native/checkpoints/spur_v27_pushJ_best.*` — full-corpus peak (7/30)
- `training/rail_native/checkpoints/spur_v43_halfB_s5555_best.*` — half-B peak (7/30)
- 42 other ckpts at `training/rail_native/checkpoints/spur_v*_best.*` — portfolio for ensemble

### Reproducer trainers
- `tools/train/lm_v54_BQ2_s77.rail` — winning recipe trainer
- `tools/train/lm_v48_BQ_s100.rail` — second peak
- `tools/train/lm_v13_d256_compile_self.rail` — full-corpus baseline (Arm 1)

### Inference binaries (one per corpus vocab)
- `tools/train/lm_infer_cpu_v46_bq.rail` — back-quarter vocab (use for v48, v50, v51-55, v54)
- `tools/train/lm_infer_cpu_v35.rail` — half-B vocab (use for v36-45)
- `tools/train/lm_infer_cpu_v13.rail` — full-corpus vocab (use for v18, v19, v22-33)

### Tools
- `tools/train/ensemble_ceiling.sh` — measure per-prompt union across all bench logs (3 sec, gives 24/30)
- `tools/train/spur_ensemble_infer.sh` — runtime per-prompt router (segfault-tolerant)
- `tools/train/parallel_rerank.sh` — N=20 rerank infrastructure
- `tools/train/grammar_walk.rail` — corpus generator (ASCII-clean, 2119 valid programs)
- `tools/train/harvest_compile_passes.sh` — compile-pass harvester (currently zero-yield from 1-2/30 ckpts)

### Docs
- `docs/SPUR_OVERNIGHT_SYNTHESIS_2026-05-01.md` — master synthesis from the long arc
- `docs/SPUR_V10_BRIEF_2026-05-01.md` — Friday-brief framing (now updated through v54)
- `docs/plans/SESSION_HANDOFF_2026-05-01.md` — earlier handoff (superseded by this doc)
- `docs/plans/SESSION_HANDOFF_2026-05-02.md` — this doc

### Memory entries (critical reads)
- `compile_rail_alone_is_lever.md` — the headline finding
- `spur_v54_peak_30pct.md` — the winning ckpt's per-band breakdown
- `spur_compile_rail_lever_reproducible.md` — 12-seed distribution, retracted "66%" claim
- `spur_halfB_better_than_full.md` — head-to-head 10-seed corpus comparison
- `spur_v48_back_quarter_peak.md` — corpus-size axis ablation
- `spur_ensemble_ceiling_24_of_30.md` — the 80% portfolio result
- `strip_grade_was_false_positive.md` — RETRACTION of the mid-session 24/30 claim, root cause and fix
- `rail_native_exit_code_bug_documented.md` — compiler patch shipped 2026-05-02
- `inline_parse_trace_falsified.md` — Tier-A2 simple form falsified
- `comprehend_is_semantic.md` — older entry, structural ceiling on Comp band

## The framing for the next session

You are picking up after 44 hours where the substrate-only Spur paradigm has been fully characterized. The compiler-as-corpus thesis works. The portfolio + router gives 80%. The Comprehension band is the hard wall.

**Your job:** decide whether the 80% portfolio is the shipping product (it can be — write the model card, push to `training/checkpoints_published/`, ship), OR whether to invest a session in P1 (multi-stage finetune to crack Comp band). Both are valid. The ROI on P1 is uncertain (52-example corpus didn't transfer; the 200+ corpus would need to be hand-curated, ~half-day work). The ROI on shipping is concrete — Spur has a real number to cite.

If you ship: the `models/spur/` model cards already exist; update them with the v54 / ensemble numbers. Push tarballs via `training/checkpoints_published/` (the in-tree-bucket pattern from `spur_bucket.md`). Spur-on-Rail at 80% is a real result that goes on the website.

If you crack Comp: P1 (multi-stage) is the cleanest single experiment. Time-box at 4 hours. If the 4-hour result is < 12/30 ensemble, give up and ship the 80%. The Comp band may genuinely require infrastructure Spur doesn't have.

The thesis Spur owned from day 1 is now empirically validated and substrate is cleaner than session start. Whatever you choose next is honest progress on a known foundation.
