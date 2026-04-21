# Phase 1c — T5 overnight baseline (d=64, 12000-step)

**Date:** 2026-04-20
**Machine:** Mac Studio M1 Ultra
**Branch:** next (HEAD `4399445`)
**Training script:** `tools/train/lm_v3_chunked.rail` (pre-wire: `seq_len=1024`, `corpus_path=training/rail_corpus_stdlib.txt`)
**Binary:** isolated compile to `/tmp/t5_overnight_bin` (re-signed), exec'd directly to bypass `/bin/sh` stdout buffer and immunize from orchestrator `/tmp/rail_out` churn.

## Result

- **Min loss: 1.37** (step 1157, re-hit at step 1550)
- Final training-step loss at kill: 2.94 (step 11183)
- Reached 11183 / 12000 steps (93%) — terminated early; cosine tail (lr ≤ 0.0003) producing no further min improvement
- **Wall: 5h 38m 6s** (20286 s real)
- **Peak memory footprint: 35.84 GB** (via `/usr/bin/time -l`) — **anomalous, see Findings**
- Start 14:23:10 EDT, kill 20:01:16 EDT
- Orchestrator (Studio) ran parallel oracle batch / compile work concurrently throughout

## Architecture

- 2-block decoder-only transformer, pre-norm
- `d = 64`, `d_ff = 3 * d = 192`
- RMSNorm (learnable γ), RoPE, SiLU MLP
- Tied embedding (W_E serves both input and output)
- Vocab: 130 chars (concatenated Rail stdlib codepoint set)
- `seq_len = 1024`
- Causal attention, single head per block

## Hyperparameters

- Optimizer: AdamW, b1=0.9, b2=0.999, eps=1e-8
- `base_lr = 0.02`, `warmup = 100` steps, cosine decay to 0 over `max_steps = 12000`
- Initialization: Kaiming-scaled `std = sqrt(2 / fan_in)` (`init_scaled`)
- Chunked sampling: per step, one random 1024-char window from the 544018-char corpus
- RNG seed: 42 (deterministic; verified bit-identical warmup across short runs)
- Arena reset per step (post-`d24340c` fix active)

## Loss trajectory (sampled every 1000 training steps)

| Step  | lr        | loss  |
|------:|-----------|-------|
|     0 | 0         | 8.40  |
|   999 | 0.01972   | 3.08  |
|  1999 | 0.01877   | 2.84  |
|  2999 | 0.01721   | 3.27  |
|  3999 | 0.01515   | 3.22  |
|  4999 | 0.01274   | 2.71  |
|  5999 | 0.01013   | 2.92  |
|  6999 | 0.00755   | 2.84  |
|  7999 | 0.00517   | 2.66  |
|  8999 | 0.00312   | 3.04  |
|  9999 | 0.00154   | 3.03  |
| 10999 | 0.00046   | 2.67  |
| 11183 | 0.00023   | 2.94  |

### Min loss — top 5 during run

| Step  | Loss  |
|------:|-------|
|  1157 | 1.368 |
|  1550 | 1.368 |
|  8389 | 1.590 |
| 10464 | 1.730 |
| 10431 | 1.762 |

## Staging validation (pre-overnight)

All short stages ran cleanly with peak memory footprint 437 MB flat — no growth 10→500:

| Stage | Steps | Wall      | Peak (time -l) | Final fresh-chunk |
|-------|------:|-----------|----------------|-------------------|
| 10    |    10 | 23 s      | 437 MB         | 5.88              |
| 20    |    20 | 34 s      | 437 MB         | 4.60              |
| 50    |    50 | 69 s      | 437 MB         | 3.48              |
| 500   |   500 | 9 min 14s | 437 MB         | 3.42              |
| 12000 | 11183 | 5h 38m    | **35.84 GB**   | n/a (killed)      |

## Findings

### 1. d=64 capacity is not the bottleneck

Min loss 1.37 is well below the naive "floor" implied by the noisy post-warmup plateau (2.7–3.3). The model absorbs easy chunks to 1.4 loss while same-batch-size evaluations of harder chunks stay above 3.0. **Per-chunk variance dominates any single-point loss reading.** Single-chunk training loss is a poor progress signal on this corpus.

### 2. Cosine tail contributed no new min

Both min-loss touches (1.37) are in the high-LR phase (steps 1157, 1550, lr ≈ 0.020). No descent below 1.59 after step 1550. The last 10000 steps at progressively lower lr produced nothing better than what the first 1500 steps already found. **For future d=64 runs on this corpus, 2000 steps is sufficient to exhaust the min-loss signal; longer runs are wasted training time under this schedule.**

### 3. Peak memory anomaly — 437 MB → 35.84 GB

Short runs (10–500 steps) held `peak memory footprint` at 437 MB flat. The 12000-step run hit 35.84 GB. This is ~80× growth for ~22× more steps — super-linear. The arena fix (`d24340c`) addresses large-block munmap but small-block bump region still leaks. Sys CPU was 7938 s / 20286 s wall = 39% of wall (and 63% of total CPU) — abnormally high, consistent with heavy page-fault / mmap churn. **Worth bisecting: insert RSS snapshots every 500 steps in a follow-up run to find where the growth starts.** Possible small-block leak amplifier active only after step ~500.

### 4. Per-chunk eval noise drowns the curve

Any given step's loss spans 1.4–4+ depending on which random chunk was drawn. For Phase 2a's d=128 comparison to be meaningful, a **multi-chunk eval** (average loss over e.g. 10 held-out chunks at each eval point) is needed. The current single-chunk print is useful as a liveness signal but not as a ranking signal.

## Follow-ups

- **For Phase 2a (d=128):** keep `max_steps` lower (≤3000), add multi-chunk eval, capture RSS every 500 steps for memory bisect.
- **Memory leak bisect:** the 437 MB → 35.84 GB delta is the most actionable finding. Single long run with periodic RSS snapshots will localize the growth point. Likely in arena small-block bump region or an allocation pattern in `m_train_step` that accumulates across steps despite `arena_reset`.
- **Single-point loss is unreliable.** Future training scripts should eval on a held-out held-fixed chunk set for monotone comparison across runs.

## Artifacts

- `/tmp/t5_overnight.log` — full 11183-step log + time -l summary (17 MB, kept on Studio local)
- `/tmp/t5_overnight.meta` — start/end timestamps
- Working-tree lm_v3_chunked.rail carries the overnight wire-up (seq_len=1024, corpus_path, max_steps=12000) plus a min-loss tracker (`min_buf` threaded through `m_train_loop`) added during staging to capture (3) above — not committed; treat as experiment knobs.
