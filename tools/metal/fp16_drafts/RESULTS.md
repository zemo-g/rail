# fp16 kernel port results — labrat overnight 2026-04-20→21

| Kernel | Outcome | Speedup | Iter (kept) | Wall (min) | Source file |
|---|---|---|---|---|---|
| matmul             | KEPT | 1.8× | 1/5 | ~5  | `matmul_f16.metal` |
| matmul_blocked     | KEPT | 1.6× | 5/5 | ~9  | `matmul_blocked_f16.metal` |
| matmul_bias_relu   | rolled back | — | 0/5 | ~9 | (failed) |

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

## Next session

1. Implement prompt v5 in `tools/labrat/labrat.rail:lb_prompt`.
2. Re-run matmul_bias_relu task — confirm KEEP.
3. Run port_kernels.sh on full Option A kernel list. Estimated 26 kernels × ~10 min average = ~4-5 hours overnight.
4. Transplant the 2 working drafts (`matmul_f16.metal`, `matmul_blocked_f16.metal`) into production `tools/metal/tensor_gpu.metal` while you're awake — review the kernels first.

## Production transplant checklist

For each `*_f16.metal` here:

- [ ] Copy the new kernel definition into `tools/metal/tensor_gpu.metal` (next to its f32 sibling)
- [ ] Add `tgl_<name>_f16` foreign decl in `stdlib/tensor.rail` (mirror tgl_<name>_f64 with half buffer pointers)
- [ ] Add host dispatch in `tools/metal/tensor_gpu_lib.m` (mirror existing entry's `@autoreleasepool` pattern, cast double→half on stage-in, half→double on stage-out)
- [ ] Rebuild `libtensor_gpu.dylib`
- [ ] Verify `./rail_native test` still passes
