# Rail-native bench v0 — first row

**Date:** 2026-04-20
**Host:** Mac Mini M4 Pro (24 GB)
**Binary:** `rail_native` at HEAD of `next` (≈025f2df / 1738433 at bench time)
**Source:** `flywheel/bench_railnative.rail` — new this session, companion to `flywheel/bench.rail`
**Student:** checkpoint at `training/rail_native/checkpoints_apr15_backup/latest` (step 1400, loss 0.333, 9 weight tensors, 1-block pre-norm, d=64, d_ff=256, V=32 Shakespeare char vocab)
**Sampling:** max 64 tokens per task, greedy (k=1, temp=1.0)

## What this row actually measures

Three deliverables landed together this session to close the flywheel observability loop for the Rail-native LM path:

1. `tools/train/generate.rail` — greedy / top-k / temperature sampler from a `stdlib/checkpoint.rail` prefix. Silent on stdout except for the decoded text, so a grader can pipe it.
2. `flywheel/bench_railnative.rail` — 30 tasks across 6 bands (FUND, IO, TOOLS, COMP, ADV, COMPREHEND), same band names as the Gemma-era `bench.rail`, but the student is the Rail-native LM and the task shape is "complete this Rail starter". Scores via a bench-local copy of `stdlib/oracle.rail::oracle_quality` (unique tempfile path to dodge `/tmp/rail_oracle_in.rail` races with concurrent `harvest_filter` / `self_train` processes).
3. Tightened thresholds in `stdlib/oracle.rail`: `oracle_min_nw_for_bonus` 64→128, new `oracle_min_unique_chars = 8`, new `oracle_min_decls_for_bonus = 2`. A lone `main = <expr>` that happens to compile no longer inherits the 10× compile-pass bonus — it has to have at least one helper decl to count.

Before this session, there was no way to tell whether training was teaching the model to write Rail. Val loss was dropping; first-shot Rail compile rate was not being measured end-to-end.

## Bench row

```
2026-04-20T10:17:20 model=railnative-d64-1blk-step1400 fund=0/5 io=0/5 tools=0/5 comp=0/5 adv=1/5 comprehend=0/5 total=1/30 (3%) q=20241
```

Per-band breakdown (`pass / q` — the partial-credit quality sum):

| Band                 | pass | q     |
|----------------------|-----:|------:|
| FUNDAMENTALS (1-4)   |  0/5 |  3219 |
| PRACTICAL I/O (5-6)  |  0/5 |  1495 |
| REAL TOOLS (7-8)     |  0/5 |  3930 |
| COMPILER (9-10)      |  0/5 |  4227 |
| ADVANCED (11+)       |  1/5 |  3105 |
| COMPREHENSION        |  0/5 |  4265 |
| **total**            | **1/30 (3%)** | **20241** |

- **Pass** = generated text compiles + links cleanly (`oracle_ok` → `ld: OK`).
- **q** = sum over the band's tasks of `oracle_quality`, which credits non-compiling output that is still Rail-shaped (base = nw × uq, divided by `1 + errs`). Tracking q over future rows is the gradient signal: even when pass-rate is stuck at 0, q should move.
- The one ADVANCED pass was an artefact — the model's continuation happened to be ignorable ASCII that the parser accepted with a single trivial `main =` left standing. Under the tightened thresholds it still scored `quality = 0` (no helper decl), so the `OK` is counted but doesn't inflate `q`.

## The honest baseline

This checkpoint was trained on 9 lines of Shakespeare with a 32-char lowercase vocab (no `=`, `|`, `(`, `)`, `[`, `]`, `\`, `>` — the core Rail punctuation is outside the vocab). The model cannot produce compilable Rail. The bench confirms that: pass rate is floor, quality score is the partial-credit signal the tightened oracle now provides.

The point of this row is to prove the **loop is closed** — training rolls forward, a checkpoint is dropped, the bench grades it through a pure-Rail pipeline (no MLX server), a timestamped row lands in `flywheel/bench_log.txt`. Every future Rail-corpus-trained checkpoint shows up here as another row, and the gap between this floor and a real Rail model becomes visible in both pass rate and Q.

## How to run

```bash
cd ~/projects/rail
./rail_native run flywheel/bench_railnative.rail --max 64 --k 1 --temp 1.0
# or with a different checkpoint:
./rail_native run flywheel/bench_railnative.rail --prefix training/rail_native/checkpoints/latest --max 128
```

Row is appended to `flywheel/bench_log.txt` with a `model=railnative-…` tag, distinct from Gemma-era rows.

## Known shape limitations (v0)

- **Char-level vocab ≠ Rail.** The current `generate.rail` rebuilds the Shakespeare vocab from the `corpus _` literal baked into the file. When Stream 1 lands a byte-level BPE tokenizer + Rail-stdlib corpus, the default here should swap over; the sampling + scoring pipeline stays.
- **Compile race.** `stdlib/oracle.rail` hard-codes `/tmp/rail_oracle_in.rail`, which collides with concurrent flywheel processes. The bench writes to its own path AND serialises rail_native invocations behind `/opt/homebrew/bin/flock /tmp/rail_compile.lock` with a size-gated retry loop — that's enough under Stream 3's harvest_filter load, but a dedicated input path should migrate back into `stdlib/oracle.rail` eventually.
- **No retry / no hint feedback.** `bench.rail` does 3-attempt retries with compiler-error hints. `bench_railnative.rail` does one greedy (or top-k) generation and scores it. That's by design for a flywheel-level signal: we want to measure what the model *knows*, not what a wrapper prompt harness can rescue.
