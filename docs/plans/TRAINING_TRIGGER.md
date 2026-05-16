# TRAINING_TRIGGER.md

Status: revised decision artifact · 2026-05-15 (calendar verdict) → 2026-05-16 (freeze-rule revision)

## Why this doc was rewritten

The 2026-05-15 verdict scheduled training restart for 2026-05-20 on calendar grounds. **The /lab chain genesis entry, recorded 2026-05-16 11:26 UTC on Studio, supersedes calendar gating.** The freeze is now evidence-based: training resumes only when a Spur checkpoint beats `substrate=30/30` on at least one of the 6 hard-bench-v3 bands within a 30-day window (closes 2026-06-15).

`days_elapsed_in_window` ticks autonomously; `max_band_delta` is `-17` at genesis (Spur best = 13/30 vs substrate ceiling = 30/30). The freeze enforces evidence-over-vibes — same discipline `feedback_build_not_sell.md` argues for at the strategy layer, now operational at the artifact layer.

See [[lab_chain]] for the chain location, schema, and how `run.rail`'s `put-goal` makes the freeze testable.

## The probe (replaces the prior "minimum-viable production run")

The bf16 + v5.1 JIT + v5 substrate stack is the candidate that justifies a freeze-falsification attempt. Frame the run *as* the probe rather than as a generic training restart.

```text
goal:        Test whether bf16 regime + v5.1 JIT fused kernels + v5
             self-hosted toolchain raise Spur's best per-band
             compile_rate above substrate=30/30 on at least one
             hard-bench-v3 band within the freeze window.

hypothesis:  Training the Spur LM under all-bf16 forward+backward
             (f64 only on embed + LM-head), with JIT auto-emission
             enabled for rmsnorm+QKV and silu+hadamard fused kernels,
             on the v3 chunked corpus, for 100k steps, then running
             the existing Spur harvest pipeline, will produce a
             checkpoint whose hard-bench-v3 measurement scores >= 30
             on at least one band.

kill_target: If after 100k LM-training steps + full Spur harvest the
             checkpoint scores < 30 on every band, the freeze holds
             with stronger evidence (substrate quality changes don't
             rescue the Spur gap). Capacity redirects to JIT v3
             (currently INCONCLUSIVE at 72% lower_hit_rate — /lab
             record #4) and architectural changes (longer context,
             different attention, MoE) become the next-frontier
             question.

counters:    spur_best_compile_rate            (out of 30)
             substrate_compile_rate            (30, control)
             max_band_delta                    (signed; positive = freeze falsified)
             best_band_name                    (which of 6 bands held the win)
             lm_train_wallclock_hours          (instrument the regime cost)
             lm_train_final_eval_loss
             lm_train_nan_step                 (-1 if no NaN; positive = numerics gate)
             lm_step_rate_steps_per_sec        (for the 1.5× kernel-fusion regression gate)

cmd:         tools/train/launch_spur_bf16_v5_probe.sh
             (TO BE DRAFTED on Studio — wraps existing
              tools/train/_pilot_jit.rail-style LM training, then
              tools/train/spur_harvest.py, then
              tools/bench/substrate_hard_bench.rail bench, then
              emits sentinel-delimited counter values + verdict to
              stdout per tools/lab/specs/run.spec.md §4-§5.)
```

## Invalidation criteria (instrument these as counter gates)

These predate the freeze framing; preserved because they catch numerics issues earlier than the band-delta check.

- **NaN before step 50k** → `lm_train_nan_step < 50000 && > 0`. Stop the run; verdict FALSIFIED with `runner_error="bf16_unstable_at_step_<N>"`.
- **Step rate > 1.5× the 10k smoke baseline** → kernel-fusion regression. Verdict INCONCLUSIVE; debug then re-fire.
- **Final eval ≥ 2.0** at step 100k → marginal LM quality gain; doesn't preclude band-delta success but signals architecture-tier change is the higher-leverage next move.

Numerics gates run BEFORE the harvest+bench. Save 18+ wallclock hours if the LM training fails the bf16 stability test first.

## How to fire (Studio)

```bash
ssh studio
cd ~/projects/rail
./rail_native run tools/lab/run.rail put-goal \
  "Test bf16+JIT+v5 Spur checkpoint vs substrate=30/30" \
  --kill="max_band_delta <= 0 at end of run" \
  --counters="spur_best_compile_rate,substrate_compile_rate,max_band_delta,best_band_name,lm_train_wallclock_hours,lm_train_final_eval_loss,lm_train_nan_step,lm_step_rate_steps_per_sec" \
  --cmd="tools/train/launch_spur_bf16_v5_probe.sh" \
  --timeout=86400 \
  --hypothesis="bf16 + JIT auto-emission + v5 toolchain raise per-band Spur compile rate to match substrate ceiling on ≥1 band" \
  --parents=<genesis-entry-id-prefix>
```

`run.rail` handles the signing + chain append; the cmd is responsible for executing the full pipeline and emitting counter+verdict sentinels. Wallclock budget: 20h LM train + 1–3h harvest + bench. Set `--timeout=86400` (24h ceiling, the spec's max).

## Confidence

Moderate-to-low. bf16 numerical stability is validated to 10k forward+backward; extrapolation to 100k is the open risk. The harder unknown is whether *substrate quality changes* (better LM, faster kernels) translate to *Spur output gains* on any single band — the freeze hypothesizes they don't. The probe's job is to prove that one way or another with a signed entry on the chain.

## Cross-references

- [[lab_chain]] — the chain primitive + current state (6 entries, genesis = freeze)
- [[rail-bf16-stable-10k-2026-05-14]] — bf16 evidence base
- [[rail-jit-fused-kernels-plan]] — 35× / 18× kernel speedups
- [[rail-post-v5.1.0-cleanup-shipped]] — v5 substrate
- [[feedback_build_not_sell]] — the policy this artifact operationalizes
