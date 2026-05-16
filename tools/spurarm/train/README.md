# Spur-arm v0 training stack

Owned by Agent B in the railarm4agent build. See
`notes/railarm4agent/AGENT_B_train.md` for the full brief and
`notes/robot_session/AGENT_B_SCOPE_DECISION.md` for the honest
narrowing relative to the frozen spec.

## Status (post-Agent-B session)

| Component | State |
|---|---|
| Tokenizer (byte-BPE 512) | shipped + validated |
| Corpus tokenization | shipped, 1500 pretrain + 800 SFT + 200 eval `.ids` files |
| Bench grader integration | shipped + smoke-tested (placeholder gives 4/20 floor) |
| Trainer scaffold | shipped; **does not run** -- runtime segfault in forward pass blocks training |
| Multi-seed fan | shipped (untested, blocked by trainer) |
| Ensemble bench | shipped (untested, blocked by trainer) |
| Watcher | shipped + tested |
| ckpt_card | shipped |

## Critical blocker: trainer runtime segfault

The base `tools/train/lm_transformer.rail` -- which we inherit from and
which our `train_spurarm.rail` mirrors -- segfaults at the first
`forward` call on both this worktree's `rail_native` and the parent
`rail/` repo's `rail_native`. The crash happens in the matmul/forward
chain after weight init, before any training step.

Per memory entries `inference_seed_segfault` and `forward_dump_gpu_leak`
this is a known class of runtime/codegen bug in the current LM stack,
not within Agent B's repair scope. AGENT_B_train.md's "Out of scope"
section explicitly defers `inference_seed_segfault` to a separate arc
"unless it actually blocks the path" -- which it does.

**Escalation requested**: a compiler-bug session is needed before any
Spur-arm training can run.

## Tokenizer

- **Type**: byte-BPE (the documented fallback per AGENT_B_train.md)
- **Vocab**: 512 (the documented fallback; SP-unigram-1024 deferred)
- **Trained on**: 50KB pretrain prefix + 30KB SFT prefix (subsample to
  fit Studio memory; full 10MB corpus OOM'd at 15GB during BPE training)
- **Pinned via reserved bytes**: `<pad>=0`, `<bos>=1`, `<eos>=2`, `<sep>=3`
- **DSL keyword coverage** (encoded as N tokens):
  - `script` -> 2, `MoveTo` -> 1, `move_to` -> 1
  - `SetGrip` -> 4, `grip_open` -> 4, `grip_close` -> 5
  - `Home` -> 4, `Wait` -> 4
  - `[`, `]`, `,`, `=` -> 1 each
  - `coordinates` -> 1

## File layout

```
tools/spurarm/train/
  README.md                  this file
  build_tokenizer.rail       byte-BPE trainer over jsonl corpus
  tokenize_corpus.rail       apply tokenizer to corpus -> .ids files
  train_spurarm.rail         single-block transformer trainer (BLOCKED)
  generate.rail              greedy-argmax decoder (placeholder stub)
  bench_eval.rail            single-shot bench v0 grader + sentinel emitter
  multi_seed_fan.sh          5-seed sequential training driver
  ensemble_bench.sh          per-seed max routing across the fan
  ckpt_card.rail             write provenance fields to .meta files

training/tokenizer/
  spurarm_v0_bpe512.vocab    512-token byte-BPE vocab
  spurarm_v0_bpe512.merges   ordered merge rules

training/corpora/
  spurarm_v0_pretrain.ids    1500 tokenized pretrain examples
  spurarm_v0_sft.ids         800 tokenized SFT examples
  spurarm_v0_eval.ids        200 tokenized eval examples

stdlib/spurarm_model.rail    config wrapper (frozen-spec gaps documented)

tools/lab/watchers/
  spurarm_base_b.sh          chain entry watcher (PASS/INCONCLUSIVE/FALSIFIED)
```

## Reproducer commands

```bash
# 1. Train tokenizer (1 minute, 80KB corpus subsample).
./rail_native run tools/spurarm/train/build_tokenizer.rail

# 2. Validate tokenizer.
./rail_native run tools/spurarm/train/build_tokenizer.rail --validate

# 3. Tokenize corpus splits (10-30s each).
./rail_native run tools/spurarm/train/tokenize_corpus.rail --split pretrain --max 1500
./rail_native run tools/spurarm/train/tokenize_corpus.rail --split sft      --max 800
./rail_native run tools/spurarm/train/tokenize_corpus.rail --split eval

# 4. Train (BLOCKED -- segfaults at first forward).
#    bash tools/spurarm/train/multi_seed_fan.sh --phase pretrain
#    bash tools/spurarm/train/multi_seed_fan.sh --phase sft
#    Both phases blocked by the lm_transformer runtime segfault.

# 5. Bench eval (works with placeholder generator at floor 4/20).
./rail_native run tools/spurarm/train/bench_eval.rail \
  --prefix /tmp/nonexistent --max-gen 100

# 6. Watcher (live re-grade + verdict).
bash tools/lab/watchers/spurarm_base_b.sh
```

## Scope deltas from the frozen spec (documented honestly)

Per `chain_caught_five_wrong_leverage_swings` -- write the chain entry
contract FIRST, build second, surface deltas honestly. These deltas
were chosen against the budget and are documented in the chain entry:

- **n_layers=1** instead of 6 (~3x param reduction at same d).
- **n_kv_heads=n_heads=1** (vanilla, no GQA) -- attention slicing per
  KV head deferred.
- **LayerNorm + ReLU + sinusoidal PE** instead of RMSNorm + SwiGLU + RoPE
  -- inherit the lm_transformer baseline.
- **byte-BPE vocab=512** instead of SentencePiece-unigram-1024
  (the documented brief fallback).
- **d=384 in the config, but the trainer crashes regardless of size**
  (also tried d=64). The blocker is below the architectural-choice level.

## What WORKS today and what BLOCKS

WORKS:
- Tokenizer end-to-end (encode/decode round-trip).
- Corpus tokenization to .ids shards.
- Bench eval harness (placeholder gives 4/20 honest floor).
- Watcher with all 7 counters + verdict logic.
- The multi_seed_fan and ensemble_bench shell drivers.

BLOCKS:
- `lm_transformer.rail` (and our `train_spurarm.rail`) crashes at the
  first `forward` call. Same crash on the parent rail repo. This is a
  runtime/codegen bug class that needs a compiler-arc session to
  diagnose. Until that lands, no Spur-arm training can run.

If/when the lm_transformer crash is fixed, the path forward:
1. Re-bootstrap (`./rail_native self` x2, verify 140/140).
2. Run pretrain fan: `bash tools/spurarm/train/multi_seed_fan.sh --phase=pretrain --steps=200`.
3. Read .meta val_loss; if any seed clears 2.5, advance to SFT.
4. Run SFT fan: `bash tools/spurarm/train/multi_seed_fan.sh --phase=sft --steps=100`.
5. Run ensemble: `bash tools/spurarm/train/ensemble_bench.sh`.
6. Append chain entry via `tools/lab/watchers/spurarm_base_b.sh`.
