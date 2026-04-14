# RAIL EVOLUTION — Master Checklist

Started 2026-04-13. Every upgrade, ranked and tracked.

## v2.14.0 (2026-04-14) — *Metal IR scaffold*

- [x] Runtime `tgl_unary_from_source` — JIT-compile Metal source +
      dispatch, with library-and-pipeline caching
- [x] `stdlib/metal_kernel.rail` — `metal_kernel_header`,
      `emit_metal_unary`, `metal_apply_unary` helpers
- [x] `tools/metal/rail_to_metal.rail` — AST → Metal
      C-expression translator (FL / V / O / ?)
- [x] End-to-end proof: three user kernels (`relu2`, `squared`,
      `shifted`) JIT-compiled from Rail source and dispatched on
      GPU in a single Rail process
- [ ] v2.15+: wire Rail parser so `\x -> expr` lambdas become
      GPU kernels automatically; extend to multi-input kernels
      and reductions

## v2.13.0 (2026-04-14) — *WASM map / filter / fold*

- [x] `$map`, `$filter`, `$fold` as WASM runtime builtins
      (closures only; named functions still require a lambda wrap)
- [x] `$call_closure` canonical closure-invocation helper
- [x] Body-structure lambda lookup — distinguishes `\x -> x * 2`
      from `\x -> x > 2` (both had been colliding on same slot)
- [x] `$clos_t` + function table always emitted (size-1 stub
      when no lambdas), unblocking the runtime helpers when
      programs do use higher-order ops

## v2.12.0 (2026-04-14) — *Multi-head attention, learnable LayerNorm*

- [x] Multi-head causal attention (forward + backward via per-head
      `attention_backward` composition) — `stdlib/transformer.rail`
      adds `extract_head` / `insert_head` column-block helpers
- [x] Learnable LayerNorm γ/β — `layernorm_backward_gb` pure-Rail
      reduction (no new kernel), Adam-updated alongside weights
- [x] Xavier-initialized weights (`scale = sqrt(6/(fan_in+fan_out))`)
- [x] End-to-end: 4-head d_model=32 transformer LM on 383-char
      Shakespeare, loss 4.30 → 0.00433 in 200 steps.  Beats bigram,
      uniform, and single-head baselines.
- [x] Discovery: ARM64 register-spill budget caps function arity
      around 30 parameters — workaround is list-bundled parameters

## v2.2.0 (2026-04-14) — *The Suite*

### Landed

- [x] Overture #1: `0.0 + int_expr` miscompile fixed (t106 regression)
- [x] Overture #2: deeply-nested-`match` workaround documented in CLAUDE.md
- [x] Overture #4: `int_to_float` / `float_to_int` formalized in quick-ref
- [x] Movement I: fused matmul+bias+GELU kernel + `linear_gelu` wrapper
- [x] Movement I: batched matmul `[B,M,K]@[B,K,N]`
- [x] Movement I: race-free parallel sum (`tensor_sum_partials` + `tgl_sum_f64`)
- [x] Movement II: `softmax_backward` kernel + dylib export
- [x] Movement II: fused `ce_softmax_backward` kernel + dylib export
- [x] Movement II: `layernorm_backward` kernel + dylib export
- [x] Movement IV: sinusoidal positional encodings in `stdlib/transformer.rail`
- [x] Movement VI: Rail AST → `.metal` kernel emitter scaffold (relu2 demo)
- [x] Finale: CHANGELOG + tag + push

Dylib export count: 15 → 24. Tests: 105/105 → 106/106. Fixed-point preserved.

### Queued for v2.3 (design intact, code deferred)

- [ ] Overture #3: float self-loop TCO — the properly-scheduled version
- [ ] Movement I: f16 half-precision variants of every unary op
- [x] Movement II: attention backward (full Q/K/V chain) — pure-Rail
      composition over softmax_backward + matmul + transpose, no new
      kernel; gradcheck 18/18 (2026-04-14, v2.4.0)
- [x] Movement II: embedding scatter-add backward — *not needed*; the
      v2.4 transformer uses one-hot @ W_E embedding so matmul
      backward IS the scatter-add (2026-04-14)
- [x] Movement V: single-head causal transformer LM trains end-to-end
      on Shakespeare — `tools/train/lm_transformer.rail`, loss
      15.2→2.62 in 300 Adam steps, beats uniform 3.47 (2026-04-14)
- [x] Movement V.5: layernorm fwd+bwd + residual + FFN composing into
      the LM. LN backward 9/9 gradcheck. Loss 2.90 (plateaus above v2.4
      on tiny corpus — optimization not architecture) (2026-04-14, v2.5.0)
