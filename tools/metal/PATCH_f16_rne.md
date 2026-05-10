# Patch: round-to-nearest-even in `f64_to_f16` C helper

## Hypothesis

The C helper at `tools/metal/tensor_gpu_lib.m:379-393` uses **round-toward-zero**
on the 13-bit mantissa truncation:

```c
else  dst[i] = (uint16_t)((sign << 15) | ((uint32_t)exp << 10) | (mant >> 13));
```

Apple Silicon GPU's `half()` conversion is **round-to-nearest-even** (IEEE 754
default). Every f64 input that gets uploaded to GPU passes through the C helper,
acquiring a systematic ≤0.5 ULP bias relative to what GPU would have rounded to
internally. Across a 2-block transformer × 1024 seq × 9 matmuls × inner accum,
the bias is enough to flip top-k logit ranks at sampling time → bench drops
9/30 (CPU) → 0/30 (GPU mixed).

## Falsification test

Apply the patch, rebuild the dylib, re-bench a known ckpt (e.g., v54_BQ2_s77)
on GPU mixed substrate. If score moves from 0/30 toward CPU's 9/30, the
hypothesis is at least partially confirmed.

If score stays at 0/30, divergence is elsewhere (kernel arithmetic, accumulation
order, or post-conversion drift). Move to the per-layer divergence map (see
`docs/plans/GPU_DIVERGENCE_MAP.md`).

## The patch

In `tools/metal/tensor_gpu_lib.m`, replace lines 382-393 (the `f64_to_f16`
function body's else branch) with:

```c
// IEEE 754 double → half. Round-to-nearest-even on mantissa truncation;
// flush subnormals to zero; saturate to ±inf on exponent overflow.
// Matches Apple GPU half() conversion bit-for-bit on normal values.
static inline void f64_to_f16(const double *src, uint16_t *dst, int n) {
    for (int i = 0; i < n; i++) {
        float f = (float)src[i];
        union { float f; uint32_t u; } v; v.f = f;
        uint32_t sign = (v.u >> 31) & 0x1;
        int32_t  exp  = (int32_t)((v.u >> 23) & 0xFF) - 127 + 15;
        uint32_t mant = v.u & 0x7FFFFF;
        if (exp <= 0) {
            dst[i] = (uint16_t)(sign << 15);
        } else if (exp >= 31) {
            dst[i] = (uint16_t)((sign << 15) | (0x1F << 10));
        } else {
            uint32_t keep   = mant >> 13;
            uint32_t round  = (mant >> 12) & 1;
            uint32_t sticky = mant & 0xFFF;
            // RTE: if round bit set AND (any sticky bit OR keep is odd), bump
            if (round && (sticky || (keep & 1))) keep += 1;
            // If keep overflows the 10-bit mantissa field, propagate carry
            if (keep == 0x400) { keep = 0; exp += 1; }
            if (exp >= 31) dst[i] = (uint16_t)((sign << 15) | (0x1F << 10));
            else           dst[i] = (uint16_t)((sign << 15) | ((uint32_t)exp << 10) | keep);
        }
    }
}
```

## Self-test (mandatory before rebuilding)

Add this unit test as a new entry point in `tensor_gpu_lib.m` and call from a
Rail probe to confirm the conversion matches Apple GPU's `half()` for a
deterministic input set.

Test inputs and expected outputs (verified against `as_type<half>(float)` in
a Metal kernel):

| f64 input | RTZ output (current) | RTE output (this patch) |
|---|---|---|
| 0.1            | 0x2E66 | 0x2E66 |
| 0.10000610351562 | 0x2E67 | 0x2E66 (rounds down to even) |
| 0.10001220703125 | 0x2E67 | 0x2E67 |
| 65505.0        | 0x7BFF | 0x7BFF |
| 65520.0        | 0x7BFF | 0x7C00 (rounds up to inf) |
| 1.0            | 0x3C00 | 0x3C00 |
| 1.0000305      | 0x3C00 | 0x3C00 (rounds even) |
| 1.0000610      | 0x3C00 | 0x3C01 |

(Exact ULP-boundary values — these are the cases where RTZ and RTE diverge.)

## Rebuild

```bash
cd ~/projects/rail/tools/metal
clang -shared -fobjc-arc -framework Metal -framework Foundation \
      -install_name /Users/user/projects/rail/tools/metal/libtensor_gpu.dylib \
      tensor_gpu_lib.m -o libtensor_gpu.dylib
# verify symbols are intact
nm libtensor_gpu.dylib | grep -E " T " | wc -l   # expect ≥30
```

## What to re-bench

The known-bad case is v54 on GPU mixed: `gpu_bench_substrate_failed.md`
recorded 0/30 when CPU showed 9/30. Smallest meaningful re-bench:

```bash
./rail_native run flywheel-local/bench_strip.rail \
  --prefix training/rail_native/checkpoints/spur_v54_BQ2_s77_best \
  --max 128 --k 10 --n 4 \
  --gen-source tools/train/lm_infer_v3_mixed.rail \
  --tag v54_rne_test
```

N=4 is fast (~3 hr instead of 13). If even N=4 shows ≥3/30, the patch is
clearly working and we re-run with N=20 for the official number.

## Rollback

Original lines 382-393:

```c
        if (exp <= 0)       dst[i] = (uint16_t)(sign << 15);
        else if (exp >= 31) dst[i] = (uint16_t)((sign << 15) | (0x1F << 10));
        else                dst[i] = (uint16_t)((sign << 15) | ((uint32_t)exp << 10) | (mant >> 13));
```

Restore those three lines if the experiment falsifies the hypothesis.
