# HalfTensor Session 2 — Mini lane (kernels + stdlib)

**Machine:** Mini (`ledaticempire@mini.tb`), M4 Pro.
**Branch:** `half-s2-kernels` (off `a7a9bb9` on `next`).
**Paired with:** Studio lane, `PROMPT_B_HALFTENSOR_S2_STUDIO.md`. You two run concurrently; the main session reconvenes when both finish.
**Budget:** 3-4 h.

## Why this split exists

Session 2 as originally scoped (kernels + training pipeline + bench, all in one) was ~4-5 h sequential. We're parallelizing: you build the non-matmul half kernels + stdlib wrappers, Studio builds the fwd-fp16 training variant concurrently using temporary `tensor_of_half → f64_op → half_of_tensor` cast shims. When your kernels land, Studio swaps shims for real calls. Final bench happens on Studio after both lanes merge.

**You own these files, exclusively this session:**
- `tools/metal/tensor_gpu.metal` (add half kernels)
- `tools/metal/tensor_gpu_lib.m` (add host dispatchers)
- `stdlib/tensor.rail` (add Rail-side wrappers in the HalfTensor block around line 477-525)
- `tools/test/*_half_smoke.rail` (new per-kernel smokes)

**Do NOT touch** `tools/train/lm_v3_chunked_half.rail` — that's Studio's file this session. If it doesn't exist yet that's fine, don't create it.

## Context from Session 1 (already merged on `next`)

`HALFTENSOR_SESSION1_RESULT.md` landed:
- `matmul_half` ADT + zero-cast dispatcher at **4.77× at 1024²**, byte-identical accuracy to cast path.
- `HalfTensor` type, `half_tensor_new`, `half_of_tensor`, `tensor_of_half` already in `stdlib/tensor.rail:477-525`.
- `tgl_f64_to_half`, `tgl_half_to_f64`, `tgl_matmul_half_host` already in `tensor_gpu_lib.m`.
- Dylib is gitignored; rebuild locally after any `tensor_gpu_lib.m` change (command in the checklist below).

## What you build

Four non-matmul half kernels + host dispatchers + Rail wrappers, each with a numerical smoke against its f64 counterpart. Log-sum-exp reformulation for softmax (fp16 overflow risk).

### Ordering (ship each as its own commit; rebase public notes after each)

1. **`tensor_add_half`** (30 min) — simplest, elementwise, no numerics risk. Validates the pattern.
2. **`tensor_scale_half`** (30 min) — scalar × HalfTensor, same pattern as add but broadcast scalar.
3. **`tensor_transpose_half`** (30 min) — shape permutation only, still just memcpy at the half level.
4. **`tensor_softmax_half`** (60-90 min) — needs log-sum-exp so `exp` doesn't overflow fp16's ~65,504 ceiling. This is the single biggest risk item. Budget a full hour.

Total: ~3 h kernel work + 30 min smoke wiring + 30 min for the dylib rebuild + commit loop = 3.5-4 h.

### Kernel contract (one per op)

Each kernel follows this pattern — read `tgl_matmul_half_host` as the template:

```c
// tools/metal/tensor_gpu_lib.m
int tgl_add_half_host(const uint16_t *A, const uint16_t *B, uint16_t *C, int n);
int tgl_scale_half_host(const uint16_t *A, double s, uint16_t *C, int n);
int tgl_transpose_half_host(const uint16_t *A, uint16_t *C, int M, int N);
int tgl_softmax_half_host(const uint16_t *A, uint16_t *C, int rows, int cols);  // along last axis
```

- Inputs are already packed halfs (Rail-side pointer is `double*` after the length header at offset 0; reinterpret to `uint16_t*` inside the C boundary — same trick Session 1 used).
- Outputs are packed halfs, no cast on exit.
- For softmax, compute `max` per row in fp32 accumulator, subtract, sum `exp` in fp32, divide, cast back to fp16 at store. This is the log-sum-exp escape hatch — accumulators in fp32 on the GPU, storage in fp16.

