# 3-day growth-determination session — Days 2 + 3

> **This session executes Day 2 and Day 3 of a 3-day growth-determination
> arc. Day 1 (v54 multi-seed sweep) was launched in the prior session and
> runs overnight 2026-05-11.**

## The question this 3-day arc answers

**Is Rail-on-Rail's compute lever real, or is the structural lever
(distillation / compile-loss) the bigger fish?**

The answer determines whether to rent a GPU rack or invest the same dollars
in a structural-lever pipeline first. The directive in
`exhaust_studio_before_renting.md` is "no rent until the answer is clear."

## Three tests, one decision

| Day | Test | Question | Output | Time |
|---|---|---|---|---|
| **1** (running) | v54 multi-seed sweep | Is v54's 13/30 the recipe ceiling or a lucky seed? | 6 bench points on the v54_BQ2 recipe (s77=13, s200=11, s100/300/400/500=TBD) | ~9 hr |
| **2** | Single-axis scaling | Does scaling ONE lever lift the ceiling? | 3 new bench points (steps × d × n_blocks) | ~14 hr |
| **3** | Distillation existence proof | Does 122B → Rail student bypass the ceiling? | 1 bench point on a distilled student | ~10 hr |

**Final deliverable end of Day 3:** the decision matrix at the bottom of
this prompt, filled in with real numbers + a single sentence verdict.

---

## ✅ Phase 0 — Check Day 1 status BEFORE any heavy operation

The v54 sweep may still be running. Heavy pre-flight (137/137,
self-compile) competes with the sweep for GPU and slows it. Lightweight
checks first; wait for sweep if it's still running; THEN do full
pre-flight.

1. `[ ]` `hostname` → `studio`. `cd ~/projects/rail`.
2. `[ ]` Day 1 status check (read-only, no GPU contention):
   - `pgrep -fl 'train_v54|run_v54_sweep'` — running or done?
   - `tail -3 /tmp/v54_sweep.log` — should show progress or
     `=== V54 SWEEP COMPLETE ===`
   - `grep -E 'spur_v54_BQ2_s(100|300|400|500)_post_fix' flywheel/bench_log.txt`
     — how many of the 4 seed benches landed?

3. **If sweep is still running** (any `pgrep` match): wait for completion
   via Monitor on the sweep log:
   ```
   Monitor:
     command:  tail -F /tmp/v54_sweep.log | grep -E --line-buffered '(SWEEP COMPLETE|DONE bench|loss=nan|panic)'
     description: v54 sweep waiting for completion
     timeout_ms: 3600000   # up to 1 hour per event
     persistent: true       # keep until you see SWEEP COMPLETE
   ```
   Do not run pre-flight or any other rail_native invocation while sweep
   is running. The sweep ETA from launch (2026-05-10 22:42 + ~14 hr paused
   + ~5.6 hr active train + ~3 hr bench) is around 2026-05-11 7-10 AM
   depending on resume time.

## ✅ Phase 1 — Full pre-flight (after sweep complete)

Sweep complete → safe to run heavy checks. Anything that fails halts the
session.