- [x] Movement III.1: Adam optimizer — fused GPU kernel, `stdlib/optim.rail`,
      XOR → 3.78e-10 in 200 steps (2026-04-14)
- [x] Movement III.2: cosine_decay LR schedule + clip_grad_norm in
      `stdlib/optim.rail` (2026-04-14)
- [x] Movement III.3: checkpoint save/load — `stdlib/checkpoint.rail`,
      manifest + per-tensor f32 binaries, round-trip verified (2026-04-14)
- [x] Movement IV.1: char-level tokenizer — `stdlib/tokenizer.rail`,
      10,320-char round-trip exact (2026-04-14)
- [x] Movement IV.2: end-to-end LM training — `tools/train/lm_shakespeare.rail`,
      loss 15.02 → 2.10 on Shakespeare, uniform baseline 3.47 (2026-04-14)
- [x] Movement IV.3: generation — `stdlib/sampling.rail` argmax/top-k/temperature
      + `tools/train/lm_generate.rail` (2026-04-14)
- [x] Movement IV: tokenizer in Rail — `stdlib/tokenizer.rail`,
      char-level (BPE-floor), shipped 2026-04-14, v2.3.0
- [x] Movement IV: end-to-end LM training on char-level Shakespeare —
      shipped twice: v2.3.0 (bigram MLP) and v2.4.0/v2.5.0 (transformer)
- [x] Movement IV: generation (argmax / top-k / temperature) —
      `stdlib/sampling.rail` + `tools/train/lm_generate.rail`,
      shipped 2026-04-14, v2.3.0
- [ ] Movement V: `self_train.rail` cutover to Rail-native inference
- [ ] Movement V: compiler-as-teacher in-process (no `shell` round-trip)
- [ ] Movement VI: `#metal_kernel` directive / compile-time kernel gen
- [x] Movement VII: float_arr support in WASM backend — full float
      stack: literals, arithmetic with var-aware type inference,
      float_arr_new/get/set, sqrt/fabs/floor/ceil intrinsics,
      int↔float conversions, show_float. Smoke proof:
      `tools/train/wasm_diffuse.rail` runs 1-D diffusion + L2 norm
      under wasmtime to 6-digit accuracy. Shipped 2026-04-14, v2.7.0.
      *Closed in v2.8*: sin/cos/exp/log/pow/tanh polyfills land
      Taylor-series implementations to ~9-digit accuracy.
- [x] Movement VII: WASM transcendentals — sin/cos/exp/log/pow/tanh
      via Taylor + range reduction, 9-digit accuracy on most inputs
      (log: 8 digits). Shipped 2026-04-14, v2.8.0.
- [x] Movement VII: MHD simulates under WASM — 128×128 Orszag-Tang
      vortex, 100 Lax-Friedrichs steps, exact mass/energy/divB
      conservation. Gated on v2.10's float PARAM inference + WASM
      tail-call elimination, both now shipped. Shipped 2026-04-14, v2.10.0.
- [x] Movement VII: MHD full run to t=π under WASM — 749 steps,
      arena_mark/arena_reset in WASM runtime keeps memory flat.
      Full vortex physics: ρ_min 2.778→1.269→2.363. Shipped
      2026-04-14, v2.11.0.
- [ ] Movement VII: WebGPU compute shaders
- [x] Movement VIII: REPL `:load file.rail` — shipped 2026-04-14, v2.6.0.
      Definition persistence across expressions already worked; the
      `:load` slurp is the new piece.
- [ ] Movement VIII: LSP hover + jump-to-def (no progress)
- [x] Movement VIII: did-you-mean suggestions for unbound names —
      Levenshtein ≤ 2 over arity-map keys, shipped 2026-04-14, v2.6.0.
- [ ] Movement IX: implicit MHD time stepping (backward Euler on Metal)
- [ ] Movement IX: Laplace current distribution in thruster engine
- [ ] Movement IX: full 2D MHD in thruster_engine.html (WebGL compute)

## TRIVIAL (under 30 min)