### Rail-side wrappers (stdlib/tensor.rail, next to `matmul_half`)

```rail
foreign tgl_add_half_host a b c n -> int
foreign tgl_scale_half_host a s c n -> int
foreign tgl_transpose_half_host a c m n -> int
foreign tgl_softmax_half_host a c rows cols -> int

add_half a b = match a | HalfTensor a_data a_shape a_strides -> match b
  | HalfTensor b_data _ _ ->
    let n = shape_size a_shape
    let c_data = float_arr_new (n / 4 + 1) 0.0
    let _ = tgl_add_half_host a_data b_data c_data n
    HalfTensor c_data a_shape a_strides

-- scale_half, transpose_half, softmax_half follow the same pattern
```

Arity ≤ 10; `shape_size` may already exist — grep before adding.

### Per-kernel smoke (new test file each)

`tools/test/{add,scale,transpose,softmax}_half_smoke.rail`. For each:

1. Build a small f64 Tensor with a deterministic seed (use existing `tent` fill pattern from Session 1).
2. Run the f64 reference op, record output.
3. Cast input to HalfTensor, run your half op, cast output back to f64.
4. Report max-abs-diff. Acceptance: **< 1e-3 at 128² shapes, < 1e-2 at seq=1024 shapes**. Softmax output max-abs-diff may need to be measured relative to its own scale (outputs in [0,1]); a 1e-3 absolute on softmax is already borderline — if you see worse, that's the log-sum-exp reformulation biting.

Each smoke is a single commit with the kernel it validates; don't batch.

## Commits (target: 8)

```
metal: tensor_add_half kernel + tgl_add_half_host dispatcher
stdlib: add_half wrapper on HalfTensor
test: add_half numerical equivalence smoke
metal: tensor_scale_half + tgl_scale_half_host
stdlib: scale_half wrapper
test: scale_half smoke
metal: tensor_transpose_half + tgl_transpose_half_host
stdlib: transpose_half wrapper
test: transpose_half smoke
metal: tensor_softmax_half (log-sum-exp) + tgl_softmax_half_host
stdlib: softmax_half wrapper
test: softmax_half smoke
```

(That's 12 commits if you split aggressively; 8 if you fuse metal+dispatcher+stdlib per op.) Either is fine; one logical unit per commit.

## After each dylib-touching commit

```bash
cd tools/metal && clang -shared -fobjc-arc \
  -framework Metal -framework Foundation \
  -install_name /Users/ledaticempire/projects/rail/tools/metal/libtensor_gpu.dylib \
  tensor_gpu_lib.m -o libtensor_gpu.dylib
```

Do **not** commit the dylib (gitignored) or the `-install_name` override.

## Done criteria

- All four smokes pass at max-abs-diff < 1e-2 at seq=1024 shapes.
- `./rail_native test` still 137/137 on Mini.
- Branch `half-s2-kernels` pushed to origin. Tell the main session via report back.

## Report back with

1. Per-kernel: max-abs-diff at 128² and 1024-row shapes.
2. Softmax: confirm log-sum-exp kept outputs in [0,1] with no NaN at seq=1024.
3. Any kernel that failed — what broke, what you tried, where you stopped.
4. Commits shipped on `half-s2-kernels`: shortlog.

If `tensor_softmax_half` proves harder than budgeted, ship the other three and flag softmax as a Session 3 item — Studio's pipeline can keep a cast-shim softmax in the meantime and still demonstrate most of the fp16 wall-time gain.

## Gotchas (re-stated)

- `foreign X -> float` with int args → garbage. Keep returns `-> int`.
- `str_replace` replaces ALL occurrences.
- Helper arity ≤ 10.
- Each new foreign decl needs its `-> int` return type; accumulate dylib rebuilds.
- `/tmp/rail_out` is per-machine; Mini won't collide with Studio.

## What happens next

When you finish, the main session reconvenes with Studio's result and yours, writes `HALFTENSOR_SESSION2_RESULT.md`, and designs Session 3 (the Phase 5 composed run at d=256).
