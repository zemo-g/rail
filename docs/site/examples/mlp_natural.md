# mlp_natural — an MLP forward pass in natural float scalars

A 2-input → 2-hidden → 1-output network with ReLU, written the way you'd *want* to write ML in Rail: float scalars as ordinary function parameters — no array boxing, no out-cell threading. On the pre-type-layer compiler this exact program segfaulted at runtime (a float scalar param miscompiled as a heap pointer); it runs correctly since the type-core increments, with float-marking proven by whole-call-site agreement analysis.

This is the `#grad` arc's flagship demo — the same natural-float style is what `#grad` differentiates at compile time.

**Source** (`examples/mlp_natural.rail`):

```rail
relu x = if x > 0.0 then x else 0.0

-- one neuron: two weighted inputs plus a bias, then ReLU.
neuron w1 x1 w2 x2 b = relu (w1 * x1 + w2 * x2 + b)

-- forward pass. h1/h2 are float user-fn RESULTS fed straight back into more
-- float params -- chained float computation across function boundaries, the
-- pattern the AD/transformer stdlib had to box around before.
mlp x1 x2 =
  let h1 = neuron 0.5 x1 0.25 x2 0.0
  let h2 = neuron 0.25 x1 0.5 x2 0.0
  neuron 0.5 h1 0.5 h2 0.0

main =
  let _ = print (cat ["mlp(1.0, 2.0)  = ", show_float (mlp 1.0 2.0)])
  let _ = print (cat ["mlp(1.0, 0.0)  = ", show_float (mlp 1.0 0.0)])
  let _ = print (cat ["relu(-3.0)     = ", show_float (relu (0.0 - 3.0))])
  let _ = print (cat ["relu(2.75)     = ", show_float (relu 2.75)])
  0
```

**Run:**

```bash
./rail_native run examples/mlp_natural.rail
```

**Output** (captured 2026-06-10):

```
mlp(1.0, 2.0)  = 1.125
mlp(1.0, 0.0)  = 0.375
relu(-3.0)     = 0
relu(2.75)     = 2.75
```

The hand-check for `mlp(1.0, 2.0)`: h1 = relu(0.5·1 + 0.25·2) = 1.0, h2 = relu(0.25·1 + 0.5·2) = 1.25, out = relu(0.5·1.0 + 0.5·1.25) = **1.125**. Floats live unboxed in ARM64 `d`-registers end to end.
