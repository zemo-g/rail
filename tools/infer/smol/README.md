# SmolLM2-135M, and checking what it says in one pass

A public language model ([HuggingFaceTB/SmolLM2-135M](https://huggingface.co/HuggingFaceTB/SmolLM2-135M),
`model.safetensors` sha256 `80521b40281d6ce74e35c9282c22539e75aa0ac8578892b2a59955ef78d55da1`)
running on Metal kernels written in Rail, and a verifier that checks a generated transcript
**exactly, in a single forward pass**, on a different GPU from the one that produced it.

## The claim

A producer generates text the usual way: prefill the prompt, then decode one token at a time
against a KV cache. For every token it records the token and an FNV-64 fingerprint of the
full 49,152-wide row of logits it was chosen from.

A verifier takes the prompt and the claimed tokens and runs **one** forward pass over all of
them. For every position it must get back the same greedy token and the same fingerprint of
the same 49,152 logits. Not approximately: bit for bit. A single altered token is caught at
its exact index.

That is possible because of one property the engine is built around: **a row's arithmetic does not depend on the pass it rides in.** Decoding one
token, prefilling eight, or scoring all 248 at once gives the same bits for every row, in the
logits and in every layer's K/V cache. Common inference stacks typically run prefill and
decode through different kernels, batch shapes and reduction splits, so re-scoring a
transcript there can confirm it only to within a tolerance (not measured here). In this
engine there is no tolerance to choose.

## Measured (2026-09-22)

| | Mac mini, M4 Pro, macOS 26.3 | MacBook Air, M1, macOS 26.6.2 |
|---|---|---|
| load the checkpoint (bf16 widened to f32 on the GPU) | 462 ms | not measured |
| produce 64 tokens (prefill 9, decode 63) | 917 ms | 1,637 ms |
| verify those 64, one pass over 72 rows | **38 ms** | 123 ms |
| produce 240 tokens | 3,734 ms | not run |
| verify those 240, one pass over 248 rows | **77 ms** | 401 ms (the mini's transcript) |
| transcript sha256, prompt below, 64 tokens | `4278004516db5cdb…` | `4278004516db5cdb…` |

The two machines are different GPU generations on different macOS versions; the Air built its
own Metal shim from source. The transcript files are byte-identical: 64 tokens and 64
fingerprints of full logit rows. The mini's 240-token transcript verifies 240/240 on the Air.

Correctness is judged by something outside Rail: `ref.py`, a numpy float32 Llama written
from the model card, reads the checkpoint itself. It agrees on every greedy token tried (64
of 64, 48 of 48 and 40 of 40 across three prompts) and on the logits to 7.4e-5 absolute
(1.9e-6 relative) over nine rows. Bit equality with numpy is not claimed and not expected.

## Run it

From the repository root on an Apple silicon Mac, with the checkpoint downloaded
(`huggingface-cli download HuggingFaceTB/SmolLM2-135M model.safetensors tokenizer.json`)
and a python3 that has `numpy` and `tokenizers`:

```
tools/infer/smol/smol.sh gen "The Rail programming language compiles itself, and" 64 /tmp/t.txt
tools/infer/smol/smol.sh verify /tmp/t.txt          # VERIFIED, exit 0
tools/infer/smol/smol.sh verify /tmp/t.txt 40 1789  # forge token 40: REJECTED at 40, exit 1
tools/infer/smol/smol.sh parity /tmp/t.txt          # 1-row == 8-row == all-at-once
tools/infer/smol/smol.sh ref /tmp/t.txt             # the numpy reference's tokens, compared
```

`smol.sh` refuses a checkpoint whose sha256 is not the pinned one. Copy a transcript to
another Mac and `verify` it there: that is the cross-device check.

## How the engine keeps the property

- The checkpoint's bf16 bytes go to the GPU untouched and a kernel widens them to f32 with a
  16-bit shift, which is exact. Linear weights are transposed once, on the GPU, also exact.
- Every kernel is MSL text in `smol_engine.rail`, JIT-compiled with fast math off.
- Matrix products use one 8x8 simdgroup kernel whose rows are independent and whose K loop is
  sequential, so a row gets the same bits whether it shares its tile with seven other rows or
  with seven rows of padding. (This kernel's cross-device identity was established earlier on
  M4 Pro, M1 Ultra and M1; see `tools/infer/README.md`.)
- Every reduction (RMSNorm, attention scores, softmax, attention output, argmax) is one
  thread's ascending loop over exactly the positions its row can see, using `fma` where it
  multiplies and adds, and a fixed polynomial for `exp`. No reduction is split across threads.
- The RoPE table is computed on the CPU in Rail with plain IEEE double arithmetic (Cody-Waite
  reduction and Taylor series, no libm), so it is the same on every machine.
- A pass takes `[pos0, rows]`: row r sits at position pos0 + r. One forward function serves the
  prefill, the decode step and the verifier.

## What this is not

- **Greedy decoding only.** Sampling would need a declared seed and a deterministic sampler.
- **The verifier re-runs the model.** It needs the weights and does roughly the producer's
  arithmetic; what it saves is the sequence of N dependent passes, which becomes one parallel
  pass. It is exact re-execution, not a cryptographic proof of inference.
- **FNV-64 is a fingerprint, not a commitment.** It catches accidents and honest disagreement.
  Against an adversary, fingerprint the rows with SHA-256 instead.
- **Apple GPUs, Metal, fast math off.** Tested on M4 Pro and M1. Not claimed across vendors,
  and not bit-equal to numpy or PyTorch.
- **Small and plain.** f32 compute, batch 1, a 256-token window (`sm_maxt`), about 70 tokens/s
  of decode on the M4 Pro. Speed is not the point here.

## Files

| file | what |
|---|---|
| `smol_engine.rail` | kernels, loader, RoPE table, the forward pass, fingerprints |
| `gen.rail` | the producer: prefill, then decode, then write the transcript |
| `verify.rail` | the verifier: one pass, token and fingerprint per position, first divergence |
| `parity.rail` | 1-row vs 8-row vs all-at-once over every logit row and every K/V cache |
| `ref.py` | the independent numpy reference and the tokenizer glue |
| `smol.sh` | pins the checkpoint, wires the paths, runs the above |
