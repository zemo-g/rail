# Phase 5 — d=256 × 2-block × HalfTensor × 3000 steps, composed run result

**Date:** 2026-04-21 evening → 2026-04-22 early.
**Branch:** `next`. Commit set follows PHASE_5A (Session 2) and HALFTENSOR_SESSION2_RESULT.
**Session structure:** main session on Studio + two concurrent parallel Studio sessions (audit/plumbing, docs).

## Headline

Two full 3000-step runs. The composed-width hypothesis — "d=256 × 2-block × HalfTensor drops eval below f64 d=128 baseline (2.87)" — **did not clear its target.** What did land:

- **First bench-runnable checkpoint in the project's history.** `save_half_checkpoint` + v3-architecture inference harness + bench integration all shipped this session. The plumbing is complete; future training runs produce bench-ready artifacts automatically.
- **First real `bench_railnative` score: 1/30 (3%).** Below the ≥5/30 deadline target, but the first honest measurement. Quality scores suggest the model produces plausible Rail shape without closing brace-level correctness — consistent with char-level perplexity ~32 (eval 3.49).
- **HalfTensor at d=256 trains stably.** Peak RSS flat at 512-580 MB across 84 minutes. No NaN/Inf. Weight-memory halving thesis confirmed — d=256 half lands at same RSS as d=128 half.
- **HalfTensor speedup scales with width as predicted.** d=256 half runs at 1.69 s/step vs extrapolated ~3 s/step for d=256 f64 — the matmul-fraction thesis from S2's Phase 5a result held.

## The two runs

### Run 1 (unpatched binary, no lr_mult, no save)

Launched before Session X landed its source patches. Running binary was compiled from the pre-patch `lm_v3_chunked_d256_half.rail`.

| step | eval mean | ± std |
|---:|---:|---:|
| 0 | 13.30 | 0.38 |
| 100 | 3.77 | 0.24 |
| 500 | 3.54 | 0.20 |
| 1000 | 3.53 | 0.20 |
| 1500 | 3.48 | 0.18 |
| 2000 | **3.40** | 0.15 |
| 2500 | 3.42 | 0.15 |
| 2900 | 3.44 | 0.13 |
| final (fresh chunk) | 3.22 | — |
| min single-chunk | 2.67 | — |

Produced no checkpoint (no save call in the running binary).

### Run 2 (patched: lr_mult=0.3 + save)

Launched immediately after Run 1 finished, using Session X's patched source. Identical compute time (~84 min).

| step | eval mean | ± std |
|---:|---:|---:|
| 0 | 13.30 | 0.38 |
| 100 | 4.33 | 0.44 |
| 500 | 4.08 | 0.25 |
| 1000 | 4.25 | 0.56 |
| 1500 | 3.72 | 0.17 |
| 2000 | 3.62 | 0.23 |
| 2500 | 3.49 | 0.22 |
| 2900 | 3.49 | 0.17 |
| final (fresh chunk) | 3.06 | — |
| min single-chunk | 2.58 | — |

**Checkpoint shipped** at `training/rail_native/checkpoints/d256_half_step3000.*` — 64 artifact files (20 weights + 40 adam m/v + manifest + adam_manifest + meta + committed).

### What `lr_mult=0.3` bought

Mixed signal. The damping on γ slowed early learning significantly (step 100 jumped from 3.77 → 4.33) but tracked the unpatched run's eval mean by step 2500. End-of-run single-chunk final improved (3.22 → 3.06) and min-during-run improved (2.67 → 2.58) — fine-grain optimization is marginally better, held-out eval is the same within noise.

Verdict: `lr_mult=0.3` isn't the unlock. d=256 × 2-block simply doesn't have enough capacity / enough training time / enough signal to beat d=128 f64 at 3000 steps.

## Bench: 1/30 on Run 2's checkpoint

First bench_railnative run ever on a Rail-corpus-trained v3-architecture model.

| band | pass | partial quality |
|---|---:|---:|
| Fundamentals | **1/5** | 2991 |
| Practical IO | 0/5 | 1620 |
| Real Tools | 0/5 | 3529 |
| Compiler | 0/5 | 4918 |
| Advanced | 0/5 | 1912 |
| Comprehend | 0/5 | 2736 |
| **total** | **1/30** | 17706 |

Quality scores are informative: Compiler band q=4918 means the model is producing near-miss Rail (ADT scaffolding, pattern-matching syntax, plausible function shapes) that doesn't quite close brace-level correctness. Real Tools q=3529 same pattern.

