# Model master session — 2026-04-30 night

You are picking up Spur model work after a substrate-correctness session. The instrument is now trusted. The numbers are real. **Tonight's job is to pull the actual model lever, not chase another substrate ghost.**

## Read first (in order)

1. `docs/MODEL_SESSION_HANDOFF.md` — the morning handoff that re-validated everything.
2. `docs/SPUR_HANDOFF_2026-04-30.md` — engineering substrate state.
3. `~/.claude/projects/-Users-user/memory/dylib_investigation_2026-04-30.md` — closes the GPU-bug rabbit hole.
4. `~/.claude/projects/-Users-user/memory/parallel_rerank_works.md` — N=20 bench is now ~13–25 min wall, not hours.
5. `~/.claude/projects/-Users-user/memory/compile_loss_scaffolding.md` — the lever you're going to pull.

## Ground truth as of this evening's rebench

5-ckpt canonical bench (N=20 parallel rerank, `lm_infer_cpu.rail`, --max 64 --k 10 --temp 0.8):

| Ckpt | Pass | Total quality |
|---|---|---|
| Spur-0.1 | **1/30** | 39,054 |
| Spur-Fix v0.2 | 0/30 | 40,079 |
| Spur-Fix v0.3 | 0/30 | 39,954 |
| Spur-v0.7 BEST (d=384) | 0/30 | 38,685 |
| Spur-v0.9-ascii | 0/30 | **test-config bug** (vocab mismatch — needs `lm_infer_cpu_ascii` binary) |

**The historical "Spur-0.1 25/30 at N=20" does not reproduce post-fix.** Today: 1/30. Either GPU fp16 numerics gave favorable argmax tie-breaks, or the historical claim was substrate-confounded. Either way, **don't anchor to it as the target**.

**Real ceiling at this scale (d=256–384, 1.74–3.89M params, 540 KB stdlib corpus, 3000 steps):** ~0–1/30 single-pass / N=20 rerank. **Capacity, min-ckpt, corpus cleanup, mixed-precision — all tried, all flat.** Quality scores cluster at 39–40k; passes are dice rolls.

## What to do tonight

### P0: Validate the v0.9-ascii test-config bug (10 min)

The v0.9-ascii ckpt was benched with the wrong inference binary (orig vocab, not ASCII vocab). Re-bench properly:

```bash
cd ~/projects/rail
./rail_native tools/train/lm_infer_cpu_ascii.rail >/dev/null 2>&1
cp /tmp/rail_out /tmp/rail_bench_rn_gen
codesign --sign - --force /tmp/rail_bench_rn_gen
./rail_native run flywheel-local/bench_railnative_rerank.rail \
    --prefix training/rail_native/checkpoints/d256_half_ascii_step3000 \
    --max 64 --k 10 --temp 0.8 2>&1 | tee /tmp/v09_proper.log
```

If still 0/30, UTF-8 cleanup didn't help compile rate (only ASCII-output rate, which is 100% by construction). If 1+/30, document the lift and move on.

### P0.5: Bench the v0.5 distill ckpt (10 min)

`spur_v05_distill_step3000` was trained on the 47-program teacher distill corpus and was NOT in tonight's rebench. Quality may differ:

```bash
./rail_native run flywheel-local/bench_railnative_rerank.rail \
    --prefix training/rail_native/checkpoints/spur_v05_distill_step3000 \
    --max 64 --k 10 --temp 0.8 2>&1 | tee /tmp/v05_rebench.log
```

If quality > 40k or pass > 1/30, the distill data shape mattered. Worth knowing.

### P1: Wire compile-loss-during-training (the actual lever) (~3–6 hr scope)

Per `compile_loss_scaffolding.md`: scaffolding shipped 2026-04-29 (`tools/train/rollout_harvest.sh` + `docs/plans/COMPILE_LOSS_DESIGN.md`); trainer integration deferred. **This is the lever no other has touched** — every "negative" recipe so far trained on a fixed corpus and bench-tested at the end. This trains with bench signal in the loop.

**Starting point:** fork `tools/train/lm_v07_d384_minckpt.rail` → `lm_v08_d256_compile_loss.rail`.

**Architecture choice:** stay at d=256 × 2-block × 3000 steps (matches Spur-0.1 baseline; one variable at a time). v0.7 d=384 didn't help; bigger isn't the lever.

**Integration shape (per the design doc):**
1. After every K=200 train steps, pause optimizer.
2. Invoke `tools/train/rollout_harvest.sh` with current weights → harvest M=20 compiling rollouts (can use `parallel_rerank.sh` infra for ~25s wall).
3. Append survivors to a "compile_corpus" buffer (capped at ~doubling original corpus size to avoid drift).
4. Resume training. Sample chunks from BOTH original corpus + compile_corpus with mixing ratio ~0.7/0.3.
5. Save min-ckpt at each new low val_loss.