1. `[ ]` `git log --oneline -1` shows `f2ee298` or later on `next`.
2. `[ ]` `git status -sb` clean (sweep may leave untracked
   `tools/train/lm_v54_BQ2_s{100,300,400,500}.rail` forks — those are
   OK as untracked; don't commit them).
3. `[ ]` `./rail_native test 2>&1 | tail -1` reports `137/137 tests passed`.
4. `[ ]` `./rail_native self && cmp rail_native /tmp/rail_self && echo OK`
   prints `OK` (cycle-2 byte-identical).
5. `[ ]` `tail -6 flywheel/bench_log.txt` shows 4 new entries with tags
   `spur_v54_BQ2_s100_post_fix`, `s300`, `s400`, `s500` (or some subset
   if sweep was interrupted).
6. `[ ]` `grep -n 'default_corpus_path' tools/train/lm_infer_v3_mixed.rail`
   shows line 31 = `"training/rail_corpus_stdlib.txt"` (sweep restores
   this at end; flag if it doesn't).

All 6 pass → record Day-1 best seed for Day 2 + proceed.

---

## Required reading

1. `~/.claude/projects/-Users-user/memory/exhaust_studio_before_renting.md`
   — the strategic gate. The whole arc serves this directive.
2. `~/.claude/projects/-Users-user/memory/honest_rebench_2026-05-10.md`
   — yesterday's 10-bench baseline. Day 1 sweep adds 4 more v54-family
   points to this table.
3. `~/.claude/projects/-Users-user/memory/cpu_substrate_conditional_trigger_2026-05-10.md`
   — the compile.rail fix. Required context for "honest" vs "pre-fix."
4. `~/.claude/projects/-Users-user/memory/studio_panic_pattern.md` — Day 2
   has three training runs back-to-back. Don't stack with bench in
   parallel — the past panic pattern was bench × training.
5. `~/projects/rail/docs/plans/HANDOFF_PORTAL_TRAINING_CONCURRENT.md` —
   portal × training is the lower-risk stack (bursty traffic, not
   sustained). Day 2's experiments can run with portal serving live.
6. `~/projects/rail/docs/plans/BATCH32_TRAINER_DESIGN.md` — relevant ONLY
   if Day 2 single-axis scaling fails and we want a fallback experiment.

Code references:
- `tools/train/lm_v54_BQ2_s77.rail` — the v54 base trainer. All Day 2
  variants are 1-line forks of this.
- `tools/train/lm_infer_v3_mixed.rail` — inference gen for bench. Set
  `default_corpus_path` to back_quarter for v54-family benches.
- `/tmp/run_v54_sweep.sh` — Day 1's orchestrator. Pattern to fork for
  Day 2 if useful.

---

## Day 2 — Single-axis scaling (3 sequential experiments)

**Goal:** hold the v54_BQ2 recipe constant except for ONE knob; measure
whether that knob lifts the ceiling.

**Use the Day-1 best seed** (highest bench score from the 6-point sweep)
as the seed for all three Day-2 experiments. This isolates the variant
under test from seed-luck.

### Experiment A — Step scaling (max_steps 3000 → 6000)

Hypothesis: more training compounds. v54 stops at 3000 steps — maybe
3000 was a leftover from earlier convention, not an actual convergence
point.

Fork `lm_v54_BQ2_s<BEST>.rail` → `lm_v54_BQ2_s<BEST>_6k.rail`:
- Change `let max_steps = 3000` → `let max_steps = 6000` (in main, around
  line 970 in the v54 trainer)
- Change ckpt paths to use `_6k_step6000` suffix
- Change log paths

Train ~168 min (2× the v54 wall-clock). Bench ~45 min. Total ~3.5 hr.

**Expected if hypothesis holds:** val_loss < 3.0; bench ≥ 15/30.
**Expected if not:** val_loss plateau at v54's 3.19; bench ≈ 13/30.

### Experiment B — d_model scaling (d=256 → d=384)

Hypothesis: bigger d adds capacity that lifts the ceiling, IF the LR
schedule from v54 (peak 0.02, warmup 100) carries over. (Yesterday's
d=384 4-block used peak=0.005 / warmup=200 and plateaued at 3.5 —
that LR was the bottleneck, not the d.)

Fork `lm_v54_BQ2_s<BEST>.rail` → `lm_v54_BQ2_s<BEST>_d384.rail`:
- Change `let d = 256` → `let d = 384`
- Keep `let base_lr = 0.02`, `let warmup = 100`, `let max_steps = 3000`
- Change ckpt paths to use `_d384` suffix

Train ~120 min (1.5× wall-clock due to bigger matmuls). Bench ~45 min.
Total ~2.75 hr.

**Stop condition for B:** if loss NaN'd in first 100 steps, the LR is
still too high for d=384 — fall back to peak_lr=0.01 with warmup=200,
re-run. (Don't do peak_lr=0.005 — yesterday proved that's too slow.)

### Experiment C — Depth scaling (n_blocks 2 → 4)

Hypothesis: more layers add representation, IF training compute scales
with it.

Fork `lm_v54_BQ2_s<BEST>.rail` → `lm_v54_BQ2_s<BEST>_4block.rail`:
- Add 2 more blocks (block2, block3) to the mk_block + cast_block_to_half
  pattern around line 940-944
- Extend `blocks = cons block0 (cons block1 (cons block2 (cons block3 [])))`
- Extend the m_train_step adam updates for blocks 2 and 3 (lines 629-649
  pattern)
- Save/load weight count changes: 2 + 9*4 = 38 weights (vs 20 for 2-block)
- Keep d=256, peak_lr=0.02, warmup=100, max_steps=3000

This is the most invasive fork — ~30 lines of careful editing. Use the
existing `lm_v3_chunked_d256_4block_half_6k.rail` as the structural
reference for 4-block setup (NOT for hyperparams — those used d=256
which proved poor).

Train ~150 min. Bench ~45 min. Total ~3.25 hr.

### Day 2 ordering and budget

Sequential, ~10 hr total. Order: B → A → C (B is fastest, C is most
invasive — front-load the cheap experiments to catch early failures).

Append all 3 bench scores to `flywheel/bench_log.txt` with
`_post_fix_<axis>` tags.

---

## Day 3 — Distillation existence proof

**Goal:** prove (or refute) that the 122B teacher can lift a Rail student
above v54's ceiling.

This is the structural-lever test. If it works, the project's investment
priority pivots; if it doesn't, the ceiling is structural at the model
class, not just compute-deferred.

### Step 3a — Harvest 122B responses for the 30 bench prompts (1-2 hr)

The bench prompts are in `flywheel-local/bench_railnative_rerank.rail`
(bench_fund, bench_io, bench_tools, bench_comp, bench_adv, bench_comprehend).
Extract them. For each, send to the live 122B portal at
`http://10.42.0.2:8082/v1/chat/completions` with a Rail-spec system prompt
matching the substrate-thesis recipe (`substrate_30_of_30_2026-05-09.md`).

System prompt template:
```
You write Rail code only. Rail spec: <paste 1KB Rail spec>.
Output a complete program ending in `main = ...`. No prose, no markdown.
```

Save responses to `/tmp/distill_harvest/<prompt_id>.rail`. Compile each
with `./rail_native /tmp/distill_harvest/<prompt_id>.rail` — if it
compiles, keep it; otherwise discard.

Expected: 25-30 of 30 compile (matches the substrate 30/30 result).

### Step 3b — Build the distillation corpus

Concatenate the kept responses into a single training corpus:
```bash
cat /tmp/distill_harvest/*.rail > training/corpora/spur_distill_122b_30prompts.txt
```

Expected corpus size: 30 × ~500 chars = ~15 KB. That's TINY compared to
back_quarter (90 KB) — might be the limiting factor.

If <15 KB feels too small, expand: also harvest 50-100 grammar-walk
prompts (per `phase5h_assets.md`) the same way. Goal: 50-100 KB of
122B-generated Rail.

### Step 3c — Train a small Rail student

Fork `lm_v54_BQ2_s<BEST>.rail` → `lm_distill_122b_s99.rail`:
- Change `corpus_path` to the distill corpus path
- Keep d=256, 2-block, 3000 steps (proven v54 recipe — isolates the
  CORPUS as the variable)
- New ckpt path: `training/rail_native/checkpoints/spur_distill_122b_s99_best`

Train ~84 min. Bench ~45 min (with back_quarter corpus matching since
the distill corpus is also Rail). Total ~2.25 hr.

### Step 3d — Decision matrix synthesis (1 hr)

Fill in this table and write the verdict:

| Metric | v54 baseline | Day-1 best seed | Day-2 A (steps) | Day-2 B (d=384) | Day-2 C (4-block) | Day-3 distill |
|---|---:|---:|---:|---:|---:|---:|
| val_loss | 3.19 | ? | ? | ? | ? | ? |
| bench | 13/30 | ? | ? | ? | ? | ? |
| Δ vs v54 | 0 | ? | ? | ? | ? | ? |

**Then complete the decision matrix:**

| Day 1 spread | Day 2 best Δ | Day 3 Δ | Verdict |
|---|---|---|---|
| <3 | flat | flat | **Recipe ceiling — need new ideas, not compute or distill** |
| <3 | ≥+2 | — | **Compute is the lever — rack justified** |
| <3 | flat | ≥+2 | **Distillation is the lever — build pipeline first** |
| ≥+5 | — | — | **Ensemble routing is the cheap win — more seeds, no scale-up** |
| <3 | ≥+2 | ≥+2 | **Compose them — rack + distill pipeline** |

---

## Floor (don't break across 3 days)

- 137/137 green after each session
- Byte-identical self-compile (cycle ≥ 2)
- `default_corpus_path` = `training/rail_corpus_stdlib.txt` at end of each session
- No pre-fix numbers quoted as targets
- Every bench claim ties to a `flywheel/bench_log.txt` post-fix line
- v_full bisect regression: `BISECT x_embed[0]=0.020599365234375`

## STOP conditions (halt + write fresh handoff)

1. Pre-flight check fails — investigate compile.rail before any model work.
2. Day 1 sweep didn't complete — bench what's there, note the gap, proceed.
3. Day 2 NaN on first attempt — switch to fallback LR (B: 0.01, C: keep
   0.02 but warmup=200), don't burn the day on retunes.
4. Day 3 distillation harvest produces <10 compile-pass responses out of
   30 — the substrate-thesis is broken (re-check Studio MLX server,
   model identity, Rail spec) before training on a bad corpus.
5. Studio panic — kill all training, restart serial.

## Reusable commands

```bash
# Day 2 fork pattern (one-line replacements via sed)
cp tools/train/lm_v54_BQ2_s<BEST>.rail tools/train/lm_v54_BQ2_s<BEST>_<axis>.rail
sed -i '' "s|<old>|<new>|g" tools/train/lm_v54_BQ2_s<BEST>_<axis>.rail

# Train + bench cycle (the sweep script is the template — /tmp/run_v54_sweep.sh)
./rail_native tools/train/lm_v54_BQ2_s<BEST>_<axis>.rail
cp /tmp/rail_out /tmp/train_<tag>
DYLD_LIBRARY_PATH=tools/metal /tmp/train_<tag> > /tmp/<tag>_train.log 2>&1

# Bench (set default_corpus_path to back_quarter FIRST)
sed -i '' 's|^default_corpus_path = ".*"|default_corpus_path = "training/corpora/spur_compile_back_quarter.txt"|' tools/train/lm_infer_v3_mixed.rail
DYLD_LIBRARY_PATH=tools/metal /tmp/rail_bench_strip \
  --prefix training/rail_native/checkpoints/<ckpt> \
  --max 60 --k 10 --temp 0.8 \
  --tag <tag>_post_fix \
  --gen-source tools/train/lm_infer_v3_mixed.rail

# Restore stdlib default before commit
sed -i '' 's|^default_corpus_path = ".*"|default_corpus_path = "training/rail_corpus_stdlib.txt"|' tools/train/lm_infer_v3_mixed.rail

# Day 3 distillation harvest
curl -X POST http://10.42.0.2:8082/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mlx-community/Qwen3.5-122B-A10B-heretic-v2-2.34bit-msq",
       "messages":[{"role":"system","content":"<rail spec>"},
                   {"role":"user","content":"<bench prompt>"}],
       "max_tokens":600,"temperature":0.3}'
```

## What success looks like end of Day 3

- Decision matrix filled in with real numbers
- Verdict written in a memory entry titled `growth_determination_2026-05-13.md`
- All Day-2 and Day-3 ckpts logged in `flywheel/bench_log.txt`
- Stale memory entries marked SUPERSEDED if they conflict with the verdict
- Pushed to `origin/next`

## What to NOT do

- Don't change multiple axes at once in Day 2 — that defeats the
  single-axis isolation.
- Don't bench against the wrong corpus (V=93 → back_quarter; V=130 → stdlib).
- Don't quote pre-fix numbers as targets.
- Don't rent compute even if Day 2 looks great. The Day 3 distillation
  result might invert the decision — wait for the full matrix.
- Don't extend the 3-day budget. If a test is inconclusive, write the
  verdict as "inconclusive at this scale" and stop. The cost of more
  experimentation is greater than the cost of an honest "we don't know."
