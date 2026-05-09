# Spur Revolution — halted state, 2026-05-06

**Halt time:** ~16:00 EDT 2026-05-06.
**Reason:** user-requested halt for save-state.
**Status of plan:** Phase I complete; Phase II in flight (training restart hadn't reached step 100 confirmation when halted).

---

## What's running RIGHT NOW

Nothing. All processes killed:
- `./rail_native run lm_v100_distill_s100.rail` (PID 36123) — killed
- All step/ckpt watchers — killed

Verified `ps -ef | grep rail_out` is empty.

## What's settled and on-disk

### Findings (Phase I — DONE)

1. **Canonical bench is saturated at substrate level.** Naked Qwen-122B-A10B-heretic-v2 + 1KB Rail spec (v3, with cons-pattern ban + builtin disambiguation) hits **30/30 compile** at N=3 in 2:23 wall on `flywheel-local/bench_strip.rail`. Reproducible.
2. **Hard-bench substrate ceiling = 8/30 non-trivial** (10/30 compile-only) at N=3. 12% per-attempt rate. Massive headroom for distillation/RL levers.
3. **Distillation produced 530 verified Rail programs**, 81KB ASCII-clean corpus at `training/corpora/spur_distill_v1.txt` from 250 prompts × N=10 rollouts. 24% steady-state yield.

### Memory + indexed

- `~/.claude/projects/-Users-user/memory/comprehension_cracked_substrate.md` — substrate-thesis validation, 29-30/30 finding.
- `MEMORY.md` index updated.

### Files shipped (uncommitted)

#### Plan docs
- `docs/plans/SPUR_REVOLUTION_2026-05-06.md` — 20-hour adaptive game plan
- `docs/plans/SPUR_REVOLUTION_LOG_2026-05-06.md` — running session log + post-distill command chain

#### Pipeline scripts
- `tools/train/build_distill_prompts.py` — 250-prompt corpus generator (compile.rail walks + mutations + grammar walks)
- `tools/train/distill_pipeline.py` — resumable teacher→corpus driver with hash-keyed dedup state file
- `tools/train/clean_distill_corpus.py` — strip headers, dedup by content-hash, ASCII filter
- `tools/train/spur_harvest.py` — Spur-ckpt-based harvester (Phase III scaffold; uses `/tmp/rail_infer_cpu`)

#### Trainer scaffolds (forks of `lm_v54_BQ2_s77.rail`, identical recipe except for the fields below)
- `tools/train/lm_v100_distill_s100.rail` — corpus_path → spur_distill_v1.txt; seed=100; ckpt prefix `spur_v100_distill_s100_*`
- `tools/train/lm_v101_combined_s101.rail` — corpus_path → spur_combined_v101.txt (NOT YET CREATED); seed=101; ckpt prefix `spur_v101_combined_s101_*`

#### Bench
- `flywheel-local/bench_hard_30.rail` — 30 prompts harvested from real codebase (compile.rail 10, transformer 6, tokenizer 3, tensor 4, autograd 2, optim 2, checkpoint 1, bpe 1, oracle 1)
- `/tmp/bench_hard_30_prompts.py` — Python mirror used by hard-bench probe
- `/tmp/full_bench_teacher_probe.py` — full-30 teacher probe (v3 spec, N configurable)
- `/tmp/hard_bench_teacher_probe.py` — hard-30 teacher probe

#### Corpora on disk
- `training/distill_prompts_v1.txt` — 250 unique prompts (deduped from 280)
- `training/corpora/spur_distill_v1.txt` — **the distilled corpus, 81KB, V=87 (ASCII-only, deduped)**
- `/tmp/distill_corpus_v1.txt` — raw distillation output (115KB; cleaner reads from this)
- `/tmp/distill_corpus_v1.txt.state.json` — distillation state file (resumable; reflects 2500 attempts done)

#### Probe artifacts
- `/tmp/probe_*.{rail,raw}` — per-(arm, prompt, seed) outputs from spec-in-context probe
- `/tmp/fbp_*.{rail,raw}` — per-prompt outputs from full-bench teacher probe
- `/tmp/hbp_*.{rail,raw}` — per-prompt outputs from hard-bench teacher probe
- `/tmp/full_bench_teacher_run_v3_n3.log` — N=3 v3-spec final run (30/30)
- `/tmp/hard_bench_run_n3.log` — hard-bench N=3 final run (8/30 non-trivial)
- `/tmp/distill_v1_run.log` — full distillation log (599 PASS / 2500 attempts)
- `/tmp/spur_v100_train.log` — v100 training log (compile + step=0 only)

## What's blocked

### Spur-v100 training never confirmed past step 0

Two attempts:

1. **First (14:45-15:47, 62 min CPU)** — fired with `tee /tmp/spur_v100_train.log | tail -3`. Eval log only got `step=0`. Process consumed 62 min CPU but never wrote step 100. Killed.
   - **Hypothesis:** stdout pipe stall through `tee | tail -3`. The `print` calls inside `m_train_loop` block when the pipe buffer fills, and `shell` calls for eval log MIGHT be chained after, never reaching their fork.
   - **Counter-evidence in stack samples:** `.Lsh_parent` did appear once in the call graph, suggesting at least one shell write fired. So either the shell write went out empty (echo of corrupted msg) or partially completed.
   - **Not yet falsified:** could also be a real perf regression in the trainer at this corpus size. Unknown.

2. **Second (15:48-16:00, ~12 min)** — fired with direct `> /tmp/spur_v100_train.log 2>&1`, no pipeline. Step 0 eval landed at 15:50. **Was waiting for step 100 confirmation when halted.**

### Open question for next session

**Is the v100 trainer actually fast enough?** v54 took ~84 min for 3000 steps (memory). Our v100 should match (same recipe, same arch, similar corpus size). If second attempt also stalls past step 0, this is a real bug — possibly:
- Some interaction between this corpus's specific char distribution and `build_vocab` / sample_chunk
- A regression in shared training infrastructure since v54 ran (Apr 28-May 2)
- Something specific to `lcg_state_new 100` vs 77 (very unlikely, it's just RNG seed)

### Floors protected

- `./rail_native test` — not re-run; was 137/137 last verified
- `spur_v54_BQ2_s77_best` ckpt — untouched, 10/30 strip-graded canonical baseline holds
- `spur_v48_BQ_s100_best` ckpt — untouched, 8/30 strip-graded back-quarter peak
- All 39+ ensemble ckpts in `training/rail_native/checkpoints/` — untouched
- Ensemble ceiling 24/30 — untouched
- Substrate ceiling 30/30 + hard 8/30 — measured today, recorded in memory

### Spur-v100 partial state (resumable)

- 64 ckpt files at `training/rail_native/checkpoints/spur_v100_distill_s100_*` from the step-0 min-ckpt save (initial weights, before training). These are essentially random-init weights, NOT useful as a resume point. Recommend deleting before next attempt.
- Distillation state file is intact; if we want to redo distillation differently (different N, different prompts), the state file makes incremental work cheap.

## Resume-from-halt commands

```bash
# 1. Clean partial v100 ckpts (initial-weights only)
rm -f training/rail_native/checkpoints/spur_v100_distill_s100_*

# 2. Reset v100 logs
rm -f /tmp/spur_v100_train.log /tmp/spur_v100_distill_s100_eval.txt /tmp/spur_v100_distill_s100_rss.txt

# 3. Diagnose first: launch v100 with stdout direct to file (not pipeline);
#    confirm step 100 lands within ~5 min. If not → real perf bug, investigate.
./rail_native run tools/train/lm_v100_distill_s100.rail > /tmp/spur_v100_train.log 2>&1 &

# 4. Watcher (the one that was active when halted):
until grep -q "step=100" /tmp/spur_v100_distill_s100_eval.txt; do sleep 15; done
echo "step 100 confirmed"
cat /tmp/spur_v100_distill_s100_eval.txt
```

If step 100 lands within ~5 min, training is healthy → wait for completion (~80 min) → bench. If not → `kill` the trainer and investigate real bug.

## Outstanding decision points (from JIT thread)

User identified 6 unresolved items in the JIT-integration discussion. Six conceded points (corpus contradiction, sub-ms claim precision, lowering measurement, scope of "lights up overnight", bench-prompt categorization, deliverables ranking). The bonus question — `op_print_int` is the actual blocker, not just `op_call` — was the right question.

**Categorization recorded** (in chat answer; should also live in plan log):

| Band | Today (056aca3) | + op_call | + op_call + print-int |
|---|:-:|:-:|:-:|
| fund (5) | 1 | 4 | 5 |
| io (5) | 0 | 0 | 0 |
| tools (5) | 0 | 0 | 0 |
| comp (5) | 0 | 0 | 0 |
| adv (5) | 0 | 0 | 0 |
| comprehend (5) | 0 | 0 | 5 |
| **Total** | **1** | **4** | **10** |

User asked to ship: ranked (c) op_call + bonus op_print_int as paired PR; (d) integer corpus + harness; (e) jit/README. Awaiting confirmation before any agent picks up.

## What I'd do first on resume

1. **Diagnose the v100 stall.** Run #3 above. If step 100 lands cleanly, the original stall was the pipe issue (root-caused). If it stalls again, root-cause is elsewhere — investigate without burning more wall.
2. **Once v100 trains, bench it** (canonical via `bench_strip.rail` --rerank-N=20). Compare to v54's 10/30. Phase II gate: ≥+5pp = distillation works.
3. **Phase III** depends on Phase II outcome: if v100 lifts, run `rollout_harvest.sh` from v100_best, build combined corpus, train v101. If v100 underperforms, investigate filter logic before stacking more layers.
4. **JIT integration:** wait for op_call + op_print_int (per audit thread). Then JIT becomes a 33%-of-bench in-process verifier — usable for distillation filtering and online RFT proof-of-concept on the integer-and-comprehend slice.

## Pacing rules invoked + adaptations made (this session)

- Killed N=20 stability run after fund/0-3 all 20/20-passed; freed teacher cycles for hard-bench (per "don't push verification when headline is locked").
- Pivoted Phase III from online `maybe_harvest` to two-stage offline harvest (per "tiny verifiable steps; B2 corpus-doubling buffer is non-trivial Rail surgery").
- Skipped Spur-v54-on-hard-bench measurement (per "not on Phase II critical path; defer to Phase IV"). Outstanding for the ablation table.
- Halted after second v100 stall instead of waiting another 60 min (per "verify removals empirically + diagnostics first" — better to investigate now than burn wall on a possibly-broken run).