**Success criteria for tonight's run:**
- Bench shows pass rate ≥ 2/30 → compile-loss is a real lever, scale the experiment.
- Bench shows ≥ 1/30 + meaningful quality bump (> 42k) → directionally promising, refine.
- Bench shows 0–1/30 + flat quality → compile-loss alone insufficient at this scale; document and move to corpus expansion.

### P2 (only if P1 ships and shows movement): Run a longer/bigger corpus variant

If P1 lifts the bench, the natural next experiment is corpus expansion. The 27B Claude-distill teacher is gone (per `next_session_pointer.md`). Options:
- Attempt to restore the 27B model (Mini? Time Machine? external drive?)
- Smoke-test gemma-4-31b as a substitute teacher (~30 min, can produce ~50 programs)
- Use Spur's own outputs from the compile-loss harvest as a second-order distill (self-bootstrapping)

**Don't start P2 if P1 is flat.** The corpus is downstream of the training-signal lever.

## What NOT to do tonight

- **Don't** chase substrate bugs further. The substrate is sound: TCO fixed, dylib investigation closed, parallel rerank works, mixed-precision landed. Per `feedback_diagnostics_first.md`: ship the counter, watch it move.
- **Don't** retrain a "cleaner corpus" or "different sampling temperature" variant. Those levers are exhausted.
- **Don't** anchor to the historical 25/30 number. It's a substrate artifact. Today's 1/30 at N=20 is the real baseline.
- **Don't** invest in a v0.10 ASCII variant with min-ckpt without first knowing P0's outcome. v0.9-ascii's bench was config-broken; resolve that before assuming corpus cleanup is dead.
- **Don't** skip the rebench config: pre-compile + codesign the inference binary BEFORE invoking the bench. The bench's gen_script races with concurrent oracle compiles and silently produces broken binaries (caused tonight's first false-zero).

## Operating discipline

- Use `/tmp/rebench_all.sh` (already on disk) as the bench harness template. It pre-stages the binary, so the gen_script race can't bite.
- Use `tools/train/parallel_rerank.sh` for any standalone N>1 sample collection. Validated 7× wall at N=8.
- Inference binary path mismatch is silent — vocab size embedded in the ckpt manifest must match the corpus the inference binary was compiled with. **One inference binary per corpus**, not per ckpt.
- Read `.meta` for `best_val_loss` BEFORE benching. If it's > 3.5, model is undertrained; bench will be flat regardless of recipe.

## Memory entries to update at end of session

- `compile_loss_scaffolding.md` → add result of P1 trainer integration (shipped / deferred / blocked).
- New memory if P1 shows movement: `compile_loss_lever_works.md` (or `compile_loss_lever_falsified.md`).
- `next_session_pointer.md` — replace tonight's pointer with EOD state.

## Concrete starter commands

```bash
# Verify substrate
./rail_native quick                                          # ~30 sec, must be 15/15
./rail_native run /tmp/tco_test.rail 2>&1 | tail -1          # must print 100, not garbage

# P0: v0.9-ascii proper bench (10 min)
./rail_native tools/train/lm_infer_cpu_ascii.rail >/dev/null && \
  cp /tmp/rail_out /tmp/rail_bench_rn_gen && \
  codesign --sign - --force /tmp/rail_bench_rn_gen && \
  ./rail_native run flywheel-local/bench_railnative_rerank.rail \
    --prefix training/rail_native/checkpoints/d256_half_ascii_step3000 \
    --max 64 --k 10 --temp 0.8 2>&1 | tee /tmp/v09_proper.log

# P0.5: v0.5 distill bench (10 min)
./rail_native tools/train/lm_infer_cpu.rail >/dev/null && \
  cp /tmp/rail_out /tmp/rail_bench_rn_gen && \
  codesign --sign - --force /tmp/rail_bench_rn_gen && \
  ./rail_native run flywheel-local/bench_railnative_rerank.rail \
    --prefix training/rail_native/checkpoints/spur_v05_distill_step3000 \
    --max 64 --k 10 --temp 0.8 2>&1 | tee /tmp/v05_rebench.log

# P1: scope compile-loss training integration
cat docs/plans/COMPILE_LOSS_DESIGN.md
ls tools/train/rollout_harvest.sh tools/train/lm_v07_d384_minckpt.rail
# Then build lm_v08_d256_compile_loss.rail per the design doc
```

## Single-line reproducer for the rebench (memorize)

```bash
./rail_native tools/train/lm_infer_cpu.rail >/dev/null && cp /tmp/rail_out /tmp/rail_bench_rn_gen && codesign --sign - --force /tmp/rail_bench_rn_gen && ./rail_native run flywheel-local/bench_railnative_rerank.rail --prefix <CKPT> --max 64 --k 10 --temp 0.8
```

Wall: ~25 min per ckpt at N=20.

## The frame

The substrate is no longer the variable. Capacity isn't the variable. Corpus cleanup isn't the variable. **The variable is whether training-time compile signal moves the bench needle.** That experiment hasn't been run. Tonight is when it gets run.

If it works, you have the path forward. If it doesn't, you've earned the right to say "Spur at this scale tops out at 0–1/30 N=20 rerank" with the receipts.
