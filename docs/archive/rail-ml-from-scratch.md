# RailML: Machine Learning From Scratch in Rail

**Goal:** A complete ML training stack — tensor ops, Metal GPU, autodiff, transformer — written in Rail, compiled by Rail, training models that write Rail, verified by the Rail compiler. The loop closes.

**Status:** DESIGN (2026-04-05)

---

## What Already Exists

Rail has more foundation for this than you'd think:

### Float Arrays (contiguous, f64)
```rail
let a = float_arr_new 1024 0.0     -- allocate 1024 doubles, zero-init
float_arr_set a 0 3.14             -- write
float_arr_get a 0                  -- read → 3.14
float_arr_len a                    -- → 1024
```
These are raw contiguous memory. No linked-list overhead. This IS a 1D tensor.

### Native Float Arithmetic
```rail
let x = 3.14 * 2.0 + 1.0          -- fadd/fmul in d-registers, no boxing
let y = sin x                      -- foreign: sin, cos, tanh, sqrt, exp, log, pow, atan2
```
IEEE 754 doubles, hardware speed, auto int→float promotion.

### Metal GPU (elementwise, integers only currently)
```rail
-- Compiler auto-dispatches map to GPU when length >= 50,000
map (\x -> x * x + 1) big_list     -- becomes Metal kernel if GPU-safe
```
Pipeline: Rail AST → Metal shader source → `xcrun metal` compile → execute → parse results back.

### What's Missing
1. **Multi-dimensional tensor type** (shape + strides over flat float_arr)
2. **Float GPU kernels** (current Metal pipeline is int-only)
3. **Matmul** (neither CPU nor GPU)
4. **Autodiff** (no gradient computation)
5. **Transformer ops** (attention, softmax, layernorm, embedding)
6. **Persistent Metal context** (current pipeline recompiles every kernel via shell)

---

## Phase 1: Tensor Type (CPU, pure Rail)

### The Type
```rail
-- Tensor = data buffer + shape + strides
-- Rail ADT:
type Tensor = Tensor FloatArr (List Int) (List Int)
--                    data      shape      strides

-- Constructor helpers
tensor_new shape init_val =
  let size = fold (\a b -> a * b) 1 shape
  let data = float_arr_new size init_val
  let strides = compute_strides shape
  Tensor data shape strides

-- Row-major strides: [d1,d2,d3] → [d2*d3, d3, 1]
compute_strides shape =
  let rev = reverse shape
  let scan = fold (\acc x -> cons (x * head acc) acc) [1] (tail rev)
  tail scan  -- drop the leading total-size element

-- Indexing: tensor_get t [i, j, k] → float
tensor_get t indices =
  match t | Tensor data shape strides ->
    let offset = fold (\acc pair -> acc + fst pair * snd pair) 0 (zip indices strides)
    float_arr_get data offset

-- Set: tensor_set t [i, j, k] val
tensor_set t indices val =
  match t | Tensor data shape strides ->
    let offset = fold (\acc pair -> acc + fst pair * snd pair) 0 (zip indices strides)
    float_arr_set data offset val
```

### Core Ops (CPU, naive but correct)
```rail
-- Matmul: (M,K) @ (K,N) → (M,N)
-- Triple nested loop. Slow. Correct. The reference implementation.
matmul a b =
  let (m, k1) = (dim a 0, dim a 1)
  let (k2, n) = (dim b 0, dim b 1)
  -- assert k1 == k2
  let c = tensor_new [m, n] 0.0
  -- for i in 0..m, j in 0..n: c[i,j] = sum(a[i,k] * b[k,j] for k in 0..k1)
  loop_matmul a b c m n k1 0
  c

-- Element-wise ops (map over flat buffer)
tensor_add a b = ...    -- float_arr element-wise
tensor_mul a b = ...    -- element-wise multiply (Hadamard)
tensor_scale a s = ...  -- scalar multiply
tensor_relu a = ...     -- max(0, x) element-wise
tensor_gelu a = ...     -- 0.5 * x * (1 + tanh(sqrt(2/pi) * (x + 0.044715*x^3)))

-- Reductions
tensor_sum a axis = ... -- sum along axis, returns smaller tensor
tensor_mean a axis = ...
tensor_var a axis = ... -- variance

-- Shape ops (no data copy — just change strides)
tensor_transpose a = ... -- swap last two dims' strides
tensor_reshape a new_shape = ... -- recompute strides, same data
```

