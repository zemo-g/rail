# Changelog

All notable changes to Rail are documented here.

## v2.7.0 (2026-04-14) — *WASM floats end-to-end*

The WASM backend gains real floating-point support.  Before this
release `grep -c "f64\|float" tools/wasm_runtime.wat` returned 0.
Now Rail compiles float-heavy programs (literals, arithmetic on
variables, float arrays, sqrt) to standalone .wasm and they
execute correctly under `wasmtime` with no runtime imports.

### Calling convention
- Rail's WASM backend uses i64 throughout the operand stack — same
  as the rest of the v2.6 codegen.  Float values travel as **raw f64
  bits stored in i64** (`i64.reinterpret_f64` round-trips).  This
  matches the ARM64 backend's convention where float values pass as
  raw bits in x-registers.

### Float literal `FL`
- New WASM codegen case in `compile.rail::wg`:
  `f64.const <literal>; i64.reinterpret_f64`.  A Rail `3.14` lands
  on the i64 stack as the bit pattern of `3.14` in IEEE 754.

### Float arithmetic with variable-aware type inference
- New `is_float_w node env` mirrors the ARM64 `is_float`.  V nodes
  (variable references) are flagged as float when the env contains
  a synthetic `__wfloat_<name>` marker, which the let-binding (D)
  emitter inserts whenever the bound expression is structurally
  float.  This lets `let x = 3.0 in let y = 4.0 in x + y` compile
  to f64 arithmetic without manual annotations.
- New `wasm_fop` table emits `f64.add / sub / mul / div` for
  arithmetic and `f64.eq / ne / lt / gt / le / ge` for comparisons.
  Comparisons return tagged-int booleans so they slot back into the
  existing if/then/else machinery.
- Mixed-type promotion: when one operand is float and the other is
  a tagged int, `wg_as_float` promotes via `i64.shr_s + f64.convert_i64_s`.

### Float arrays in WASM memory
- New `$float_arr_new`, `$float_arr_get`, `$float_arr_set`,
  `$float_arr_len` in `tools/wasm_runtime.wat`.  Layout matches
  ARM64: bytes [0..7] hold the length as raw i64, bytes [8..]
  hold the f64 payload.  The Rail handle is `(byte_ptr << 1)` so
  the LSB tag bit reads as 0 (pointer), matching cons cells.

### Conversions
- `$int_to_float` (= `$to_float`) — `i64.shr_s + f64.convert_i64_s
  + i64.reinterpret_f64`.
- `$float_to_int` — `f64.reinterpret_i64 + i64.trunc_f64_s + tag`.

### Math intrinsics
- `$sqrt`, `$fabs`, `$floor`, `$ceil` ship as native WASM intrinsics
  (`f64.sqrt`, `f64.abs`, `f64.floor`, `f64.ceil`) wrapped to take
  i64-bits and return i64-bits.
- `$show_float` formats an f64 to a `<int>.<6 decimal digits>`
  string with sign handling, by reusing the WASM heap allocator.
- **Deferred to v2.8**: `sin / cos / exp / log / pow / tanh`.  These
  have no native WASM intrinsics and need Taylor-series polyfills
  with proper range reduction (~150 lines of WAT each).

### Smoke proof
- **`tools/train/wasm_diffuse.rail`** — 1-D box-filter diffusion on
  a 16-cell float_arr, 50 passes, with L2 norm via sqrt.  Steady
  state of a linear ramp matches analytic prediction:
  `[0, 8, 15]` invariant, `‖[0..15]‖₂ = √1240 = 35.213633` (6
  digits agree).  Compiles to a 31KB .wat, runs in wasmtime.

### Tooling fix
- `dispatch_wasm` now prepends `/opt/homebrew/bin:/usr/local/bin`
  to the shell `PATH` before invoking `wat2wasm` and `wasmtime`,
  since the Rail `shell` builtin doesn't inherit the user's
  interactive PATH.

### Known limitations (v2.7 → v2.8)
- Recursive float function parameters not auto-inferred.  Use a
  1-element float_arr accumulator (the same idiom that works
  around the equivalent ARM64 limitation).
- Non-ASCII chars in string literals fail wat2wasm escape.
- Transcendental math foreigns (sin/cos/exp/log/pow/tanh) absent.

### Counters
- Dylib export count: 25 (unchanged — WASM is a separate backend).
- Tests: 106/106.
- Fixed-point self-compile: preserved.
- Adam XOR + three_class_mlp regression: still pass.

## v2.6.0 (2026-04-14) — *Compiler/REPL polish*

Two small but high-leverage quality-of-life improvements.  No new GPU
kernels, no new training math.

### Did-you-mean for unbound identifiers
- **`compile.rail::find_closest_name` + `edit_dist`** — Levenshtein
  edit distance over the arity-map keys.  When code generation
  reaches the user-function fallthrough with a name that's neither
  in the arity map, the local env, nor a self-call, the compiler
  emits a `WARNING: 'foo' is not defined; did you mean 'bar'?`
  before the assembler produces its cryptic linker error.
  Threshold: edit distance ≤ 2.  Skips compiler-internal names
  (those starting with `_`).  Cold path only — zero cost on
  successful compiles.
- Confirmed: a typo'd `doubel 21` against a defined `double` now
  prints `WARNING: 'doubel' is not defined; did you mean 'double'?`.

### REPL `:load file.rail`
- **`tools/repl.rail::repl_load`** — `:load <path>` reads a source
  file, drops bare `--` comments and the trailing `main = ...`
  block, and appends the remaining top-level decls to the running
  REPL session.  Subsequent expressions can call any function
  defined in the loaded file.  Verified by piping
  `:load /tmp/foo.rail` followed by `double 21`, `square 7`,
  `triple 5` — all return correct results.
