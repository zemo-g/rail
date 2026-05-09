# 2026-05-08 — Bench-Bottleneck Pivot Handoff

**Status:** marathon stopped mid-run. All 6 v6×/v7× ckpts trained and on disk; only v67's raw_n1 cell + the v54 GPU validation bench actually finished. Pivoted to comprehensive handoff because the bench-wall-clock numbers turned out 6-8× the marathon estimate, busting the 60-hr cap.

This is a **data dump for fresh eyes** — every measurement, every falsification, every untested lever. The hope: somebody (you, me-tomorrow, the next session) sees a pattern in the corpus of evidence that I missed in the moment.

---

## The headline question

**Is val_loss a valid filter for the 16-scaffold marathon?**

Two ckpts (v68, v72) sit at val_loss < 2.85 — substantially below every other ckpt on disk. If their bench score lifts above v54's 9-10/30 baseline, val_loss is a real proxy and we use it to triage the remaining 14 scaffolds (saves ~130 hr of bench wall-clock). If not, val_loss is decoupled from compile rate at the curriculum end of the spectrum and we need a different signal.

**Neither has been benched yet.** That is THE unfinished experiment.

---

## Trained ckpts on disk

```
spur_v60_phaseB_best                step=300   val_loss=3.11
spur_v62_best                       step=2900  val_loss=3.21
spur_v63_best                       step=2600  val_loss=3.16
spur_v66_best                       step=0     val_loss=13.57   (untrained, ignore)
spur_v67_BQ2_s200_best              step=2800  val_loss=3.20    (back-quarter × seed=200, post-`.no_gpu`-fix verify)
spur_v68_curriculum_s201_best       step=2100  val_loss=2.83    ★ second
spur_v69_preimage_s202_best         step=2800  val_loss=3.34    (A4 preimage corpus)
spur_v70_halfB_s205_best            step=2900  val_loss=3.46    (compile.rail half-B)
spur_v71_trace_s206_best            step=200   val_loss=3.51    DISCARDED — only 200 steps + corpus is the falsified inline-trace pattern (per `inline_parse_trace_falsified.md`)
spur_v72_curriculum_s301_best       step=2800  val_loss=2.80    ★ LEADER (curriculum × seed=301; reproducibility test of v68)
```

Plus 30+ historical Spur ckpts in `training/rail_native/checkpoints/` (Spur-v0.1 through Spur-v54+) — see `spur_ensemble_ceiling_24_of_30.md` for the 24/30 ensemble ceiling across them.

---

## Measurements that landed

### v67 post-`.no_gpu`-fix verify

| Cell | wall-clock | score | notes |
|------|-----------:|-------|-------|
| raw_n1   | 44 min  | **1/30 (3%)**, total q=5224, only Fundamentals 1/5 | |
| raw_n20  | killed at 5h35m, ~prompt 13/30 | partial | log only has 89 bytes preserved (compile output only) — buffered scores lost on SIGTERM |
| strip_n1 | killed mid-cell | — | |
| strip_n20| not started | — | |

**Interpretation:** post-`.no_gpu`-fix CPU substrate works. raw_n1 = 1/30 is consistent with `compile_zero_wall` (single-sample is structurally degenerate; the discriminating signal lives at N=20 with sampling).

### v54 GPU substrate validation (the killer datapoint)

`tools/train/lm_infer_v3_mixed.rail` (fp16 weights × fp32 acts × fp32 accum, GPU dylib) on Spur-v54 ckpt, raw N=20.

| Substrate | Wall-clock | Score |
|-----------|-----------:|-------|
| CPU (lm_infer_cpu.rail)               | ~2.3 hr (historical) | **9/30** raw, 10/30 stripped |
| **GPU mixed** (lm_infer_v3_mixed.rail)| **~7 min**           | **0/30** all categories |

**Wall-clock leverage was real (~20×).** Score was invalid: every seed × every prompt produced `ok=0 q=0`. fp16 weight quantization shifts the top-k sampling distribution enough that compile rate collapsed from 9 to 0. **Argmax-identity (k=1) is necessary but not sufficient for substrate substitution.** See `gpu_bench_substrate_failed.md`.

### Argmax-identity smoke

3-substrate generation comparison on v67 ckpt at k=1 (deterministic argmax), `--max 40`, prompt `"main = "`:

| Substrate | Output (hex tail) |
|-----------|-------------------|
| HALF      | `main\n\n\n\n...` (id 10) |
| MIXED     | `main\n\n\n\n...` (id 10) |
| CPU       | `main\n\n\n\n...` (id 10) |

**Byte-identical.** The "GPU dylib first-token-only" framing is wrong (per `dylib_substrate_argmax_identity.md`). All three substrates hit a model-level argmax wall, just at different speeds. Falsifies `dylib_first_token_only` (now retired) and tightens `dylib_investigation_2026-04-30` (fp16 affects k>1 sampling tail, not argmax).

### Sampling differential at k=10 (same setup, --seed 42)

| Substrate | Output |
|-----------|--------|
| HALF      | mostly newlines |
| MIXED     | mostly newlines |
| CPU       | `/i/tF` (degenerate but non-newline) |

CPU's k=10 produces *different* low-probability tokens than GPU's. This explains the v54 0/30 GPU result: top-k weighted multinomial depends on rank-1..rank-10 logit ratios, which fp16 perturbs enough to break compile.

### v72 training trajectory

```
step=0     mean=13.78
step=100    5.48
step=200    3.05
step=300    2.99 ← first sub-3.0
step=400    3.04
step=500    3.15
step=600    3.27
step=700    3.10
step=800    3.25
step=900    3.34 ← drift
step=1000   3.27
step=1100   3.04
step=1200   3.46
step=1300   3.26
step=1400   3.06
step=1500   3.20
step=1600   2.94 ← new best
step=1700   3.11
step=1800   3.00
step=1900   3.00
step=2000   2.97
step=2100   2.90
step=2200   2.89
step=2300   2.96
step=2400   2.97
step=2500   2.97
step=2600   2.93
step=2700   2.87
step=2800   2.80 ← BEAT v68's 2.83 — final best
step=2900   2.82
```

**Pattern:** early dip → noise plateau → cosine end-stage compression dug a deeper basin. Same as v68. Recipe is real.

---

## Bench wall-clock — the bombshell

The marathon handoff (`docs/handoffs/2026-05-07-marathon.md`) budgeted **2.3 hr per ckpt for the 4-cell grid**. Reality at d=256 × N=20 × max=128 × 30 prompts on CPU substrate:

- raw_n1: 44 min  ✓ (matches budget)
- raw_n20: extrapolated **~12-13 hr** based on 13-of-30 prompts in 5h35m  ✗ (6× over budget)
- strip_n1: ~44 min  ✓
- strip_n20: extrapolated **~12-13 hr**  ✗

**Per-ckpt full-grid: ~25-27 hr.** Per-ckpt strip-N20-only: ~13 hr. 4 remaining ckpts × 13 hr = 52 hr just for the strip cells. **Marathon math doesn't close** under any cell-reduction plan that preserves N=20.

Throughput math: 13 hr × 3600 / (30 prompts × 20 samples × 128 tokens) = ~6 sec/token aggregate. But parallel_rerank.sh runs `--max-parallel 8`, so per-worker rate is ~13 tok/sec. That's fine for d=256 CPU. **The bench isn't slow per-token — it's slow because there's a LOT of tokens.**

**Implication:** any future bench plan needs to either:
- reduce work (max=64? N=10? prompts=15?)
- or accept multi-day wall clocks
- or fix the GPU substrate (see "Untested levers" below)

---

## What I retired this session

- `dylib_first_token_only.md` — RETIRED. Wall is the model, not the dylib.
- `dylib_investigation_2026-04-30.md` — TIGHTENED. fp16 affects k>1 sampling, not argmax.
- `gpu_bench_substrate_failed.md` — NEW. Argmax-identity ≠ substrate substitutability.
- `dylib_substrate_argmax_identity.md` — NEW. The 3-substrate smoke + reproducer.

---

## Untested levers (the fresh-eyes invitation)

Ranked by my guess at EV:

### 1. Bench v68 + v72 (the methodology test)

**Cheapest path forward.** ~13 hr each on strip-N20 CPU. If both lift to 11+/30, val_loss is validated as a triage filter and the next 14 scaffolds get fast iteration. If they don't, val_loss is decoupled at the curriculum end and the marathon needs a different gating signal entirely.

The killer is wall-clock. At ~13 hr/ckpt × 2 ckpts = 26 hr, you can run them overnight twice. Doable.

### 2. Reduce-the-bench experiments