### Deliverable
- `stdlib/tensor.rail` — tensor type + all CPU ops
- Test: `matmul (2x3 matrix) (3x2 matrix)` = correct result, verified against hand computation
- Test: matmul 64x64 completes in reasonable time on CPU

---

## Phase 2: Metal GPU Acceleration

### Upgrade Current Pipeline

The current Metal codegen in `compile.rail` (lines 927-940, 2073-2076, 2412-2439) does:
1. AST → Metal shader string (int only, elementwise)
2. Write to `/tmp/rail_gpu.metal`
3. `xcrun metal -c` → `.air` → `metallib`
4. External `gpu_host` binary executes kernel
5. Parse CSV results back

**Required upgrades:**

#### 2a. Float support in Metal kernels
```metal
// Current (int only):
kernel void rail_kernel(device int *data [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    int x = data[id];
    data[id] = (x * x + 1);
}

// New (float):
kernel void rail_kernel(device float *data [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    float x = data[id];
    data[id] = x * x + 1.0;
}
```
Change: `gen_metal_kernel` emits `float` instead of `int`. `ast_to_metal` handles float literals. `gpu_host` reads/writes float buffers.

#### 2b. Matmul kernel
```metal
// Tiled matmul — the inner kernel of ML
kernel void matmul_kernel(
    device const float *A [[buffer(0)]],
    device const float *B [[buffer(1)]],
    device float *C [[buffer(2)]],
    constant uint &M [[buffer(3)]],
    constant uint &N [[buffer(4)]],
    constant uint &K [[buffer(5)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint row = gid.y;
    uint col = gid.x;
    if (row >= M || col >= N) return;

    float sum = 0.0;
    for (uint i = 0; i < K; i++) {
        sum += A[row * K + i] * B[i * N + col];
    }
    C[row * N + col] = sum;
}
```

M4 Pro GPU: 16 cores, 38 TFLOPS fp16, ~4 TFLOPS fp32. Even a naive kernel gets 1-2 TFLOPS — enough for 10-100M param training.

#### 2c. Persistent Metal context (critical for training speed)

Current pipeline recompiles Metal shaders via shell every call. For training, need:
- Compile kernels once at startup
- Reuse Metal device + command queue across calls
- Pass float_arr buffers directly (zero-copy — Metal and CPU share unified memory on Apple Silicon!)

**Implementation**: New Rail runtime functions in ARM64 assembly:
```
_rail_metal_init          -- create device + command queue, store globally
_rail_metal_compile_kernel -- compile MSL string → pipeline state, cache it
_rail_metal_dispatch      -- dispatch kernel with float_arr buffers
```

The unified memory architecture means float_arr pointers can be used directly as Metal buffer pointers. No GPU upload/download. This is the Apple Silicon advantage — the data is already there.

#### 2d. Additional GPU kernels for ML
```metal
// Softmax (two-pass: max + exp-sum)
// LayerNorm (mean + variance + normalize)
// GELU (elementwise)
// RoPE (rotary position embeddings)
// Cross-entropy loss
// Backward kernels for each
```

### Deliverable
- `gpu_host` upgraded for float buffers + multi-buffer dispatch
- Metal matmul verified against CPU matmul on 256x256
- GPU matmul 1024x1024 in <10ms (validates Metal pipeline works)
- Persistent context: 1000 matmuls without recompiling shader

---

## Phase 3: Forward-Only Inference

Load RailGPT weights and run inference in pure Rail. No Python, no MLX.

### Weight Loading
```rail
-- RailGPT checkpoint is safetensors format
-- Need: read binary file → parse safetensors header → extract float arrays
-- Alternative: dump weights to a simple binary format from Python once:
--   [n_layers][d_model][n_heads][vocab_size]
--   [weight1_name_len][weight1_name][weight1_shape][weight1_data_f32...]
--   ...
-- Rail reads this directly into Tensor objects

load_model path =
  let bytes = read_binary path
  let config = parse_header bytes
  let weights = parse_weights bytes config
  Model config weights
```