- The REPL's per-expression definition persistence already worked
  in v2.0; this release just adds the file-slurp shortcut.

### Counters
- Dylib export count: 25 (unchanged).
- Tests: 106/106.
- Fixed-point self-compile: preserved.

## v2.5.0 (2026-04-14) — *Pre-norm transformer block*

Adds the missing transformer infrastructure: **LayerNorm forward+backward,
residual connections, and FFN block**.  All gradients verified against
finite differences (LN 9/9, attention 18/18).  The v2.4 single-head
attention LM grows into a proper pre-norm transformer block.

### LayerNorm
- **`stdlib/transformer.rail::layernorm_save`** — forward variant that
  returns `(y, mean, rstd)`, populating two extra float_arrs of length
  `n_rows` for use by backward.
- **`stdlib/transformer.rail::layernorm_backward_dx`** — Rail wrapper
  around the existing `tgl_layernorm_backward_f64` dylib export.
  Returns dx as a Tensor.  γ/β fixed at (1, 0) for v2.5; learnable
  γ/β + dgamma/dbeta accumulation queued for v2.6.
- **Hot fix in `layernorm_rows`.**  Same `0.0 + dim` bug pattern as
  `head_dim` in v2.4 — `dim` extracted from the shape list via
  `head (reverse x_shape)` was being passed to `+` as a tagged int,
  producing subnormal-bit divisions.  All forward LN was returning nan
  before this.  Replaced with explicit `int_to_float`.
- **`tools/train/layernorm_gradcheck.rail`** — central-difference
  gradcheck on dx for n_rows=3, dim=3.  All 9 slots PASS at f32
  tolerance (analytic and numerical agree to ~1e-13 absolute).

### Pre-norm transformer block
- **`tools/train/lm_transformer.rail`** — full pre-norm block:
  ```
  ln1   = LayerNorm(x_pe)
  attn  = causal_self_attention(ln1)
  x_attn = x_pe + attn          ← residual #1
  ln2   = LayerNorm(x_attn)
  ffn   = ReLU(ln2 @ W_F1) @ W_F2
  x_blk = x_attn + ffn          ← residual #2
  logits = x_blk @ W_O
  ```
  7 trainable parameter tensors (W_E, W_Q, W_K, W_V, W_O, W_F1, W_F2),
  Adam updates on every one.  Backward chains through residuals, FFN,
  LN2, attention, LN1, and embedding — all composing existing
  primitives, no new GPU kernels.

### Result on the v2.3/v2.4 test bench
| Run | Loss | vs uniform 3.47 | vs bigram 2.10 | vs v2.4 attn-only 2.62 |
|---|---|---|---|---|
| v2.5 pre-norm + LN + FFN, 500 steps, lr=0.05 | **2.90** | beats | does not beat | does not beat |

The architecture is mathematically correct (gradchecks pass) and trains
stably, but on this 383-char corpus the added LN + FFN complexity does
not outperform the simpler v2.4 architecture.  This is a known
small-data / small-model phenomenon — closing the gap is queued for
v2.6+ (learnable γ/β, multi-head attention, larger d_model, regular
weight decay, longer training).

### Counters
- Dylib export count: 25 (unchanged).
- Tests: 106/106.
- Fixed-point self-compile: preserved.
- Numerical gradchecks: attention 18/18, LN 9/9.

## v2.4.0 (2026-04-14) — *Movement V: attention end-to-end*

Closes the transformer-training spine: **attention backward + a
single-head causal transformer LM that trains end to end on
Shakespeare**.  No new GPU kernels — all of attention's backward chain
composes from existing primitives (matmul, transpose,
`tgl_softmax_backward_f64`, `tensor_scale`).  Embedding gradients use a
one-hot matmul, so `dW_E = X^T @ dX_pe` falls out for free without a
dedicated scatter-add kernel.

### Compiler / stdlib hot fix
- **`stdlib/transformer.rail` int→float coercion bug.**  Three call
  sites used `0.0 + head_dim` to promote the int extracted from
  `head (tail q_shape)` into a float for `sqrt`.  The Overture #1 fix
  in v2.2.0 covers most cases of this pattern but the deeply-nested
  match position was still emitting raw tagged-int bits — `sqrt(2)`
  was being passed `4.94e-323` (the subnormal that bits-cast to
  tagged-int 5) and returning `4.97e-162`.  Replaced all three sites
  with explicit `int_to_float head_dim`.  All forward-attention
  callers were producing nan before this fix.

### Attention backward
- **`stdlib/transformer.rail::attention_backward`** — pure-Rail
  composition.  Given the saved forward `attn` (post-softmax) and the
  upstream `dO`, returns `(dQ, dK, dV)` via:
  ```
  dV     = attn^T @ dO
  dAttn  = dO @ V^T
  dScaled = softmax_backward(attn, dAttn)
  dScores = dScaled * (1/√d)
  dQ      = dScores @ K
  dK      = dScores^T @ Q
  ```
  Causal-mask attention reuses the same routine — masked positions get
  `attn=0` from the forward, which makes their `dScaled` rows
  identically zero through softmax_backward (no explicit backward
  mask needed).
- **`tools/train/attention_gradcheck.rail`** — central-difference
  gradcheck on dQ, dK, dV at seq=3, d=2.  Tolerance 0.01 (f32 noise
  floor).  All 18 slots PASS.

### Single-head causal transformer LM
- **`tools/train/lm_transformer.rail`** — `embed → +sin/cos PE →
  causal self-attention → output projection`.  Adam + cosine LR
  schedule + tokenizer + 5-tensor parameter set (W_E, W_Q, W_K, W_V,
  W_O).  No layernorm, no residual, no FFN — minimum-viable
  transformer, 300 Adam steps, d=16.  Loss 15.20 → **2.62** on the
  same 383-char Shakespeare excerpt; beats uniform baseline (3.47)
  but does not beat the v2.3 bigram baseline (2.10).  Closing that
  gap is queued for v2.5 (layernorm forward+backward, residuals, FFN
  block).

