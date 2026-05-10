# Session prompt — 2026-05-11 — capacity scaling + honest ensemble re-bench

## Where we are (one paragraph)

The matmul_cpu "heisenbug" was a 9-line codegen bug in `compile.rail`
(emit_x1 fast path silently used `mov x1, x0` when LHS was a top-level
nullary like `seq_len`). Fixed at commit `02a6a1d`. CPU and GPU
substrates now produce bit-equivalent output. Three honest re-benches
landed: **halfB 6/30, v54 13/30, Spur-v0.1 1/30** (collapsed from
flagship 25/30 ensemble). The buggy substrate had been measuring
sampling-bias-through-zero-prompt for months; we now have a working
measurement loop for the first time. v54 (smoke_v54_repro_best) is the
new model lead. The substrate-thesis 30/30 (naked Qwen + Rail spec)
is unaffected and remains the only solidly-measured high-water mark.

**The strategic axis: 17-point gap from v54's 13/30 (Rail-trained) to
substrate-thesis 30/30 (frontier LLM through Rail). Closing it is the
mission.**

---

## ✅ Verification checklist (10 items — do FIRST, in order)

Run each. Anything that fails halts the session until resolved.

1. `[ ]` `cd ~/projects/rail && git log --oneline -1` shows
   `ff8563b` or later on `next`, ahead of origin only if a new
   session commit just landed.
2. `[ ]` `git status -sb` is clean (no uncommitted modifications).
3. `[ ]` `./rail_native test 2>&1 | tail -1` reports `137/137 tests passed`.
4. `[ ]` `./rail_native self && cmp rail_native /tmp/rail_self && echo OK`
   prints `OK` (byte-identical fixed point — cycle 2 clean).
5. `[ ]` `grep -n 'l_in_env' tools/compile.rail | head -2` shows
   the fix is present at line ~1464 AND not at line ~1493 (cmp site
   was intentionally NOT patched — defer for later).
6. `[ ]` Regression test: `./rail_native run tools/diagnose/cpu_bisect_v_full.rail
   -- --prefix runs/smoke_v54_repro/checkpoints/smoke_v54_repro_best
   --corpus training/corpora/spur_compile_back_quarter.txt
   --prompt "main = " --max 1 --k 1` prints
   `BISECT x_embed[0]=0.020599365234375`. If it prints `~10^-315`,
   the fix has regressed — DO NOT proceed.
7. `[ ]` `grep -n 'default_corpus_path' tools/train/lm_infer_v3_mixed.rail`
   shows `training/rail_corpus_stdlib.txt` (canonical default — not
   the session-local back_quarter or half_b paths).
8. `[ ]` Substrate parity smoke: produce the same string from CPU
   and GPU substrates on `halfB_s7777_fresh` with seed 7. Both should
   emit identical output starting `main = ,o re r rr_ ,a l0 ,ar o a`.
   See HANDOFF_NEXT_SESSION.md for the exact commands.
9. `[ ]` `tail -3 flywheel/bench_log.txt` shows the three honest
   re-benches landed 2026-05-10: halfB=6/30, v54=13/30, spur_v01=1/30.
10. `[ ]` Read `cpu_substrate_conditional_trigger_2026-05-10.md` and
    `honest_rebench_2026-05-10.md` from `~/.claude/projects/-Users-user/memory/`
    in full before touching any model file. The interpretation of the
    Spur lineage has been rewritten; old memory entries are stale.

All 10 pass → proceed to the work below.

---

## The end goal (restated)

Best, most efficient, reliable models possible — **trained by Rail,
in Rail, on Rail**. The 30/30 substrate-thesis result with naked
Qwen + Rail spec is the high-water mark we measure against. Crossing
that on a Rail-trained model (without Qwen support at inference time)
is the Rail-on-Rail mission completing one full lap.

**17-point gap = the work.**

## How we get there (4 phases)

| Phase | What | Why | Expected lift |
|---|---|---|---|
| **1. Honest ensemble re-bench** | Re-bench the top 10 ckpts from the historical 39-ckpt ensemble | Identify which architectural choices were real signal vs lucky-bug | Reveals the true ensemble ceiling. ~3-4 hr serial; could be parallelized. |
| **2. Capacity scaling** | Train d=512 × 4-block × full V=130 stdlib corpus × longer schedule | We've never trained a properly-sized model on the working substrate | +5-15 bench points if scaling-laws hold |
| **3. Compile-loss training** | Wire `rollout_harvest.sh` into the trainer; compile-pass becomes part of the loss | Owner-of-compiler advantage = owner-of-verifier-as-loss | +5-10 points; structurally unavailable to non-compiler-owning projects |
| **4. Substrate distillation** | Naked Qwen at 30/30 generates 50K Rail-on-Rail training samples; train a Rail model on them | Compiler-owner is ALSO teacher-owner | Closes the remaining gap to 30/30 or beyond |

This session focuses on **Phase 1 + Phase 2 in parallel**.

---

## This session's work (concrete)

### Foreground — honest ensemble re-bench (3-4 hr)

