# pathb — attested integer-exact SmolLM2-135M forward (pure Rail)

A full **30-layer SmolLM2-135M** forward pass, computed in **integer-exact
fixed-point (F=24, S=2^24)** with **zero float on the exact path**, then
hashed → Ed25519-signed by a witness → beacon-anchored → independently
verified. No MLX, no PyTorch, no Python in the forward — pure Rail.

This is the demonstrating consumer of the `mul_shr` compiler primitive
(zemo-g/rail PR #19). It needs `mul_shr` to compile.

## Verified result (2026-06-18)

Prompt `"The capital of France is"` (tokenized pure-Rail by `tok2`, ids
`504 3575 282 4649 314`, byte-identical to HF):

| Property | Result |
|---|---|
| Scope | all 30 layers, full 49152 vocab, real BPE prompt |
| Determinism | bit-reproducible across runs/processes/recompiles — `logits_full.txt` sha256 `d8a9f0c7…` |
| **HF parity** | **argmax = token 260 `' the'` = HF fp32 greedy token** |
| Attestation | Pi-witness (fleet0) Ed25519 signed, beacon-anchored, verified |
| Foreign check | `pathb_foreign_check_full.py` on stock python3 (pure RFC-8032): exit 0 |

Honest scope: top-1 matches HF exactly; lower top-5 ranks reshuffle under
F=24 quantization (HF's #2 was `' Paris'`; the fixed-point tail differs).
Top-1 is robust; the tail is not bit-identical to fp32, as expected.

A 1-layer precursor (`logits.txt`, sha `d476010e…`) is also attested and kept
as the minimal mechanism proof.

## Why it needs `mul_shr`

SmolLM2 has "massive activations" (`max|h|` ~19,000 by layer 11). In F=24
that is ~2^38; RMSNorm squares it (~2^76), overflowing Rail's 63-bit ints.
`mul_shr a b s = (a*b)>>s` computes the product in a full 128-bit intermediate
(`mul`+`smulh`), so it is exact at any magnitude. `pf_ssq`, `pf_normapply`,
and `pf_silu` use it.

## Reproduce

1. `pip`-free: have `HuggingFaceTB/SmolLM2-135M` in your HF cache, and copy its
   `tokenizer.json` to `smollm2_tokenizer.json` here.
2. Point `pf_blob` in `pathb_forward_full.rail` and `pathb_quant.rail` at your
   local `model.safetensors` blob path (machine-specific; pre-push cleanup TODO:
   read it from a file/env instead of hardcoding).
3. Build + run (the binary directly — `./rail_native run` SIGBUSes on the load):
   ```
   ./rail_native tools/railml/pathb/pathb_forward_full.rail
   RAIL_ARENA_MB=8192 /tmp/rail_out          # -> logits_full.txt + sha256
   ./rail_native tools/railml/pathb/pathb_attest_full.rail && RAIL_ARENA_MB=2048 /tmp/rail_out
   python3 tools/railml/pathb/pathb_foreign_check_full.py
   ```

## Files

| File | Role |
|---|---|
| `pathb_quant.rail` | BF16 → fixed-point F=24 quant of real weights (1-layer artifact path) |
| `pathb_forward.rail` | 1-layer integer-exact forward (mechanism proof) |
| `pathb_forward_full.rail` | **full 30-layer** forward, on-the-fly BF16 loader, full vocab |
| `pathb_attest.rail` / `_full.rail` | hash → Pi-witness Ed25519 sign → beacon anchor → verify |
| `pathb_foreign_check.py` / `_full.py` | independent pure-RFC-8032 verifier (no shared crypto) |
| `tok2.rail` / `tok2_lib.rail` / `tok_prompt_check.rail` | pure-Rail byte-level BPE tokenizer + check |
| `probe_bigread.rail` | proves `read_file_bytes` holds the 269MB blob, `byte_at` indexes it |
| `logits*.txt` / `*.attestation.json` | the attested artifacts |
