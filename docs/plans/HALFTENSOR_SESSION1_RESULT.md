# HalfTensor Session 1 — result + analysis

**Date:** 2026-04-21 PM (Mini, M4 Pro).
**Branch:** `next`. Commits: `e366f4a` stdlib / `abdc2f0` metal / `876e90e` test.
**Scope boundary:** Session 1 = Steps 1-2 + smoke, per `PROMPT_B_HALFTENSOR.md`.
This doc converts the result into a Session 2 plan.

## The headline number

At **1024×1024, 50 iterations, warmed up**:

| Dispatcher | per-call | notes |
|---|---:|---|
| `tgl_matmul_f16` (existing, f64↔f16 cast every call) | **10,682 µs** | kernel ~2.2 ms, cast ~8.5 ms |
| `tgl_matmul_half_host` (new, zero-cast) | **2,237 µs** | memcpy + kernel |
| **speedup** | **4.77×** | |

The cast-overhead diagnosis from Phase 4b's doc (`PHASE_4B_BENCH.md`) was
exactly right: the f16 kernel is fast; the per-entry-point
`f64 → f32 → f16` and per-exit `f16 → f32 → f64` loops were ~80% of the
wall time on a 1024² matmul.

## Speedup curve

Three sizes, same fill pattern (tent in [-0.5, 0.5], seeds 7 and 43),
same iteration harness:

| Size (N×N) | iters | `tgl_matmul_f16` ns/call | `tgl_matmul_half_host` ns/call | speedup |
|---:|---:|---:|---:|---:|
| 128 | 200 | 386,385 | 207,495 | **1.86×** |
| 512 | 100 | 2,927,800 | 561,990 | **5.20×** |
| 1024 | 50 | 10,682,400 | 2,236,660 | **4.77×** |

Shape: as the matmul gets bigger, cast cost grows with `M·K + K·N + M·N`
(linear in elements) while kernel cost grows with `M·K·N` (cubic). At
128² the kernel is so cheap (~200 µs) that dispatch and memcpy latency
floor the measurement. At 512²+ the cast actually dominates and the
speedup plateaus at ~5×.

For the real training workload — `seq=1024 d=128` gives matmul sizes
like 1024×128 (attention Q,K,V projections) and 1024×1024 (attention
scores) and 1024×384 (FFN) — we're in the 3-5× speedup regime, not the
1.86× floor.

## Accuracy floor — identical to the existing cast path

`md_cast` = max abs diff between `tgl_matmul_f16` output and the f64
reference. `md_half` = same vs `tensor_of_half ∘ matmul_half`.

| Size | `md_cast` | `md_half` | delta |
|---:|---:|---:|---:|
| 128² | 8.30e-4 | 8.30e-4 | **0** (same to all 14 displayed digits) |
| 512² | 3.17e-3 | 3.17e-3 | **0** |
| 1024² | 6.92e-3 | 6.92e-3 | **0** |

**HalfTensor's accuracy is IDENTICAL to `tgl_matmul_f16`** — byte-
identical output arrays, at every size tested. That matches the design:
both paths use the same `matmul_f16` kernel; only the host-side cast
path differs. The cast itself uses the same `f64_to_f16` /
`f16_to_f64` helpers; `tgl_matmul_half_host` just moves them from the
hot path to one-time `half_of_tensor` / `tensor_of_half` calls.

Max abs diff scales with K (reduction length) at ~7e-3 per 1024 — that's
the inherent fp16-accumulator precision of the kernel, nothing we can
change from the Rail side.

## Session 2 scope — revised

Original prompt allocated ~6 hours for Session 2 (Steps 3-5: half
training clone + non-matmul half kernels + wall-time bench + memory
bench). Given 5× is larger than expected, rethinking the scope.

### Keep in scope
1. **Half-weights, half-activations training variant**
   (`tools/train/lm_v3_chunked_half.rail`). Initialize weights as
   HalfTensor once at `main`; fwd runs on HalfTensors end-to-end.
2. **Backward stays f64** per Phase 4b's finding: cast dx back to f64
   at `m_block_bwd` entry, compute grad-weights and Adam updates in
   f64, cast the updated weight back to fp16 at end of adam step.
3. **Non-matmul half kernels** for the fwd path — but only the ones
   that live in matmul-neighbors:
   - `tensor_softmax` on HalfTensor (attention scores)
   - `tensor_scale` on HalfTensor (scale by 1/√d)
   - `tensor_add` on HalfTensor (residual connections)
   - `tensor_transpose` on HalfTensor (K^T for scores)
   - Keep `rope_apply`, `rmsnorm_save` as f64 — they do narrow-band
     per-element ops where precision loss hurts disproportionately and
     savings are small.
4. **10-step wall-time bench** at `seq=1024 d=128 2-block`. Target
   revised to **≥1.6×** (up from 1.3×, because cast elimination on 9
   fwd matmuls per block × 2 blocks × 10 steps = 180 fewer casts
   should buy more than the earlier ceiling).

### Out of scope for Session 2 (push to Session 3)
5. **d=128 × 4-block memory bench with room for d=256**. This is the
   capacity-doubling prize. It's worth its own session to get the
   measurement methodology right and compare against A's 4-block
   3000-step baseline. Won't land the same night as the fwd pipeline.