### Counters
- Dylib export count: 25 (unchanged — no new kernels).
- Tests: 106/106 (unchanged).
- Fixed-point self-compile: preserved.
- Numerical attention gradcheck: 18/18 PASS.

## v2.3.0 (2026-04-14) — *Movement III: the training stack*

Closes the training-loop spine: **Adam + cosine LR + grad clipping +
checkpoint save/load + char-level tokenizer + generation (argmax /
top-k / temperature)**.  All five queued critical-path items from the
v2.2 handoff now compose end to end on a real language-model
objective — `tools/train/lm_shakespeare.rail` trains a char-level
bigram LM to below-uniform loss in 200 Adam steps and
`tools/train/lm_generate.rail` samples text back out of the saved
checkpoint.

Proof write-up: `docs/first_lm.md`.

### Adam optimizer (fused GPU kernel)
- **`kernel void adam_update`** in `tools/metal/tensor_gpu.metal` — one
  dispatch per parameter tensor per step. Reads `w, g, m, v` plus a
  6-element hyperparameter array `[lr, β1, β2, ε, bc1, bc2]`; mutates
  `w, m, v` in place. Bias correction terms computed host-side so the
  kernel stays scalar-allocation-free.
- **`tgl_adam_update_f64`** dylib export. Six register args (four
  `float_arr` pointers + hyp pointer + N), follows the scalar-packing
  idiom of `tgl_scale_f64`. Smoke test in `tools/metal/smoke_test.c`.
- **`stdlib/optim.rail::AdamState`** — m/v float_arrs plus mutable step
  counter.  `adam_state n` builds fresh state; `adam_update_raw` is the
  hot path on raw float_arrs (used by manual backward loops);
  `adam_update` wraps `Tensor` destructure.
- **`tools/train/adam_xor.rail`** — XOR loss 0.425 → 3.78e-10 in 200
  steps, lr=0.05. One fused GPU dispatch per parameter per step
  (vs ≈12 dispatches in the pure-Rail tensor-op chain of
  `tools/railml/train.rail`).

### LR schedule + grad clipping
- **`cosine_decay step warmup max_steps base_lr`** in
  `stdlib/optim.rail` — linear warmup to `base_lr` over the first
  `warmup` steps, then half-cosine decay to 0.0.  Clamped to 0.0
  after `max_steps` to avoid negative lrs.  Verified at 5 canonical
  points (`tools/train/lr_clip_test.rail`).
- **`clip_grad_norm grads max_norm`** — computes the global L2 norm
  of a list of gradient tensors via GPU dispatch (tensor_mul for
  squaring, CPU reduce for the sum — cheap compared to the
  element-wise square), scales every tensor by `max_norm / norm`
  when the threshold fires, returns `(clipped_grads, pre_norm)`.
  The running total is accumulated through a `float_arr` slot
  instead of a recursive float param to side-step Rail's
  cross-function float-inference gap.

### Checkpoint save/load
- **`stdlib/checkpoint.rail`** — `save_model prefix tensors` writes a
  text manifest (`<prefix>.manifest`, one line per tensor with
  rank and dims) plus per-tensor f32 payload files
  (`<prefix>.<i>.f32`).  `load_model prefix` reads them back into
  fresh Tensors.  Round-trip verified bit-identical in
  `tools/train/ckpt_test.rail`; reload of the LM checkpoint produces
  the same forward-pass loss to 1e-10.

### Tokenizer
- **`stdlib/tokenizer.rail::Vocab`** — char-level vocab built by
  first-appearance order.  `build_vocab text` returns a `Vocab`,
  `encode / decode` round-trip exactly.  Verified on 10,320 chars
  (`tools/train/tokenizer_test.rail`).  Byte-level BPE with merge
  rules is queued for v2.4 — the v2.3 shape is the BPE-floor char
  vocab.

### End-to-end LM training
- **`tools/train/lm_shakespeare.rail`** — 2-layer MLP bigram LM,
  `one_hot(32) → Linear(32) → ReLU → Linear(32) → softmax`.  Trains on
  a 383-char Shakespeare excerpt for 200 steps with Adam + cosine
  schedule.  Loss drops 15.02 → 2.10 vs uniform baseline 3.47.
  Checkpoint save + reload + eval gives bit-identical loss.

### Generation
- **`stdlib/sampling.rail`** — `sample_argmax`, `sample_topk`,
  `sample_temperature`, plus `fill_uniforms` (awk-backed PRNG — Rail's
  int PRNG overflows on multiplicative LCGs, so we lean on shell).
  Top-k selection is O(V·k), adequate for small vocabs.
- **`tools/train/lm_generate.rail`** — loads the saved LM checkpoint,
  rebuilds the vocab from the same corpus, generates 80 tokens with
  each of the three strategies.  Argmax converges to a high-probability
  bigram cycle ("To the the the..."); top-k k=3 produces more varied
  Shakespeare-ish text ("To an tha the toro...").

### Counters
- Dylib export count: 24 → 25.
- Tests: 106/106 (unchanged — all additions are stdlib + demos, not
  compiler changes).
- Fixed-point self-compile: preserved.

## v2.2.0 (2026-04-14) — *The Suite*

A multi-movement session performed live. Overture fixed two parser/codegen
burrs. Movement I expanded the Metal kernel library. Movement II put
backward passes on the GPU. Movement IV added positional encodings.
Movement VI sketched the fifth backend. Movements III / V / VII / VIII / IX
are designed and queued in EVOLUTION.md with full specs.

