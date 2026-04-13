# RAIL EVOLUTION — Master Checklist

Started 2026-04-13. Every upgrade, ranked and tracked.

## TRIVIAL (under 30 min)

- [x] CSP-split thruster_engine.html for ledatic.org (done 2026-04-13)
- [x] CSP-split plasma_lab.html (done 2026-04-13)
- [x] CSP-split mhd_web.html (done 2026-04-13)
- [x] CSP-split ramjet.html (done 2026-04-13)
- [x] parse_float input validation — _atof("") returns 0.0, already safe (2026-04-13)
- [ ] Landing page preview thumbnails (CSS-only)
- [x] GPU dispatch for matmul in tensor.rail (done 2026-04-13)
- [x] GPU dispatch for relu in tensor.rail (done 2026-04-13)
- [ ] GPU dispatch for tensor_add, tensor_mul, tensor_scale
- [x] Cache gpu_available check (float_arr flag, checks once) (2026-04-13)
- [x] Clean /tmp/rail_tg_*.txt after GPU ops (2026-04-13)

## EASY (1-4 hours)

- [ ] GPU dispatch for ALL remaining tensor ops (sigmoid, tanh, exp, softmax, transpose, SGD, cross-entropy, relu_backward)
- [x] tensor_gpu as persistent daemon — TCP on :9300, auto-fallback to file mode (2026-04-13)
- [ ] Binary pipe GPU protocol from Rail (byte_at/byte_set headers)
- [x] Deploy ramjet_3d.html to ledatic.org/plasma/thruster3d (2026-04-13)
- [ ] MHD solver: adaptive steps_per_frame (if frame <10ms, double steps)
- [ ] Validation scatter plot in thruster engine Validate tab
- [x] parse_int as compiler builtin — _strtol via _str_unwrap (2026-04-13)
- [ ] Float self-loop TCO for d8-d15 callee-saved registers

## MEDIUM (1-2 days) — THE 13 TENSOR PRIMITIVES

These unblock autograd.rail (which is already complete):

- [x] tensor_relu_mask (2026-04-13)
- [x] tensor_gelu_backward (2026-04-13)
- [x] tensor_softmax — numerically stable, sums to 1.0 (2026-04-13)
- [x] tensor_sum_last (2026-04-13)
- [x] tensor_sum_batch (2026-04-13)
- [x] tensor_mean_last (2026-04-13)
- [x] tensor_broadcast_last (2026-04-13)
- [x] tensor_mul_broadcast (2026-04-13)
- [x] tensor_one_hot (2026-04-13)
- [x] tensor_embedding_lookup (2026-04-13)
- [x] tensor_slice_row (2026-04-13)
- [x] tensor_accumulate_row (2026-04-13)
- [x] tensor_scale_by_loss (2026-04-13)

ALL 13 DONE + 10 additional autograd utilities added.
Autograd.rail LINKS. Forward pass verified (C[0,0]=2.2 correct).
Backward pass segfaults in ag_backward — list depth issue, needs debug.

## MEDIUM (1-2 days) — OTHER

- [ ] dlopen GPU dispatch (tensor_gpu.dylib, zero-copy via unified memory)
- [ ] Wire self_train.rail to tensor.rail (kill Python/MLX dependency)
- [ ] WASM: add float_arr support to WASM backend, port mhd.rail
- [ ] Full 2D MHD replacing parametric model in thruster_engine.html (WebGL compute)
- [ ] Binary float array file I/O builtins (float_arr_write_bin, float_arr_read_bin)
- [ ] Autograd on GPU (backward passes dispatch through Metal)
- [ ] Proper Laplace current distribution in thruster engine
- [ ] CF Worker content-type routing for .css/.js/.wasm
- [ ] GPU matmul double-buffered persistent buffers

## HARD (3-5 days)

- [ ] Metal IR direct from compile.rail (backend #5 — Rail source → .metal)
- [ ] Train neural_mhd entirely in Rail on Metal (first pure-Rail GPU training)
- [ ] Implicit MHD time-stepping (backward Euler, 100-1000x larger dt)
- [ ] WebGPU compute for browser physics (WGSL shaders, iPhone GPU)
- [ ] Transformer forward pass in Rail (attention, SwiGLU, layernorm — types exist, wiring needed)
- [ ] Self-training loop on Metal (zero Python, compiler as oracle)
- [ ] Darwin syscall libc (eliminate ld -lSystem)
- [ ] WASM stdlib: filter/map/fold as builtins
- [ ] Coil optimization with real EM solver (Biot-Savart, Nelder-Mead)

## EPIC (1-3 weeks)

- [ ] Full Metal backend in compile.rail (Rail → Metal for any pure function)
- [ ] 10M parameter model trained entirely in Rail on Metal
- [ ] 3D axisymmetric MHD on Metal with volume raymarching
- [ ] Hardware-in-the-loop thruster testbed (serial/SCPI control)
- [ ] Source-to-source autodiff in compile.rail (compiler pass)
- [ ] Rail package registry + CDN

## ALREADY DONE (verified this session)

- [x] parse_float compiler builtin (2026-04-13)
- [x] Metal tensor compute server — 13 kernels, 269 GFLOPS (2026-04-13)
- [x] tensor.rail GPU auto-dispatch for matmul + relu (2026-04-13)
- [x] Compiler self-hosted with parse_float, 98/98, fixed-point (2026-04-13)
- [x] thruster_engine.html — SI-calibrated MPD design (2026-04-13)
- [x] mhd_axisym.metal — 256×512 live GPU MHD solver (2026-04-13)
- [x] Deployed to ledatic.org/plasma/* (2026-04-13)
- [x] Mobile-responsive design (2026-04-13)
- [x] MLP forward pass on GPU verified (2026-04-13)

## ALREADY DONE (pre-existing, confirmed by survey)

- [x] Autograd engine — 810 lines, 11 tracked ops, tape-based (complete, needs 13 tensor prims)
- [x] Adam optimizer — full implementation in tools/railml/train.rail
- [x] Transformer types — AttnWeights, FFNWeights, LayerWeights, Model, Tokenizer
- [x] Binary weight I/O — parse_config, parse_one_weight, fill_tensor_data
- [x] RailGPT 400M — from-scratch, live on :8082, 80% compile L1-L2
- [x] Self-training orchestrator — 848 lines, 25-level curriculum, 117 rounds
- [x] Data pipeline — 22K+ examples, 18 sources, SHA-256 dedup
- [x] Benchmark suite — 30 tasks, 6 bands, output-verified
- [x] Intervention ledger — append-only audit trail
- [x] Grammar pre-check — syntax validation before compiler
- [x] gpu_host.rail — Metal GPU bridge framework
- [x] dlopen.rail + mmap.rail — FFI infrastructure
- [x] Net2Net model growth — 10M→50M→200M→400M

## THE CRITICAL PATH

```
13 tensor primitives → autograd links → train.rail wires up
    → first training run on Metal → self-training on Metal
    → Rail improves itself on its own hardware
```

The 13 primitives are the ONLY blocker. Everything else is built.
