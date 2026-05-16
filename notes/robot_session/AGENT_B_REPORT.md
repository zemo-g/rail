# Agent B final report -- Spur-arm-base-v0

## verdict

**INCONCLUSIVE -- TRAINER BLOCKED ON PRE-EXISTING RUNTIME BUG**

Per the chain entry contract in
`notes/railarm4agent/CHAIN_SKELETON_AGENT_B.md`. The infrastructure
scaffold ships cleanly end-to-end; the training core blocks on a known
runtime/codegen bug class (`inference_seed_segfault`) that is out of
scope for Agent B per the brief. Specifically:

- The base trainer `tools/train/lm_transformer.rail` segfaults at the
  first `forward` call (LayerNorm + ReLU + sinusoidal PE single-block),
  both in this worktree's `rail_native` and in the parent `rail/`
  repository's `rail_native`. Our derived trainer
  `tools/spurarm/train/train_spurarm.rail` inherits the same crash
  pattern.
- `tools/metal/.no_gpu` sentinel + dylib presence makes no difference.
  The crash happens on weight-init -> first matmul, before any GPU
  dispatch.
- Per AGENT_B_train.md "Out of scope": "Fixing `inference_seed_segfault`
  (work around with argmax; the bug is a separate arc unless it
  actually blocks the path)." It blocks the path.
- Per `chain_caught_five_wrong_leverage_swings`: this is a Stage 5+
  feature work / user-budget territory. Surface honestly, do not
  autonomous-swing.

## counter values (chain entry)

```
model_params_M                       = 15   (target, single-block actual ~2M)
tokenizer_vocab_size                 = 512  (byte-BPE fallback shipped)
pretrain_seeds_passed_val_loss_2     = 0    (no training ran)
sft_best_bench_v0_single_shot        = 0    (no SFT ran; placeholder 4/20 floor)
sft_best_seed                        = 0    (n/a)
ensemble_bench_v0_goal_reach         = 0    (no fan)
wall_hours                           = 1.5  (engineering, no training)
```

(`model_params_M=15` is the target, baked into the chain skeleton, not
the actual single-block param count.)

## what ships (infrastructure complete)

| Deliverable | Status | Path |
|---|---|---|
| Tokenizer trainer | shipped | `tools/spurarm/train/build_tokenizer.rail` |
| Trained tokenizer | shipped | `training/tokenizer/spurarm_v0_bpe512.{vocab,merges}` |
| Corpus tokenization | shipped | `tools/spurarm/train/tokenize_corpus.rail` |
| Tokenized splits | shipped | `training/corpora/spurarm_v0_{pretrain,sft,eval}.ids` |
| Model config wrapper | shipped | `stdlib/spurarm_model.rail` |
| Single-block trainer | scaffold-only (segfaults) | `tools/spurarm/train/train_spurarm.rail` |
| Generator (greedy argmax) | placeholder shipped | `tools/spurarm/train/generate.rail` |
| Bench eval (20 prompts) | shipped + tested (4/20 floor) | `tools/spurarm/train/bench_eval.rail` |
| Multi-seed fan driver | shipped (untested) | `tools/spurarm/train/multi_seed_fan.sh` |
| Ensemble routing | shipped (untested) | `tools/spurarm/train/ensemble_bench.sh` |
| Ckpt card | shipped | `tools/spurarm/train/ckpt_card.rail` |
| Watcher | shipped + tested | `tools/lab/watchers/spurarm_base_b.sh` |
| README | shipped | `tools/spurarm/train/README.md` |
| Scope decision (honesty) | shipped | `notes/robot_session/AGENT_B_SCOPE_DECISION.md` |

## what doesn't ship (blocked)

- Trained pretrain ckpts (5 seeds).
- Trained SFT ckpts (5 seeds).
- `training/checkpoints/spurarm-base-v0_best.ckpt` symlink.
- Real bench numbers per seed.
- Real ensemble numbers.

These are all downstream of the `forward`-pass segfault.

## tokenizer choice