### Compiler (Overture)
- **`0.0 + int_expr` miscompile fixed.** When one operand is a float
  literal and the other is an int expression whose type can't be
  statically inferred (because `body_has_float` blocks
  `mark_int_params`), the O-handler now detects int-producing O-nodes
  on the mixed side and emits `asr`+`scvtf` for promotion. Surgical
  (no runtime type check, no false positives on raw float bits with
  LSB=1). New regression test `t106 mixed_float_int_op`. 106/106.
- **Deeply-nested `match` chains** — documented workaround pattern in
  CLAUDE.md: flatten to a single indentation level at the top of the
  function body, followed by a linear `let` stream. Parser fix deferred.
- **`int_to_float` / `float_to_int`** promoted into the documented
  builtin quick-reference.

### Metal kernels (Movement I)
- **`matmul_bias_gelu`** — transformer-FFN native, fused matmul +
  bias + GELU in one dispatch.
- **`matmul_batched`** — `[B, M, K] @ [B, K, N] → [B, M, N]`. One
  3D threadgroup per output element, z-index is batch.
- **`tensor_sum_partials`** — race-free parallel reduction. Each
  threadgroup writes one partial; host sums the partials. Replaces
  the atomic-add note that was racy under multi-threadgroup dispatch.

### Backward kernels (Movement II)
- **`softmax_backward`** — `dx_i = y_i(dy_i − Σ y_k dy_k)`, one row
  per thread, inner dot product inline.
- **`ce_softmax_backward`** — fused CE gradient `(probs − onehot)/batch`
  replaces the Rail-side loop in `three_class_mlp.rail`.
- **`layernorm_backward`** — mean/var-aware, computes `∂L/∂x` in a
  single kernel given precomputed `mean` and `rstd` from forward.

### Transformer stdlib (Movement IV)
- **Sinusoidal positional encodings.** `sinusoidal_pe seq dim`
  returns a `[seq, dim]` Tensor whose even columns are `sin(pos/10000^(2i/d))`
  and odd columns are `cos(...)`. `apply_pe x pe = tensor_add x pe`.
  Smoke test verifies `sin(0)=0, cos(0)=1, sin(1)≈0.841, cos(1)≈0.540`.
- `linear_gelu` wrapper on top of the fused `matmul_bias_gelu` kernel.

### Metal IR backend scaffold (Movement VI)
- **`tools/metal/rail_to_metal.rail`** — minimal Rail AST → `.metal`
  kernel emitter for pure float→float lambdas. Demo emits a working
  `relu2` kernel; `xcrun metal -c /tmp/rail_emitted.metal` compiles
  clean. Proves the path; `#metal_kernel` directive integration next.

### Dylib exports
3 → 15 → **24**. Persistent MTLBuffer pool still amortizing allocation
across the full set. `smoke_test.c` still passes its 29 checks.

### Numbers
| | v2.1.2 | v2.2.0 |
|---|---|---|
| Tests | 105 | 106 |
| Metal kernels | 14 | 20 |
| Dylib exports | 15 | 24 |
| Backward-on-GPU | only via matmul path | softmax+CE+LN fused |
| Transformer PE | — | sinusoidal |
| Backends | 4 | 4½ (Metal-emitter scaffold) |

Self-compile byte-identical. Nothing in the Mozart piece needed red ink.

## v2.1.2 (2026-04-14, overnight session)

The second half of v2.1.x — closing every remaining gap in the
Rail→Metal path and pushing past XOR to real classification.

### Dylib: full GPU op coverage via FFI
`libtensor_gpu.dylib` now exports 15 ops (was 3). Every tensor op used
by `stdlib/tensor.rail` routes through C ABI FFI — no more /tmp file
pipes on the hot path. New exports:

- `tgl_add_f64`, `tgl_mul_f64`, `tgl_scale_f64` — elementwise
- `tgl_sigmoid_f64`, `tgl_exp_f64`, `tgl_tanh_f64` — activations
- `tgl_softmax_rows_f64` — 3-pass row-wise softmax
- `tgl_transpose_f64` — row-major transpose
- `tgl_relu_backward_f64` — masked gradient for training
- `tgl_sgd_update_f64` — in-place weight update
- `tgl_cross_entropy_f64` — loss over a batch
- `tgl_matmul_relu_f64` — fused matmul+bias+relu (new kernel)

### Persistent MTLBuffer pool
Best-fit reuse across ops (32 slots, page-rounded). Cuts
`newBufferWithLength` overhead on training loops where the same
shapes are dispatched over and over.

### Fused matmul+bias+relu kernel
`matmul_bias_relu` in the .metal lib — one dispatch for the classic
MLP layer instead of three. Used automatically by `linear_relu` in the
new transformer stdlib.

### Three-class MLP trains on Metal
`tools/train/three_class_mlp.rail` — 2D→32→3 classifier on 3 synthetic
clusters, cross-entropy + SGD, analytical backward pass. Loss 5.63 →
0.006 in 200 steps. **100% accuracy on 90 samples.** Every op in the
forward and backward pass dispatches through the dylib FFI. First
multi-class training on Metal in pure Rail.

### Transformer forward pass stdlib
`stdlib/transformer.rail` — linear, linear_relu (fused), layernorm,
scaled-dot-product attention (with optional causal mask), feedforward,
pre-norm transformer block. `tools/railml/transformer_forward.rail`
runs a 4-token × 8-dim two-layer stack and verifies softmax rows sum
to 1.0. All matmuls and activations dispatch to Metal.

### Tensor op benchmark
`tools/bench/tensor_ops.rail` — measures per-op latency via the dylib
path at multiple sizes. Reveals ~5ms per-call overhead (command buffer
+ f64↔f32 copies dominate below N=1024²).

