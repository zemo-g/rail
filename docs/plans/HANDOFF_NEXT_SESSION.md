# Handoff — 2026-05-10 evening — 10 honest re-benches landed; d=384 training in background

**Headline.** Phase 1 of SESSION_PROMPT_2026-05-11 shipped: **10 honest
re-benches** of the top historical Spur ckpts, post compile.rail fix.
The post-fix ensemble ceiling is **~13–16/30** (upper bound on per-band
max-pass), down from the bug-inflated pre-fix "24/30 ensemble." **v54
remains the lead at 13/30**, with bq_s200 a NEW finding at 11/30.

**Strategic directive in effect** (`exhaust_studio_before_renting.md`):
Push Studio (M1 Ultra, 64 GB) to real limits — batch / d / blocks / seq /
parallel seeds — before renting. Honest numbers non-negotiable.

---

## Current state

**Branch:** `next` at `39b9585` (ahead by: 2 untracked trainer forks).
**Tests:** 137/137 green.
**Substrates:** CPU + GPU mixed both correct post compile.rail fix at `02a6a1d`.
**Training (background):** `d=384 × 4-block × V=130 stdlib × LR=0.005 ×
warmup=200 × max_steps=6000`. PID 63461. ~5 hours of bench-driven
SIGSTOP gap; resumed 21:21. Expect ~12 hours total runtime. Initial loss
14.41, paused at step 43 / 13.78. Output: `/tmp/d384_train.log`. Ckpt
will save to `training/rail_native/checkpoints/d384_4block_half_step6000`.

**d=512 4-block tried first** and NaN'd at step 43 with LR=0.01. Fell
back to d=384 per stop condition. The d=512 trainer is at
`tools/train/lm_v3_chunked_d512_4block_half_3k.rail` (untracked).

---

## 10 honest re-bench results (post-fix, 2026-05-10)

| # | Ckpt | Corpus (V) | Pre-fix peak | **Post-fix** | Notes |
|---:|---|---|---:|---:|---|
| 1 | smoke_v54_repro_best | back_quarter (93) | 9 | **13/30** | Lead |
| 2 | halfB_s7777_fresh | half_b (96) | 10 | 6/30 | |
| 3 | Spur-v0.1 (d256_half_step3000) | stdlib (130) | 25 ens | 1/30 | -24, retired |
| 4 | spur_v05_distill_step3000 | stdlib (130) | unk | 1/30 | |
| 5 | d256_4block_half_step3000 | stdlib (130) 4-block | — | 1/30 | |
| 6 | spur_v27_pushJ_best | half_b (96) | 7 | 1/30 | -6 collapse |
| 7 | halfB_s5555_repro_best | half_b (96) | unk | **8/30** | NEW |
| 8 | spur_v48_BQ_s100_best | back_quarter (93) | 8 | 7/30 | -1 stable |
| 9 | spur_v54_BQ2_s77_best | back_quarter (93) | 9 | **13/30** | byte-id v54 (q=105969) |
| 10 | bq_s200_repro_best | back_quarter (93) | unk | **11/30** | NEW high |

**Headlines:**

1. **v54 is reproducible** — smoke_v54 = v54_BQ2 byte-identical at q=105969.
2. **bq_s200 = 11/30** is the second-best ckpt, never previously measured.
3. **All V=130 stdlib ckpts collapsed to 1/30** post-fix. Bigger corpus
   without bigger compute does NOT generalize.
4. **The 17-point gap** from v54 13/30 to substrate-thesis 30/30 stays
   the mission target.

Per-band best across the 10 (upper-bound ensemble ceiling):
- FUND 4/5 + IO 3/5 + Tools 3/5 + Comp 4/5 + Adv 2/5 + Comprehend 0/5
  = **16/30 upper bound**, ~13-15 realistic.

---

## What's NEXT (ranked by ROI for "exhaust Studio")

