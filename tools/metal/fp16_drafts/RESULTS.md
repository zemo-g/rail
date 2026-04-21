# fp16 kernel port results — labrat overnight 2026-04-20→21

| Kernel | Outcome | Speedup | Iter (kept) | Wall (min) | Source file |
|---|---|---|---|---|---|
| matmul             | KEPT | 1.8× | 1/5 | ~5  | `matmul_f16.metal` |
| matmul_blocked     | KEPT | 1.6× | 5/5 | ~9  | `matmul_blocked_f16.metal` |
| matmul_bias_relu (v1) | rolled back | — | 0/5 | ~9 | (see v2) |
| matmul_bias_relu (v2, fp32-bias hint) | **KEPT** | **1.8×** | 1/5 | ~5 | `matmul_bias_relu_f16.metal` |
| matmul_bias_gelu (v6, uniqueness + fp32-bias) | **KEPT** | **1.7×** | 1/5 | ~5 | `matmul_bias_gelu_f16.metal` |

## matmul_bias_relu failure mode

All 5 iters failed:
- 3 no-ops (FIND text didn't match source)
- 1 compile-fail
- 1 below-gate at speedup=1.3

Diagnosis: prompt v4's closing markdown fence (` ``` `) leaks into the
model's FIND text. Specifically the model produces:

```
FIND:
}
```        ← this line is the closing fence from the prompt, not source

REPLACE:
}

kernel void matmul_bias_relu_f16(...)
```

The `}\n```\n` substring doesn't exist in the actual source file (the
closing fence is part of the prompt frame). `str_replace` no-ops →
labrat skips the iter via the no-op detector → next iter same problem.

This same failure mode hit the v3 stability sweep (with `<<<FILE_END>>>`
markers) before being patched in prompt v4.

## Prompt v5 needed

Use no closing markers around the file body. Natural text break:

```
TASK: <goal>

CURRENT FILE:

<file content here>

Now produce a FIND/REPLACE/END patch.
```

Model sees raw text; no fence to echo. The "Now produce..." line is the
natural boundary. Worked example after that.

## Post-addendum (2026-04-21 08:05)

Prompt v5 landed (commit 88b2953), and `matmul_bias_relu` was retried
with an updated task spec v2 adding a **fp32-bias hint**: keep the bias
buffer as `float` (fp32) even in the fp16 kernel, avoiding per-cell
`half(float_bias)` conversion in the hot path. Bench was patched to
pass the same fp32 bias buffer to both f32 and f16 kernels.

Result: **iter 1 KEEP at 1.8× speedup**. The fp32-bias hypothesis was
correct — v1's half-bias approach stalled at 1.2–1.3× because of the
conversion overhead.

**All 3 matmul-family kernels now have labrat-produced fp16 variants
ready for production transplant.** Phase 4a Option A is materially
unblocked.

## Next session

1. Transplant all 3 drafts into production `tools/metal/tensor_gpu.metal`
   (rename existing `matmul` → `matmul_f32` etc. first).
2. Add corresponding `tgl_*_f16` foreign decls in `stdlib/tensor.rail`
   and host dispatch in `tools/metal/tensor_gpu_lib.m`.
3. Rebuild `libtensor_gpu.dylib`; `./rail_native test` must still pass.
4. Extend `port_kernels.sh` spec list with the remaining matmul
   variants (`matmul_bias_gelu`, `matmul_batched`, softmax, layernorm
   variants). Each probably needs its own task-spec hint (same pattern
   as v2 — identify fp32-stays buffers).
5. Run `port_kernels.sh` overnight to chain-port the rest.

## Production transplant checklist

For each `*_f16.metal` here:

- [ ] Copy the new kernel definition into `tools/metal/tensor_gpu.metal` (next to its f32 sibling)
- [ ] Add `tgl_<name>_f16` foreign decl in `stdlib/tensor.rail` (mirror tgl_<name>_f64 with half buffer pointers)
- [ ] Add host dispatch in `tools/metal/tensor_gpu_lib.m` (mirror existing entry's `@autoreleasepool` pattern, cast double→half on stage-in, half→double on stage-out)
- [ ] Rebuild `libtensor_gpu.dylib`
- [ ] Verify `./rail_native test` still passes
