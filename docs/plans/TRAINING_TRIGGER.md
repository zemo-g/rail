# TRAINING_TRIGGER.md

Status: decision artifact · 2026-05-15

## The question

bf16 forward+backward 10k clean (eval 2.09, 2h04m), v5.1 JIT auto-emission adds 35× rmsnorm+QKV / 18× silu+hadamard fused kernels. Three weeks of training-adjacent substrate work (bf16 regime, GPU kernels, JIT pipeline, autograd validation) is bottled. **Either schedule a production training run that consumes it, or stop adding to the pile.**

## Minimum-viable bf16 production run

- **Architecture:** existing `tools/train/lm_transformer.rail` (no architectural change).
- **Regime:** all-bf16 forward + backward; f64 only on embed + LM-head (per `rail-bf16-stable-10k-2026-05-14.md`).
- **Corpus:** the v3 chunked corpus already in `rail-training/`. No new dataset work.
- **Length:** 100,000 steps. (10k was a smoke test; production = 100k+ to see eval converge below 2.0.)
- **Wallclock estimate:** ~20h on Studio at current per-step rate.
- **Eval gate:** every 10k steps against the v3 eval set. Strict target: eval ≤ 2.0 by step 100k.
- **JIT kernels:** enabled — the run is the validation that 35×/18× holds across 100k forward+backward steps without numerical drift.

## Invalidation criteria

- NaN anywhere before step 50k → bf16 regime isn't production-ready; revert and stop the pile.
- Eval ≥ 2.0 at step 100k → regime + GPU work delivered marginal gain at current architecture; stop adding training-support substrate, pivot to architecture (longer context, different attention, MoE) before more numerics work.
- Step rate > 1.5× the 10k smoke baseline → some kernel-fusion regression slipped in; debug and re-run before the production read.

## Verdict

**Schedule.** Concretely: next Studio window after the ledatic-arm MaxArm arrival on 2026-05-17 settles (target start 2026-05-20). Run is non-blocking on the arm work — Studio can host both if the arm bringup uses Mini for inference.

If Studio is genuinely unavailable for 20h continuous within 7 days of this doc's date, the verdict flips to "freeze training-support work" — the substrate has shipped, more substrate without a consumer is the asymmetry `feedback_build_not_sell.md` warns about reaching its limit.

## Confidence

Moderate. The bf16 + JIT stack is validated at 10k. The risk is non-numerical: Studio scheduling pressure, an arm-work emergency, or an undiscovered slow-drift bug between 10k and 100k. The 50k NaN gate catches the latter early.
