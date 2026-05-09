# Spur Revolution — running session log

Per `SPUR_REVOLUTION_2026-05-06.md` adaptation rule #4: 5-line journal entry per phase.

---

## 2026-05-06 09:30 — Session started

Context: yesterday's grammar-walk climb closed (commit 325cb12). Naked-Qwen + spec found 29/30 in 2:23, then 30/30 with extended spec. Substrate-thesis confirmed; Spur demoted from bench-cracker to small-scale RLVR testbed.

## Phase I — Close out + ground-truth substrate (TARGET 0-3h)

- ✅ Canonical 30/30 confirmed at N=3 with v3 spec (Rail's no-cons-pattern + builtin-disambig added).
- ✅ Hard-bench built: `flywheel-local/bench_hard_30.rail` — 30 prompts harvested from compile.rail (10) + transformer (6) + tokenizer (3) + tensor (4) + autograd (2) + optim (2) + checkpoint (1) + bpe (1) + oracle (1).
- ✅ Hard-bench substrate ceiling = **8/30 non-trivial** at N=3 (10/30 compile-only). 12% per-attempt rate. **Massive headroom for Phase II/III.**
- ✅ Memory entry `comprehension_cracked_substrate.md` saved + indexed.
- 🔁 Pivot taken: Spur-v54-on-hard-bench skipped (not on Phase II critical path). Will measure during Phase IV ablation when bench harness is generalized.

**Phase I gate:** PASSED. Substrate ceiling locked, hard-bench in repo with documented ceiling.

## Phase II — Compile-graded distillation → Spur-v100 (TARGET 3-9h)

- ✅ Pipeline scripts: `tools/train/{build_distill_prompts,distill_pipeline,clean_distill_corpus}.py`.
- ✅ 250 unique prompts in `training/distill_prompts_v1.txt` (200 compile.rail walks + 30 mutation + 50 grammar; was 280, deduped 30 collisions).
- ✅ Spur-v100 trainer scaffold: `tools/train/lm_v100_distill_s100.rail` (back-quarter recipe seed=100, fork of v54).
- 🔄 Distillation N=10 running (started 10:53). Sanity slice yielded 33% on easy prompts; full run yielded ~12-17% (hard prompts dominate). ETA 14:30-ish (~4h).
- ⏳ After: corpus cleanup → train Spur-v100 (~80 min) → bench v100 on canonical + hard.

## Phase III — Compile-loss-during-training (TARGET 9-15h)

- ✅ Discovered existing in-tree design: `docs/plans/COMPILE_LOSS_DESIGN.md` (2026-04-29). REINFORCE-style positive-only RFT via `maybe_harvest` hook + corpus-doubling buffer (option B2). The deferred work is the trainer-integration.
- 🔁 **Pivot:** simplified from "online maybe_harvest" to "two-stage offline harvest." After Spur-v100 completes, run `rollout_harvest.sh` to collect compile-passes from v100, append to corpus, train v101 from scratch on combined corpus. Equivalent signal, much simpler integration. Online version becomes Phase III stretch goal if time permits.
- ⏳ Awaiting Spur-v100 completion (Phase II.5 gate).

## Phase IV — Capstone + write-up (TARGET 15-20h)

- ⏳ Pending Phases II + III.

---

## Adaptation log (cross-phase decisions)

- **2026-05-06 10:38** — Killed N=20 stability run after fund/0-3 all hit 20/20 pass. Headline number 30/30 settled at N=3; N=20 blocked teacher cycles needed for hard-bench. Per pacing rule: don't push verification when headline is locked.
- **2026-05-06 10:46** — Dedup'd prompt corpus (280 → 250). distill_pipeline's prompt_id hash naturally caught duplicates from random.choice over a small templates list.
- **2026-05-06 10:55** — Phase III simplification: from online maybe_harvest to two-stage offline. Decision rationale: B2 corpus-doubling buffer is non-trivial Rail surgery in v54 trainer; two-stage produces equivalent supervised signal with zero trainer changes. Online version stays in the playbook as stretch.

## Open questions / risks

- **Q1:** Will Spur-v100 (distill-corpus only) outperform Spur-v54 (compile.rail back-quarter only)? Both at ~90KB-class corpora. If v100 < v54, distillation lever fails and we pivot to corpus mixing.
- **Q2:** Does the seed parameter actually vary mlx_lm.server output? Several N=3 runs showed identical len across seeds for easy prompts — could mean deterministic-on-easy or seed-ignored. Affects rollout diversity claims for harvest-based training.
- **Q3:** Spur-v54 hard-bench score is unknown. Without it, the ablation table has a missing cell. Plan to bench during Phase IV.
- **R1:** 4-hour distillation is the longest single-step in the plan. Single point of failure for the teacher endpoint.
- **R2:** find_key-style failures in distillation rollouts will reduce corpus yield on the harder compile.rail-walk prompts. Mitigation: extended spec already includes list-recursion + builtin guidance; further iteration deferred to v2 if v1 corpus underperforms.

---

## Post-distillation command chain (fire when distill_v1_run.log shows DONE)

```bash
# 1. Clean distill corpus → training/corpora/spur_distill_v1.txt
python3 tools/train/clean_distill_corpus.py \
  --in /tmp/distill_corpus_v1.txt \
  --out training/corpora/spur_distill_v1.txt

# 2. Train Spur-v100 (back-quarter recipe, seed=100, ~80 min wall)
./rail_native run tools/train/lm_v100_distill_s100.rail 2>&1 | tee /tmp/spur_v100_train.log

# 3. Bench Spur-v100 on canonical (~25 min wall)
./rail_native run flywheel-local/bench_strip.rail \
  --prefix training/rail_native/checkpoints/spur_v100_distill_s100_best \
  --rerank-N 20 2>&1 | tee /tmp/spur_v100_canonical.log

# 4. Spur-v100 hard-bench (TBD — needs harness; defer to Phase IV when bench
#    machinery is generalized)

# 5. (Phase III, after v100 done): harvest from v100, train v101.
CKPT=spur_v100_distill_s100_best \
  N_SEEDS=20 MAX=128 K=10 TEMP=0.8 NO_WS=16 \
  OUT_CORPUS=training/corpora/spur_v101_harvest.txt \
  tools/train/rollout_harvest.sh

# 6. Combine corpora and train v101 (recipe = v100 with corpus_path swap + seed change)
cat training/corpora/spur_distill_v1.txt training/corpora/spur_v101_harvest.txt \
  > training/corpora/spur_combined_v101.txt
# (need to scaffold lm_v101_combined_s101.rail similar to v100; deferred)
```

## Updates pending memory

If Spur-v100 lifts ≥+5pp over Spur-v54 on canonical bench, update:
- `compile_zero_wall.md` — wall partially fell to distillation lever
- `compile_rail_alone_is_lever.md` — adds "distilled corpus rivals/exceeds compile.rail back-quarter"
- New entry: `spur_v100_distillation_lift.md` capturing the recipe + delta.

If Spur-v101 (post-harvest) lifts over v100, add:
- `compile_loss_works.md` capturing the structural-advantage demonstration
- Update `structural_advantage_thesis.md` from "thesis" to "validated"
