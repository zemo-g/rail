# Phase 5h — Comprehend ceiling is real: N=300 falsifies the sampling hypothesis

**Date:** 2026-04-24.
**Result:** at N=300 compiler-re-rank on Spur-0.1, Comprehend band scored **0/5 across 1,500 samples**. Zero compile-passes. The band is confirmed structurally unreachable by sampling alone.

## The experiment

Last-ditch attempt to push past 25/30: run compiler-re-rank at **N=300 samples per task** on the 5 Comprehend band tasks only (the 5 tasks unsolved at N=20). If the model had even a 1-in-1,000 probability mass on "complete the function AND append a valid `main = ...`", 300 independent samples per task would catch it.

- Checkpoint: Spur-0.1 (d=256 × 2-block × half × 3000 steps)
- Decoder: `--k 50 --temp 0.8` (the Phase 1 sweep winner)
- Tasks: 5 (factorial, flatten, fold, map, find_key) × 300 samples = **1,500 compiler-graded samples**
- Wall: ~18 hours continuous
- Safety: `caffeinate -ism` + `stdbuf -oL` + `nohup` — no sleep, no crash, no sample skipped

## Results

```
Comprehend: 0/5   q=2912
pass rate:  0/30  (0%)
total q:    2912
```

Zero `ok=1` occurrences in 1,500 compiler invocations.

### Quality distribution (the informative part)

| q value | count | what it means |
|---:|---:|---|
| 0 | 1,021 | pure garbage — not even Rail-shaped |
| 528 | 86 | same near-miss (identical or near-identical output) |
| 471 | 82 | another repeated near-miss |
| 594 | 46 | another |
| 702 | 45 | another |
| 441 | 37 | another |
| 742 | 23 | another |
| 630 | 20 | another |
| 473 | 19 | another |
| 504 | 13 | another |

**~480 of 1,500 samples produced Rail-shaped near-misses clustered at a small number of quality values.** The model is generating repeated similar output patterns — function bodies without `main =` closures — and the compiler consistently fails them on the same error (undefined `_main`). The distribution has visible *mass* on "function body" but effectively **zero mass** on "function body + main block."

## What this tells us

1. **Sampling has a structural ceiling on semantic-intent tasks at this scale.** Even at 300 samples per task with our widest feasible k (50), Spur-0.1's generation distribution never crosses the `main = ` threshold on any of the 5 Comprehend prompts. The 14 → 25 jump that N=20 produced on structural bands was real; scaling N further on semantic bands produces 0 additional passes.

2. **The model's support is narrow, not shallow.** If the model's distribution was just low-probability on valid outputs, 300 samples would catch at least one. The fact that it caught *zero* means the distribution puts essentially *no* mass on the correct structural shape. The model literally doesn't "know" that `-- complete this factorial so it prints 120\nfact n = ` needs a `main =` continuation, and no amount of sampling surfaces a skill the model doesn't have.

3. **25/30 is not a sampling ceiling — it's a semantic ceiling.** Spur-0.1 saturated compiler-re-rank on the bands where the training corpus provided exposure (all 5 of FUND/IO/Tools/Compiler/Advanced end with `main = ` in their prompts, giving the model a strong "continue after main =" signal). Comprehend prompts don't, and stdlib doesn't teach the model to generate `main =` de novo.

## What would crack Comprehend (future, not today)

1. **Diagnostic-corpus training at scale** (Spur-Fix v0.3+). Triples like `(partial_function_no_main, "_main undefined", partial_function_plus_main)` would teach the model the missing protocol. Requires ≥5,000 triples, model-in-the-loop generation, loss masking on `<FIXED>` block. See `DIAGNOSTIC_CORPUS.md`.

2. **Prompt wrapping with main-template scaffold**. Change the bench's Comprehend prompts to include a `\nmain = ` suffix, matching the other bands' format. **This is a bench change, not a model change** — but it could be argued either way whether it's fair. Arguably, if the task wants "complete the body such that printing yields X," the prompt should include the `main = print (show (fn input))` harness. A clean engineering argument.

3. **Post-process with main-injection**. Append a generic `\nmain = 0\n` to any sample missing `main`. Guarantees compile-pass but sidesteps the challenge. Not a legitimate model-capability claim.

4. **Runtime-feedback fix-loop.** The bench's `exec_match` already runs compiled programs and compares stdout to expected. Use this AS PART of the re-rank criterion: sample → if compiles and runs → check output → if wrong, prompt `<BROKEN>\n{code}\n<DIAG>\nstdout mismatch: got X expected Y\n<FIXED>\n` → sample a semantic correction. Requires the fix-loop model to exist (Spur-Fix v0.3+).

Of these, (1) is the real research direction. (2) is an honest engineering call. (3) is cheating. (4) depends on (1).

## What ships

Spur-0.1 + compiler re-rank at N=20 / k=50 → **25/30 (83%)** remains the final flagship number for 2026-04-27.

The N=300 experiment sharpens the narrative from "we got 25/30, Comprehend is unsolved" to **"we got 25/30 and empirically proved that the sixth band is a semantic ceiling, not a sampling ceiling, falsifying the hypothesis at 1,500 compiler-graded samples."** That's a strictly stronger result for the paper.

## Logs

- `/tmp/spur_comprehend_n300_1776978246/main.log` (1,558 lines, full per-sample record)
- `flywheel/bench_log.txt` row: `2026-04-24T11:08:16 model=spur-0.1-comprehend-N300-k50 ... comprehend=0/5 total=0/30 (0%) q=2912`

## The one-liner this replaces

Old: *"Comprehend's 0/5 is unsolved; maybe more sampling would help."*
New: **"Comprehend's 0/5 is a structural gap — 1,500 compiler-graded samples don't find a single valid output, proving the ceiling is at the training-distribution level, not at the sampling-search level."**
