# Chain entry skeleton -- Agent B (tokenizer + base model + SFT)

Authored 2026-05-16 BEFORE Agent B swings, per memory
`chain_caught_five_wrong_leverage_swings`. ASCII only.

Parent: `66bb63f9` (substrate-thesis robot-arm baseline).

---

## goal

Train Spur-arm-base-v0: a ~15M-param pure-Rail transformer (6 layers,
d=384, 6 heads, GQA(2), vocab=1024, fp32) that maps NL prompts to Rail
robot-arm DSL scripts. Hit single-shot bench v0 >= 12/20 on best seed
and ensemble >= 15/20 across 5 seeds, with SFT initialized from a
2-phase pretrain on the v0 corpus (34576 pairs, 56% procedural, 24%
substrate-in-SFT).

## hypothesis

The two-phase recipe (pretrain on 29k paraphrase prior with masked
prompt loss, then SFT on 5k DSL-exact with bench-v0 gating) carries
enough signal from the corpus -- even with its 191-unique-script SFT
ceiling and procedural skew -- to lift a 15M model from 0/20 to >=12/20
on best seed and >=15/20 on ensemble. Argmax (k=1) decoding is used
throughout to dodge inference_seed_segfault.

## kill_target

Best single-shot bench v0 across all 5 seeds < 8/20 after SFT.

(That is the hard floor. <8 means either the architecture is too small,
the recipe is wrong, or the corpus is unfit. Closes as FALSIFIED with
named root cause -- escalate to user before scaling to d=512.)

Soft falsification (close as INCONCLUSIVE, do not push to Agent C):
- Phase 1 acceptance fails: fewer than 3 of 5 seeds drop val_loss < 2.0.
- Phase 2 acceptance fails: no seed hits >=12/20 single-shot.
- Tokenizer falls back to byte-BPE (acceptable but document in entry).
- inference_seed_segfault blocks eval entirely, even with argmax.

## counters

- model_params_M                       -- target == 15 (config-frozen)
- tokenizer_vocab_size                 -- target == 1024 (or 512 if byte-BPE fallback)
- pretrain_seeds_passed_val_loss_2     -- target >= 3 of 5
- sft_best_bench_v0_single_shot        -- target >= 12 (PASS) / >= 8 (not FALSIFIED)
- sft_best_seed                        -- which seed produced the best
- ensemble_bench_v0_goal_reach         -- target >= 15
- wall_hours                           -- observability; honest reporting

## cmd

bash tools/lab/watchers/spurarm_base_b.sh

(Agent B authors the watcher. It must reload the best ckpt and re-run
bench_eval.rail live -- not read a cached score -- to keep the verdict
empirical, mirroring Agent A's sample_grader_check pattern.)

## parent

66bb63f9  -- substrate-thesis robot-arm baseline (substrate hit 20/20
              at N=20 rerank; this agent must beat the 0/20 untrained
              floor by a wide margin to be useful, but is allowed to
              be below substrate's ceiling).

## verdict resolution

- PASS         -- pretrain >=3/5 seeds val_loss <2, SFT best >=12/20,
                  ensemble >=15/20. Tokenizer at vocab 1024 (or
                  documented byte-BPE 512). Reproducer clean.
- INCONCLUSIVE -- recipe progressed but didn't hit ensemble 15/20;
                  best single-shot somewhere in [8, 12). Agent C may
                  still be useful (RL may close the gap), but caller
                  must mark this clearly. Do NOT push to Agent C
                  automatically -- escalate to user.
- FALSIFIED    -- best <8/20. Recipe / size / corpus is wrong. Escalate
                  before scaling.

## non-negotiables baked into the swing

- Pure Rail end-to-end. Use stdlib/transformer.rail + autograd + optim
  + checkpoint + bpe. Extend, don't replace. No Python in the runtime.
- Argmax decoding only during eval (k=1). inference_seed_segfault
  memory: --max 128 --k 10 crashes ~50% of seeds on the current
  inference path. Workaround is in-spec.
- Don't stack training with Agent C or any other heavy workload --
  studio_panic_pattern. B runs solo on Studio GPU.
- DSL (stdlib/robot_arm.rail), sim (tools/robot/arm_sim.rail), and
  grader (tools/robot/grader.rail) are FROZEN. Do not edit them. If a
  bug surfaces, file a note and ship around it.
- Counter-discipline: write bench_eval.rail FIRST, run on random
  weights, expect ~0/20, THEN start training. Per
  feedback_diagnostics_first.
- Bootstrap discipline: if you touch stdlib/transformer.rail or
  runtime files, 2-cycle rebootstrap + verify 140/140 BEFORE training.
- Honest val_loss tracking: read .meta val_loss before benching every
  time. val_loss_underread + oracle_metric_gotcha both apply.

## corpus quality acknowledgement (read before training)

The corpus Agent B consumes (training/corpora/spurarm_v0.jsonl) has
known limitations the user has accepted as the v0 starting state:

- 56% procedural (template-generated NL+script pairs).
- Only 191 unique scripts across 5000 SFT pairs (~26 NL paraphrases
  per script).
- VH/ALFRED kept navigation-only (Grab/Pickup remap dropped because it
  faulted in object-less worlds). No pick-and-place from those sources.
- Substrate is 4% of total, 24% of SFT. Linguistic-paraphrase diversity
  is mostly from procedural templates, not substrate-rephrasing.

This is the corpus -- do not try to fix Agent A's pipeline. If bench
hits a hard ceiling that traces back to corpus diversity, surface it
honestly as INCONCLUSIVE with a recipe-or-corpus diagnostic, not as a
FALSIFIED model.
