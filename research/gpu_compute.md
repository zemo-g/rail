# GPU Compute Research for Rail
*2026-03-16 — What to steal for a small language emitting Metal shaders*

---

## 1. Futhark — Pure Functional to GPU

**What it is**: Statically typed, purely functional array language (Haskell-like) that compiles to GPU code. Research language from DIKU (University of Copenhagen).

**Compilation pipeline**:
- Source → core IR (essentially a tiny functional language) → optimization passes → flattened parallel IR → C/OpenCL/CUDA/Metal backend code
- The compiler started as "not much more than a compiler IR" that grew into a language
- Backends: `futhark c` (sequential), `futhark opencl`, `futhark cuda`, `futhark metal` (added ~2022)
- Generated code is C with embedded GPU kernel strings, compiled with system compiler

**Key technique — Incremental Flattening**:
- Nested parallelism (map-of-map, map-of-reduce) is "flattened" to single-level GPU parallelism
- Generates multi-versioned code: different code paths for different input sizes
- Full flattening (from NESL) always works but produces inefficient code; incremental flattening is smarter

**Parallel primitives (SOACs)**:
- `map`, `reduce`, `scan`, `scatter`, `reduce_by_index` (histogram)
- These are the ONLY sources of parallelism — compiler knows exactly what's parallel
- Fusion: adjacent maps fuse into single kernel, map-reduce fuses, etc.
- Cost model: Work (total ops) and Span (critical path assuming infinite parallelism)
- Optimal = O(n) work, O(log n) span (e.g., tree reduction)

**Critical constraint**: No dynamic memory allocation in GPU code. All array sizes must be computable before kernel launch. Compiler pre-computes sizes symbolically.

