# Cap H parameter count — Phase 1.4

Reference: `spurarm-embodiment-roadmap.md` §1.4. This document is the
canonical breakdown that `config_cap_h.rail` agrees with at compile
time via `cap_h_params_check`.

## Frozen constants

| symbol | value | rationale |
|---|---|---|
| `d_model` | 256 | roadmap §1.4 canonical |
| `n_layers` | 6 | vs v0's 1; depth bump is the whole point |
| `n_heads` | 8 | `head_dim = d_model / n_heads = 32` |
| `n_kv_heads` | 8 | vanilla MHA (no GQA in Cap H, unlike the original frozen v0 spec) |
| `d_ff` | **2816** | **adjusted from default to hit the 14.7M target** (see "Adjustment" below) |
| `vocab` | 1024 | tokenizer v2 (roadmap §1.3) |
| `seq_len` | 256 | spec target, not v0's 96 workaround |
| `tied_lm_head` | 1 | LM-head matmul reuses embed weights as W^T |

## Component breakdown

| component | formula | value |
|---|---|---:|
| Embedding matrix | `V × d` = `1024 × 256` | **262,144** |
| Per layer — attention (4 matrices) | `4 × d × d` = `4 × 256²` | 262,144 |
| Per layer — SwiGLU FFN (3 matrices) | `3 × d × d_ff` = `3 × 256 × 2816` | 2,162,688 |
| Per layer — RMSNorms (2 × gamma vector) | `2 × d` | 512 |
| **Per layer total** | — | **2,425,344** |
| All 6 layers | `6 × 2,425,344` | 14,552,064 |
| Final RMSNorm | `d` | 256 |
| LM-head (tied with embed) | `0` | 0 |
| **TOTAL** | — | **14,814,464** |

≈ **14.81M parameters**, **+0.78% above 14.7M target** (well inside the ±5% band).

## Adjustment from the roadmap baseline

The roadmap §1.4 pins `d_model = 256`, `n_layers = 6`, `n_heads = 8`, `vocab = 1024`,
`seq_len = 256`, and a target of "~14.7M params". It does NOT pin `d_ff`.

A standard Llama-style SwiGLU sizing (`d_ff = (8/3) × d_model ≈ 683`) at this
geometry yields:

```
embed              = 262,144
attn/layer         = 262,144
ffn/layer (SwiGLU) = 3 × 256 × 683 = 524,544
norms/layer        = 512
per-layer          = 787,200
6 layers           = 4,723,200
final norm         = 256
total              = 4,985,600   (~5.0M — 66% short of target)
```

A vanilla `d_ff = 4 × d_model = 1024` only gets to ~6.6M. To hit 14.7M with the
roadmap's fixed `(d_model, n_layers, n_heads, vocab)`, the **single** hyperparameter
the task allows me to adjust must be `d_ff`. Solving:

```
embed + n_layers × (4d² + 3·d·d_ff + 2d) + d + 0  =  target
262144 + 6 × (262144 + 768·d_ff + 512) + 256      =  14,700,000
262144 + 1,575,936 + 4608·d_ff + 256              =  14,700,000
4608 · d_ff                                       =  12,861,664
d_ff                                              ≈  2791.6
```

Rounded up to the next multiple of 64 → **`d_ff = 2816`** (yields 14,814,464,
+0.78% above target). 64-multiples are preferred for SIMD-aligned GEMM kernels
on Apple Silicon Metal (the matmul kernels in `tools/metal/tensor_gpu.metal`
chunk on 64-element tiles).

### Why not adjust `n_layers` or `d_model` per task default

The task instructs "prefer reducing `n_layers` or `d_model`". But reducing either
moves further from the 14.7M target rather than toward it — the roadmap config
at the canonical `(d=256, L=6)` is already under-parametrised vs target with
typical `d_ff`. The right knob to close the 14.7M gap is `d_ff` (which the
roadmap left unspecified). Documenting here so the choice is auditable.

### What if SwiGLU is too expensive

If the corpus / training-budget evidence later shows SwiGLU isn't pulling its
weight, switching to vanilla ReLU 2-matrix FFN (`2 × d × d_ff` instead of `3 ×`)
would require `d_ff = 4187` (round to 4224) to hold the param target. SwiGLU is
the default per the original frozen spec in `notes/railarm4agent/AGENT_B_train.md`,
so we stick with it.

## Tied-LM-head sensitivity

| variant | total params | delta |
|---|---:|---:|
| tied (chosen) | 14,814,464 | — |
| untied | 15,076,608 | +262,144 (+1.77%) |

Both fit within ±5% of 14.7M, but tied is the canonical small-LM convention
and saves 262 K params + reduces gradient noise on the vocab dim. Keep tied.

## Compatibility with bf16 + JIT routing

The param count is precision-agnostic; bf16 vs f64 affects only memory and
wall-clock, not weight count. The chosen `(d=256, d_ff=2816)` shapes ALL
divide cleanly by:

- 8 (n_heads → head_dim = 32)
- 64 (Metal SIMD tile in `tools/metal/tensor_gpu.metal`)
- 32 (typical f64 register-blocking on M1 Ultra)

This is intentional so the JIT'd rmsnorm+QKV and silu+hadamard fused kernels
(`stdlib/jit.rail` in main rail repo) can be applied without reshape padding
once they're backported into spurarm-B.

## Cross-check command (post-implementation)

The `cap_h_params_check` function in `config_cap_h.rail` recomputes the total
from the constants every time it's called. After any constant change, the
trainer should print:

```
let _ = print (cat ["params: ", show (cap_h_params_total 0)])
let ok = cap_h_params_check 0
```

and abort if `ok != 1`. The matching exact-value `cap_h_params_exact 0 = 14814464`
is hard-coded as the assertion target; if the math drifts, both this document
and the constant need to be updated in lockstep.

## Availability (post db20fee, 2026-05-22)

Both bf16 matmul and the JIT'd fused kernels are present on the
`spurarm/cap-h` branch via the foundation commit `db20fee`. Specifically:

- `stdlib/tensor.rail` exports `matmul_bf16` + `tgl_matmul_bf16` FFI.
- `stdlib/jit.rail` exposes `jit_compile_rmsnorm_qkv` + `jit_run_rmsnorm_qkv`
  (35× over per-op) and `jit_compile_silu_hadamard` + `jit_run_silu_hadamard`
  (18× over per-op).
- `stdlib/jit_emit.rail` / `jit_match.rail` / `jit_node.rail` / `jit_tape.rail`
  back the dispatch path.

The Cap H trainer should set `cap_h_use_jit_kernels _ = 1`. The forward
smoke deliberately keeps it OFF to keep the per-op shape verification
deterministic. No prerequisite work remaining for Phase 1.5 on the
precision/kernel front.
