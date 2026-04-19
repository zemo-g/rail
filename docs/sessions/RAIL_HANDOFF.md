# Rail — Session Handoff (2026-04-14, v2.1.2)

**Last commit:** `738af7e rail v2.1.2: full dylib GPU coverage + transformer + 3-class training`
**Tag:** `v2.1.2` (pushed to zemo-g/rail)

## One-Line Sanity

```bash
cd ~/projects/rail && ./rail_native test && ./rail_native run tools/train/three_class_mlp.rail | tail -3
```

Expect `105/105 tests passed` followed by the final loss and `100%` accuracy.

## What's in the box (v2.1.2)

### Compiler
- `parse_float`, `parse_int`, scientific notation, binary f32 I/O, null-safe `==`
- 105 tests. Self-compiles byte-identical.

### Metal GPU
- `libtensor_gpu.dylib` — **15 exports**, persistent MTLBuffer pool, fused matmul+bias+relu
- Every tensor op dispatches via FFI. No /tmp files on the hot path.
- `tools/metal/smoke_test.c` — 29 dylib exports verified in pure C (no Rail)

### Tensor stdlib (`stdlib/tensor.rail`)
- Full GPU auto-dispatch: matmul, add, mul, scale, relu, sigmoid, exp, tanh,
  softmax, transpose, relu_backward, sgd_update, cross_entropy, matmul_relu (fused)
- CPU fallbacks remain when the dylib is absent

### Transformer stdlib (`stdlib/transformer.rail`) ← NEW
- `linear`, `linear_relu` (fused kernel), `layernorm`
- `scaled_dot_attention`, `scaled_dot_attention_causal`
- `feedforward`, `transformer_block_prenorm`
- Forward-pass-only. Training-side still TODO.

### Trainable networks
- `tools/train/first_gpu_train.rail` — XOR, 50 steps, loss 0.43 → 0.04
- `tools/train/xor_converge.rail` — XOR, 500 steps, loss 0.38 → 8.88e-16
- `tools/train/three_class_mlp.rail` — **3-class classifier, 100% accuracy**
  - Forward + backward + SGD entirely on Metal via dylib
  - Multi-class cross-entropy, analytical backprop, transpose-based grad

### Benchmarks & tooling
- `tools/bench/tensor_ops.rail` — per-op latency on the dylib path
  - ~5ms fixed per-call overhead (f64↔f32 + command buffer dispatch)
  - N ≥ 1024² is where GPU compute starts to dominate
- `tools/deploy/gen_plasma_landing.rail` — CSS-only animated thumbnails
- `tools/deploy/cf_deploy.rail` — auto Content-Type from key suffix

## Gotchas discovered this session

1. **`0.0 + int_expr` doesn't reliably produce a float in `float_arr_set`** —
   the tagged-int bit pattern gets stored as a subnormal double. Always
   use `int_to_float expr` when mixing integer work with float_arr writes.

2. **Deeply nested `match` chains can confuse the parser.** Six-deep nested
   `match | ADT -> match | ADT -> ...` works; the same code split across
   `let`-bindings hits "expected decl" errors. Flatten or extract helpers.

3. **Foreign declarations are load-bearing for int untagging.** Rail emits
   the `asr/tst/csel` untag sequence only when `afind` locates the callee
   in the arity map (base ≥ 1000). Missing `foreign` decl → Rail treats the
   callee as a regular Rail function and skips untagging → dylib receives
   tagged values (2n+1) and chaos ensues. Always declare every C ABI entry.

## Key files

| Path | What |
|---|---|
| `tools/compile.rail` | Compiler (4,778 lines) |
| `stdlib/tensor.rail` | CPU + GPU tensors (1,232 lines) |
| `stdlib/autograd.rail` | Reverse-mode AD (852 lines) |
| `stdlib/transformer.rail` | Attention, LN, FFN — NEW |
| `tools/metal/tensor_gpu.metal` | 14 Metal kernels |
| `tools/metal/tensor_gpu_lib.m` | Dylib host (585 lines) |
| `tools/metal/smoke_test.c` | Dylib C-side validator — 29 checks |
| `tools/train/three_class_mlp.rail` | Multi-class training on Metal |
| `tools/railml/transformer_forward.rail` | End-to-end forward test |
| `tools/bench/tensor_ops.rail` | Tensor op latency benchmark |
| `CHANGELOG.md` | v2.1.0 + v2.1.1 + v2.1.2 |
| `EVOLUTION.md` | Master checklist |

## Start here next session

1. `cd ~/projects/rail`
2. `./rail_native test` → `105/105 tests passed`
3. `./rail_native run tools/train/three_class_mlp.rail | tail -3` → `100%`
4. `cat CHANGELOG.md` → latest entries
5. `cat EVOLUTION.md` → remaining checklist

## Rebuild dylib after Metal kernel edits

```bash
cd tools/metal
rm -f /tmp/tensor_gpu.metallib
xcrun metal -c tensor_gpu.metal -o /tmp/tensor_gpu.air
xcrun metallib /tmp/tensor_gpu.air -o /tmp/tensor_gpu.metallib
clang -shared -fobjc-arc -framework Metal -framework Foundation \
  -install_name /Users/ledaticempire/projects/rail/tools/metal/libtensor_gpu.dylib \
  tensor_gpu_lib.m -o libtensor_gpu.dylib
./smoke_test  # verify all 29 C-side checks still pass
```

## Critical path for the next session

```
transformer forward → training loop → text generation → self-training
  → everything else in EVOLUTION.md
```

The forward pass works. What's missing for end-to-end LM training:
1. Attention backward (softmax bwd, matmul bwd chain)
2. LayerNorm backward
3. Embedding lookup + its backward
4. Adam optimizer (SGD works; Adam converges faster for transformers)
5. Toy-size LM training on character-level data