### Transformer Forward Pass
```rail
-- GPT-2 style (matching RailGPT architecture)
-- RoPE + SwiGLU + pre-norm + tied embeddings

transformer_forward model tokens =
  let x = embedding_lookup model.embed tokens  -- (seq_len, d_model)
  let x = fold (\x layer -> transformer_block layer x) x model.layers
  let x = layer_norm model.final_norm x
  logits model.embed x  -- tied embeddings: (seq_len, vocab_size)

transformer_block layer x =
  let residual = x
  let x = layer_norm layer.norm1 x
  let x = multi_head_attention layer.attn x
  let x = tensor_add residual x
  let residual = x
  let x = layer_norm layer.norm2 x
  let x = swiglu_ffn layer.ffn x
  tensor_add residual x

multi_head_attention attn x =
  let q = matmul x attn.wq    -- (seq, d) @ (d, d) → (seq, d)
  let k = matmul x attn.wk
  let v = matmul x attn.wv
  let q = apply_rope q         -- rotary position embeddings
  let k = apply_rope k
  -- reshape to (n_heads, seq, head_dim), compute attention per head
  let scores = matmul q (transpose k)  -- (seq, seq)
  let scores = tensor_scale scores (1.0 / sqrt head_dim)
  let scores = causal_mask scores       -- upper triangle = -inf
  let scores = softmax scores
  let out = matmul scores v
  matmul out attn.wo              -- output projection

swiglu_ffn ffn x =
  let gate = matmul x ffn.w_gate   -- (seq, d) @ (d, 4d) → (seq, 4d)
  let up = matmul x ffn.w_up
  let gate = silu gate              -- SiLU = x * sigmoid(x)
  let x = tensor_mul gate up        -- element-wise gate
  matmul x ffn.w_down               -- (seq, 4d) @ (4d, d) → (seq, d)
```

### Token Generation
```rail
generate model prompt max_tokens temperature =
  let tokens = tokenize prompt
  loop_generate model tokens max_tokens temperature 0

loop_generate model tokens remaining temp i =
  if remaining == 0 then tokens
  else
    let logits = transformer_forward model tokens
    let next_logits = last_row logits           -- only need last position
    let next_logits = tensor_scale next_logits (1.0 / temp)
    let probs = softmax next_logits
    let next_token = sample probs               -- multinomial sample
    let tokens = append tokens [next_token]
    loop_generate model tokens (remaining - 1) temp (i + 1)
```

### BPE Tokenizer in Rail
```rail
-- RailGPT uses 4K vocab BPE, all Rail keywords are single tokens
-- Merge table: list of (pair, replacement) ordered by priority
-- Encode: split to chars → repeatedly merge highest-priority pair

tokenize text =
  let chars = map char_to_id (chars text)
  apply_merges chars merge_table

apply_merges tokens merges =
  if length merges == 0 then tokens
  else
    let (pair, replacement) = head merges
    let tokens = merge_pair tokens pair replacement
    if changed then apply_merges tokens merges
    else apply_merges tokens (tail merges)
```

### Deliverable
- `tools/railml/inference.rail` — full transformer inference
- Load RailGPT-10M weights (small, fast to test)
- Generate 50 tokens, verify output matches Python/MLX version token-for-token
- Benchmark: tokens/sec on M4 Pro (target: >10 tok/s for 10M model)
- **This replaces the Python MLX dependency for serving**

---

## Phase 4: Backward Pass (Autodiff)

### Approach: Tape-Based (first), Source-to-Source (later)

**Tape-based** is simpler and maps naturally to Rail's functional style. Each forward op returns `(output, backward_fn)` where `backward_fn` is a closure that computes gradients given upstream gradient.

