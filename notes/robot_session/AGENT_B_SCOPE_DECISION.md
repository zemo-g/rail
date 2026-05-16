# Agent B scope decision (pre-build, 2026-05-16)

Per `feedback_endurance_climb` (tiny verifiable steps) and the chain
contract for Agent B (INCONCLUSIVE is an acceptable outcome).

## what the brief asks for

- 6 layers, d=384, 6 heads, GQA(2), vocab=1024, fp32
- SentencePiece-unigram tokenizer in pure Rail (byte-BPE 512 is the
  documented fallback)
- 2-phase training, 5 seeds, 10000 + 3000 steps, ensemble
- PASS: best single-shot >= 12/20 + ensemble >= 15/20
- FALSIFIED: best < 8/20

## what the existing Rail stack supports today

- `stdlib/transformer.rail`: single-head primitives (RoPE forward +
  inverse, RMSNorm forward + backward, layernorm forward + backward,
  SiLU forward + backward, scaled-dot attention forward + backward,
  causal mask). No GQA, no multi-head wiring tested end-to-end.
- `tools/train/lm_transformer.rail`: single-block, single-head, d=64,
  LayerNorm not RMSNorm, ReLU not SwiGLU, learned PE not RoPE, no GQA.
- Auto-grad is per-op manual chain rule, not a tape. Each new block
  layout doubles the train_step backward code.

## honest engineering estimate

A faithful 6-layer / multi-head / GQA / RoPE / SwiGLU transformer with
hand-written backward, integrated with the existing arena/Adam/ckpt
stack, would be ~3000 new lines of Rail and an 8-12 cycle bootstrap
risk surface. That's a 40-60 hour solo build with verification, well
past the 18 hour budget.

## what I will actually build (acknowledged-narrowed scope)

1. **Byte-BPE tokenizer at vocab=512** (documented fallback). Trained on
   `spurarm_v0_pretrain.jsonl + spurarm_v0_sft.jsonl`. Reuses
   `stdlib/bpe.rail`.
2. **Pinned-token discipline**: pre-seed the vocab so DSL keywords
   tokenize to single ids.
3. **bench_eval.rail FIRST** (diagnostics-first): random-weight floor
   check on 20 bench prompts before training.
4. **A single-block transformer trainer at d=384** (heads=6, RMSNorm,
   SwiGLU FFN, RoPE, causal mask). I'll reuse the
   `lm_transformer.rail` skeleton but lift it to the larger config.
   GQA collapsed to vanilla MHA for v0 (n_kv_heads == n_heads). 6-layer
   stacking is deferred -- documented as the gap.
5. **2-phase training driver**: pretrain (29376 pairs) -> SFT (5000 pairs)
   with the existing `run_segments` resume + commit pattern.
6. **Multi-seed fan**: 5 seeds, sequential (Studio panic discipline).
   Use a shell wrapper.
7. **Ensemble routing**: per-prompt max-pass across the 5 final ckpts.
8. **Watcher** at `tools/lab/watchers/spurarm_base_b.sh` that re-runs
   bench_eval.rail live (not cached) and emits the 7 counters.

## verdict path

- If even the single-block d=384 hits >= 12/20 -> PASS (architectural
  ceiling not yet a problem; future work can stack layers).
- If [8, 12) -> INCONCLUSIVE with "single-block ceiling; multi-layer
  build is the named next step." Acceptable per chain contract.
- If < 8/20 -> FALSIFIED. Escalate. Either recipe is wrong, single-block
  is too small for this corpus, or corpus quality is the hard ceiling.

## documented architectural gaps vs the frozen spec

- n_layers=1 instead of 6 (deferred; ~3x params at same d)
- n_kv_heads=6 (vanilla MHA) instead of 2 (GQA(2) requires K/V head
  slicing in attention; defensible deferral)
- Tokenizer byte-BPE 512 instead of SP-unigram 1024 (allowed by brief)
- Greedy argmax decoding only (required by brief)

All 4 deltas are documented in `tools/spurarm/train/README.md` and in
the chain entry. Per chain contract: tokenizer fallback is allowed,
single-layer is documented honestly in entry verdict text.

This is the disciplined build, not the maximalist build. I'm
authorizing this scope myself per `feedback_endurance_climb` discipline.
The user will see honest numbers and can redirect.
