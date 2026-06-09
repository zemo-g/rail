# r37 exact-integer eval semantics — `eval=xint-q24-v1`

The v2 gate's one soft criterion: okForeign re-derived the metric with numpy **float64**, which
matches Rail's float forward *empirically* (argmax is robust to the tiny cross-stack float
differences **on this artifact**) but not *provably* — a different libm/BLAS could flip a
borderline argmax. v3 removes float from the verification path entirely: the metric becomes a
**deterministic integer function of (committed weights, committed splits, this spec)**. Any
implementation of this spec, in any language on any machine, produces the bit-identical metric.

This is the third leg of the artifact-attestation resolution (train float → attest weights →
**eval exact-int**), inheriting the proven primitive semantics from `tools/bitexact`
(bx4/bx7/lm10 — Rail↔Python bit-exactness already demonstrated across rungs 22–36).

## Representation

- Fixed-point Q.24: real x ↦ integer X = round(x·S), S = 2²⁴ = 16777216.
- `td(a,b)` = integer divide truncating toward zero (ARM `sdiv`; Rail `/` on ints). Python
  mirror: `q = |a|//|b|; q if signs equal else -q`. **All divides below are td.**
- Committed weights are the Q.24 integers from `r37_force_weights_q24_full.txt` **used as-is**
  (no float reconstruction).

## Spec constants (all exact integers)

| name | value | derivation (informative) |
|---|---|---|
| S | 16777216 | 2²⁴ |
| LN10000_q | 154526885 | round(ln 10000 · S) |
| LNEPS_q | 168 | round(1e-5 · S) |
| ISD_q | 2097152 | S/8 exactly (1/√64; d=64) |
| LN2_q | 11629080 | round(ln 2 · S) (inside bx4_fxexp) |

## Inherited primitives (normative; defined in `tools/bitexact/bx_fixed.rail` and mirrored in
`tools/bitexact/bx4_foreign_check.py` / `bx7_foreign_check.py`)

- `fxexp(x)` — arg-reduced degree-8 Horner poly, coeffs round(S/i!); `exp_neg` k≥50 → 0.
- `fxsqrt(v)` = isqrt(v·S), floor digit-by-digit integer sqrt.
- `sin(th)`, `cos(th)` for th ∈ [0, 2π·S) — octant-reduced polys (`bx4_sin`/`bx4_cos`).
- `reduce2pi(th)` — exact two-limb range reduction for th < 16384·S (`bx4_reduce2pi`).

## RoPE tables — derived, not committed

For d=64, positions p = 0..T−1 (T = holdout seq length), pairs j = 0..31:

```
x_j     = td(j · LN10000_q, 32)          -- (2j/d)·ln10000 in Q.24
THETA_j = fxexp(−x_j)                    -- 10000^(−2j/d) in Q.24  (THETA_0 = S exactly)
ANG     = reduce2pi(p · THETA_j)         -- p·θ_j mod 2π   (p·θ ≤ 558·S ≪ 16384·S: in-domain)
CT[p][j] = cos(ANG) ;  ST[p][j] = sin(ANG)
```

No table is committed because none is needed: the table is a pure integer function of the spec.
(Float-trained RoPE differs from these integer tables by ≲2e-5 rad at p≈558 — part of the
quantized-eval semantics, exactly like weight quantization itself.)

## Forward pass (2-block pre-norm, mirrors the trained float arch)

All weights W[in][out]. Holdout ids from first-appearance vocab over train[:2000] (V=27).
Input rows: `h[p] = w_e[ids[p]]` (row select, exact) for p = 0..T−1, T = len(ids)−1.

- **dot / matvec**: `out_c = td( Σ_i x_i·W[i][c], S )` — exact integer sum, ONE truncation.
- **layernorm** (γ=S, β=0 committed): `µ = td(Σx, d)`; `dx = x−µ`;
  `var = td( Σ td(dx_i·dx_i, S), d )`; `den = fxsqrt(var + LNEPS_q)`;
  `y_i = td(dx_i·S, den)`; out_i = `td(y_i·γ_i, S) + β_i` (= y_i for γ=S,β=0).
- **rope row p** (lm10 `rope_fx` form): for j=0..31, C=CT[p][j], Sn=ST[p][j]:
  `y[2j] = td(x[2j]·C, S) − td(x[2j+1]·Sn, S)`; `y[2j+1] = td(x[2j]·Sn, S) + td(x[2j+1]·C, S)`.
- **block** (blk = 1 then 2):
  `ln1 = LN(h)` rowwise; `q = rope(mv(ln1,wq))`, `k = rope(mv(ln1,wk))`, `v = mv(ln1,wv)`;
  scores row i over j ≤ i only (causal by construction, no mask constant):
  `sc_j = td( td(Σ_c q[i][c]·k[j][c], S) · ISD_q, S )`;
  `w = softmax(sc)` = `m = max(sc); e_j = fxexp(sc_j − m); z = Σe; w_j = td(e_j·S, z)`;
  attn out (lm10 per-term form): `o[c] = Σ_{j≤i} td(w_j·v[j][c], S)`;
  `h = h + o` (exact); `ln2 = LN(h)`;
  `f = mv(relu(mv(ln2, wf1)), wf2)` with `relu = max(0,·)`; `h = h + f` (exact).
- **readout**: `logits[p] = mv(h[p], w_o)`; `pred[p] = argmax` (first max wins, strict >).
- **metric** (`force_score`, unchanged from v1/v2): for every occurrence m of `"-- "` in the
  holdout text with m+6 < T: score += Σ_{k=0..3} [ pred[m+2+k] == ids[m+3+k] ].

## Overflow (Rail 63-bit safety)

Python verifier records the max |exact-sum accumulator| and max fxsqrt argument over the whole
eval and FAILS if either ≥ 2⁶², proving the Rail evaluation cannot have wrapped for THIS
artifact + holdout. The bound is part of the attestation record (`max_acc_bits`).
**Measured on the committed artifact: max_acc_bits = 60** (T = 559) — 2 bits of headroom.

## Signed message (v3)

```
r37|v3|train=<sha>|holdout=<sha>|weights=<sha>|metric=<m>/64|pred=<sha>|T=55|order=<14 names>|q=Q.24|eval=xint-q24-v1|pulse_pre=<id>|pulse_post=<id>
```

`pred=<sha>` is the SHA-256 of the full T-char prediction string (every argmax decision, not
just the 64 scored digits) — the signature binds the ENTIRE eval output trace, so "metric
reproduced" is a corollary of "output reproduced". The float-forward metric (62/64, v2 record)
remains as the training-time result; the v3 metric is the canonical, machine-checkable one.
Gate threshold unchanged (T′=55 > lookup 48).