### Bug fix: missing `foreign tgl_relu_f64` declaration
When v2.1.1 migrated to the dylib path, `foreign tgl_relu_f64` was
dropped from `stdlib/tensor.rail`. Without it, Rail treated the call
as a regular Rail function, skipping the int-untagging sequence
(`asr`+`tst`+`csel`) before the BL. N arrived in the dylib as the
tagged value (2n+1) and every second dispatch segfaulted. Restoring
the declaration immediately fixes a whole family of hangs.

### Tooling: landing page thumbnails + CF deploy Content-Type
- `tools/deploy/gen_plasma_landing.rail` — generates /plasma index
  with CSS-only preview thumbnails (arc, rings, vortex, nozzle,
  helix). No raster assets, pure animated gradients.
- `tools/deploy/cf_deploy.rail` — auto-detects Content-Type from KV
  key suffix (.css, .js, .wasm, .svg, .json, .png, else HTML) and
  attaches as KV metadata so the Worker can set headers without a
  hardcoded suffix table.

### Test count, fixed point
105/105. Self-compile byte-identical.

## v2.1.1 (2026-04-14)

Follow-up session addressing v2.1 technical debt.

### Tests
- 7 new regression tests for v2.1 compiler features: parse_float,
  parse_int, scientific notation (int and fractional), null-safe ==,
  binary f32 I/O, and tensor primitives. Suite: 98 → 105.
- Float self-loop TCO fix REVERTED — initial `mark_int_params` guard
  removal caused segfaults in self-recursive float functions. Proper
  fix deferred to HARD tier (requires float-param-aware TCO scheduler).

### Dlopen GPU path
- `libtensor_gpu.dylib` with C ABI (tgl_init, tgl_matmul_f64, tgl_relu_f64).
- Fixed ObjC runtime init: `__attribute__((constructor))` warmup forces
  class registration before Rail calls the dylib.
- Absolute install_name so dyld finds the dylib without DYLD_LIBRARY_PATH
  (macOS SIP strips that env var through /bin/sh).
- tensor.rail auto-detects dylib and uses FFI path for matmul; falls
  back to binary file I/O if missing.
- Discovered Rail's foreign ABI untags ints before passing — dylib
  receives raw ints, not tagged.
- First full neural-network convergence: XOR MLP 500 steps, lr=0.8,
  loss 0.38 → 8.88e-16 (machine epsilon). Max prediction error 1.2e-7.

### Metal matmul optimization
- New `matmul_blocked` kernel with 4×4 register blocking.
- N=1024: 741 → 1734 GFLOPS (2.3x). Previous v2.1: 269 GFLOPS.
- Overall 6.5x improvement at that size.
- Byte-identical outputs vs basic kernel.
- dylib uses blocked kernel by default; falls back to basic if missing.

### Autograd design note
- Added documentation explaining the `slot == 0` sentinel pattern and
  the compiler invariant it relies on (test t103 pins it).

## v2.1.0 (2026-04-13)

The GPU session. Rail now drives its own Metal GPU, trains neural
networks end-to-end, and hosts a deployed physics platform.

### Compiler
- **`parse_float`** builtin: string → float via `_atof` + `_str_unwrap`
- **`parse_int`** builtin: string → int via `_strtol` + `_str_unwrap`
- **Null-safe `==` / `!=`**: `_rail_eq` / `_rail_ne` now guard against
  null dereferences and type-mismatch comparisons. `tensor == 0` no
  longer segfaults.
- **Float self-loop TCO**: `mark_int_params` no longer blocked by
  `body_has_float`. Tensor CPU loops now get register-allocated int
  counters while preserving d8 save/restore.
- **Scientific notation literals**: lexer extended to parse `1e6`,
  `1.5e-3`, `6.022e23`, `2.5E+4`.
- **Binary f32 I/O**: `float_arr_to_f32_file` / `float_arr_from_f32_file`
  as builtins. Direct Darwin syscalls (open/write/read/close).
- Self-compiles byte-identical. 98/98 tests.

### Tensor stdlib (stdlib/tensor.rail — 1004 lines)
- 13 autograd primitives unblock `stdlib/autograd.rail`: `tensor_relu_mask`,
  `tensor_gelu_backward`, `tensor_softmax`, `tensor_sum_last`,
  `tensor_sum_batch`, `tensor_mean_last`, `tensor_broadcast_last`,
  `tensor_mul_broadcast`, `tensor_one_hot`, `tensor_embedding_lookup`,
  `tensor_slice_row`, `tensor_accumulate_row`, `tensor_scale_by_loss`.
- 10 utilities: `tensor_matmul`, `tensor_copy`, `tensor_cross_entropy_loss`,
  `tensor_from_int`, `tensor_to_int`, `tensor_get_int`, `tensor_map_scalar`,
  `tensor_ones_like_shape`, `tensor_scalar_val`, `tensor_sum_all`.
- GPU auto-dispatch for matmul, relu, exp, tanh, sigmoid, softmax, transpose.
- Binary f32 pipe for matmul (no text parsing overhead).
- Data-copying `tensor_transpose` (matmul requires row-major contiguous).

### Autograd (stdlib/autograd.rail)
- Links for the first time. All dependencies resolved.
- Forward graph and backward pass both verified correct.
- Reverse-mode tape-based AD with 11 tracked ops.

### Metal GPU (tools/metal/)
- `tensor_gpu.metal` — 13 compute kernels (tiled matmul, elementwise,
  activations, softmax 3-pass, transpose, SGD update, cross-entropy).
  **269 GFLOPS** matmul 512×512 on M4 Pro.
- `tensor_gpu.m` — host with file-mode CLI, binary matmul mode,
  stdin binary protocol, benchmark.
- `tensor_daemon.py` — persistent TCP daemon on :9300 for lower-latency
  dispatch. tensor.rail auto-detects and uses if running.

