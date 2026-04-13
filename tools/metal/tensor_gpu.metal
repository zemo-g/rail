// tensor_gpu.metal — Metal compute kernels for Rail tensor operations
// These kernels accelerate stdlib/tensor.rail operations on GPU.
// Supports: matmul, element-wise (add, mul, relu, exp, tanh), softmax, reduce
//
// All operations use float32 for GPU efficiency.
// Rail's native f64 tensors are converted on dispatch.

#include <metal_stdlib>
using namespace metal;

// ═══════════════════════════════════════════════════════════
// MATRIX MULTIPLY: C[M×N] = A[M×K] × B[K×N]
// Tiled for shared memory efficiency
// ═══════════════════════════════════════════════════════════

#define TILE 16

kernel void matmul(
    device const float *A     [[buffer(0)]],
    device const float *B     [[buffer(1)]],
    device float       *C     [[buffer(2)]],
    constant uint      &M     [[buffer(3)]],
    constant uint      &K     [[buffer(4)]],
    constant uint      &N     [[buffer(5)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 lid [[thread_position_in_threadgroup]])
{
    uint row = gid.y;
    uint col = gid.x;

    threadgroup float As[TILE][TILE];
    threadgroup float Bs[TILE][TILE];

    float sum = 0.0f;
    uint numTiles = (K + TILE - 1) / TILE;

    for (uint t = 0; t < numTiles; t++) {
        uint aCol = t * TILE + lid.x;
        uint bRow = t * TILE + lid.y;

        // All threads load (even out-of-bounds ones) to avoid shared memory races
        As[lid.y][lid.x] = (row < M && aCol < K) ? A[row * K + aCol] : 0.0f;
        Bs[lid.y][lid.x] = (bRow < K && col < N) ? B[bRow * N + col] : 0.0f;

        threadgroup_barrier(mem_flags::mem_threadgroup);

        for (uint i = 0; i < TILE; i++) {
            sum += As[lid.y][i] * Bs[i][lid.x];
        }

        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (row >= M || col >= N) return;
    C[row * N + col] = sum;
}

// ═══════════════════════════════════════════════════════════
// ELEMENT-WISE OPERATIONS
// ═══════════════════════════════════════════════════════════

kernel void tensor_add(
    device const float *A  [[buffer(0)]],
    device const float *B  [[buffer(1)]],
    device float       *C  [[buffer(2)]],
    constant uint      &n  [[buffer(3)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= n) return;
    C[gid] = A[gid] + B[gid];
}

kernel void tensor_mul(
    device const float *A  [[buffer(0)]],
    device const float *B  [[buffer(1)]],
    device float       *C  [[buffer(2)]],
    constant uint      &n  [[buffer(3)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= n) return;
    C[gid] = A[gid] * B[gid];
}

kernel void tensor_scale(
    device const float *A      [[buffer(0)]],
    device float       *C      [[buffer(1)]],
    constant float     &scalar [[buffer(2)]],
    constant uint      &n      [[buffer(3)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= n) return;
    C[gid] = A[gid] * scalar;
}

kernel void tensor_add_scalar(
    device const float *A      [[buffer(0)]],
    device float       *C      [[buffer(1)]],
    constant float     &scalar [[buffer(2)]],
    constant uint      &n      [[buffer(3)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= n) return;
    C[gid] = A[gid] + scalar;
}

// ═══════════════════════════════════════════════════════════
// ACTIVATION FUNCTIONS
// ═══════════════════════════════════════════════════════════

kernel void tensor_relu(
    device const float *A  [[buffer(0)]],
    device float       *C  [[buffer(1)]],
    constant uint      &n  [[buffer(2)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= n) return;
    C[gid] = max(A[gid], 0.0f);
}

kernel void tensor_relu_backward(
    device const float *A     [[buffer(0)]],
    device const float *grad  [[buffer(1)]],
    device float       *out   [[buffer(2)]],
    constant uint      &n     [[buffer(3)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= n) return;
    out[gid] = (A[gid] > 0.0f) ? grad[gid] : 0.0f;
}

kernel void tensor_tanh_fwd(
    device const float *A  [[buffer(0)]],
    device float       *C  [[buffer(1)]],
    constant uint      &n  [[buffer(2)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= n) return;
    C[gid] = tanh(A[gid]);
}

kernel void tensor_exp(
    device const float *A  [[buffer(0)]],
    device float       *C  [[buffer(1)]],
    constant uint      &n  [[buffer(2)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= n) return;
    C[gid] = exp(A[gid]);
}

kernel void tensor_sigmoid(
    device const float *A  [[buffer(0)]],
    device float       *C  [[buffer(1)]],
    constant uint      &n  [[buffer(2)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= n) return;
    C[gid] = 1.0f / (1.0f + exp(-A[gid]));
}

// ═══════════════════════════════════════════════════════════
// SOFTMAX (two-pass: max-subtract + exp-normalize)
// ═══════════════════════════════════════════════════════════

// Pass 1: find max per row (for numerical stability)
kernel void softmax_max(
    device const float *A       [[buffer(0)]],
    device float       *maxvals [[buffer(1)]],
    constant uint      &rows    [[buffer(2)]],
    constant uint      &cols    [[buffer(3)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= rows) return;
    float mx = A[gid * cols];
    for (uint j = 1; j < cols; j++) {
        mx = max(mx, A[gid * cols + j]);
    }
    maxvals[gid] = mx;
}

// Pass 2: exp(x - max) and sum
kernel void softmax_exp_sum(
    device const float *A       [[buffer(0)]],
    device float       *expA    [[buffer(1)]],
    device float       *sums    [[buffer(2)]],
    device const float *maxvals [[buffer(3)]],
    constant uint      &rows    [[buffer(4)]],
    constant uint      &cols    [[buffer(5)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= rows) return;
    float mx = maxvals[gid];
    float s = 0.0f;
    for (uint j = 0; j < cols; j++) {
        float e = exp(A[gid * cols + j] - mx);
        expA[gid * cols + j] = e;
        s += e;
    }
    sums[gid] = s;
}

// Pass 3: normalize
kernel void softmax_normalize(
    device float       *expA [[buffer(0)]],
    device const float *sums [[buffer(1)]],
    constant uint      &rows [[buffer(2)]],
    constant uint      &cols [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.y >= rows || gid.x >= cols) return;
    expA[gid.y * cols + gid.x] /= max(sums[gid.y], 1e-8f);
}

// ═══════════════════════════════════════════════════════════
// REDUCTIONS
// ═══════════════════════════════════════════════════════════

kernel void tensor_sum(
    device const float *A    [[buffer(0)]],
    device float       *out  [[buffer(1)]],
    constant uint      &n    [[buffer(2)]],
    uint gid [[thread_position_in_grid]],
    uint lid [[thread_position_in_threadgroup]],
    uint tgSize [[threads_per_threadgroup]])
{
    // Partial sums in threadgroup
    threadgroup float shared[256];
    float val = (gid < n) ? A[gid] : 0.0f;
    shared[lid] = val;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Reduce within threadgroup
    for (uint s = tgSize / 2; s > 0; s >>= 1) {
        if (lid < s) shared[lid] += shared[lid + s];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (lid == 0) {
        // Atomic add to output (approximate for f32)
        // For exact results, use multi-pass reduction
        out[0] += shared[0]; // NOTE: race condition if multiple threadgroups
    }
}

// ═══════════════════════════════════════════════════════════
// SGD UPDATE: w -= lr * grad
// ═══════════════════════════════════════════════════════════

kernel void sgd_update(
    device float       *weights [[buffer(0)]],
    device const float *grads   [[buffer(1)]],
    constant float     &lr      [[buffer(2)]],
    constant uint      &n       [[buffer(3)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= n) return;
    weights[gid] -= lr * grads[gid];
}

// ═══════════════════════════════════════════════════════════
// CROSS-ENTROPY LOSS
// ═══════════════════════════════════════════════════════════

kernel void cross_entropy(
    device const float *probs   [[buffer(0)]],
    device const uint  *targets [[buffer(1)]],
    device float       *losses  [[buffer(2)]],
    constant uint      &batch   [[buffer(3)]],
    constant uint      &vocab   [[buffer(4)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= batch) return;
    uint target = targets[gid];
    float p = max(probs[gid * vocab + target], 1e-8f);
    losses[gid] = -log(p);
}

// ═══════════════════════════════════════════════════════════
// TRANSPOSE: B[N×M] = A[M×N]^T
// ═══════════════════════════════════════════════════════════

kernel void tensor_transpose(
    device const float *A  [[buffer(0)]],
    device float       *B  [[buffer(1)]],
    constant uint      &M  [[buffer(2)]],
    constant uint      &N  [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.y >= M || gid.x >= N) return;
    B[gid.x * M + gid.y] = A[gid.y * N + gid.x];
}
