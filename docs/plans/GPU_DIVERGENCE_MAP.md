# GPU divergence map — the missing experiment

## Why this hasn't been done before

Past sessions cycled through hypotheses (pool reuse, fp16 saturation, first-token-only, dylib staleness) and falsified each. They never built the **per-layer CPU↔GPU output diff**, which would localise the divergence to a specific kernel rather than narrating a hypothesis.

Per `feedback_diagnostics_first.md` ("ship the counter before changing the thing") and `feedback_root_cause_investigation.md` ("re-read tool output literally") this is the experiment that ends the cycle.

## What the dylib actually does

Confirmed by reading `tools/metal/tensor_gpu_lib.m` 2026-05-09:

- `tgl_init` does `dladdr(&tgl_init)` to find its own dylib path → loads `tensor_gpu.metal` (sibling file, fresh string each init) → `[device newLibraryWithSource:opts:&err]`. No metallib cache, no embedded source string.
- `tools/metal/tensor_gpu.metal` (916 lines, 35 kernels) **already contains** `matmul_f16`, `matmul_blocked_f16`, `matmul_f32x_halfw`, `matmul_bias_relu_f16`, `matmul_bias_gelu_f16`, `tensor_add_f16`, `tensor_scale_f16`, `tensor_transpose_f16`, `tensor_softmax_f16`. The `tools/metal/fp16_drafts/` directory is obsolete — kernels were merged into the main file.
- Dylib install_name is correct (`~/projects/rail/tools/metal/libtensor_gpu.dylib`); the `~/...` reference in `stdlib/tensor.rail:204` is a stale comment, not load-bearing.
- No `double` token in main `.metal` source → silent-killer hypothesis (per `metal_one_source_string.md`) is **falsified**.

## Surviving hypothesis after this dive

The dylib **works correctly** — it just rounds fp16 differently than the C-emulated `f64_to_f16` / `f16_to_f64` helpers do. Native Apple Silicon GPU fp16 vs the inline IEEE-754 conversion in `tensor_gpu_lib.m` lines 379-410 differ on:

- Subnormals (CPU helper flushes to zero; GPU may round-to-nearest-even normal)
- Rounding mode on the 13-bit mantissa truncation (`mant >> 13` is round-toward-zero; GPU's hardware round-to-nearest-even keeps one extra bit of accuracy)
- NaN canonicalization (CPU helper passes mantissa through; GPU may canonicalize)

Each individual difference is sub-ULP on the inputs. But across a 2-block transformer × 1024 seq positions × 9 matmuls/block, the accumulated drift can flip top-k ranks on the final logit head — which is what the bench measures.

## The experiment: per-layer divergence map

Run inference on a fixed seed + fixed prompt through the same checkpoint on (1) the all-CPU substrate `tools/train/lm_infer_cpu.rail`, (2) the GPU-mixed substrate `tools/train/lm_infer_v3_mixed.rail`. Capture the activation tensor at every named tensor (post-RMSNorm, post-Q/K/V, post-attn, post-block, post-final-RMSNorm, post-logits). Compute max-abs-delta and mean-abs-delta per layer.

Pseudocode for the dump tool:

```rail
-- tools/diagnose/forward_dump.rail <substrate> <ckpt> <prompt> <out_dir>
-- emits one .f32 file per named activation. CPU pass and GPU pass dump to
-- /tmp/forward_dump_<substrate>/<layer_name>.f32, then a Python or pure-Rail
-- diff tool reads matching pairs.

main =
  let substrate = nth 1 args
  let ckpt      = nth 2 args
  let prompt    = nth 3 args
  let out_dir   = nth 4 args
  ...
  -- forward pass with hooks on every named tensor
  let _ = dump_tensor (cat [out_dir, "/embed.f32"]) embed
  let _ = dump_tensor (cat [out_dir, "/block0_ln1.f32"]) ln1_0
  let _ = dump_tensor (cat [out_dir, "/block0_q.f32"]) q_0
  ...
```

## Acceptance criterion

The experiment **succeeds at producing useful information** if it produces a per-layer table like:

| Layer | max_abs_delta | mean_abs_delta | first divergence at step |
|---|---|---|---|
| embed | 0 | 0 | — (deterministic) |
| block0_ln1 | 1.2e-5 | 4e-7 | (drift from int→float gather) |
| block0_q | 8e-4 | 2e-5 | (matmul fp16 truncation) |
| block0_k | 8e-4 | 2e-5 | |
| block0_attn_scores | 0.04 | 1e-3 | (softmax sensitive) |
| block0_attn_out | 0.05 | 2e-3 | (cumulative) |
| ... | | | |
| final_logits | 0.5+ | 0.05 | (top-k flip plausible) |

If max_abs_delta at any layer is >1.0 *before* the cumulative softmax steps, that's a kernel arithmetic bug, not precision drift. If max is <0.01 throughout but logits delta is >0.5, it's pure precision and the surface is `f64_to_f16` rounding (not the kernel).

## Decision tree

| Outcome | Surface to fix |
|---|---|
| Kernel arithmetic bug found | Patch the specific kernel; re-run; per-layer delta should drop to ~0 |
| Pure precision drift | Replace `f64_to_f16` with round-to-nearest-even, keeping only the half-of-mantissa truncation. Alternatively add stochastic rounding for the final logit projection only. |
| Drift dominated by `attn_scores` softmax | Use `tensor_softmax_f64` (CPU) for the softmax even on GPU path; cheap. |
| Drift identical to mixed-precision result | Already at the floor of fp16 weight quantization; only fix is fp32 weights, which costs the memory-bandwidth saving. |

## Cost

- Dump tool: ~150 lines of Rail (forward pass with hooks + tensor serialization). 1-2 hr.
- Diff tool: ~50 lines of bash + awk OR a small Rail program. 30 min.
- Run + analyze: 5 min.

Total: ~2 hr of focused work. Compared to the 5+ sessions of hypothesis-cycling without localized data, this is cheap.

## Out of scope for this experiment

- Re-bench v54 ckpt on GPU (already done, scored 1/30 fp32-logits, 0/30 mixed; the *result* is known, the *cause* is what this experiment finds).
- JIT inference acceleration — separate lever in `JIT_INTEGRATION.md`.
- Trainer GPU acceleration — depends on the same rounding question.