**Performance**:
- Matches Thrust (NVIDIA's C++ GPU library) on simple reductions
- Beats Thrust on non-commutative operations (scan-based) at large input sizes
- "Decent performance" on stencil computations without specialized tricks
- Small inputs: GPU overhead dominates (290ms vs <10ms CPU for dot product on small arrays)
- Large inputs (10M elements): 10x+ faster than CPU

**Metal backend status**: Exists, works, but Metal lacks some features OpenCL has (no 64-bit atomics was a historical issue). Performance comparable to OpenCL on Apple Silicon.

**What to steal**:
- The SOAC model: `map`, `reduce`, `scan` as the fundamental parallel building blocks
- Symbolic size pre-computation for GPU memory allocation
- Fusion rules: adjacent maps → single kernel, map-reduce → single kernel
- Work/span cost model for deciding CPU vs GPU dispatch
- Multi-versioned code generation based on input size

---

## 2. Halide — Algorithm/Schedule Separation

**What it is**: DSL embedded in C++ for image processing pipelines. Decouples WHAT to compute from HOW to compute it.

**The key idea — separation of concerns**:
```
Algorithm: blur_y(x, y) = (input(x,y-1) + input(x,y) + input(x,y+1)) / 3
Schedule:  blur_y.gpu_tile(x, y, xo, yo, xi, yi, 8, 8)
```
- Algorithm is pure math — never changes
- Schedule controls tiling, vectorization, parallelism, memory locality
- Same algorithm, different schedule = CPU SIMD, GPU blocks, or distributed

**GPU scheduling directives**:
- `gpu_tile(x, y, bx, by, tx, ty, 8, 8)` — maps to blocks + threads
- `gpu_blocks(var)` / `gpu_threads(var)` — explicit hardware mapping
- `compute_at(func, var)` — controls where intermediates are computed (shared memory)
- `.vectorize()`, `.parallel()`, `.unroll()` — standard optimizations

**Compilation pipeline**:
- C++ API builds in-memory IR → optimization passes → target-specific lowering
- Can JIT-compile or emit object files
- Backends: CUDA, OpenCL, Metal, D3D12, plus CPUs (x86, ARM, RISC-V)
- On macOS: Metal preferred over OpenCL due to driver reliability

**Autoscheduler** (2019): Automatically finds good schedules using beam search + learned cost model. Gets ~80-90% of hand-tuned performance. The search space is combinatorial (tile sizes × fusion decisions × storage decisions).

**What to steal**:
- Separation of algorithm from schedule is the single best idea here
- Rail could define computation functionally, then have schedule annotations control GPU mapping
- `gpu_tile` concept: split loops into block-level and thread-level
- `compute_at` for controlling shared memory staging
- The autoscheduler approach: even a simple heuristic scheduler beats manual tuning for most cases

---

## 3. SPIR-V Cross — Shader Language Translation

**What it is**: Tool from Khronos that parses SPIR-V bytecode and converts to GLSL, HLSL, MSL (Metal), or JSON reflection.

**Translation pipeline**:
1. Parse SPIR-V binary into internal IR
2. Reflection: extract resource bindings, types, buffer layouts
3. Code generation: emit target language with readable output

**Supported targets**: GLSL, HLSL, MSL (Metal Shading Language), JSON reflection, C++ (deprecated)

**Key design decision**: Prioritizes readable output over mechanical translation. Generated MSL looks like hand-written code, not IR dumps.

**Limitations**: Some obscure GLSL features unsupported. Semantic differences between languages require manual intervention (e.g., HLSL combined image/sampler → GLSL separate objects).

**What to steal**:
- SPIR-V as universal GPU IR is the industry standard approach
- If Rail ever needs multiple GPU backends, compiling to SPIR-V then using SPIRV-Cross for Metal output is viable
- But for Metal-only: skip SPIR-V entirely, emit MSL directly (simpler, fewer abstraction layers)
- The reflection API pattern: analyzing shader resources for automatic buffer binding

---

## 4. Metal Shading Language — Compute Primitives

**Execution model**:
```
Grid → Threadgroups → SIMD Groups → Threads
```

**Apple Silicon specifics**:
- SIMD width: 32 threads per SIMD group
- Max threadgroup size: 512-1024 threads (device-dependent)
- Threadgroup memory: 32KB per threadgroup
- Unified memory: CPU and GPU share physical RAM — no copies needed
- M1 Max: up to 48GB GPU-accessible from 64GB system RAM
- M4 Pro: 10 GPU cores

**Compute primitives available**:
- **Parallel map**: trivial — each thread processes one element
- **Reduction**: tree reduction within threadgroup, then atomic across threadgroups
- **Scan (prefix sum)**: Hillis-Steele or Blelloch within SIMD group, then across threadgroups
- **SIMD group operations**: `simd_sum`, `simd_prefix_exclusive_sum`, `simd_shuffle`, `simd_broadcast`
- **Atomics**: `atomic_fetch_add`, `atomic_fetch_max`, etc. (threadgroup atomics MUCH faster than device atomics)
- **Matrix operations**: via Metal Performance Shaders (MPS) framework, not raw MSL
- **Barriers**: `threadgroup_barrier(mem_flags::mem_threadgroup)` for sync within threadgroup

**Data types for compute**:
- `half` (16-bit float) — use whenever possible, halves register pressure
- `float` (32-bit) — standard
- `int`/`uint` — NOTE: use `int` (signed) for loop indices, enables vectorized loads
- `float4` vectors — use for memory coalescing (128-bit loads vs 32-bit)

**Key performance rules**:
- Use `half` over `float` where precision allows — fewer registers, higher occupancy
- Signed loop indices enable compiler vectorization (unsigned disables it!)
- Threadgroup atomics are fast, device-scope atomics are slow
- Textures have separate L1 cache from buffers — use for 2D spatial data
- Dynamic indexing into stack arrays causes register spill — avoid
- Batch multiple compute encoders per command buffer

**What to steal**:
- SIMD group operations are the fast path — `simd_sum` for reductions, `simd_shuffle` for communication
- Two-level reduction: SIMD-level → threadgroup-level → device-level
- `half` as default numeric type for GPU work (with `float` fallback)
- Signed int for indices is a subtle but important codegen detail
- Threadgroup memory as explicit scratchpad (32KB limit)

---

## 5. Taichi — Python-like to GPU Kernels

**What it is**: Python DSL using decorators (`@ti.kernel`) to mark functions for GPU compilation. JIT-compiled.

**Compilation pipeline**:
1. **Python AST transformation**: `ASTTransformer` converts decorated function body to Taichi frontend IR
2. **SSA IR generation**: Frontend IR lowered to hierarchical Static Single Assignment IR
3. **Optimization passes**: Loop vectorization, type inference, CSE, dead code elimination, constant folding, access lowering, atomic demotion, auto-diff
4. **Backend codegen**: Optimized SSA IR → LLVM (CPU/CUDA) or Metal/OpenGL shader compilers

**Backends**: CPU, CUDA, Vulkan, OpenGL, Metal (macOS)

**Key design — SNode (Structured Nodes)**:
- Generic data containers for hierarchical, dense/sparse, multi-dimensional fields
- Decouples computation from data layout
- Can switch AoS ↔ SoA with minimal code changes
- This is similar to Halide's algorithm/schedule separation but for data layout

**Mega-kernel design**: Write substantial computation in single kernels rather than many small fused operators. Reduces kernel launch overhead.

**Performance**: 50-100x over native Python. Outermost `for` loops in kernels are auto-parallelized.

**What to steal**:
- `@ti.kernel` decorator model — Rail equivalent: annotate functions for GPU compilation
- SNode data layout decoupling — express data structure separately from computation
- Auto-parallelization of outermost loops — simple rule, big payoff
- Mega-kernel approach: one big kernel > many small ones (launch overhead matters)
- The backend selection pattern: `ti.init(arch=ti.gpu)` tries CUDA → Vulkan → Metal → CPU

---

## 6. Triton — JIT GPU Kernels from Python

**What it is**: OpenAI's language for writing GPU kernels in Python. Targets NVIDIA GPUs primarily. Block-oriented programming model.

**Compilation pipeline**:
1. **Python → Triton IR**: `@triton.jit` decorator captures function, builds Triton IR (MLIR-based)
2. **Triton IR optimization**: Inliner, Combine, Canonicalizer, CSE, Loop Invariant Code Motion
3. **TritonGPU IR**: Adds GPU-specific data layouts and optimizations
   - Pipeline pass: N-buffer optimization for global→shared memory transfers
   - Prefetch pass: shared→register transfer optimization
   - Coalescing pass: memory access pattern optimization
4. **LLVM IR → PTX**: Final lowering inserts inline PTX for performance-critical ops (`ldmatrix`, `mma.sync`)

**Data layout system** (critical innovation):
- **Blocked Layout**: Maps tensors across threads with `sizePerThread`, `threadsPerWarp`, `warpsPerCTA`
- **Shared Layout**: Specifies swizzling to avoid bank conflicts
- **MMA Layout**: Tensor core output arrangements
- **DotOperand Layout**: Matrix multiply input patterns
- **Slice Layout**: Single-dimension indexing

**Programming model**: SPMD — many program instances each process a block of data. "If you had a vector of length 256 and block_size of 64, the programs would each access elements [0:64, 64:128, 128:192, 192:256]."

**What to steal**:
- Block-oriented programming model is simpler than thread-level
- The layout system: explicit data layout descriptions that the compiler uses for optimization
- N-buffer prefetching: overlap memory transfers with computation
- Bank conflict avoidance via swizzling in shared memory layouts
- MLIR as compilation framework — proven for GPU IR transformations

---

## 7. WebGPU WGSL — The New Shader Language

**What it is**: W3C standard shader language for WebGPU. Designed for portability across GPU architectures.

**Compute model**:
- Workgroups (= Metal threadgroups) containing invocations (= threads)
- Workgroup shared memory for cooperation
- Private memory per invocation

**Memory address spaces** (explicit, not implicit):
- `private` — per-invocation
- `workgroup` — shared within workgroup (= Metal threadgroup memory)
- `uniform` — read-only, all invocations
- `storage` — general-purpose buffers with access modes
- `function` — stack-like temporaries

**Data types**: bool, i32, u32, f32, f16, vec2-vec4, mat2x2-mat4x4, arrays, structs. No implicit type promotion — all casts explicit.

**Built-in compute operations**:
- Atomics: load, store, add, sub, max, min, and, or, xor
- Barriers: `workgroupBarrier()`, storage/texture barriers
- Subgroup operations: reduction, broadcast, shuffle (like Metal SIMD ops)
- 63+ numeric functions

**Resource limits**:
- Private memory: 8,192 bytes per shader
- Workgroup memory: 16,384 bytes (vs Metal's 32KB)
- Max struct members: 1,023
- Max nesting depth: 15

**vs Metal**: WGSL prioritizes portability and safety over performance. Stricter uniformity analysis. Smaller workgroup memory. No implicit conversions. More conservative but runs everywhere.

**What to steal**:
- Explicit address space declarations — forces clear thinking about memory
- The uniformity analysis concept — prevents non-deterministic GPU behavior
- WGSL's type system is actually cleaner than Metal's — no implicit promotions
- But: if targeting Metal directly, WGSL's conservatism is unnecessary overhead

---

## 8. GPU vs CPU Efficiency — Crossover Points

**Where GPU wins decisively**:
| Operation | GPU Advantage | Minimum Size for GPU Win |
|-----------|--------------|-------------------------|
| Matrix multiply | 10-100x | ~512x512 |
| Element-wise map | 5-50x | ~100K elements |
| Reduction (sum) | 5-20x | ~1M elements |
| Scan (prefix sum) | 3-10x | ~1M elements |
| Sorting | 2-5x | ~1M elements |
| Image convolution | 10-50x | ~256x256 |

**Where CPU wins**:
- Small arrays (< ~10K elements): GPU launch overhead dominates
- Sequential algorithms with data dependencies
- Branch-heavy code (GPU SIMD divergence kills performance)
- Small, irregular workloads
- Single operations (overhead of dispatch > compute time)

**Futhark's concrete numbers**: Dot product of small arrays — GPU 290ms vs CPU <10ms. At 10M elements, GPU 10x faster. The crossover is real and workload-dependent.

**Apple Silicon special case**: Unified memory eliminates transfer overhead. The crossover point is LOWER on Apple Silicon than discrete GPU systems because there's no PCIe copy cost. For UMA systems, even ~50K element operations can benefit from GPU.

**GPU matmul progression** (A100, 4092x4092):
| Optimization | GFLOPs | % of Peak |
|-------------|--------|-----------|
| Naive | 309 | 1.3% |
| Memory coalescing | 1,987 | 8.5% |
| Shared memory tiling | ~8,000 | ~35% |
| 2D blocktiling | 15,972 | 68.7% |
| Vectorized loads | 18,237 | 78.4% |
| Warp-level tiling | 21,779 | 93.7% |

**Key insight**: Getting to 70% of peak is relatively easy with tiling + shared memory. Getting to 95% requires increasingly exotic optimizations. For a language compiler, targeting 70% is pragmatic.

**What to steal**:
- Automatic CPU/GPU dispatch based on input size thresholds
- For Apple Silicon UMA: threshold is lower than you'd think (~50K elements)
- Target 70% peak with tiling + shared memory — diminishing returns beyond
- Memory coalescing alone gives 6x speedup — it's the single most important optimization

---

## 9. Apple Metal Best Practices for M-Series

**Unified Memory Architecture**:
```
CPU and GPU share the same physical memory pool.
No copies needed. Just create a MTLBuffer and both sides see it.
M1 Max: up to 48GB GPU-accessible
M4 Pro: ~16GB GPU-accessible from 24GB system
```

**Optimal threadgroup configuration**:
- SIMD width = 32 on all Apple Silicon
- Threadgroup size should be multiple of 32
- Common choices: 256 (8 SIMD groups) or 512 (16 SIMD groups)
- Query `maxTotalThreadsPerThreadgroup` from pipeline state — varies by kernel complexity
- Higher register pressure → fewer threads per threadgroup

**Memory hierarchy**:
- Registers (fastest, per-thread, limited)
- Threadgroup memory (32KB, shared within threadgroup, explicit)
- Texture cache (separate L1, good for 2D spatial access)
- Buffer cache (separate L1)
- Device memory (unified, no copy needed from CPU)

**Critical codegen rules**:
1. **Use `half` (16-bit)** — halves register pressure, doubles throughput for many ops
2. **Signed `int` for loop indices** — enables compiler auto-vectorization
3. **`float4` vector loads** — 4x memory throughput via coalesced 128-bit loads
4. **Avoid dynamic stack array indexing** — causes register spill to memory
5. **Threadgroup atomics over device atomics** — order of magnitude faster
6. **Textures for 2D data** — dedicated cache + lossless compression
7. **Batch command encoders** — multiple compute dispatches per command buffer

**Occupancy** (threads active / max possible):
- Reduced by: high register usage, threadgroup memory usage, complex ALU
- Improve by: using `half`, reducing stack arrays, setting appropriate `maxTotalThreadsPerThreadgroup`

**Triple-buffering**: CPU writes buffer N+1 while GPU reads buffer N. Three buffers to cover CPU prep + GPU execution + GPU read overlap.

**What to steal for Rail**:
- Emit `half` by default for GPU numeric types, `float` only when needed
- Generate `int` (not `uint`) loop variables
- Emit `float4` vector loads for contiguous array access
- Threadgroup size = 256 as safe default (8 SIMD groups of 32)
- For reductions: SIMD-level reduce → threadgroup-level → atomic device-level
- No data copies needed on Apple Silicon — just share the buffer

---

## 10. Functional Languages → Metal Compute: Prior Art

**Futhark → Metal**: The most direct prior art. Works. Compiles pure functional array code to Metal compute kernels. Challenges encountered:
- Metal's lack of 64-bit atomics (historical, may be resolved in newer hardware)
- Metal's different memory model vs OpenCL required backend adjustments
- Performance is comparable to OpenCL backend on Apple Silicon
- Key limitation: all memory must be pre-allocated — no dynamic allocation in kernels

**Accelerate (Haskell) → GPU**: Haskell array language that compiles through LLVM to CUDA (PTX). No Metal backend.
- Uses LLVM as common backend — functional IR → LLVM IR → PTX
- Performs fusion: combining multiple array operations into single kernels
- Type-safe runtime code generation
- Key insight: functional purity makes fusion SAFE — no side effects means reordering is always valid

**Common challenges across all functional→GPU projects**:
1. **Memory allocation**: GPUs don't do dynamic alloc. Must pre-compute all sizes.
2. **Closures**: GPU kernels can't capture heap-allocated closures. Must inline or specialize.
3. **Recursion**: GPUs have limited/no call stack. Must convert to iteration.
4. **Higher-order functions**: Must be monomorphized/specialized before GPU codegen.
5. **Garbage collection**: Not possible on GPU. Must use regions or linear types.

**What actually works**:
- Restrict parallelism to known primitives (map, reduce, scan) — don't try to auto-parallelize general code
- Inline everything — GPU kernels should be flat
- Specialize all polymorphism — no generics in GPU code
- Pre-compute all buffer sizes on CPU, allocate, then launch kernel

**What to steal**:
- Futhark's approach: a small set of parallel primitives, everything else is sequential
- Accelerate's approach: LLVM as backend enables optimization passes for free
- Functional purity enables aggressive fusion — this is the killer advantage
- Convert closures to specialized kernel functions at compile time
- Linear/uniqueness types to avoid GC on GPU (Futhark uses uniqueness types for this)

---

## Synthesis: What Rail Should Steal

### Tier 1 — Steal Now
1. **Parallel primitives as language constructs**: `map`, `reduce`, `scan` with known GPU implementations. Don't auto-parallelize — be explicit.
2. **Emit `half` by default** for GPU numerics. Generate `int` loop indices. Use `float4` vector loads.
3. **Threadgroup size = 256** as default (8 SIMD groups of 32).
4. **Fusion**: Adjacent maps → single kernel. Map-reduce → single kernel. Functional purity makes this safe.
5. **CPU/GPU dispatch**: Below ~50K elements on Apple Silicon, run on CPU. Above, dispatch to GPU.
6. **Pre-compute buffer sizes** on CPU before kernel launch. No dynamic allocation in kernels.

### Tier 2 — Steal Soon
7. **Halide-style algorithm/schedule separation**: Define computation functionally, control GPU mapping separately.
8. **Two-level reduction**: SIMD group reduce → threadgroup reduce → device atomic.
9. **Shared memory tiling** for matrix operations (gets you to 70% of peak).
10. **Memory coalescing**: Ensure contiguous thread access patterns (6x speedup alone).

### Tier 3 — Steal Later
11. **Triton's data layout system**: Explicit tensor layouts that drive optimization.
12. **Taichi's SNode**: Decouple data layout from computation.
13. **Multi-versioned codegen**: Different kernel variants for different input sizes (Futhark's incremental flattening).
14. **Autoscheduler** (Halide-style): Even simple heuristics beat manual tuning.

### Architecture Decision: Skip SPIR-V
Rail emits Metal directly. Don't go through SPIR-V — it adds complexity for no benefit when targeting only Apple Silicon. If you ever need Vulkan/CUDA, add SPIR-V then. For now, direct MSL emission is simpler and gives full access to Metal features (SIMD ops, threadgroup memory, Apple-specific optimizations).

### The Functional Advantage
Rail's functional core is actually perfect for GPU compilation:
- Pure functions = safe fusion (no side effects)
- Immutable data = no aliasing problems
- Known parallel primitives = predictable GPU mapping
- No GC needed if you use linear/uniqueness types for GPU buffers
- Closures must be specialized/inlined at compile time for GPU (no heap allocation)
