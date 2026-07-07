# rail-gpt — session handoff (2026-07-07)

Branch **`feat/rail-gpt-unify`** (off `feat/attested-int-gpu-kernels`/PR#41 @ 09aed3a).
29 commits this session. Working tree clean. **Local-only — not pushed to any remote.**

## What this is
The unified Rail GPT: one GPT-2 spine (the owned 138M, `~/.ledatic/railml-trial/canonical_bestpass.safetensors`),
CPU + GPU backends (both bit-exact), full attested training, bf16 scaling, one CLI. Built by
consolidating four scattered efforts (inference engine, trainer, kernels, attestation) into one stack.

## Run it (`tools/gpt/rail_gpt.rail` -> compile -> `rail-gpt <verb>`)
```
cd ~/projects/rail-gpt-unify && ./rail_native --out-prefix /tmp/railgpt tools/gpt/rail_gpt.rail
/tmp/railgpt generate --prompt "def reverse(xs):"   # tokenize->GPU gen->detok, coherent Rail (pure Rail)
/tmp/railgpt generate                                # 40% top-1 next-token on real corpus (6500x chance)
/tmp/railgpt infer                                   # owned 138M forward -> argmax 5836
/tmp/railgpt verify --ledger <jsonl>                 # hash-chain tamper check (real)
/tmp/railgpt train / eval / help
```
GPU runners need `RAIL_ARENA_MB=8000` and compile-to-binary (not `run`).

## Key artifacts (all under tools/gpt/ + stdlib/gpt/)
- **Forward**: `stdlib/gpt/gpt_{fx,ln,mlp,attn,forward}.rail` (CPU twins) ; `gp_forward_gpu`-in `tools/gpt/gp_forward_gpu.rail` (GPU). Both -> argmax 5836.
- **Training**: `gpt_backward.rail` (all bwd twins) ; `gpt_tiny_train_all.rail` (every param, CE->0). Real-scale = `tools/metal/attested_train_minibatch.rail` (B=8, converges, mean CE 3.31->7e-6, `RAIL_ARENA_MB=10500`).
- **Attestation**: `gpt_attest.rail` (signed hash-chain ledger, correspondence, tamper-evident, Ed25519).
- **bf16 scaling**: `gp_bf16.rail` (codec) ; bf16 matmuls in `gpt_fx.rail` ; `gp_138m_bf16.rail` (bf16-weight 138M -> 5836). Weights+opt 4x each: 4B ~96GB->~24GB (fits Studio 58GB).
- **Working model**: `gp_generate.rail` (corpus accuracy) ; `gp_talk.rail` (free-gen) ; `tok.rail` (pure-Rail 16k BPE, bit-identical to Python).
- **Cross-device**: `xdev_fused.rail` + `xdev_all.rail` -> ALL fx kernels byte-identical Mini(M4Pro)==Studio(M1U). Unblocks fleet sharding Phase 0.5.

## Verify everything still works
```
for t in gpt_twins_test gpt_backward_test gpt_train_test gp_bf16_test gp_bf16w_test gpt_bf16_adam_test; do
  ./rail_native --out-prefix /tmp/v tools/gpt/$t.rail >/dev/null 2>&1 && /tmp/v 2>/dev/null | tail -1; done
```

## Remaining (all bounded, none envelope-pushing)
- witness / export verbs are scaffolds (mode-B port ; multi-tensor safetensors writer).
- Wire the attested ledger into the unified model trainer (proven on optimizer loop + mode-A engine, not fused into gp_).
- Optional: push branch to a remote to make it durable off this machine.

## Rail traps earned (see memory rail-gpt-unification-2026-07-06 + rail-traps-index)
imports NOT transitive (only direct-import symbols referenceable; self-contained runners) · no import dedup (linear chain) · `.Learly` early-return label collides across `if <cmp> then <const>` fns · high-arity self-loop w/ strings SIGSEGVs (bundle to `st`) · 2^62 literal unrepresentable · deep cons/if nesting parse-fails · `arr_get` on a list segfaults · /tmp source files break transitive imports.

Full detail: memory `rail-gpt-unification-2026-07-06.md`.