```rail
-- A "traced" tensor carries its backward function
type TrackedTensor = Tracked Tensor (Tensor -> List (Tensor, Tensor))
--                          value    grad_fn: upstream_grad → [(param, param_grad), ...]

-- Matmul forward + backward
tracked_matmul a b =
  -- Forward
  let output = matmul (value a) (value b)
  -- Backward closure captures a, b for gradient computation
  let grad_fn = matmul_backward (value a) (value b)
  Tracked output grad_fn

matmul_backward a_val b_val upstream_grad =
  -- d(loss)/d(A) = upstream_grad @ B^T
  let da = matmul upstream_grad (tensor_transpose b_val)
  -- d(loss)/d(B) = A^T @ upstream_grad
  let db = matmul (tensor_transpose a_val) upstream_grad
  [(a_val, da), (b_val, db)]
```

**NOTE**: Rail has a known issue with lambda segfaults in `filter`. For backward closures, use named functions that take captured values as explicit arguments:

```rail
-- Instead of: \grad -> matmul grad (transpose b)
-- Use: matmul_backward a_val b_val   (returns a function that takes grad)
-- Rail flattens nested lambdas to multi-param, so this is natural
```

### Gradient Ops Needed

| Forward Op | Backward (d_output → d_inputs) |
|---|---|
| `matmul(A, B)` | `dA = dOut @ B^T`, `dB = A^T @ dOut` |
| `tensor_add(A, B)` | `dA = dOut`, `dB = dOut` |
| `tensor_mul(A, B)` | `dA = dOut * B`, `dB = dOut * A` (Hadamard) |
| `relu(X)` | `dX = dOut * (X > 0)` |
| `gelu(X)` | `dX = dOut * gelu'(X)` (derivative of GELU) |
| `softmax(X)` | `dX = softmax * (dOut - sum(dOut * softmax))` |
| `layer_norm(X)` | standard layernorm backward (mean/var chain rule) |
| `cross_entropy(logits, targets)` | `d_logits = softmax(logits) - one_hot(targets)` |
| `embedding(W, ids)` | `dW[ids] += dOut` (scatter-add) |

### Gradient Checking
```rail
-- Numerical gradient: (f(x+eps) - f(x-eps)) / (2*eps)
-- Compare against analytical backward. Must match to ~1e-5 relative error.
grad_check fn x eps =
  let analytical = backward fn x
  let numerical = numerical_grad fn x eps
  let rel_error = tensor_max (tensor_abs (tensor_sub analytical numerical))
                  / (tensor_max (tensor_abs analytical) + 1e-8)
  rel_error  -- should be < 1e-5
```

### Source-to-Source (Phase 4b — the Rail way)

After tape-based works, add a compiler pass:

```
diff : (Tensor → Tensor) → (Tensor → Tensor → Tensor)
       forward_fn        → backward_fn(input, upstream_grad) → input_grad
```

The compiler already does AST transforms (optimizer, GPU dispatch). Autodiff is one more transform:
- Walk the AST
- For each op node, emit the adjoint
- Chain rule composes adjoints
- Result: a new function in the compiled binary, zero overhead

This is what JAX does (source-to-source via tracing), but Rail would do it at compile time on the actual AST. No Python overhead, no tracing overhead. The derivative IS compiled ARM64.

### Deliverable
- `stdlib/autograd.rail` — tape-based autodiff
- Gradient check passes for all ops (matmul, add, relu, softmax, layernorm, cross_entropy)
- Full transformer backward pass computes gradients for all parameters
- Benchmark: forward+backward on 10M model, <1s per batch

---

## Phase 5: Training Loop

### Optimizer (Adam)
```rail
-- Adam state per parameter: (m, v, t) — first moment, second moment, step count
type AdamState = Adam Tensor Tensor Int

adam_update param grad state lr beta1 beta2 eps =
  match state | Adam m v t ->
    let t = t + 1
    let m = tensor_add (tensor_scale m beta1) (tensor_scale grad (1.0 - beta1))
    let v = tensor_add (tensor_scale v beta2) (tensor_scale (tensor_mul grad grad) (1.0 - beta2))
    let m_hat = tensor_scale m (1.0 / (1.0 - pow beta1 (to_float t)))
    let v_hat = tensor_scale v (1.0 / (1.0 - pow beta2 (to_float t)))
    let update = tensor_mul m_hat (tensor_map (\x -> 1.0 / (sqrt x + eps)) v_hat)
    let new_param = tensor_sub param (tensor_scale update lr)
    (new_param, Adam m v t)
```

