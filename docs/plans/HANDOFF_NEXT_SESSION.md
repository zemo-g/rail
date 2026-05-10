# Handoff — honest bench baseline established + heisenbug bisection map

**Headline.** **halfB_s7777_fresh on GPU mixed substrate with matched
corpus = 10/30 (33%) in 25.6 min wall-clock.** First honest bench number
on the v54 lineage. Beats historical CPU 9/30 (v54) and 7/30 (halfB),
both of which were OOB-garbage-driven per the substrate-inversion finding.
**5.4× faster** than CPU-substrate bench (25.6 min vs ~138 min).

**Branch state at handoff**: `next` at HEAD (this session's commits below),
pushed to origin/next. 137/137 green. New deliverables:
- `--corpus` flag on `lm_infer_v3_mixed.rail` (committed)
- `--corpus` passthrough on `parallel_rerank.sh` (committed)
- HalfTensor case in `check_vocab_matches` (committed)
- Bench log archived: `flywheel/bench_logs/halfB_s7777_gpu_matched_2026-05-10.log`

---

## Read first (in order, ~5 min)

1. `MEMORY.md` index — skim the `2026-05-10` entries
2. `cpu_substrate_bisect_progress_2026-05-10.md` — what was learned this session
3. `lever1_let_bind_fix_falsified.md` — what was tried and ruled out
4. `vocab_embedding_shape_mismatch_2026-05-10.md` — the substrate-inversion finding
5. The 4 SUPERSEDED-tagged entries (cpu_inference_substrate, gpu_bench_substrate_failed, v54_fp32logits_partial_lift, compile_zero_wall)

## Current state (what's true now)

**Substrate situation:**
- **CPU substrate** (`lm_infer_cpu.rail`, `forward_dump_cpu_bin`): produces
  deterministic-but-wrong x_embed values in real-model contexts, even
  with matched corpus. Heisenbug triggered by file-level function definitions
  (heap layout / data section / register allocation). 3 let-bind fixes in
  matmul_k FALSIFIED.
- **GPU mixed substrate** (`lm_infer_v3_mixed.rail`): correct x_embed
  (verified via direct lookup w_e[8,0] = 0.020599 match). Bench result on
  halfB_s7777_fresh + matched half_b corpus: **10/30 (33%)** in 25.6 min.
  Per-band: Fund 3/5, IO 2/5, Tools 2/5, Compiler 3/5, Adv 0/5, Comp 0/5.
  Works at full max=60 on V=96 halfB. Segfaults at `--max ≥ 24` on V=93
  ckpts (smoke_v54_repro, bq_s200_repro) — separate bug, see Lever B.

**Substrate matrix:**

| Ckpt set | V | CPU substrate | GPU mixed substrate |
|---|---:|---|---|
| smoke_v54_repro / bq_s200_repro | 93 | wrong (heisenbug) | works to ~max=20, segv ≥24 |
| halfB_s5555_repro / halfB_s7777_fresh | 96 | wrong (heisenbug presumed) | works to max=60 |
| any with V=130 corpus drift | * | OOB-garbage | OOB-zeros (correct lookup, wrong embeds) |

---

## Ranked open levers

### Lever A — Bisect file-level fns to isolate heisenbug trigger (HIGH ROI; ~2-4h)

`cpu_substrate_bisect_progress_2026-05-10.md` lists the diff:
- bisect_v6 (5KB, no unused fns) = correct
- fd_min (17KB, has unused fns from forward_dump_cpu.rail) = wrong

Start from bisect_v6 (recreate from the smoke template in the memory
entry), add file-level definitions one at a time from the list:
- argmax_row_loop / argmax_row
- topk_sample family
- infer_forward
- ids_to_string
- argv_get

The first definition that flips x_embed from 0.020599 to garbage is the
trigger. Then dig into compile.rail's emit path for that function class.

If you isolate it, this is potentially the matmul_cpu fix that eluded
Lever 1 — and it would unblock years of bench measurement on
real-model contexts.

### Lever B — Fix the GPU mixed segfault at high max on V=93 ckpts (MEDIUM ROI; ~1-3h)

Mixed substrate works on V=96 halfB but crashes on V=93 bq lineage at
max≥24. Likely a Metal kernel boundary issue at specific dim sizes.

Reproducer:
```bash
DYLD_LIBRARY_PATH=tools/metal /tmp/lm_infer_v3_mixed_test \
  --prefix runs/smoke_v54_repro/checkpoints/smoke_v54_repro_best \
  --prompt "main = " --max 30 --k 1 --temp 0.8 --seed 100 \
  --corpus training/corpora/spur_compile_back_quarter.txt
# rc=139 (SIGSEGV)
```

Check: forward_dump_gpu_bin runs to completion at full seq, but crashes
at the 24th token in gen_loop. Difference is gen_loop's tensor_softmax
or rope_apply on a growing active dim. Bisect by inserting probes
between ops in `gen_loop` (V=93, run_id 1, fixture seed=100).

Outcome: if fixed, GPU substrate becomes the working bench oracle for
all current ckpt sets, unlocking honest bench measurement.

### Lever C — Retrain ckpts on a non-drifted corpus (HIGH ROI; ~1-3h)

The cleanest fix to the substrate problem is a ckpt where V_corpus ==
W[0].rows AND W[0].rows is the corpus we want to bench against. Most
v54-era ckpts were trained on `spur_compile_back_quarter.txt` (V=93)
but the bench prompts encode through `rail_corpus_stdlib.txt` (V=130).

Train a fresh halfB-style ckpt at d=256 × 3000 steps × seed=77, but on
the FULL `training/rail_corpus_stdlib.txt` (V=130). Then bench against
the same corpus. Substrate-OOB risk goes to zero.

`spur_halfB_better_than_full.md` says half-B at peak hits 7/30. New
variant on V=130 should hit similar or higher (more training data to
cover the rail_corpus_stdlib byte distribution).

Bootstrap: 1-2 hr training on Studio (per training_pace_regression
memory), then ~15 min bench wall-clock once GPU substrate is fixed,
or ~2hr if CPU substrate.

### Lever D — JIT lower.rail vreg widening (MEDIUM ROI; ~3-6h)

Carried over from previous handoff. Same scope. Allocator at
`jit/lower.rail:121` hard-fails on 10th simultaneous caller-save vreg.
Adding stack-spill code path opens the lex pre-check gate for more
complex programs. 39/39 jit tests must stay green.

### Lever E — Quartz real-event smoke (LOW-MEDIUM ROI; ~1-2h)

Same scope as previous handoff. Per `tools/desk/README.md` punch list
item #3.

---

## Reusable commands

```bash
# Re-run the GPU substrate bench on halfB
./rail_native flywheel-local/bench_strip.rail
cp /tmp/rail_out /tmp/rail_bench_strip
/tmp/rail_bench_strip \
  --prefix runs/halfB_s7777_fresh/checkpoints/halfB_s7777_fresh_best \
  --max 60 --k 10 --temp 0.8 \
  --tag halfB_s7777_gpu \
  --gen-source tools/train/lm_infer_v3_mixed.rail
# Note: --corpus passthrough through bench_strip is BROKEN (nullary
# top-level binding re-evaluates per rail_quirks.md). Workaround: edit
# lm_infer_v3_mixed.rail's default_corpus_path locally for now.

# CPU substrate dump for divergence comparison
rm -f /tmp/forward_dump_cpu/*.txt
tools/diagnose/forward_dump_cpu_bin \
  --prefix runs/smoke_v54_repro/checkpoints/smoke_v54_repro_best \
  --prompt "main = " --max 1 \
  --corpus training/corpora/spur_compile_back_quarter.txt

# GPU substrate dump
rm -f /tmp/forward_dump_gpu/*.txt
tools/diagnose/forward_dump_gpu_bin \
  --prefix runs/smoke_v54_repro/checkpoints/smoke_v54_repro_best \
  --prompt "main = " \
  --corpus training/corpora/spur_compile_back_quarter.txt

# Per-layer divergence table
tools/diagnose/forward_diff_analyze.sh

# Test suite (must stay green after any stdlib change)
./rail_native test  # 137/137

# Self-compile + cycle check (after stdlib changes)
./rail_native self && cmp rail_native /tmp/rail_self && echo "byte-identical"

# Push (relay handles GitHub)
git push origin next
```

---

## Heisenbug & gotchas

1. **Adding `print` statements changes the bug.** Heap layout shifts
   with any source-level change. Verify fixes by reading dump files,
   not by adding inline probes.

2. **Stale bins.** Whenever you change a `.rail` source, REBUILD the bin
   (`./rail_native <file>.rail && cp /tmp/rail_out <bin>`).

3. **`./rail_native run` swallows link errors.** Check for `as: OK ld: OK`
   in the compile output before trusting results.

4. **Nullary top-level bindings re-evaluate** (per `rail_quirks.md`).
   `corpus_path_holder = arr_new 1 ""` returns a FRESH array each
   reference. Plumb mutable state via main → function-arg chain instead.

5. **`--corpus` plumbing through bench_strip is broken.** The flag
   reaches lm_infer_v3_mixed.rail and parallel_rerank.sh (committed
   support), but bench_strip can't pass it through because of #4.
   Workaround: edit gen_src's default locally for the bench session.

6. **`var * const + var` is a codegen heisenbug pattern** — but the
   Lever 1 falsification shows the bug is deeper. Don't trust let-bind
   workarounds alone; verify the actual output.

7. **GPU mixed substrate segfaults at ≥24 tokens on V=93 ckpts.**
   Works at higher maxes on V=96 halfB. See Lever B.

8. **Studio panics under stacked workloads.** Don't run parallel_rerank
   N=20 and concurrent training. Per `studio_panic_pattern.md`.

---

## Commit norms

(Same as previous handoff — commit per logical change, ship-shape,
137/137 each commit, push after each, update memory entries.)

---

## STOP conditions (write a fresh handoff and halt)

(Same as previous handoff: bench improvement landed; speed improvement
landed; 3 consecutive failed attempts; Studio panic risk; 137/137 breaks;
stuck after 30 min on something off the lever list.)

---

## What success looks like

A clean handoff with at least:
- One isolated heisenbug-trigger function (Lever A) OR a working GPU
  substrate at max=60 on V=93 ckpts (Lever B) OR a fresh-corpus ckpt
  with reproducible bench number (Lever C)
- 137/137 still green
- Pushed to origin/next
- Memory entries updated with the new finding(s)