Has anyone validated whether N=10 or max=64 or 15-prompt subsets *correlate* with the canonical N=20/max=128/30-prompt score? If they do (within ±2/30 on the 24/30-saturated ensemble), we have a cheap proxy bench. Cheap to test: pick 3 historical ckpts with known canonical scores (Spur-v0.1=25/30, v54=9/30, v0.9-ascii=2/30), run reduced bench, check correlation.

### 3. JIT-accelerate `lm_infer_cpu.rail`

`jit_distill_integration_negligible.md` shipped 2.06× speedup on harvest_teacher grading. The same JIT primitives could potentially accelerate the inference hot loop (forward pass through 2 transformer blocks). Has not been wired. Cost: 2-4 hr engineering. EV: 2-5× bench wall-clock if it works (would put per-ckpt strip-N20 at ~3-7 hr).

### 4. fp32-logits GPU path

The GPU mixed substrate failed because *fp16 weights* perturb top-k logit ratios. **Hypothesis:** if we cast the final logit matmul output to fp32 *before* softmax, the sampling distribution would track CPU's. Would require 30-60 min of dylib + harness work. Test on v54 first; if it scores 7-11/30, GPU substrate is rescued at 7-min wall-clock per ckpt.

This is the highest-EV experiment that wasn't run today. **The smoke we did showed argmax is identical; the fp16-only-affects-sampling-tail finding has been the thread we kept pulling.** A targeted fp32-logits patch is the surgical version of the substrate swap.

### 5. Curriculum scaling experiments

v68 (seed=201) hit 2.83. v72 (seed=301) hit 2.80. Curriculum is robustly the best recipe. Untested:

- Different seeds: 5-10 more seeds of curriculum to map the val_loss distribution. If the distribution mode is around 2.85 ± 0.10, that's the "real" capability of this recipe at d=256.
- Larger d (320, 384, 512): curriculum at higher dim. Per `spur_v3_local_optimum`, d=384 was 1/30, d=512 was NaN — but those were on compile.rail-only corpus, not curriculum. Curriculum may scale differently.
- More steps: 5000, 10000. Cosine end-stage compression is what dug v72's basin. Maybe a longer cosine cycle digs deeper.
- LR ablation: v54-class recipes used LR=0.01. Curriculum used the v68 default (need to check). LR sweep on curriculum is unexplored.

### 6. Wave 2 / Wave 3 marathon scaffolds

15 scaffolds remain on disk, all 100-300 lines, all with `main =`:

- **Wave 2 (trainer surgery):** A1 process reward (8-bin loss path), A2 two-channel parse-trace (proper form, not the falsified inline pattern), A3 type-conditioned, C1 DPO, C2 GRPO.
- **Wave 3 (heavy infra):** B1 MCTS sampler, B3 adversarial self-play, D4 PBT, D3 construct-routed MoE, B4 REPL env.

Whichever bench-cost-reduction lever lands first, these are the next unit of work.

### 7. Mini parallel arm

Per `role_split.md` and `deploy_via_mini.md`. Mini has its own M-series GPU, sits at `10.42.0.2`. Could train a different scaffold concurrent with Studio's run. Doubles training throughput, doesn't help bench. Cost: ~10 min coordination.

### 8. Naked-Qwen as ongoing baseline

Per `comprehension_cracked_substrate.md`: naked Qwen-122B + 1KB Rail spec → 29/30 in 2:23. Spur exists for the structural-advantage thesis; we should bench every Spur ckpt against a *fresh* naked-Qwen run on the same prompts to measure the gap. Right now we have the 29/30 number from one run; we should re-establish the baseline with current bench harness for a clean comparison.

---

## Files that exist and are useful

