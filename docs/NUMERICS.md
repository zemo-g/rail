# Rail numerics contract

What is bit-exact and reproducible in Rail, what is not, and where the boundary
is. This exists because "bit-exact" is only a checkable claim if the numeric
contract is written down. Scope it to a platform; do not assume cross-platform
bit-identity for the float/libm/GPU paths.

## Exact & deterministic: integer and fixed-point

- **63-bit tagged integers** are exact. Arithmetic (`+ - * / %`) is integer-exact;
  there is no silent float promotion unless a float operand is present.
- **`mul_shr a b s`** computes `(a*b) >> s` in a **full 128-bit intermediate**
  (`mul` low-64 + `smulh` high-64; `tools/compile.rail`), so fixed-point multiply
  does not overflow the 63-bit tag. This is the overflow-safe primitive behind
  Rail's bit-exact ML: the SmolLM2-135M and Qwen3 forward passes that reproduce
  HuggingFace **bit-for-bit** run an **integer-exact** path (see
  `tools/bitexact/`), not floating point.
- **`idot`** is an exact integer dot-product / matmul used on that path.
- The integer path is bit-identical on any conforming ARM64. **This is the
  substrate the attestation claims rest on** — integers, not floats.

Overflow is a real hazard on the 63-bit tag; guard multiplicative/loop code with
`mul_shr` or two-limb arithmetic. See `tools/bitexact/` for the overflow tests.

## Deterministic per-platform: IEEE 754 doubles

- Floats are **unboxed IEEE 754 doubles in ARM64 d-registers**. `fadd`/`fmul`/
  `fdiv`/`fsqrt` are round-to-nearest-even and deterministic **on a given ISA**.
- **Reduction order is fixed by the source** — Rail does not reassociate or
  auto-vectorize float reductions, so `fold (+) 0.0 xs` sums left-to-right every
  time.
- **Precision regime:** bf16 (f32 exponent range, no fp16 NaN cliff) for
  activations; **f64 on the embedding and LM-head** — the "f64 truth line".

## NOT bit-identical across platforms (the escape hatches)

These compile and run, but break cross-platform bit-identity. Bit-exact work must
avoid them or pin the platform. See [SAFE_SUBSET.md](SAFE_SUBSET.md).

- **Host libm via FFI** — `sin cos sqrt pow exp log tanh` (`stdlib/math.rail`) call
  the platform's libm, which is **not correctly-rounded** and differs across OS /
  libm versions. A bit-exact path uses integer/polynomial approximations instead.
- **GPU / Metal** — FMA contraction, reduction order, and denormal handling differ
  from the CPU path; GPU bit-exactness requires the integer-exact path or
  tightly-pinned kernels, not the default.
- **x86_64 backend** — float lowering/rounding may differ from ARM64.

## What "bit-exact" is scoped to

A **specific platform** (ARM64 macOS), a **specific attested build** (the committed
seed, sha in [STATUS.md](STATUS.md)), and the **integer-exact path**. Cross-platform
bit-identity is **not** claimed for float, libm, or GPU paths.

## How to verify

- `tools/bitexact/` — the integer-exact forward/train harness + overflow guards.
- The HF-parity demos: SmolLM2 reproduced to a pinned sha; Qwen3 first-logit
  `g[0]=12095` matches HF greedy. These are reproducible, not asserted.
- Provenance, not correctness: a bit-identical result proves *the same computation
  ran*, not that the computation is *right*. See [THREAT_MODEL.md](THREAT_MODEL.md).