### First neural network training (tools/train/first_gpu_train.rail)
- 2-layer MLP learns XOR via autograd + SGD.
- Every matmul in forward and backward dispatches to Metal GPU.
- Loss: **0.425 → 0.043** in 50 steps. First pure-Rail GPU training.

### RAIL PLASMA (tools/plasma/)
- `thruster_engine.html` (1,365 lines): SI-calibrated 2D axisymmetric MPD
  thruster design tool. Maecker analytical thrust model with self-field +
  applied-field + gasdynamic components. Validates against 12 published
  data points from Stuttgart SX3 + JPL AF-MPDT. Optimizer sweeps,
  hardware spec generator.
- `mhd_axisym.metal` + `mhd_live.m`: real-time 2D axisymmetric MHD solver,
  256×512 grid, adaptive time-stepping on M4 Pro Metal.
- `mhd_server.py` + `thruster_live.html`: HTTP frame streaming at 30fps
  for remote (mobile) viewing.
- All tools mobile-responsive with touch support.
- Deployed public: `ledatic.org/plasma/{engine,lab,mhd,ramjet,thruster3d}`,
  CSP-compliant split CSS/JS/HTML.

### Runtime
- Compiled Metal host binaries (`tensor_gpu`, `mhd_live`) now gitignored;
  rebuilt from source on demand.

## v2.0.0 (2026-04-06)

121 commits since v1.4.0. The biggest release since v1.0.

This is the version where Rail stops being just a self-hosting compiler
and becomes a self-improving system. The compiler is now the teacher in
three distinct training lineages — LLM-LoRA, Metal-GPU MLP, and
integer-PCFG — and the operational discipline to keep them honest
(intervention ledger, recovery chain, runtime overrides) is built in
pure Rail.

### Compiler & runtime
- **Native floats**: unboxed IEEE 754 doubles in ARM64 d-registers.
  Float arrays, foreign FFI (`sin`/`cos`/`sqrt`/`tanh`/`exp`/`log`/`pow`),
  auto int→float promotion, ~10× speedup vs boxed.
- **Effect handlers**: `try body handler` via setjmp/longjmp. Deep
  unwinding, nested handlers, restartable error recovery.
- **GC bootstrapped**: lower-bound check in `gc_try_mark`, 10/10 stress
  self-compiles. Self-compile fully reliable, no more intermittent
  SIGSEGV. Bootstrap via binary-patching `_rail_gc → ret`.
- **d8 callee-saved float register**: float operations inside recursive
  functions now get the fast self-loop optimization (was blocked by the
  `body_has_float` guard). Unblocked the neural plasma MLP training.
  5/5 d8_test, 7/7 float_bug_test pass.
- **FFI strdup wrap**: string-returning foreign calls now strdup-wrapped
  through the runtime. Fixed the memory bug that was holding tests at
  91/92 → 92/92 for the first time.
- **Polymorphic show**: works on int, float, string, lists (incl.
  nested), nil, and ADTs.
- **Exhaustive match**: non-exhaustive `match` is now a compile-time
  error (was a warning), with runtime trap on fallthrough.
- **Parser `in` keyword**: `let x = val in body` now works alongside
  the newline-indent style.
- **Type checker**: forward inference pass emits warnings for head/tail
  on non-list, arithmetic on non-numeric, wrong arity, calling
  non-functions.
- **Performance**: tail-recursive loops match C `-O2` (5 instructions
  per iteration). Self-loop → bottom-test, untagged register params,
  direct register arithmetic, auto-memoization, constant folding, type
  guard elimination, fused compare-and-branch.

### Backends (4 stable)
- **macOS ARM64** — primary, 92 tests, fixed point self-compile
- **Linux ARM64** (Pi Zero 2 W) — fleet display deployed
- **Linux x86_64** (WSL) — Razer training node
- **WASM** — closures via `call_indirect` + env-passing, ADT
  construction (`Some 42`, `Circle 5`), pattern matching (int / ADT
  ctor / wildcard / string), heap allocator, lists (cons/nil/head/tail/
  length), recursive functions, string ops (append/join/show/reverse),
  print fix (trailing null byte off-by-one), 7 playground demos at
  compile.ledatic.org

### Public sandbox
- **compile.ledatic.org** — public sandboxed compiler. AST whitelist,
  WASM import validation, 19-test adversarial suite, Cloudflare Tunnel.
- **ledatic.org v2.0** — main site redeployed with 6 WASM demos in
  browser (hello, fib, math, lists, ADTs, closures, string ops).
- Site scrubbed: no hardware models/specs, only capability metrics.

### Self-training flywheel
- **Hyperagent**: bench-gated training loop. 30 fixed tasks across 6
  bands. Decision logic: keep adapter only if bench improves, rollback
  otherwise.
- **DNA harvester**: 199 verified examples extracted from
  `compile.rail`, stdlib, and known-good pattern recombinations. Pure
  from birth.
- **RAILGPT bench**: 14/30 (Gemma 4 E4B + Rail adapter), 13/30
  (Qwen 4B + Rail adapter). Up from 1/30 baseline.
- **Curated training corpus**: 3.67 MB of deduped, quality-weighted
  Rail programs from 17 sources. SHA-256 dedup, 90/5/5 split.
- **Cross-arch training**: Mac Mini M4 Pro for inference + orchestration,
  Razer 3070 for CUDA QLoRA training, Pi Zero 2 W for fleet display.

### Neural Plasma Engine
- **3D Metal MHD simulator** (`tools/plasma/plasma_3d.rail`): 128³
  grid, 8 conserved variables (density, momentum, B-field, energy),
  Lax-Friedrichs scheme on Metal compute kernels. Volume raymarcher
  renders density, magnetic pressure, current sheets. 30 fps with
  orbit camera + auto-rotate.
