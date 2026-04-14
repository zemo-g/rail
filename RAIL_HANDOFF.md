# Rail — Session Handoff (2026-04-13)

**Last session:** 2026-04-13 (6 hours, 9 commits, rail v2.1 shipped)
**Last commit:** `5478967 gitignore: compiled Metal host binaries`

## One-Line Sanity Check

```bash
cd ~/projects/rail && ./rail_native test && ./rail_native run tools/train/first_gpu_train.rail | tail -3
```

Should print `98/98 tests passed` followed by `Loss decreased: YES / Training Complete`.

## Start Here

1. `cd ~/projects/rail`
2. `./rail_native test` → `98/98 tests passed`
3. `./rail_native self && diff rail_native /tmp/rail_self` → nothing (fixed-point)
4. `cat EVOLUTION.md` → full checklist
5. Read this file for what's in flight

## What's Built and Working (v2.1)

### Compiler
- `parse_float`, `parse_int` builtins via `_str_unwrap + _atof/_strtol`
- Null-safe `==`/`!=` — heap_object == integer no longer segfaults
- Float self-loop TCO — tensor CPU loops run at register speed
- Scientific notation: `1e6`, `1.5e-3`, `6.022e23`
- Binary f32 I/O: `float_arr_to_f32_file` / `float_arr_from_f32_file`
- Self-hosted, 98/98, fixed-point

### Metal GPU (`tools/metal/`)
- `tensor_gpu.metal` — 13 kernels, 269 GFLOPS matmul on M4 Pro
- `tensor_gpu.m` — CLI with file modes (matmul, matmul_bin, add, mul, relu,
  tanh_fwd, exp, sigmoid, softmax, transpose) + benchmark + stdin protocol
- `tensor_daemon.py` — persistent TCP server on :9300 (optional, for speed)
- **Rebuild binary:** `cd tools/metal && clang -framework Metal -framework Foundation -fobjc-arc tensor_gpu.m -o tensor_gpu`

### Tensor stdlib (`stdlib/tensor.rail` — 1004 lines)
- 13 autograd primitives: relu_mask, gelu_backward, softmax, sum_last/batch,
  mean_last, broadcast_last, mul_broadcast, one_hot, embedding_lookup,
  slice_row, accumulate_row, scale_by_loss
- 10 utilities: tensor_matmul, tensor_copy, tensor_cross_entropy_loss,
  tensor_from_int, tensor_to_int, tensor_get_int, tensor_map_scalar,
  tensor_ones_like_shape, tensor_scalar_val, tensor_sum_all
- GPU dispatch: matmul (binary pipe), relu, exp, tanh, sigmoid, softmax, transpose
- CPU fallbacks for all ops (registers-only after float TCO fix)

### Autograd (`stdlib/autograd.rail` — 810 lines)
- **LINKS and WORKS** — verified with XOR MLP training
- Tape-based reverse-mode AD
- 11 tracked ops: matmul, add, sub, mul, relu, gelu, softmax, layer_norm,
  cross_entropy, embedding, leaf
- Backward pass produces correct gradients (dA, dB verified analytically)

### Plasma platform (`ledatic.org/plasma/*`)
- `/plasma` — landing with 5 tools
- `/plasma/engine` — SI-calibrated MPD design (Maecker model + validation plot)
- `/plasma/lab` — interactive electrode + magnet rings
- `/plasma/mhd` — 2D WASM MHD (Orszag-Tang, 2.5KB binary)
- `/plasma/ramjet` — 1D nozzle with magnetic coils
- `/plasma/thruster3d` — 3D helical arc thruster
- All CSP-compliant (HTML + external CSS + external JS), mobile-responsive

### Live GPU MHD streamer
- `tools/plasma/mhd_live` (gitignored) — 256×512 Metal solver, adaptive stepping
- `tools/plasma/mhd_server.py` — HTTP frame server on :9200
- `ledatic.org/plasma/engine/live` when both running

### First GPU Training (`tools/train/first_gpu_train.rail`)
- XOR MLP, 2-layer, 50 steps, loss 0.425 → 0.043
- Every matmul dispatched to Metal GPU

## The Critical Path

**dlopen GPU dispatch** is the single highest-leverage upgrade remaining.
Current binary-file pipe: ~5ms/op. Target dlopen: ~0.5ms/op. 10x speedup
unlocks viable flywheel training on Metal.

Sketch:
1. Build `libtensor_gpu.dylib` from `tools/metal/tensor_gpu.m`
2. Export C ABI: `tensor_gpu_matmul(float *A, float *B, float *C, int M, int K, int N)`
3. Rail loads via `stdlib/dlopen.rail` (already exists)
4. `tensor.rail` calls via FFI — unified memory = zero-copy on Apple Silicon

Once dlopen lands → training speed 10-100x → flywheel viable on Metal →
self-training loop closes without Python/MLX.

