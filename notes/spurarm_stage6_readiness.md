# Spur-arm Stage 6 push — readiness draft

Authored 2026-05-17 at Stage 5 close. Stage 5 chain entries `1a4ba0f4`
(Cap A PASS), `3069abbe` (Cap B FALSIFIED), `ad65dd6c` (Cap C FALSIFIED).

## Stage 5 finding — restated

**val_loss is uncorrelated with bench at our training scale.** Every
configuration tested mode-collapses to a different degenerate attractor:

| Config | val_loss | bench | Attractor |
|---|---|---|---|
| d=64 / 200+100 / v0 corpus | ~11 | 3/20 | mixed |
| d=64 / 400+200 / v1 corpus | 4.64 | 3/20 | `script = [Home]` |
| d=128 / 1000 / v1 corpus + GPU | **3.49** | **0/20** | `script = [script = [...` |

Stage 5 caps (B sampling, C scaling) couldn't move bench. The cap is **structural** — architecture or loss formulation. Stage 6 must discriminate which, then fix it.

## The structural cap — three named candidates

### Cap D: architecture mismatch
Current spurarm: **LayerNorm + ReLU + sinusoidal-PE** (Agent B's scope-narrowed config). Spec called for **RMSNorm + SwiGLU + RoPE**. Hypothesis: sinusoidal-PE doesn't give attention enough positional signal, so the model context-collapses; RoPE would fix.

### Cap E: loss formulation / EOS signal
Current trainer: prompt-masked cross-entropy. If EOS never appears in loss (or appears so rarely the model never learns to emit it), the model has no termination signal — it spams continuation tokens forever. Hypothesis: EOS supervision is missing or weak.

### Cap F: decoding regularization
Current: pure greedy argmax (or top-k sample, neither works). No length penalty, no repetition penalty, no n-gram banning, no grammar constraint. Hypothesis: even if the model has reasonable next-token distributions, the decoding strategy lets it cycle on repetition.

## Free pre-Stage-6 probe — discriminates D vs E

**Inspect EOS probability across positions** on a v1 checkpoint. Trivial smoke:

```rail
-- Load seed 314 pretrain. Build prompt b10. Run forward. For each
-- generated step, log p(EOS) and p(argmax token). If p(EOS) is near 0
-- universally, the model never learned to stop — Cap E dominates.
-- If p(EOS) is reasonable but argmax always picks something else,
-- the cap is decoding (Cap F) or attention (Cap D).
```

Wall-clock: ~5 min. Decisively reroutes Stage 6.

**Pre-pre probe (one-liner):**

```bash
./rail_native run tools/spurarm/train/generate.rail \
  --prefix training/checkpoints/spurarm-base-v0_seed314_pretrain_final \
  --prompt "Move the arm to point A." --max 5 2>&1 | head -20
```

If `<EOS>` (token id 2) appears in the argmax output, model knows to terminate. If only repetition appears, terminator signal is broken.

## Pre-drafted kill_targets

### Cap D (architecture) — RoPE alone first

```
goal:        Stage 6 Cap D: RoPE replaces sinusoidal-PE; bench past 3/20
hypothesis:  Sinusoidal-PE in our single-block transformer doesn't supply
             enough positional resolution at sequence length 96, causing
             context-collapse. RoPE applied to Q,K (no other changes)
             lifts bench >= 4/20 single-seed at d=64 400+200 steps.
kill_target: PASS if best_bench >= 4/20. FALSIFIED if <= 3/20.
counters:    d_model, steps, best_val_loss_x100, best_bench, pe_kind
cmd:         tools/lab/watchers/spurarm_stage6_cap_d_rope.sh
parents:     ad65dd6c
```

Implementation cost: ~100 lines (RoPE rotation in attention), bootstrap
trainer + generate. Wall ~1 h engineering + 1 h training+bench.

### Cap E (loss/EOS) — verify EOS in loss first

```
goal:        Stage 6 Cap E: trainer includes EOS supervision; model emits EOS
hypothesis:  Current trainer masks the loss to script tokens only and the
             corpus may have inconsistent EOS placement. Adding explicit
             EOS supervision lifts the rate at which the model produces
             terminator tokens, escapes "spam prefix forever" collapse.
kill_target: PASS if (a) p(EOS at correct termination position) > 0.1
             on holdout AND (b) best_bench >= 4/20 retrain. FALSIFIED
             otherwise.
counters:    eos_prob_at_correct_pos_x1000, train_eos_token_count,
             best_val_loss_x100, best_bench
cmd:         tools/lab/watchers/spurarm_stage6_cap_e_eos.sh
parents:     ad65dd6c
```

Implementation cost: ~30 lines (loss-mask edits) + verify corpus EOS
placement. ~30 min engineering + ~20 min retrain.

### Cap F (decoding regularization) — no-repeat n-gram

```
goal:        Stage 6 Cap F: n-gram repetition penalty escapes collapse
hypothesis:  Current decoder lets the model emit "script = [script = [..."
             because nothing penalizes repetition. A simple no-repeat-3gram
             constraint plus length normalization unblocks ~3-4 prompts
             beyond argmax baseline.
kill_target: PASS if best_bench >= 4/20. FALSIFIED if <= 3/20.
counters:    no_repeat_n, length_penalty_x100, best_bench, baseline_bench
cmd:         tools/lab/watchers/spurarm_stage6_cap_f_norepeat.sh
parents:     ad65dd6c
```

Implementation cost: ~50 lines in generate.rail (track recent n-grams,
mask in sampling). Wall ~30 min total.

## Recommended Stage 6 order

1. **Free pre-probe FIRST.** ~5 min. Decisively names the cap. If model
   never emits EOS in argmax output, jump straight to Cap E (cheapest fix
   if confirmed). If EOS appears but bench fails for other reasons,
   Cap D or F.

2. **Cap F (decoding reg) is the cheapest swing.** ~30 min. Inference-only
   change, no retraining. If a no-repeat-3gram + length penalty pushes
   bench past 3/20, the cap is decoding and architecture is a separable
   future arc.

3. **Cap E (EOS) if F doesn't unblock.** ~50 min. Cheaper than D because
   it doesn't require new attention math.

4. **Cap D (RoPE) last.** ~2 h. Substantive engineering. Only do this
   after F + E are tested or known to be insufficient.

5. **Combined fix.** If individual caps each yield small improvement,
   try D+E+F together for the final Stage 6 PASS run.

## Dependencies

```
pre-probe ─────────► narrows D vs E vs F
                        │
Cap F (decode)  ←───────┤   independent
                        │
Cap E (loss)    ←───────┤   independent
                        │
Cap D (arch)    ←───────┘   most expensive

Final integration: D + E + F together if needed.
```

Cap A's GPU unblock (chain `1a4ba0f4`) accelerates D especially —
larger architectures need GPU.

## Honest priors

Best guess (subject to falsification by pre-probe):

- Cap E most likely: the spam-prefix collapse looks like a missing
  termination signal. If the model has been trained without EOS in the
  loss, it never learned to stop.
- Cap F second most likely: even with EOS signal, greedy decoding can
  cycle. A length penalty alone might push bench past 3/20.
- Cap D third: RoPE matters more at long context. At seq=96 the
  difference may be smaller than expected.

Prior strength: low. **The free pre-probe should run first.** Stage 5
caught wrong-leverage swing #7 by testing the wrong cap; don't repeat
the pattern.

## What "finishing B" honestly looks like at Stage 6

If Cap D OR E OR F lands bench >= 6/20 on a 5-seed fan:

- Spur-arm becomes a usable (if narrow) trained-model option for the
  substrate-replacement story
- The "own-model" half of the user's goal is delivered
- The arm side (Cap D for hardware) ships when MaxArm arrives

If all three caps FALSIFY:

- The architecture-spec gap is fundamental at single-block + 2M params
- Stage 7 would be 6L spec config + GPU + many more steps (~10K)
- That's multi-day budget; user decision

## Files that need editing (per cap)

| Cap | Files | LOC |
|---|---|---|
| D (RoPE) | `stdlib/transformer.rail` (attention QKV rotation) | ~80 |
| | `tools/spurarm/train/train_spurarm.rail` (forward) | ~20 |
| | `tools/spurarm/train/generate.rail` (decode forward) | ~20 |
| E (EOS) | `tools/spurarm/train/train_spurarm.rail` (loss mask) | ~30 |
| | possibly `tools/spurarm/train/tokenize_corpus.rail` (EOS append) | ~10 |
| F (no-repeat) | `tools/spurarm/train/generate.rail` (decode regularization) | ~50 |

Bootstrap impact: Cap D needs trainer + compile.rail-untouched recompile
across all 3 files. Cap E only train_spurarm.rail. Cap F only generate.rail.

## Pre-existing artifacts from Stage 5

- Cap A: `.no_gpu` removed; GPU verified. `tools/metal/libtensor_gpu.dylib` has absolute install_name.
- Cap B: `tools/spurarm/train/generate.rail` extended with `--sample/--top-k/--seed` flags. Default still argmax. Useful for Cap F.
- Cap C: `stdlib/spurarm_model.rail` reverted to d=64. d=128 attempt cleaned; v1 d=64 checkpoints intact.

## Quick decision rubric for next session

Run pre-probe. Then:

| Pre-probe shows | Then attempt |
|---|---|
| EOS never in argmax | Cap E (loss/EOS) first |
| EOS appears but argmax cycles | Cap F (decoding) first |
| Output looks fine but bench fails | Cap D (architecture) first |
| Inconclusive | Cap F (cheapest) |
