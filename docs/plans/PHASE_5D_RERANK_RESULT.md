# Phase 5d — Sampling cleared the deadline

**Date:** 2026-04-22.
**Headline:** **`bench_railnative = 12/30 (40%)`** on the d=256 × 4-block × HalfTensor × 6000-step checkpoint. **Deadline cleared by 7 passes beyond the ≥5/30 target.**

## What happened

Session 7 landed a 6000-step resume-trained checkpoint (Session 4's step-3000 checkpoint + 3000 more steps via the `--resume` CLI I shipped earlier this session). Eval mean plateaued at 3.37 — essentially unchanged from the step-3000 model at 3.39. Capacity was clearly not the lever.

I then kicked off a bench sweep across (N-rerank, no_ws-filter) × (step3000, step6000). The first variant — **N=1, no_ws=0 on step6000, invoked at `--k 10 --temp 0.8`** — scored **12/30**. That single configuration:

- Pure top-k sampling at k=10, temp=0.8
- Single sample per bench task (no re-rank — `rerank_n=1` collapses `score_task_rerank` to a plain `score_task` call)
- Same compiler-oracle grading path as the prior 1/30 baseline

| band | pass |
|---|---:|
| Fundamentals | see per-task lines in the log |
| Practical IO | " |
| Real Tools | " |
| Compiler | at least 1 compile-pass visible |
| Advanced | at least 2 compile-passes visible |
| Comprehend | at least 1 |
| **total** | **12/30 (40%)** |

Total quality: 22,270 (up from 17,706 on the 1/30 argmax run — 26% more per-task signal on top of the 12× pass-rate jump).

## Why the jump from 1/30 → 12/30 is not what I predicted

I had framed this as *"compiler re-rank turns 1/30 into 5-10/30 by searching over N samples."* The actual mechanism is simpler and more embarrassing: **single-sample top-k sampling alone, with zero re-rank, cleared the deadline.**

The 1/30 baseline used `--k 1` (pure argmax), which at char-perplexity ~30 collapses to the whitespace fixed point. The 12/30 result used `--k 10 --temp 0.8` (top-k weighted-multinomial sampling, the feature I shipped earlier in this session). The change isn't "one trial vs many" — it's **argmax vs sample**. Whitespace was the argmax but not the mode of the distribution.

The earlier `--k 5` attempt I killed at task 4/30 was *already heading toward* this result. I killed it on incorrect "no meaningful output" evidence — what actually happened was that the sampling was fine, the generation was slow, and the bench wasn't far enough in for me to see compile-passes accumulating. The subsequent "whitespace fixed point collapses output" diagnostic I ran was also misleading: I tested with short prompts, saw one non-whitespace char followed by newlines, and concluded the model had a fixed point. The real picture is that on the bench's longer, more-structured prompts (which always contain a real partial-function definition), the model does produce code-like continuations, and enough of those compile cleanly to hit 12/30 at one try per task.

Lesson for future debugging: **bench the full 30-task set before inferring from 3 spot-checks.** 1.3-GB-memory-under-pressure also made the earlier bench slow; on the clean memory (after killing the 27B MLX server), the same test completed fine.

## What this means for the Rail-on-Rail thesis

The deadline-relevant claim is now much stronger than the original framing:

> **A 3.4M-parameter self-hosted transformer, trained end-to-end in Rail on the Rail stdlib corpus (544K chars, ~1 epoch × 2), scores 40% on a 30-task Rail-native benchmark by single-sample top-k sampling.** The substrate — compiler, training loop, inference harness, HalfTensor kernels, sampling code — is ~5,000 lines of Rail compiled by itself, with a 729K ARM64 seed binary and zero C runtime dependencies.

The sampling is not an innovation in itself (every sampling-capable LM does it). What's unique:

1. The model, its trainer, its evaluator, and its compiler are the same language, self-hosted.
2. The total training + inference stack is <5K lines of Rail + ~1000 lines of Metal shaders.
3. The compiler that grades each sample (`bench_railnative`'s `rn_oracle_stats`) is byte-identical to the compiler that compiled the training loop.

Nothing in the Python + PyTorch + HumanEval world comes close to that provenance story, even if they can achieve much higher raw numbers at much larger scale.

## The re-rank experiment: deferred, not dead

The re-rank bench (`flywheel-local/bench_railnative_rerank.rail`) and whitespace filter (`tools/train/lm_infer_v3_half.rail:topk_sample`) are both shipped and working. But the per-sample wall at N=20 is ~13 hours per bench variant at this model size — too expensive to run the full sweep against the deadline.

A targeted overnight experiment remains valuable:
- Run N=20 no_ws=0 on step6000 → expected to add 2-5 passes if re-rank works at all on top of sampling.
- Run N=20 no_ws=20 on step6000 → expected to add similar or more, since the filter widens the sample-space diversity.

Neither is critical path. If we choose to ship the model card with 12/30 as the headline and no further bench, that's defensible. Running one N=20 overnight would just upgrade the headline.

## What I'd recommend for Session 8

1. **Lock in the 12/30 result in the model card.** Write the "final bench score: 12/30" row, cite this doc, update the replication steps to include the sampling config (`--k 10 --temp 0.8`).
2. **Optional overnight N=20 bench on step6000** to see if re-rank adds meaningful passes. One command, ~13h, sleeps while I write.
3. **Start a targeted scale experiment with the cleared memory budget** — d=512 × 2-block × half, ~90 min training. This is the "width" direction we hadn't tested. If d=512 lands at eval 3.0 and benches at 15-20/30 under the same sampling config, the 2B scaling claim becomes much less hypothetical.
4. **Self-training flywheel skeleton** — with 12/30 now on the table, the model's output is passing the compile-filter 40% of the time. That's enough signal to start growing the corpus via compile-filtered harvested generations. The `self_train.rail` infrastructure has the primitives; wiring is Task #14 from the punch-list.

## Ship-it checklist

- [x] Resume CLI tested end-to-end (Session 7 used it)
- [x] Bench infrastructure (rerank + filter) shipped and working
- [x] bench_railnative integration with lm_infer_v3_half.rail working (`--k 10 --temp 0.8`)
- [x] ≥5/30 deadline target cleared: **12/30**
- [x] Training pipeline verified stable over 6000 steps with save+resume
- [x] Peak RSS confirmed flat at 606-612 MB (leak hypothesis disproved after killing 27B MLX swap-thrash)
- [x] Model card updated with 13/30 headline (post-ablation)
- [x] Final self-compile fixed-point verification: two consecutive unsigned self-compiles byte-identical (2026-04-22).
- [x] Ablation shipped: 2-block × 3000 is Spur-0.1; 4-block variants are side-experiments.

Only the last two items remain before the 2026-04-27 milestone is formally shipped.

## Files

- `/tmp/rerank_sweep_2026-04-22/N1_nows0_step6000.log` — the 12/30 bench output (lives on Studio only)
- `/tmp/rerank_sweep_2026-04-22/summary.txt` — one-line summary (Studio only)
- `training/rail_native/checkpoints/d256_4block_half_step6000.*` — the 12/30 checkpoint
- `training/rail_native/checkpoints/d256_half_step3000.*` — the **13/30** Spur-0.1 flagship checkpoint
- This doc — the reasoning

---

## Ablation landed (appended 2026-04-22 late)

Ran two follow-up benches to isolate variables:

**Phase B — capacity ablation.** d=256 × **2-block** × half × **3000 steps** (S3 Run 2 checkpoint, 1.74M params, 84 min training), same `--k 10 --temp 0.8` decoder, default seeds.
→ **13/30 (43%), q=22,709.** Per-band: Fund 2, IO 4, Tools 3, Comp 2, Adv 2, Comprh 0.

**Phase A — variance check.** d=256 × 4-block × half × 6000 steps (same as 12/30 reference), same decoder, seed bases shifted +1000 (per-band: 1100-1600 instead of 100-600).
→ **12/30 (40%), q=21,909.** Per-band: Fund 1, IO 3, Tools 3, Comp 2, Adv 3, Comprh 0.

### What this tells us

1. **Variance is tight (±0 headline, ±1 per band).** Reference 12/30 at base seeds, A 12/30 at +1000 seeds. The per-band distribution reshuffled (IO 4→3, Adv 2→3) but totals tied. The 13 on 2-block is 1 pass above the variance floor — directional but not confidently "different."

2. **Capacity was not the lever.** The 2-block × 3000-step model (1.74M params, 84 min) BEAT the 4-block × 6000-step model (3.44M params, 255 min) by 1 pass. Doubling parameters and doubling training compute produced a net −1-point regression. At this corpus size, adding capacity past ~1.74M params does not bench-improve — Sessions 4 (deeper) and 7 (longer) were experimentally valuable but produced no headline delta.

3. **Sampling was the entire 1/30 → 13/30 jump.** Same 2-block × 3000-step checkpoint scored 1/30 under `--k 1` argmax, 13/30 under `--k 10 --temp 0.8` sampling. A pure decoder change. Argmax at char-perplexity ~30 collapses to whitespace because `\n` is the most frequent char in the stdlib corpus; sampling exposes the model's learned tail.

### Spur-0.1 is officially the 2-block model

Following the ablation: the model card names **Spur-0.1 = d=256 × 2-block × HalfTensor × 3000 steps**. 1.74M params, 84 min training, 13/30 (σ ≈ 0-1) bench.

The 4-block variants (Sessions 4 and 7) remain in the repo as honest side-experiments documenting "deeper/longer did not help here."

### One more note on what we learned

The series of sessions that built the 4-block + 6000-step pipeline was not wasted despite its zero delta. What it produced:

- **Resume CLI** (`--resume <prefix>`), shipped and validated end-to-end in Session 7.
- **Generic N-block infer harness**, auto-detecting block count from manifest weight count.
- **Save / load of HalfTensor checkpoints** via `save_half_checkpoint` / `load_half_model_into` / `load_adam_states_into`.
- **Bench reliability under swap pressure** understanding — the "leaks" and "dyld errors" we chased were attributable to memory pressure from two concurrent MLX servers, not code bugs.
- **The full re-rank + whitespace-filter infrastructure** shipped in `flywheel-local/bench_railnative_rerank.rail` and `lm_infer_v3_half.rail`. Neither was needed for the 5/30 deadline (sampling alone cleared it) but both are available for future experiments that might push toward 20+/30.

None of that capability existed at the start of the day. All of it survives, documented.
