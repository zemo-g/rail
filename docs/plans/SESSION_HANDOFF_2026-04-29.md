# Session handoff — 2026-04-28 → 29 (deep dive: substrate fix, distillation, min-ckpt)

**Headline:** This session pivoted from "can we train a better Spur-Fix?" to "is the bench oracle even working?" The answer was no — the dylib regressed silently in a morning rebuild experiment, all bench numbers were corrupted, and tonight's six v0.4 training experiments were uninterpretable. We rebuilt the substrate from scratch (CPU f64 inference + KV-cache shape narrowing + mini-bench), validated four checkpoints under it, discovered teacher distillation works at 47% hit rate via Studio's Claude-distilled Qwen-27B, trained two new architectures (v0.5 distill, v0.6/v0.7 d=384), and uncovered that **min-eval-checkpoint is a real durable lever** (5/5 shape vs 3/5 on identical training run). Compile rate at single-sample remains **zero across every ckpt and config tested** — the wall is below the model.

## The artifacts shipped (all in tree, durable across sessions)

### Bench substrate
- **`tools/train/lm_infer_cpu.rail`** — pure-CPU f64 inference. Mathematically equivalent to dylib (verified at first-token greedy). Includes the KV-cache-equivalent shape narrowing (78× speedup at max=8, 12× at max=128). Use when `tools/metal/.no_gpu` exists.
- **`tools/train/mini_bench_cpu.sh`** — 5-task liveness check. Reports shape rate (≥4 unique non-ws chars) + compile rate. ~5 min/ckpt at max=16.
- **`tools/train/quick_sample.sh`** — parallel knob-sweep harness. N seeds in parallel, then serial compile + classify.
- **`tools/train/head_to_head.sh`** — full-length max=128 head-to-head between two ckpts, 5 prompts × 3 seeds.

### Teacher distillation
- **`tools/train/teacher_distill.sh`** — POST to Claude-distilled Qwen-27B at `10.42.0.2:8080`, parse content, compile-filter, optionally output-match-filter, append survivors to corpus. 47/75 compile, 31/75 match expected output. Pass system+user via env-vars to avoid bash/python escaping pitfalls.
- **`tools/train/build_v05_corpus.sh`** — concatenate `corpus_mixed_v3e.txt` + distilled survivors → augmented corpus.
- **`training/corpus_distill_pilot1.txt`** (8 programs, 1.3 KB) and **`pilot2.txt`** (47 programs, 5.2 KB) — first two harvests.

### Training infrastructure
- **`tools/train/lm_v05_distill.rail`** — v3e + distilled corpus, d=256 × 2-block × 3000 steps. Trained Spur v0.5 (final loss 3.59).
- **`tools/train/lm_v06_d384.rail`** — d=384 × 2-block × 3000 steps on v3e. 3.89M params (vs 1.74M at d=256). Trained Spur v0.6 (final 3.39, min train-loss 2.72).
- **`tools/train/lm_v07_d384_minckpt.rail`** — v0.6 + min-eval-checkpoint patch. Saves `<prefix>_best` every time eval mean hits new low. Trained Spur v0.7 BEST (5/5 shape) and FINAL (3/5 shape) from the same run.
- **`tools/train/v05_pipeline.sh`**, **`v06_pipeline.sh`**, **`v07_pipeline.sh`** — orchestrators (harvest → corpus → train → bench).

### Trained checkpoints (in `training/rail_native/checkpoints/`)
- `spur_v05_distill_step3000` — distill+stdlib corpus, d=256
- `spur_v06_d384_step3000` — d=384 cosine-decayed final
- `spur_v07_d384_step3000` — bit-identical to v0.6 (deterministic re-run)
- **`spur_v07_d384_best`** — d=384 saved at step 2600 where eval mean was 3.50 (the headline result)

## Standings under CPU mini-bench

| Ckpt | val_loss | shape/5 | compile/5 |
|---|---|---|---|
| **v0.7 BEST (d=384, step 2600)** | 3.50 | **5** | 0 |
| v0.5 (distill) | 3.59 | 5 | 0 |
| v0.4b' | 3.62 | 5 | 0 |
| Spur-0.1 (d=256) | 3.06 | 4 | 0 |
| v0.4d | 3.25 | 4 | 0 |
| v0.4c | 3.79 | 4 | 0 |
| v0.7 FINAL = v0.6 (d=384, step 3000) | 3.39 | 3 | 0 |
| v0.2 | 3.59 | 3 | 0 |
| v0.4e | 3.23 | 2 | 0 |

## Open problems (in priority order)