### Data Pipeline
```rail
-- Rail corpus is already tokenized (from RailGPT's BPE tokenizer)
-- Training data: fixed-length sequences from tokenized .rail files
-- No DataLoader — just read chunks from preprocessed binary file

load_batch data_file batch_size seq_len offset =
  let tokens = read_int_chunk data_file offset (batch_size * (seq_len + 1))
  -- input: tokens[0..seq_len-1], target: tokens[1..seq_len]
  let inputs = reshape tokens [batch_size, seq_len]
  let targets = reshape (slice tokens 1) [batch_size, seq_len]
  (inputs, targets, offset + batch_size * (seq_len + 1))
```

### Training Loop
```rail
train model data_file config =
  let state = init_adam_state model
  loop_train model state data_file config 0 0

loop_train model state data_file config step offset =
  if step >= config.max_steps then model
  else
    let (inputs, targets, new_offset) = load_batch data_file config.batch_size config.seq_len offset
    let (loss, grads) = forward_backward model inputs targets
    let (model, state) = adam_step model grads state config.lr

    -- Log every N steps
    let _ = if step % 100 == 0 then
      print (cat ["step ", show step, " loss ", show_float loss])
    else 0

    -- Checkpoint every N steps
    let _ = if step % 1000 == 0 then
      save_checkpoint model (cat ["/tmp/railml_ckpt_", show step, ".bin"])
    else 0

    loop_train model state data_file config (step + 1) new_offset
```

### Deliverable
- `tools/railml/train.rail` — full training loop
- Train 10M model from random init on Rail corpus for 1000 steps
- Loss decreases monotonically
- Generated code starts looking like Rail by step 500
- Benchmark: steps/sec on M4 Pro (target: >1 step/s for 10M, batch=4, seq=256)

---

## Phase 6: The Closed Loop

This is where it gets unprecedented.

```
                    +------------------+
                    |  Rail Compiler   |  ← the oracle (ground truth)
                    +--------+---------+
                             |
                    compiles + verifies
                             |
              +--------------+---------------+
              |                              |
        [correct code]                [error message]
              |                              |
              v                              v
     +--------+--------+          +---------+---------+
     | Harvest to       |          | Error → repair    |
     | training corpus  |          | example           |
     +---------+--------+          +---------+---------+
               |                             |
               +-------------+---------------+
                             |
                      +------+------+
                      | Retrain     |
                      | (in Rail!)  |
                      +------+------+
                             |
                      +------+------+
                      | RailML      |
                      | Model       |
                      +------+------+
                             |
                      generates code
                             |
                    +--------v---------+
                    |  Rail Compiler   |
                    +------------------+
```

### The Self-Improving Cycle
```rail
self_improve model compiler curriculum =
  -- Pick a task from curriculum
  let task = next_task curriculum
  -- Generate code
  let code = generate model task.prompt 512 0.7
  -- Compile with the Rail compiler (THE ORACLE)
  let result = shell (cat ["./rail_native run /tmp/candidate.rail 2>&1"])
  if is_success result then
    -- Harvest: add (prompt, code) to training data
    let _ = append_jsonl "training/harvest.jsonl" task.prompt code
    -- Advance curriculum
    self_improve model compiler (advance curriculum task)
  else
    -- Error: create repair example (prompt + error → corrected attempt)
    let _ = append_jsonl "training/errors.jsonl" task.prompt code (err_msg result)
    self_improve model compiler curriculum
```

### What Makes This Different From Everything Else

1. **Zero external dependencies**: Rail compiles Rail, Rail trains the model, Rail runs inference, Rail verifies the output. The entire stack is one language.

2. **Perfect training signal**: The compiler is an oracle. Not RLHF, not human preference, not vibes. Binary: compiles or doesn't. Produces correct output or doesn't. No label noise.