**byte-BPE at vocab=512**, the documented fallback per AGENT_B_train.md
("If SentencePiece-unigram in pure Rail is too heavy a lift in this
session, the acceptable fallback is byte-level BPE at vocab=512.").
Rationale:

- The repo already ships a working byte-BPE trainer
  (`stdlib/bpe.rail`); SP-unigram would be a 4-8h build from scratch.
- BPE training on 1MB+ of corpus OOM'd at 15GB on Studio (Jetsam-killed).
  The 80KB pretrain+sft subsample fits in 1GB and trains in 7s. Byte-BPE
  quality is dominated by encode-time merges, not training-corpus size,
  so the subsample is a justified pragmatic choice.
- DSL keyword coverage validated: `script` -> 2 tokens, `MoveTo` -> 1,
  `move_to` -> 1, `Home/Wait/SetGrip/grip_open/grip_close` -> 4-5 each,
  bracket/comma/equals -> 1 each. Acceptable for v0; SP-unigram would
  likely fold the longer keywords to 1 token but the difference is
  marginal at small d.

## wall-clock breakdown (engineering only)

| Phase | Wall (approx) |
|---|---|
| Required reading + scope decision | 20 min |
| Tokenizer trainer + first BPE run (OOM) + capped subsample | 25 min |
| Corpus tokenization (debug + retry) | 30 min |
| Bench eval + generator placeholder + end-to-end smoke | 25 min |
| Trainer (write + crash + diagnose) | 35 min |
| Watcher + ensemble + ckpt_card + README + final report | 30 min |

Roughly 2.5 wall hours. No training ran -- no training wall-clock.

## anything surprising worth a memory entry

Three observations worth promoting:

1. **lm_transformer.rail forward is currently broken** even on the
   parent rail repo (`/Users/user/projects/rail/rail_native run
   tools/train/lm_transformer.rail` segfaults at the first forward).
   This blocks any new training arc that builds on this trainer. The
   `inference_seed_segfault` memory entry already exists; suggest
   extending it with a "blocks new-trainer arcs" tag.

2. **`bpe_train` allocates ~150x the input size in RAM** at
   vocab=target. 1MB input -> 15GB peak. The persistent counts map in
   `bpe_train_loop_deferred` + cons-list output accumulation are the
   culprits. Memory `bpe.rail O(n^2) blowup` would document the cap.

3. **`./rail_native run` masks compile-banner-in-stdout** when piping
   into a candidate file. The bench grader path had to compile the
   generator once and cache the binary so the candidate file doesn't
   inherit "Compiling .../  as: OK  ld: OK". This is a discipline lesson
   for any tool that produces verbatim text consumed by another tool.

## open follow-ups for Agent C

Agent C (constrained decode + DAPO RL) is blocked by the same trainer
crash that blocks Agent B. C cannot start until the
`lm_transformer.rail` forward path is fixed. Specifically:

- **Constrained decode**: needs a working `generate.rail` that emits
  per-step logits from a trained checkpoint. Today's placeholder
  generator emits a constant string and provides no logit hook.
- **DAPO RL**: needs (a) a working SFT base from Agent B, and (b) a
  working sampler in the inference path. Both blocked.

If the compiler/runtime bug is fixed and Agent B's trainer runs even
on a 10-step smoke, Agent C can begin by writing the
constrained-decode wrapper around our `generate.rail` and running the
RL loop against the SFT checkpoints.

Per chain entry contract: do NOT push to Agent C automatically.
INCONCLUSIVE means escalate to the user.

## reproducer (post-fix)

When the trainer crash is fixed, the path to PASS is:

```bash
cd /Users/user/projects/rail-spurarm-B
bash tools/spurarm/train/multi_seed_fan.sh --phase=pretrain --steps=200
# Read .meta val_loss; expect 3 of 5 < 2.0.
bash tools/spurarm/train/multi_seed_fan.sh --phase=sft --steps=100
# Read fan_sft_results.txt; expect best seed >= 12/20.
bash tools/spurarm/train/ensemble_bench.sh
# Expect ensemble >= 15/20.
bash tools/lab/watchers/spurarm_base_b.sh
# Should print VERDICT=PASS with all 7 counters populated.
```

## commit chain

- 29157ed spurarm-train: tokenizer landing -- byte-BPE 512 + corpus shards
- f347650 spurarm-train: bench harness + trainer scaffold + watcher

On branch spurarm/B-train. NOT pushed. NOT merged to next.