- [x] CSP-split thruster_engine.html for ledatic.org (done 2026-04-13)
- [x] CSP-split plasma_lab.html (done 2026-04-13)
- [x] CSP-split mhd_web.html (done 2026-04-13)
- [x] CSP-split ramjet.html (done 2026-04-13)
- [x] parse_float input validation — _atof("") returns 0.0, already safe (2026-04-13)
- [ ] Landing page preview thumbnails (CSS-only)
- [x] GPU dispatch for matmul in tensor.rail (done 2026-04-13)
- [x] GPU dispatch for relu in tensor.rail (done 2026-04-13)
- [x] GPU dispatch for tensor_add, tensor_mul, tensor_scale (2026-04-14)
- [x] Cache gpu_available check (float_arr flag, checks once) (2026-04-13)
- [x] Clean /tmp/rail_tg_*.txt after GPU ops (2026-04-13)

## EASY (1-4 hours)

- [x] GPU dispatch for remaining tensor ops — exp, tanh, sigmoid, softmax,
      transpose all dispatch to Metal (2026-04-13). Still CPU-only: SGD,
      cross_entropy, relu_backward (autograd internal ops).
- [x] tensor_gpu as persistent daemon — TCP on :9300, auto-fallback to file mode (2026-04-13)
- [x] Binary pipe GPU protocol — float_arr_to_f32_file + float_arr_from_f32_file
      as compiler builtins. tensor.rail matmul uses binary path (no text
      parsing). Metal host adds matmul_bin file mode (2026-04-13)
- [x] Scientific notation in float literals — 1e6, 1.5e-3, 6.022e23 all parse
      correctly. Lexer extended to consume optional e[+-]?digits suffix
      after integer or fractional part (2026-04-13)
- [x] Deploy ramjet_3d.html to ledatic.org/plasma/thruster3d (2026-04-13)
- [x] MHD solver: adaptive steps_per_frame — doubles when frame <10ms,
      halves when frame >30ms, range [5..200] (2026-04-13)
- [x] Validation scatter plot in thruster engine Validate tab —
      measured vs predicted thrust with ±30% error band (2026-04-13)
- [x] parse_int as compiler builtin — _strtol via _str_unwrap (2026-04-13)
- [~] Float self-loop TCO — PARTIAL. Initial fix (remove body_has_float guard
      in mark_int_params) caused segfaults in self-recursive functions with
      float params. Reverted. Proper fix requires handling float params in
      the self-loop TCO register scheduling. See HARD tier for real work.

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
Backward pass WORKS after compiler fix (_rail_eq null/type-mismatch guard).
First training run: XOR MLP loss 0.425→0.043 on Metal GPU.

## MEDIUM (1-2 days) — OTHER

- [x] dlopen GPU dispatch — libtensor_gpu.dylib with C ABI, tensor.rail
      auto-detects and uses FFI path when dylib present. Zero-copy for
      float_arr payload. Fixed ObjC runtime init with `__attribute__((constructor))`
      and absolute install_name. XOR network converges to machine precision
      in 500 steps (loss 0.38 → 8.88e-16). (2026-04-13)
- [ ] Wire self_train.rail to tensor.rail (kill Python/MLX dependency)
- [ ] WASM: add float_arr support to WASM backend, port mhd.rail
- [ ] Full 2D MHD replacing parametric model in thruster_engine.html (WebGL compute)
- [x] Binary float array file I/O builtins — float_arr_to/from_f32_file (2026-04-13)
- [x] Autograd on GPU (every op now via dylib; three_class_mlp.rail proves
      end-to-end training — forward, backward, SGD — all on Metal) (2026-04-14)
- [ ] Proper Laplace current distribution in thruster engine
- [~] CF Worker content-type routing for .css/.js/.wasm (deploy-side ready
      in cf_deploy.rail; worker-side change pending worker source access) (2026-04-14)
- [x] GPU matmul persistent buffers — MTLBuffer pool in libtensor_gpu.dylib (2026-04-14)
- [x] Fused matmul+bias+relu kernel (2026-04-14)
- [x] Transformer forward pass in Rail — stdlib/transformer.rail,
      attention + layernorm + FFN, verified softmax rows sum to 1 (2026-04-14)
- [x] Three-class MLP training on Metal — 100% accuracy in 200 steps,
      beyond XOR, multi-class cross-entropy + SGD (2026-04-14)
- [x] Landing page preview thumbnails (CSS-only, 5 animated tiles) (2026-04-14)

## HARD (3-5 days)

- [ ] Metal IR direct from compile.rail (backend #5 — Rail source → .metal)
- [ ] Train neural_mhd entirely in Rail on Metal (first pure-Rail GPU training)
- [ ] Implicit MHD time-stepping (backward Euler, 100-1000x larger dt)
- [ ] WebGPU compute for browser physics (WGSL shaders, iPhone GPU)
- [x] Transformer forward pass in Rail — stdlib/transformer.rail shipped (2026-04-14)
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