- **Pure-Rail neural surrogate**: linear model trained on 32×32 MHD
  data with analytical backprop. Loss 4.45 → 0.03 over 500 steps,
  single-step mass conservation error 0.027%.
- **Metal GPU MLP training**: 30 → 128 → 6 MLP, 204K examples from
  64×64 MHD, full forward + backward pass on GPU using 10 custom
  Metal kernels. ~85× faster than the pure-Rail CPU version.
- **Neural renderer** (`tools/plasma/neural_renderer.rail`): runs the
  trained MLP forward pass on every cell of a 64×64 grid each frame.
  **The neural network IS the physics engine** — no PDE solver at
  runtime.
- **Stability fix**: spectral normalization + conservation drift loss
  bound the simulation to 200 stable steps. Single-step mass error
  -0.17% → -0.02% via positivity penalty. Output clamping for stable
  multi-step simulation. Residual prediction + normalization (mass
  error 168% → 0.39%).

### Empire → Rail Transplant (4 sessions, all pure Rail, zero Python)

The operational discipline patterns from the paused Empire trading
system, ported as Rail-native infrastructure for the flywheel. **All
four crown jewels shipped 2026-04-06.**

#### Session 1: Intervention Ledger
- `flywheel/interventions.jsonl` — append-only audit log
- `flywheel/interventions_tail.rail` — Rail-native viewer
- 5 hooks in `tools/train/self_train.rail`: round_end, level_advance,
  level_fallback, goal_grind, server_skip
- Helpers `kvi`, `kvs`, `log_intervention`

#### Session 2: Recovery Chain
- `flywheel/flush.rail` — pure Rail rotator. Per protected file: cp
  src→tmp, mv backup→prev, mv tmp→backup. Three guards: source-empty,
  size-shrunk, line-collapse.
- Wired into `tools/train/run_training.sh` — runs every round
- Protected files: `harvest.jsonl`, `progress.txt`,
  `interventions.jsonl`, `bench_log.txt`, `s0_state.txt`

#### Session 3: Domain Plugin Spine
- `tools/domains/` — filesystem-as-registry plugin convention. No
  dispatcher, no manifest, no registry file. The filesystem IS the
  registry.
- `tools/domains/README.rail` — convention spec
- `tools/domains/list.rail` — discovery via `find`
- `tools/domains/neural_plasma/` — first domain (state + bench, real
  d8 regression canary 2/2)
- `tools/domains/s0_pcfg/` — second domain (full 5-verb implementation)

#### Session 4: Runtime Overrides + Audit
- `flywheel/overrides.txt` — bounded tunables (pass_threshold,
  advance_threshold, fallback_threshold, retrain_threshold)
- `flywheel/override_set.rail` — CLI setter with bounds check + audit
- `load_override` helper in `self_train.rail` reads tunables every
  round, replaces hardcoded literals
- Every override write logs to `interventions.jsonl`

### s0_pcfg — second domain on the spine, compiler-as-teacher

A 23-rule probabilistic context-free grammar over Rail tokens, trained
by REINFORCE against the rail compiler. The whole "model" is 23
integer weights. **Compile-as-teacher in 720 lines of pure Rail.**

- **5 program shapes**: inline, named-binding, statement chain,
  function definition, ADT + match
- **92% lifetime strict pass rate** after 30 ticks of training
- **No gradient descent, no transformer, no GPU, no tokens**
- **Discoveries the model found that we didn't put there**:
  - Rail tolerates undefined identifiers (returns 0)
  - Named-binding program shape compiles more reliably than inline
    `print (show E)` — measurable preference, REINFORCE found it
  - Integer division by zero is silent (returns 0)
  - Real traps (missing right operand) die fast under negative reward
- **Closes the loop** via `cross_feed.rail`: translates PCFG-verified
  programs into self_train's harvest format with SHA-256 dedup. **Two
  oracles, one corpus.**
- **Continuous training**: wired into `run_training.sh` per-round hook.
  PCFG trains while LLM trains, both feed the same harvest.
- Full writeup: `docs/s0_pcfg.md` (485 lines, 4 discoveries, 4 Rail
  compiler quirks discovered while building, 6 extension paths)

### Forward regression bisector
- `flywheel/regress.rail` — pure Rail tool that reads the intervention
  ledger and reports any pass-rate drop bigger than a threshold, plus
  the suspect events (override_write, level_fallback, server_skip,
  goal_grind) that occurred in the window before the drop. Threshold
  configurable. The level 25 → 6 historical regression that motivated
  the ledger is gone (pre-ledger), so this tool runs **forward**: it
  watches for the next drop and tells you what changed.

### Stdlib
- `stdlib/file.rail` — added `append_line` helper, used by ledger
  writers and harvest collectors
- `str_find`, `str_contains`, `str_replace`, `str_split` (multi-char),
  `str_sub`, `read_line` — full string toolkit
- `arr_new`, `arr_get`, `arr_set`, `arr_len` — mutable arrays
- 38 stdlib modules total: json, http, sqlite, regex, base64, socket,
  crypto, csv, datetime, env, fs, hash, math, net, os, path, process,
  random, sort, string, test, toml, list, strbuf, fmt, file, stat,
  llm, mmap, dlopen, dirent, signal, time, url, args, autograd, map,
  tensor

### REINFORCE on Gemma LoRA — scoping plan
- `docs/reinforce-lora-plan.md` (364 lines) — half-day Razer-side
  spike to replace cross-entropy LoRA with policy-gradient on
  compile-pass reward. Same training signal that drove s0_pcfg from
  46% → 92% strict pass rate, applied to the 4B-param LLM that
  currently sits at 14/30 on the bench. 6 phases with abort criteria,
  5 risks with mitigations, honest 50% confidence on the make-or-break
  phase. **The big swing for the next session.**