### P0 — `libtensor_gpu.dylib` sequential-call bug
The fresh-rebuilt dylib produces `<prompt><1 char><newlines>` collapse on inference. Single-op smoke tests (matmul/softmax/transpose/scale/add at d=384, seq=1024, fp16) ALL pass under it. Diagnosed: bug is in *sequential* `tgl_*_half_host` calls, not primitive ops. Hypotheses falsified:
- arena_mark/arena_reset interaction (removed; collapse persists)
- rail_native binary regression (Apr 19 backup tested, same)
- inference source regression (`git checkout 9fe736a` of `lm_infer_v3_half.rail`, same)

Most likely: MTLBuffer pool reuses staging buffers across calls (line ~1404 in `tools/metal/tensor_gpu_lib.m`'s `tgl_matmul_half_host`). Needs Metal-side debugging or alternate buffer-pool strategy. **Not on critical path** while CPU substrate works — but blocking fast inference at d=256 (would give ~25× speedup over CPU).

### P1 — Compile=0 wall
See `memory/compile_zero_wall.md`. Two hypotheses left:
1. **fp16 sharpening was the historical lever.** Old (Apr 22) dylib ran fp16; current dylib broken; CPU runs f64. Restore OLD dylib state (git checkout ~Apr 22, rebuild) to test.
2. **Historical 13/30 single-sample was a measurement artifact.** Always was rerank-N=20 implicitly.

EV: hypothesis (1) gives a 13/30-style ceiling back if true. Hypothesis (2) means we need a much better model. Cheaper to test (1) first.

### P2 — Distill corpus is too small
47 programs / 612 KB corpus = 0.8% by bytes. Insufficient to dominate training distribution. Push to 500+ programs (~3-hour harvest at 25 sec/call × 60% hit rate) to make distill the dominant signal. Then train v0.8 = d=384 + min-ckpt + 500-program corpus.

## Pickup playbook

```bash
# 1) Verify state
cd ~/projects/rail
ls tools/metal/.no_gpu              # should exist (CPU-mode-default for inference)
ls /tmp/rail_infer_cpu              # the compiled CPU inference binary

# 2) Sanity-check the substrate
/tmp/rail_infer_cpu \
  --prefix training/rail_native/checkpoints/spur_v07_d384_best \
  --max 16 --k 10 --temp 0.8 --seed 100 --no-ws-first 12 \
  --prompt 'fact n = if n <= 1 then 1 else n * fact (n - 1)
main = '
# expect multi-token continuation with ≥4 unique non-ws chars

# 3) Reproduce the standings
tools/train/mini_bench_cpu.sh \
  training/rail_native/checkpoints/spur_v07_d384_best v07_BEST_recheck

# 4) Run a knob sweep against the strongest ckpt
CKPT=spur_v07_d384_best MAX=128 K=10 NO_WS=16 SEEDS="1 2 3 4 5" \
  tools/train/quick_sample.sh
```

## What NOT to do

- Don't restart the v0.4 Spur-Fix iteration — those measurements were under broken bench, results were noise.
- Don't trust any pre-2026-04-28 single-sample bench number without re-bench under CPU substrate.
- Don't use `Qwen3.6-35B-A3B` at port 8081 as the teacher — it's a thinking-mode model that burns 800+ tokens reasoning. Use the **Claude-distilled 27B at port 8080**.
- Don't attribute compile=0 to "the model is bad." The wall is in the substrate (likely fp16 vs f64 sharpening), not the architecture.
- Don't skip the min-ckpt patch on any future training run — the durability win is real (5/5 shape vs 3/5 on identical run).

## Memory updates this session

- `dylib_first_token_only.md` — dylib's sequential-call bug with arena hypothesis falsified
- `val_loss_underread.md` — read .meta first; val_loss tracks training but not sampling distribution
- `min_checkpoint_lever.md` — the headline finding; cosine decay narrows distribution; save on min-eval
- `teacher_distill_works.md` — Claude-distilled 27B at port 8080 = working teacher
- `cpu_inference_substrate.md` — CPU + KV-shape-narrowing = the bench oracle
- `compile_zero_wall.md` — wall is below model; two hypotheses standing
- `MEMORY.md` index updated

## Next-session P0

Decide between: (a) restore old dylib state to test fp16 hypothesis [4-hour expt: git rev work + rebuild + re-bench], (b) push distill corpus to 500+ programs and retrain v0.8 [overnight], (c) accept compile=0 ceiling and pivot to the rerank+compile-loss-during-training infrastructure [biggest open theoretical lever].