3. **Unified memory**: On Apple Silicon, CPU and GPU share memory. Tensors don't move. The compiler and the model operate on the same data without serialization.

4. **The bootstrap**: Rail compiled itself. Now it trains a model that writes Rail. If the model gets good enough, it could propose compiler improvements — which get verified by compiling the compiler. Self-improvement with a proof checker.

---

## Build Order & Dependencies

```
Phase 1: Tensor (CPU)          ← no dependencies, start here
   |
Phase 2: Metal GPU             ← needs Phase 1 for verification
   |
Phase 3: Inference             ← needs Phase 1 (CPU ok), Phase 2 (fast)
   |                              *** MILESTONE: drop Python/MLX dependency ***
Phase 4: Autodiff              ← needs Phase 1 + 3
   |
Phase 5: Training              ← needs Phase 1-4
   |                              *** MILESTONE: train model in pure Rail ***
Phase 6: Closed Loop           ← needs Phase 5 + compiler
                                  *** MILESTONE: self-improving Rail ***
```

### Time Estimates (focused work)

| Phase | Effort | What unlocks |
|---|---|---|
| 1. Tensor | 2-3 days | Foundation for everything |
| 2. Metal GPU | 3-5 days | 100-1000x speedup over CPU matmul |
| 3. Inference | 3-4 days | Kill Python dependency, serve from Rail binary |
| 4. Autodiff | 5-7 days | Gradient computation, the hardest phase |
| 5. Training | 2-3 days | Full training loop, mostly plumbing |
| 6. Closed loop | 1-2 days | Just connecting existing pieces |

**Total: ~3-4 weeks of focused work**

### Risk Register

| Risk | Impact | Mitigation |
|---|---|---|
| Float precision in matmul accumulation | Training diverges | Use Kahan summation or f64 accumulators |
| Metal kernel compilation latency | Slow training | Persistent context (Phase 2c), precompile all kernels |
| Lambda segfault in backward closures | Can't do autodiff | Use named functions with explicit captures (Rail pattern) |
| Arena exhaustion from tensor allocations | OOM | GC handles this now; also arena_mark/reset per batch |
| Compiler string limits on generated Metal code | Silent miscompile | Chunked writes for kernel source (known Rail pattern) |

---

## Architecture Decisions

### Why tape-based autodiff first (not source-to-source)
- Tape works today with Rail's current feature set
- Source-to-source requires a new compiler pass (powerful but complex)
- Tape gets us training; S2S is an optimization for later
- Can switch to S2S without changing the training loop API

### Why f64 not f16/bf16
- Rail's native floats are f64 (IEEE 754 double)
- M4 Pro does 38 TFLOPS fp16 but f64 is what we have
- For 10-100M models, f64 throughput is sufficient
- f16 can be a Metal-only optimization (compute in f16, store in f64)

### Why not use MPS (Metal Performance Shaders) directly
- MPS matmul would be faster out of the box
- But it's an opaque framework — can't inspect or modify
- Custom kernels mean we understand every instruction
- Custom kernels can be specialized (fused ops, custom layouts)
- Rail's philosophy: if you didn't build it, you don't own it

### Why 10M model first (not larger)
- Fits entirely in L2 cache on M4 Pro
- Fast iteration: train for 10 min, see results
- All bugs are findable at small scale
- Growth path already proven (RailGPT: 10M → 50M → 200M → 400M via Net2Net)

---

## The Poetic Version

Rail compiles itself. A language that knows its own grammar at the deepest level — not as documentation, but as executable code that produces byte-identical binaries.

Now teach it to learn. Give it tensors, give it gradients, give it the ability to adjust weights based on evidence. The evidence is its own compiler output. The training signal is truth, verified by the system itself.

A model trained this way doesn't learn to approximate human preferences about code. It learns to write code that *the compiler accepts*. The oracle isn't a human labeler or a reward model — it's the same compiler that compiled the training system.

When the model gets good enough to propose improvements to the compiler, and those improvements are verified by compiling the compiler with itself, the system has achieved something that doesn't have a name yet.

It started with a language. It ends with a language that writes itself.