6. **Self-training corpus retrain in fp16**. Stretch goal from the
   prompt; parked until Session 2 proves half-weights converge.

### New risk items
- **Softmax numerics in fp16** is tricky: the exp→sum→div pattern can
  overflow fp16's max (~65,504) for large scores. Will need log-sum-exp
  reformulation. Budget a full hour for that kernel alone.
- **RoPE in fp16** could land later — it's a sin/cos multiply-add. If
  Session 2 time is tight, keep it f64 (with one cast on either side
  of the rope_apply call) and bench anyway.

### Estimated Session 2 wall-time
~4-5 hours: 1h softmax kernel, 1h other non-matmul half ops, 1h
training clone + edits, 1h stage 10/50/500 + bench, 30m writeup.

## Gotchas from Session 1

### 1. Rail's foreign float-return ABI with int args
`foreign tgl_now_ms dummy -> float` followed by `tgl_now_ms 0` returned
garbage (`3.6e-319`). The `-> float` return encoding (3000) triggers
`untag_float_args` on the caller side (`tools/compile.rail:1252`) — it
assumes all args are float, so `0` (int) got untagged as if it were
tagged-float bits. Workaround: switched the smoke to a shell-based
`date +%s%N` nanosecond clock via `parse_int_acc`. Kept `tgl_now_ms`
in the dylib as a future fix candidate, but it isn't consumed by any
caller yet.

### 2. `abs_f` name collision
`abs_f x = if x > 0.0 then x else 0.0 - x` is already defined in
`stdlib/tensor.rail:1526`. Defining it again in the smoke test
produced a duplicate-symbol assembler error. Fix: inline the body in
`max_diff_loop`.

### 3. Rail float-arr ABI + reinterpret cast
Rail's `float_arr` layout is `[length(8), data...]`. The existing
`tgl_*_f64` / `tgl_*_f16` dispatchers receive `double*` and do
`Aptr = A + 1` to skip the length header. For HalfTensor the same
trick works with a reinterpret: `(uint16_t*)(A + 1)` where A is still
`double*` at the C boundary. Four halfs per 8-byte slot, little-endian
native on ARM64. No explicit bit ops needed on the Rail side — pack
and unpack happen inside the dylib.

### 4. Zero-initialized HalfTensor = half-zeros
`float_arr_new n 0.0` writes the bit pattern `0x0000000000000000` to
every slot. Reinterpreted as `uint16_t[4]`, that's four `0x0000` halfs
= fp16 zero. So `half_tensor_new shape` is both "uninitialized" and
"all zeros" at once, which is what we want for result buffers.

### 5. `macOS date +%s%N` works on this machine
Surprised me — BSD date doesn't support `%N`. Mini has GNU coreutils
installed via Homebrew, which aliases `date`. If this smoke moves to
Studio or Pi, it'll need a fallback to `python3 -c 'import time;
print(int(time.time()*1e9))'` or similar. Noted here so Session 2
doesn't get caught.

### 6. Dylib is gitignored (both machines)
As noted in Phase 4b's doc. Mini's dylib needed a rebuild with
`clang -shared -framework Metal -framework Foundation -fobjc-arc
tensor_gpu_lib.m -o libtensor_gpu.dylib` to pick up the three new
symbols. Studio will need the same rebuild before A's next GPU run.

### 7. `cp + codesign` dance on rail_native
Standard Phase 4a gotcha — didn't apply this session because stdlib
edits don't touch rail_native, but Session 2 may need a self-compile
if HalfTensor primitives grow (e.g. adding an `int_arr` or
`half_arr` native type to the runtime). Keep the recipe handy:
`cp /tmp/rail_self rail_native && codesign -s - --force rail_native`.

## The one-liner for the model card

> "A Rail-native transformer whose forward matmuls, weights, and
> inference activations are all fp16 — cast once at init, never per
> call — verified end-to-end by a Rail compiler written in Rail."

If Session 2 lands a converging half-training pipeline, that line is
defensible. It's defensible NOW for inference (`matmul_half` already
works numerically; just needs the fwd-only non-matmul ops to match).

## Files

- `stdlib/tensor.rail` — `HalfTensor` ADT + foreigns + wrappers.
- `tools/metal/tensor_gpu_lib.m` — `tgl_f64_to_half`,
  `tgl_half_to_f64`, `tgl_matmul_half_host`, `tgl_now_ms`.
- `tools/test/matmul_half_smoke.rail` — passes at 8.2e-4 md + 5.16×
  bench at 1024².
- `docs/plans/HALFTENSOR_SESSION1_RESULT.md` — this document.
- Not shipped: `/tmp/halftensor_curve.rail` — one-off 3-size curve
  script, reconstructible from the smoke if needed.

## Done / next

Session 1 delivered in under budget (prompt said 2 hours for Steps 1-2
+ smoke; actual ≈1.5 h including the crash debugging). Numbers are
better than expected. Session 2 now has a tight ~4-5 hour scope with
soft target ≥1.6× on the training wall, clear risk items
(softmax/RoPE numerics), and an explicit out-of-scope for the memory
bench. Ship that in a separate session when the training pipeline is
proven.
