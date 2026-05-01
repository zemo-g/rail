# Session B — Round 3 prompt: the "f16 everywhere" reframing

You closed Phase 4a (leak fix + diagnostics) and Phase 4b (fp16 wiring + wall-time bench). Both shipped, both measured, both had honest ceilings. Your Phase 4b doc nailed the root cause of the 1.07× ceiling in one sentence: **"Host-side double↔half cast per matmul eats a non-trivial fraction of the kernel win."**

The obvious next move is follow-up #1 from your own doc: a persistent fp16 tensor type. That's the safe, correct move and I'd accept it.

But you asked for out-of-the-box. Here is what I actually want you to consider — a bigger frame that, if it works, changes what "Rail-on-Rail" even means.

## The reframe

Right now fp16 is plumbing: we have f64 tensors that *temporarily* visit the GPU in half precision. The cast cost is the bottleneck, so the reflex is "keep tensors in half longer."

Flip it. **Make f16 the native representation of the model, and f64 the temporary.**

Weights live in fp16 on the host. Activations live in fp16 on the host. The forward pass is fp16 end-to-end. Backward *only* promotes to f64 for grad-weight accumulation and Adam state (per Phase 4b's numerical finding — those are the precision-critical operations). Everything else is half.

This isn't "optimize the cast overhead." This is "stop paying the cast at all, except where we literally cannot."

If it works:
- Model memory halves. d=128 × 4-block weight memory goes from ~50 MB to ~25 MB — now we can try d=256 in the same RSS budget.
- Backward stays f64 where it matters, so the nat-of-regression Phase 4b saw doesn't happen.
- `bench_railnative` becomes a more honest measurement: the inference path is fp16, which is how anyone would actually deploy a Rail-native LM.
- Phase 4c (model card) gets a real story: "the world's first transformer whose training loop, weights, and inference path are all verified by a Rail compiler written in Rail, running in half precision."

## What you'd actually build

### Step 1 — `HalfTensor` ADT + stdlib primitives (2 h)

In `stdlib/tensor.rail`:

```rail
type HalfTensor = | HalfTensor half_data shape strides
```

`half_data` is a `float_arr` where each *pair* of 32-bit slots holds four fp16 values (or use a dedicated `uint16_arr` type if you want to add one to the runtime — check `stdlib/tensor.rail`'s existing array primitives first). Simplest path: reuse `float_arr`, pack two halfs per double slot, unpack at the dylib boundary. Dylib already does the packing/unpacking today for the `_f16` dispatchers — extend those primitives to accept half-packed input.

Primitives:
- `half_tensor_new shape` — allocates half-packed storage
- `half_of_tensor t` — f64 → fp16 host-side, returns new HalfTensor
- `tensor_of_half h` — fp16 → f64 host-side, returns new Tensor (only used at measurement/checkpoint boundaries, not inside the hot path)

### Step 2 — Matmul that takes HalfTensor inputs directly (1 h)

New dispatcher variants in `tools/metal/tensor_gpu_lib.m`:

```c
int tgl_matmul_half_host(const uint16_t *A, const uint16_t *B, uint16_t *C, int M, int K, int N);
```

No cast on entry, no cast on exit. A is already packed halfs, output stays packed halfs. This is what the kernel *actually* wants — we've been paying the cast to satisfy the Rail-side `float_arr` type.

Rail-side wrapper in `stdlib/tensor.rail`:
- `matmul_half a b` — both HalfTensor, output HalfTensor

### Step 3 — Forward-pass-in-fp16 training variant (2 h)

Clone `tools/train/lm_v3_chunked.rail` → `lm_v3_chunked_half.rail`:

- Weights initialized as HalfTensor from the start (cast once at init time).
- `m_block_fwd` operates entirely on HalfTensors. RMSNorm, RoPE, softmax, hadamard — all the non-matmul ops need half variants in `tools/metal/tensor_gpu.metal` (this is the real work — probably 3-4 new half kernels, pattern-match from the f64 versions).
- `m_block_bwd` casts inputs back to f64 at entry (for numerical stability), computes grad-weights in f64, accumulates in f64 Adam state, then casts the *updated weight* back to fp16 at the end of the adam step.
- dx propagating backward stays fp16 — it's the grad-*weights* that need f64, not the dx.

The critical insight: f64 visits the hot path *briefly*, during the part where fp16 provably loses signal (grad-weight accumulation per your Phase 4b finding). Everywhere else is half.

### Step 4 — Convergence check + wall-time bench (1 h)

- 500 steps at seq=1024, d=128, 2-block. Multi-chunk eval at step 0, 100, 200, 300, 400.
- Acceptance: eval trajectory within 0.2 of f64 baseline at each checkpoint. Per Phase 4b, your fwd-only variant already tracked within 0.1-0.2 — this should be at least as good because the weights-stay-in-fp16 setup keeps the same numerical invariants.
- Wall-time at 10 steps, seq=1024, d=128, 2-block, eval disabled. Target: ≥1.4× vs f64 baseline. Reasoning: your 1.07× had cast overhead on every matmul. Eliminating the cast on forward (9 matmuls per block, 2 blocks, 10 steps = 180 casts per run, each casting M·K + K·N doubles) should recover most of the gap between 1.07× and the 1.17× forward-only ceiling, and push beyond — because some non-matmul ops (RoPE, softmax) also get faster on half data.

### Step 5 — Memory claim, validated (30 min)

This is the real prize. A d=128 × 2-block model's host-side weight memory halves. Verify with `/usr/bin/time -l peak memory footprint`:
- Baseline f64: ~460 MB
- Target fp16: if weight memory is a meaningful fraction, expect peak in the 300-400 MB range.

If peak RSS drops by ≥50 MB at 2-block, extrapolate to 4-block (A's current experiment): the peak would drop proportionally, and **A could then try d=256 × 4-block in the same RSS budget**. That's a capacity-doubling we haven't been able to do before.

## Stretch — the real out-of-the-box idea

If Steps 1–5 land cleanly and A's 3000-step result is good, propose a follow-on to the user: **retrain the self-training corpus in fp16**. Everything downstream of training (bench_railnative, harvest, retrain) becomes 2× cheaper. The private flywheel repo's overnight budget doubles. That's the compounding lever.

If instead Steps 1–5 show that half-everywhere isn't numerically viable even with f64 grad-weight escape hatches, you've ruled out a major capacity path with a tight experiment — and the HalfTensor infrastructure is still useful for inference-only deployment later (bench_railnative model card).

Either outcome is a win. The failure mode is "we learned something." The success mode is "capacity doubled."

## Scope discipline

This is at least 7 hours of work if everything goes well. Don't try to land it in one session. Structure:

- **Session 1 (this one):** Steps 1–2 + a tiny smoke. Prove `matmul_half` with HalfTensors both sides is numerically close to matmul_f64 with a round-trip, and runs without cast overhead. Commit as `stdlib: HalfTensor ADT + matmul_half` and `metal: tgl_matmul_half_host zero-cast dispatcher`. Stop there and report.
- **Session 2 (later):** Steps 3–5 in a second session, armed with the smoke's numbers.

Don't ship a half-finished `lm_v3_chunked_half.rail`. Either it converges or it's rolled back.

## Do NOT touch

- `tools/train/lm_v3_chunked.rail` — A's 2-block baseline, leave at current state.
- `tools/train/lm_v3_chunked_4block.rail` — A's active 3000-step experiment. A's run (PID 14545 on Studio) may still be alive when you start; check before running any GPU bench.
- `tools/train/lm_v3_chunked_fp16.rail` — your own Phase 4b artifact, also leave alone.

New file: `tools/train/lm_v3_chunked_half.rail` (Session 2 only, not this session).

## Constraints to respect

- Rail-side helper arity ≤10 params.
- `str_replace` replaces ALL occurrences — grep FIND targets first when cloning-and-swapping.
- `float >=` codegen segfault — route via ×1000 int compare.
- `cp rail_native <x>` invalidates codesign — re-sign after.
- Studio and Mini both need the rebuilt dylib (`clang -shared ...` per the build line in `tensor_gpu_lib.m`, with `-install_name` override for whichever machine you're on — do NOT commit the install_name patch).

## Commit granularity (Session 1 only)

- `stdlib: HalfTensor ADT + host-side fp16 pack/unpack`
- `metal: tgl_matmul_half_host — zero-cast fp16 matmul dispatcher`
- `test: matmul_half numerical equivalence smoke`

Three commits, stop, report back with:
1. Max-abs diff between `matmul_half` and `matmul_f64` (should be ~1e-3, same order as the existing fp16 smoke).
2. Wall-time of `matmul_half` vs `tgl_matmul_f16` on a 1024×1024 matmul microbench (should show the cast overhead saving).

## The key line

**Don't optimize the cast. Eliminate the language's need for it.**

If this works, Rail-on-Rail graduates from "a training experiment" to "a transformer whose native precision is fp16, verified end-to-end by a Rail compiler written in Rail." That's the phrase the Phase 4c model card gets to use.

Ship Session 1. Report numbers. We'll decide Session 2 scope after.