```
flywheel-local/bench_railnative_rerank.rail        # canonical raw bench (rerank_n=1 currently, change to N before run)
flywheel-local/bench_strip.rail                    # canonical strip bench (rerank_n=1 currently)
flywheel-local/bench_gpu_validate_n20.rail         # rerank_n=20 baked in — for any GPU substrate experiments
flywheel-local/bench_gpu_validate_strip_n20.rail   # rerank_n=20 baked in — strip variant
tools/train/lm_infer_cpu.rail                      # bench oracle (post-cpu-substrate-fix, has matmul_cpu wrapper bypassing gpu_available)
tools/train/lm_infer_v3_mixed.rail                 # GPU mixed (FAILED on bench validation today; may work with fp32-logits patch)
tools/train/lm_infer_v3_half.rail                  # GPU all-fp16 (worse than mixed)
tools/train/full_bench.sh                          # 4-cell grid runner
tools/train/strip_n20_only.sh                      # NEW today — single-cell strip-N20 wrapper
tools/train/marathon_queue_after_v67.sh            # NEW today — process-PID-gated queue runner
tools/test/sequential_matmul_half_test.rail        # primitive determinism probe (GPU dylib byte-deterministic at primitive level)
training/bench_logs/v54_gpu_validate/raw_n20.log   # v54 GPU 0/30 evidence
training/bench_logs/v67_postfix_20260508_100622/   # v67 raw_n1=1/30, raw_n20 partial (89 bytes preserved, scores lost on SIGTERM)
training/marathon_results.md                       # the live narrative
```

## Reproducer for the dylib smoke

```
CKPT=training/rail_native/checkpoints/spur_v67_BQ2_s200_best
DYLD_LIBRARY_PATH=tools/metal ./rail_native run tools/train/lm_infer_v3_half.rail \
  --prefix "$CKPT" --prompt "main = " --max 40 --k 1 --temp 1.0 | xxd | tail -3
DYLD_LIBRARY_PATH=tools/metal ./rail_native run tools/train/lm_infer_v3_mixed.rail \
  --prefix "$CKPT" --prompt "main = " --max 40 --k 1 --temp 1.0 | xxd | tail -3
./rail_native run tools/train/lm_infer_cpu.rail \
  --prefix "$CKPT" --prompt "main = " --max 40 --k 1 --temp 1.0 | xxd | tail -3
```

All three: `main\n\n\n\n...` (id 10). Byte-identical at argmax.

## Reproducer for the GPU bench failure

```
caffeinate -dis env DYLD_LIBRARY_PATH=tools/metal ./rail_native run \
  flywheel-local/bench_gpu_validate_n20.rail \
  --prefix training/rail_native/checkpoints/spur_v54_BQ2_s77_best \
  --max 128 --k 10 --temp 1.0 \
  --tag v54-gpu-mixed-rawN20 \
  --gen-source tools/train/lm_infer_v3_mixed.rail
```

Returns 0/30 in ~7 min. v54 CPU baseline is 9/30.

---

## The hypothesis worth chasing tomorrow

**fp32-logits dylib patch.** The substrate-swap failed because fp16 logit-matmul produces slightly-wrong top-k probability mass. If the *only* matmul that cares about precision (the final logit projection) goes through an fp32 path, the rest of the dylib's fp16 path might be safe. The argmax-identity smoke is consistent with this — it's only at sampling that fp16 matters.

This is one targeted edit to `tools/train/lm_infer_v3_mixed.rail` (or a new `lm_infer_v3_fp32logits.rail`): swap the final `matmul_mixed` against the embedding table for a full-f64 matmul. Cost: 30 min. EV: huge if it works (rescues GPU bench at ~7 min/ckpt → marathon math closes).

If it works: 16-scaffold marathon collapses from ~80 hr to ~2 hr.

If it doesn't: at least we've narrowed the precision-chain culprit to *not just the logit projection* — pointing at attention or RMSNorm or earlier matmuls in the chain. Each falsification narrows the search.

---

## What I'd tell myself if I walked into this cold

1. Don't restart the marathon as a marathon. The bench-wall-clock numbers don't close. Either fix the bench (lever #4 above) or pick a different gating metric.
2. v68 + v72 are the two ckpts with information value. Bench *one* of them on strip-N20 CPU overnight to settle the val_loss-as-filter question. That's 13 hr. Fire-and-forget.
3. While that runs, try the fp32-logits patch on v54. 30 min experiment, win-or-lose answer. If win → re-bench the 6 marathon ckpts in ~30 min total.
4. The structural-advantage thesis (`structural_advantage_confirmed`) is still the load-bearing claim. Spur-v2 = 19/30 with trace strip is real. Don't lose sight of why we're training Spur at all — the compile-as-verifier loop exists nowhere else.
5. The naked-Qwen ceiling (29/30) is the gap to close. Spur-v2's 19/30 is closer than I'm celebrating.

---

## Active processes — none

All bench/queue/training processes were SIGKILLed at handoff time. `flywheel-local/bench_*.rail` files restored to `rerank_n = 1` (default). No background work running. Disk state is consistent.