## Next Priorities (from EVOLUTION.md)

### MEDIUM
- [ ] dlopen GPU dispatch ← **HIGHEST LEVERAGE**
- [ ] Wire self_train.rail to tensor.rail (kill Python MLX dep)
- [ ] WASM: add float_arr support to WASM backend
- [ ] Full 2D MHD in thruster_engine.html (WebGL compute, replace parametric)
- [ ] Autograd on GPU (backward already partial via matmul dispatch)
- [ ] CF Worker content-type routing

### HARD
- [ ] Metal IR from compile.rail (5th backend — Rail source → .metal)
- [ ] Train neural_mhd in Rail on Metal (needs autograd list-depth work)
- [ ] Transformer forward pass in Rail (types in tools/railml/inference.rail)
- [ ] Self-training loop on Metal (zero Python)

## Gotchas

1. **`head []` returns 0** — by design
2. **Lambda capture can segfault** — use named functions
3. **String `++`** only in return position, use `join` in let bindings
4. **Single-char `split`** — use `str_split` for multi-char
5. **Scientific notation** — FIXED this session (`1e6` works)
6. **`tensor == 0` segfault** — FIXED this session (null/type guards in `_rail_eq`)

## Active Processes

```bash
# Check what's running
ps aux | grep -E "tensor_daemon|mhd_live|mhd_server" | grep -v grep
lsof -i :9200   # MHD stream server
lsof -i :9300   # Tensor GPU daemon

# Start GPU daemon (optional — tensor.rail falls back to file mode)
nohup /opt/homebrew/bin/python3.11 tools/metal/tensor_daemon.py 9300 > /tmp/tensor_daemon.log 2>&1 &

# Start MHD live streamer
cd tools/plasma && nohup ./mhd_live > /tmp/mhd_live.log 2>&1 &
nohup /opt/homebrew/bin/python3.11 mhd_server.py 9200 > /tmp/mhd_server.log 2>&1 &
```

## Key Files

| Path | What |
|---|---|
| `tools/compile.rail` | The compiler (4,730+ lines) |
| `stdlib/tensor.rail` | CPU + GPU tensors (1,004 lines) |
| `stdlib/autograd.rail` | Reverse-mode AD (810 lines) |
| `tools/metal/tensor_gpu.metal` | 13 Metal compute kernels |
| `tools/metal/tensor_gpu.m` | Metal host binary source |
| `tools/metal/tensor_daemon.py` | Persistent GPU server |
| `tools/train/first_gpu_train.rail` | First GPU training — reference impl |
| `tools/train/self_train.rail` | Flywheel orchestrator (stuck at L6, needs tensor.rail wiring) |
| `tools/railml/inference.rail` | Transformer types (forward pass stubbed) |
| `tools/railml/train.rail` | Adam optimizer (stubs need real model wiring) |
| `tools/plasma/thruster_engine.html` | SI-calibrated MPD design engine |
| `tools/plasma/mhd_axisym.metal` | Live 2D axisymmetric MHD solver |
| `tools/deploy/cf_deploy.rail` | Cloudflare KV deploy (needs `~/Desktop/rings` token) |
| `EVOLUTION.md` | Master checklist |
| `CHANGELOG.md` | Release history |

## Deploy Pattern (CSP-Split HTML)

For any new ledatic.org tool with inline `<style>`/`<script>`:

```python
import re
html = open('tool.html').read()
css = re.search(r'<style>(.*?)</style>', html, re.DOTALL).group(1)
js = re.search(r'<script>(.*?)</script>', html, re.DOTALL).group(1)
html2 = re.sub(r'<style>.*?</style>', '<link rel="stylesheet" href="/PATH/KEY.css">', html, flags=re.DOTALL)
html2 = re.sub(r'<script>.*?</script>', '<script src="/PATH/KEY.js"></script>', html2, flags=re.DOTALL)
# Upload 3 files to CF KV: PATH/KEY.css (text/css), PATH/KEY.js (application/javascript), PATH/KEY (text/html)
```

Token: `~/Desktop/rings`
Account: `2acd6ceb3a0c57f1f2b470433d94bc87`
KV namespace: `be34022eeedc4d6fb802087156eb1aae`

## Session History (9 commits)

```
5478967 gitignore: compiled Metal host binaries
8ee13a8 compiler: binary f32 I/O + scientific notation literals
afed42c tensor: softmax + transpose GPU, MHD adaptive, val plot
82516e4 compiler: float self-loop TCO
62fca8d tensor: GPU exp, tanh, sigmoid + generic dispatchers
ebdaa86 rail_native: fixed-point rebuild
8f916ba compiler: parse_int builtin, tensor daemon
3e88c6a tensor: cache gpu_available, deploy thruster3d
1703a0d rail v2.1: Metal GPU tensor ops, autograd, plasma, training
```