| # | Lever | Cost | Expected lift | Notes |
|---:|---|---|---|---|
| 1 | **Batch size 1 → 16-32** | 1 day of trainer fork | Likely big sample-efficiency win | Studio is at batch=1 — biggest underutilized lever |
| 2 | **d=384 bench (when training finishes)** | 1 hr bench | First post-fix data point at next size class | Required for scaling-law fit |
| 3 | **d=512 with LR engineering** | 1 day | Either reaches d=512 or proves precision wall | Lower LR, gradient clipping, fp32 logits |
| 4 | **Compile-loss training** | 2-3 days | +5-10 pts (structural lever) | `compile_loss_scaffolding.md` partly shipped |
| 5 | **Distillation: Qwen → Rail student** | 3-5 days | +10-15 pts (substrate teacher) | Closes gap to 30/30 directly |
| 6 | **Multi-process: 4 seeds concurrent** | 0.5 day | Honest ensemble curve at scale | Studio has cores spare |

**Sequence rationale:**
- (2) finishes overnight tonight — that's free data
- (1) is the largest single Studio lever untouched, before anything else
- (3) unlocks the d→d-scaling-law curve that justifies renting
- (4-5) are structural levers; do AFTER (1-3) prove compute trajectory

---

## Floor (don't break)

- 137/137 green
- Byte-identical self-compile fixed point (cycle ≥ 2)
- `default_corpus_path` in `lm_infer_v3_mixed.rail` = `training/rail_corpus_stdlib.txt` ✅ (restored at end of bench loop)
- v_full bisect harness produces 0.020599 (regression test for compile fix)
- Don't quote pre-fix bench numbers (24/30, 25/30) as targets
- Every claim cites a `flywheel/bench_log.txt` post-fix line

---

## Reusable commands

```bash
# Resume d=384 training if killed
DYLD_LIBRARY_PATH=tools/metal /tmp/train_d384 \
  --resume training/rail_native/checkpoints/d384_4block_half_step6000 \
  > /tmp/d384_train.log 2>&1 &

# Bench any ckpt (set default_corpus_path to match training corpus first)
DYLD_LIBRARY_PATH=tools/metal /tmp/rail_bench_strip \
  --prefix <CKPT_PREFIX> \
  --max 60 --k 10 --temp 0.8 \
  --tag <TAG>_post_fix \
  --gen-source tools/train/lm_infer_v3_mixed.rail

# Corpus matching table:
#   V=93  → training/corpora/spur_compile_back_quarter.txt
#   V=96  → training/corpora/spur_compile_half_b.txt
#   V=130 → training/rail_corpus_stdlib.txt  (default)

# Sequential bench loop (matches halfB+BQ recipe)
/tmp/run_bench_loop.sh  # if regenerated; see flywheel/ for inline

# Self-compile + cycle check
./rail_native self && cmp rail_native /tmp/rail_self && echo "byte-identical"

# Regression test for codegen fix
./rail_native run tools/diagnose/cpu_bisect_v_full.rail \
  -- --prefix runs/smoke_v54_repro/checkpoints/smoke_v54_repro_best \
     --corpus training/corpora/spur_compile_back_quarter.txt \
     --prompt "main = " --max 1 --k 1
# expect: BISECT x_embed[0]=0.020599365234375
```

---

## Memory entries updated this session

- `exhaust_studio_before_renting.md` — NEW. Strategic directive.
- `honest_rebench_2026-05-10.md` — extended with 10-ckpt table + ensemble ceiling.
- `MEMORY.md` — added the new exhaust-Studio entry near the top.

---

## What to NOT do next session

- Don't rent a GPU rack until (1)+(3) prove compute scaling on Studio.
- Don't bench against `rail_corpus_stdlib.txt` for V=93/96 ckpts (OOB → 0/30).
- Don't try d=512 again without LR engineering FIRST. NaN at step 43 was real.
- Don't quote pre-fix scores. The bug-inflation lesson is the load-bearing
  one.
- Don't lump multiple Studio levers in one experiment — change one thing
  at a time so the scaling-law fit stays interpretable.