Historical context (from `flywheel/bench_log.txt.backup`, per Session Y): peak historical score 14/30 on 2026-04-04. 7 of 18 historical rows scored ≥5/30. Those models were different architectures on different corpora, so direct comparison is imperfect — but the ceiling demonstrably exceeds 5/30 for this bench.

**Gap to target:** 4 more passes. At char-level perplexity ~32, we need to drop to perplexity ~15-20 (eval ~2.7-3.0) to start reliably producing compile-clean 50-200 char Rail programs.

## What this session shipped

**Infrastructure (Session X parallel lane):**
- `stdlib/checkpoint.rail` — `save_half_model`, `load_half_model`, `save_half_checkpoint`, `load_half_checkpoint`, `load_half_model_into`. Round-trip smoke: max-abs-diff 4.94e-324 (bit-exact).
- `tools/train/lm_v3_chunked_d256_half.rail` — patched with `lr_mult=0.3` on γ and final `save_half_checkpoint` call.
- `tools/train/lm_infer_v3_half.rail` (~250 lines) — v3-arch greedy decode harness. CLI matches bench_railnative's expected invocation exactly.
- `tools/test/half_checkpoint_smoke.rail` — round-trip smoke test.
- `flywheel-local/bench_railnative.rail` — scp'd from private `Ledatic-Empire/rail-training` repo; patched locally to (a) compile `lm_infer_v3_half.rail` instead of `generate.rail`, (b) bypass `/opt/homebrew/bin/flock` which is absent on Studio. **Not committed to this repo (the canonical copy lives in the private training repo).**

**Docs (Session Y parallel lane):**
- `docs/plans/PHASE_4C_MODEL_CARD.md` — flagship model card with TBD rows (now filled: 1/30 bench, 3.49 eval, 84 min wall, 512-580 MB peak).
- `docs/plans/DEADLINE_2026-04-27_PUNCHLIST.md` — P0/P1/P2 punch-list for the 2026-04-27 milestone, with machine assignments and slippage analysis.
- `docs/plans/SESSION_4_RANKING.md` — 5 candidate Session 4 directions ranked by deadline leverage.

**Main session:**
- `tools/train/lm_v3_chunked_d256_half.rail` — Session 3 d=256 config (initial, pre-patch).
- This doc.

## Deadline reality check

2026-04-27 is 5 working days out. Remaining items from `DEADLINE_2026-04-27_PUNCHLIST.md`:

| P0 | done |
|---|---|
| d=256 training variant exists + trained + checkpoint | ✅ |
| v3 inference harness exists | ✅ |
| Bench integration patch applied | ✅ |
| First bench number | ✅ (1/30) |

| P1 — push bench to ≥5/30 | status |
|---|---|
| Deeper model (d=256 × 4-block) | queued — Session 4 this run |
| Longer training (6000 steps) | alternative |
| Better init / LR schedule | research |

| P2 | |
|---|---|
| Closed flywheel round wiring | blocked on Mini availability |
| Model card polish | 90% done; fill final numbers after Session 4 |

**Go/no-go:** tight. P0 fell fast this session. P1 needs at least one model iteration that pushes bench ≥5/30. If Session 4's deeper run lands in the 3-5/30 range, we're comfortable. If it lands at 1-2/30, we need another iteration (better training signal, longer training) before the deadline. Descope threshold: if no model has crossed 5/30 by 2026-04-25 EOD, drop the closed-flywheel-round P2 item.

## Session 4 — deeper

User-selected: **d=256 × 4-block × HalfTensor**. Rationale:
- 2× the transformer capacity at the width that already works.
- Session 2's d=128 × 4-block ran in 2.6 h at d=128. At d=256, the matmul scaling + HalfTensor savings project to ~3-4 h for 3000 steps.
- Peak RSS at d=256 × 4-block half should stay ~1.0 GB (2× the 2-block peak) — within budget.

Alternatives not picked this round (could stack):
- Train longer (6000 steps) at same 2-block.
- d=512 × 2-block (wider) — memory budget more pressured but tests a different axis.

Plan: clone `lm_v3_chunked_d256_half.rail`, apply the 2→4 block transform from `lm_v3_chunked_4block.rail`, stage 10→50→500→3000, write `PHASE_5B_DEEPER_RESULT.md`, re-bench against the new checkpoint.
