# SPEC — Attested fixed-point backward pass (act 10)

**Goal.** Prove the *training* step stays in the attestation chain: a
fixed-point gradient + weight update that runs bit-exact on GPU and CPU,
twin-verified. This is the last conceptual unknown between "attested forward
pass" and "attested training."

## Scope (MVP)

One linear layer, MSE loss, one SGD step. Deliberately minimal — every
transformer weight update is this exact shape (an upstream gradient replaces
the MSE term; the outer-product + update is identical). Not full transformer
backprop; that is composition once this unit is proven.

- Weights `W` : d×d, row-major (row i = output neuron i)
- Input `x` : d, target `t` : d
- Learning rate `LR` : Q32.32 scalar

## Math (Q32.32, all ops mul_shr / add / shift — the proven substrate)

Forward (already proven as `fx_matvec`):
```
y_i = Σ_j mul_shr(W_ij, x_j, 32)
```
Loss gradient (MSE `L = Σ (y_i - t_i)²`, the ×2 is a left shift):
```
g_i = (y_i - t_i) << 1
```
Weight gradient (rank-1 outer product):
```
dW_ij = mul_shr(g_i, x_j, 32)
```
SGD update:
```
W'_ij = W_ij - mul_shr(LR, dW_ij, 32)
```

## Fused kernel `fx_sgd_step` (one thread per row i)

```
y_i = Σ_j mul_shr(W_ij, x_j, 32)      // recompute forward inline
g_i = (y_i - t_i) << 1
for j: O_ij = W_ij - mul_shr(LR, mul_shr(g_i, x_j, 32), 32)
```
Output `O` = updated W (d×d). Params packed `W(d*d) | x(d) | t(d)`, LR baked
as an emit-time constant.

## Twin + attestation

- CPU twin computes identical formula on the `mul_shr` primitive.
- Verify `O` (updated W) byte-identical CPU vs GPU → `SGD-TWINS-AGREE`.
- Record `attested-train-step-v0` binds `W`, `x`, `t`, `LR`, `W'` by sha256,
  AND (review S4) the emitted kernel source hash `msl_sha256` — which contains
  the baked LR — so the record pins the COMPUTATION, not just the data. `d` and
  the fixed-point format (`shift=32`, `ONE=2^32`) are recorded too (N3).

## Overflow safety — bounds chosen to EXERCISE the 128-bit path (rev. after review S1/S2)

Review S2: tight bounds (2^27) would let a naive int64 `a*b>>32` match the twin,
so the 128-bit `mul_shr` would be dead weight and the wrap-width discipline never
tested. Fix: widen bounds so intermediate PRODUCTS genuinely exceed 2^63 (forcing
the 128-bit path) while all RESULTS stay < 2^62 (no Rail/int64 wrap on stored
values). Review S1: `t` is now PINNED to y-scale, not left free.

Bounds: `|W|,|x| < 2^38`, `|t| < 2^50` (pinned), `d ≤ 64`, `LR ≈ 2^20`.
- `W_ij · x_j` ≈ 2^38·2^38 = **2^76** → overflows int64, needs 128-bit ✓
- `y_i` = Σ_64 mul_shr(·,·,32) ≈ 64·2^44 = 2^50  (< 2^62 ✓)
- `g_i` = (y_i − t_i) << 1 ≈ 2^52  (< 2^62 ✓)
- `g_i · x_j` ≈ 2^52·2^38 = **2^90** → needs 128-bit ✓;  `dW_ij` ≈ 2^58
- `LR · dW` ≈ 2^20·2^58 = 2^78 → needs 128-bit ✓;  `mul_shr(LR,dW,32)` ≈ 2^46
- `W'_ij` ≈ 2^46  (< 2^62 ✓)

Every STORED result < 2^62 (no wrap); every PRODUCT that matters exceeds 2^63
(128-bit path genuinely exercised). This makes the naive-int64 negative control
below actually diverge — a real wrap-width proof, not just plumbing.

## Controls (rev. after review S3)

- **Negative control (S2 → real):** a naive-int64 variant of `mul_shr`
  (`(a*b)>>32` in plain `long`, no `mulhi`) MUST diverge, because at these bounds
  the products overflow int64. Proves the 128-bit path is load-bearing.
- **Tamper control (S3):** perturb one `x_j` by a LARGE magnitude (≥ 2^37, not
  1 LSB — a small delta is swallowed by truncation and false-passes). Assert the
  updated `W'` diverges from the untampered run.

## Explicitly out of scope (honest boundaries)

- No `dL/dx` (input gradient) — not needed for a single-layer update; add later
  for multi-layer chaining (`dx_j = Σ_i mul_shr(W_ij, g_i, 32)` = W^T·g, another
  matvec).
- No optimizer state (Adam moments) — SGD only. Adam is more mul_shr + a
  fixed-point rsqrt we already have.
- No convergence claim. This proves the step is *attested and exact*, not that
  it *learns* — a separate, later, loss-goes-down experiment.

## Success criteria

1. `SGD-TWINS-AGREE`, 0 mismatches over d×d updated weights.
2. Deterministic run-to-run.
3. Negative control: a naive 64-bit variant of any overflow-capable step
   diverges (there is none here by construction — so instead, a *tamper*
   control: perturb one `x_j`, updated W must diverge).
4. Full suite 178/178, jit_emit smokes green.