### Compute fleet
- **Mac Mini M4 Pro** (24 GB) — primary inference, compilation,
  orchestration, training
- **MacBook Air M1** (8 GB) — keepawake via Tailscale
- **Razer 3070** (RTX 3070, 8 GB VRAM) — CUDA QLoRA training,
  x86_64 Rail via WSL
- **Pi Zero 2 W** (416 MB) — Rail compiler, fleet LCD display, live
  Tailscale pings

### Identity & open source
- **GitHub Linguist PR** submitted to fix Rail being detected as
  Haskell. README badge added.
- Repo public under BSL 1.1 (converts to MIT 2030-03-14)

### Numbers

| | v1.4 (2026-03-22) | v2.0 (2026-04-06) |
|---|---|---|
| Tests | 70 | 92 |
| Backends | 1 | 4 (ARM64, Linux ARM64, x86_64, WASM) |
| Stdlib modules | ~22 | 38 |
| Compiler lines | 1,979 | 3,865 |
| Self-improving lineages | 1 (LLM-LoRA) | 3 (LLM-LoRA, Metal-MLP, PCFG-REINFORCE) |
| Operational discipline | manual | full (ledger + recovery + spine + overrides + bisector) |
| Domain plugins | 0 | 2 (neural_plasma, s0_pcfg) |

### What's next
- **REINFORCE on Gemma LoRA** — see `docs/reinforce-lora-plan.md`
- **Continuous self-improvement** — `run_training.sh` already runs
  the closed loop every round (s0_pcfg tick + cross_feed)
- **Empire transplant Tier 2** — port-when-needed (multi-turn tools,
  prompt caching, kill switches)

---

## v1.4.0 (2026-03-22)

- **Garbage collector**: conservative mark-sweep GC in `runtime/gc.c`. Scans ARM64 stack frames via x29 chain, traces tagged objects, builds free list. Triggered when 1GB bump-alloc fails. Programs can now allocate well beyond 1GB total.
- **Nested lambdas**: `\a -> \b -> a + b` compiles correctly. Flattened to multi-param closures, with direct application beta-reduced at compile time.
- **Multi-capture closures**: closures capturing 2+ variables now load all captures (up to 4).
- **Exhaustiveness checking**: compiler warns on non-exhaustive ADT pattern matches, listing missing constructors.
- **70 tests** (up from 67), stable with GC + 1GB allocator.
- Compiler grown to 1,979 lines.

## v1.3.0 (2026-03-21)

- **Flywheel self-training**: 25-level curriculum, compiler-verified training data, auto-advance at 80%+ for 3 consecutive rounds.
- **MCP server**: Rail exposed as a Model Context Protocol tool server.
- **32-layer LoRA training**: targets both self-attention and Gated DeltaNet layers in Qwen3.5-4B.
- **Fleet tools**: distributed node management (`tools/fleet/`), fleet agents for ARM64 and x86_64.
- **Thinking mode**: robust response parsing for thinking-mode LLM inference in `runtime/llm.c`.
- Closure label counter fix in compiler.

## v1.2.1 (2026-03-21)

- Quality scoring layer for training data.
- v5 adapter deployed (PEFT-to-MLX converted, more data).
- Razer sparkline in fleet dashboard.

## v1.2.0 (2026-03-21)

- **`cat` builtin** for file concatenation.
- Linux cross-compiler fixes.
- Pi Zero fleet display in dashboard.

## v1.1.0 (2026-03-18 -- 2026-03-20)

- **Metal GPU backend**: Rail compiles to Apple Silicon compute shaders (`tools/gpu.rail`).
- **WASM backend**: compiles Rail to WebAssembly (`tools/wasm.rail`). Runtime WIP.
- **x86_64 backend**: sandboxed subset in `tools/x86_codegen.rail`.
- **Concurrency**: `spawn`, `channel`, `send`, `recv` for fiber-based concurrency.
- **Flywheel framework**: `flywheel/waterfall.rail` orchestrator, `flywheel/bench.rail` 30-task benchmark.
- **`#generate` directive**: compile-time AI code generation.
- **Map fusion**: `map f (map g data)` optimized to single-pass `map (f . g) data`.
- **Tree-sitter grammar** for syntax highlighting.
- **22 stdlib modules**: json, http, sqlite, regex, base64, socket, crypto, csv, datetime, env, fs, hash, math, net, os, path, process, random, sort, string, test, toml.
- Reorganized `tools/` directory structure.
- Arena mark/reset fix -- 67/67 tests stable.
- Flywheel data pipeline audit + 49-issue fix cycle.

## v1.0.0 (2026-03-17)

- **Self-hosting achieved**: Rail compiler (`tools/compile.rail`) compiles itself to ARM64. Output is byte-identical on re-compilation (fixed point).
- **Rust deleted**: 21,086 lines of Rust replaced by 1,774 lines of Rail.
- **329K seed binary**: no external dependencies beyond macOS `as` + `ld`.
- 67 tests passing.
- Pattern matching + algebraic data types.
- Tail-call optimization.
- Tagged pointer runtime (integers shifted, heap objects raw).
- 1GB bump arena allocator.
- CLI interface: `rail_native run`, `rail_native test`, `rail_native self`.
- Linux ARM64 cross-compilation support.

## Pre-1.0 (2026-03-14 -- 2026-03-16)

- ARM64 native code generation from Rail AST.
- Self-compilation achieved, then reached fixed point.
- TCO for constant-stack recursion.
- ADTs and pattern matching.
- Floats, FFI, imports, list operations.
- Async fibers, literal patterns, guards in match.
- `rail generate` -- AI code generation via local LLM.
- Channels and float FFI returns.
- GPU auto-dispatch for pure arithmetic.
- Original Rust implementation (interpreter, parser, type checker, LSP, Cranelift JIT).