Goal: get an honest number on the **top 10 historical Spur ckpts**
(from `spur_ensemble_ceiling_24_of_30.md`'s 39-ckpt list) so we know
which architectural choices were real signal.

1. Identify the 10 ckpts to re-bench. Recommended: spur_v54
   variants (v54, v48 back-quarter peak, v54 LR=0.01 = v54a), 3 halfB
   seeds (s5555, s7777_fresh, s7777_repro), Spur-v0.1, plus 3 wild
   cards from the ensemble curve (highest pre-fix scores).
2. For each ckpt: identify training corpus (check the run's manifest /
   meta), edit `default_corpus_path` in `lm_infer_v3_mixed.rail`
   accordingly, run bench, record result, restore default.
3. After the 10th: revert `default_corpus_path` to
   `training/rail_corpus_stdlib.txt` (canonical), `git diff` should
   be empty.
4. Append findings to `honest_rebench_2026-05-10.md` (extend the
   existing entry; don't create a new one).
5. Push the bench log + memory updates.

**Time budget**: ~25 min per bench × 10 = ~4 hr. Run sequentially
to avoid `studio_panic_pattern.md` stacking.

**Stop conditions for Phase 1**:
- Any bench segfaults consistently → file the bug and skip that ckpt
- Studio thermals approach the panic threshold → stop, defer remainder

### Background — kick off d=512 capacity training (~12 hr overnight)

Goal: first honest d=512 training run on the working substrate.

1. Pick the most successful trainer source (recommend
   `tools/train/lm_v54_compile.rail` if it exists; otherwise the
   half-B / back-quarter pattern at d=256 → fork to d=512).
2. Modify: `d_model = 512`, `n_blocks = 4`, `max_steps = 6000` or
   higher, training corpus = `training/rail_corpus_stdlib.txt`
   (V=130 full stdlib).
3. Kick off in background via `run_in_background: true`. Log RSS
   peak via `time -l` per `init_matters.md`.
4. Don't bench until val_loss has moved past v54's training final
   (`val_loss_underread.md`).
5. If training finishes overnight, bench the resulting ckpt as the
   FIRST move next session.

**Time budget**: kicked off at session start, runs in background
while Phase 1 bench loop runs in foreground. Total: ~12 hr.

**Stop conditions for Phase 2**:
- val_loss diverges (NaN / inf) → kill training, fall back to d=384
- Studio thermal pressure from concurrent bench → kill training,
  re-run when bench is done

---

## Floor (don't break)

- 137/137 green
- Byte-identical self-compile fixed point (cycle ≥ 2)
- v_full bisect harness produces 0.020599 (regression test for the
  compile fix)
- `default_corpus_path` in `lm_infer_v3_mixed.rail` is
  `training/rail_corpus_stdlib.txt` at end of session
- Don't stack heavy workloads on Studio (parallel_rerank N=20 ×
  training collides; panic risk per `studio_panic_pattern.md`)
- Don't commit binaries that weren't bootstrapped (rail_native must
  reach byte-identical cycle-2 before any commit)

## Honest-numbers discipline

- Every bench result goes to `flywheel/bench_log.txt`
- Every "this ckpt scores X" claim must cite the post-fix run
  (2026-05-10 evening or later)
- Pre-fix numbers (24/30 ensemble, 25/30 Spur-v0.1, etc.) are
  **historical artifacts only**. Don't quote them as targets.
- v54 at 13/30 is the current bar to beat.

## STOP conditions (write a fresh handoff and halt)

1. Any of the 10 verification checks fails and can't be unblocked
   in <30 min.
2. The d=512 training run NaN-diverges and 2 attempts at lower LR
   also fail.
3. Bench segfaults more than 2 of the 10 ckpts.
4. Studio panics (configd watchdog).
5. 3 consecutive failed attempts at any single goal.
6. You're stuck >45 min on something not on the lever list.

## Reusable commands

```bash
# Self-compile + cycle check (always run after compile.rail edits)
./rail_native self && cmp rail_native /tmp/rail_self && echo "byte-identical"

# Run 137/137
./rail_native test  # expect "137/137 tests passed"

# Regression test for the codegen fix
./rail_native run tools/diagnose/cpu_bisect_v_full.rail \
  -- --prefix runs/smoke_v54_repro/checkpoints/smoke_v54_repro_best \
     --corpus training/corpora/spur_compile_back_quarter.txt \
     --prompt "main = " --max 1 --k 1
# expect: BISECT x_embed[0]=0.020599365234375

# Honest bench on a ckpt (edit default_corpus_path FIRST to match training corpus)
./rail_native flywheel-local/bench_strip.rail && cp /tmp/rail_out /tmp/rail_bench_strip
DYLD_LIBRARY_PATH=tools/metal /tmp/rail_bench_strip \
  --prefix runs/<ckpt-dir>/checkpoints/<ckpt-name> \
  --max 60 --k 10 --temp 0.8 \
  --tag <ckpt>_post_fix_matched \
  --gen-source tools/train/lm_infer_v3_mixed.rail \
  2>&1 | tee /tmp/bench_<ckpt>.log

# Push (relay handles GitHub)
git push origin next
```

## What success looks like for THIS session

A clean handoff with at least:
- 10 ckpts honestly re-benched, results in `flywheel/bench_log.txt`
- The honest ensemble ceiling number (max-pass routing across the 10)
- A d=512 training run kicked off (or completed, depending on timing)
- v54's 13/30 status validated or superseded
- Memory entries updated; nothing stale
- Pushed to `origin/next`

## What to NOT do

- Don't chase the historical 25/30 number. It was bug-driven. Gone.
- Don't bench against `rail_corpus_stdlib.txt` (V=130) for ckpts
  trained on smaller-V corpora — that's the OOB scenario, returns 0/30.
- Don't try to patch the cmp site (line ~1493 in compile.rail) without
  a regression case showing it matters. Defensive fixes during the
  capacity-scaling phase add risk.
- Don't run more than one heavy workload on Studio at once. Bench
  serial, training in background while bench runs is OK; bench +
  bench is not.
- Don't write new memory entries to "remind" yourself of what just
  happened in this session. Update existing entries.
