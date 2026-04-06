// neural_mhd_gpu.metal — GPU kernels for MLP MHD surrogate training
// Forward: matmul + bias + relu
// Backward: mse_grad, matmul_AT_B, matmul_A_BT, relu_backward
// Update: SGD

#include <metal_stdlib>
using namespace metal;

#define TILE 16

// ═══════════════════════════════════════════════════════════
// 1. TILED MATMUL: C = A[M x K] @ B[K x N]
// ═══════════════════════════════════════════════════════════

kernel void matmul_kernel(
    device const float *A [[buffer(0)]],
    device const float *B [[buffer(1)]],
    device float       *C [[buffer(2)]],
    constant uint      &M [[buffer(3)]],
    constant uint      &N [[buffer(4)]],
    constant uint      &K [[buffer(5)]],
    uint2 gid   [[thread_position_in_grid]],
    uint2 tid   [[thread_position_in_threadgroup]],
    uint2 tgid  [[threadgroup_position_in_grid]])
{
    threadgroup float tA[TILE][TILE];
    threadgroup float tB[TILE][TILE];
    uint col = gid.x, row = gid.y;
    float sum = 0.0f;
    uint nTiles = (K + TILE - 1) / TILE;
    for (uint t = 0; t < nTiles; t++) {
        uint aCol = t * TILE + tid.x;
        uint bRow = t * TILE + tid.y;
        tA[tid.y][tid.x] = (row < M && aCol < K) ? A[row * K + aCol] : 0.0f;
        tB[tid.y][tid.x] = (bRow < K && col < N) ? B[bRow * N + col] : 0.0f;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint i = 0; i < TILE; i++) sum += tA[tid.y][i] * tB[i][tid.x];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (row < M && col < N) C[row * N + col] = sum;
}

// ═══════════════════════════════════════════════════════════
// 2. MATMUL A^T @ B: C[K x N] = A^T[K x M] @ B[M x N]
//    A is stored row-major as [M x K], read transposed
// ═══════════════════════════════════════════════════════════

kernel void matmul_at_b_kernel(
    device const float *A [[buffer(0)]],
    device const float *B [[buffer(1)]],
    device float       *C [[buffer(2)]],
    constant uint      &M [[buffer(3)]],
    constant uint      &N [[buffer(4)]],
    constant uint      &K [[buffer(5)]],
    uint2 gid [[thread_position_in_grid]])
{
    // C[k, n] = sum_m A[m, k] * B[m, n]
    uint col = gid.x;  // n
    uint row = gid.y;  // k
    if (row >= K || col >= N) return;
    float sum = 0.0f;
    for (uint m = 0; m < M; m++) {
        sum += A[m * K + row] * B[m * N + col];
    }
    C[row * N + col] = sum;
}

// ═══════════════════════════════════════════════════════════
// 3. MATMUL A @ B^T: C[M x K] = A[M x N] @ B^T[N x K]
//    B is stored row-major as [K x N], read transposed
// ═══════════════════════════════════════════════════════════

kernel void matmul_a_bt_kernel(
    device const float *A [[buffer(0)]],
    device const float *B [[buffer(1)]],
    device float       *C [[buffer(2)]],
    constant uint      &M [[buffer(3)]],
    constant uint      &K [[buffer(4)]],
    constant uint      &N [[buffer(5)]],
    uint2 gid [[thread_position_in_grid]])
{
    // C[m, k] = sum_n A[m, n] * B[k, n]
    uint col = gid.x;  // k
    uint row = gid.y;  // m
    if (row >= M || col >= K) return;
    float sum = 0.0f;
    for (uint n = 0; n < N; n++) {
        sum += A[row * N + n] * B[col * N + n];
    }
    C[row * K + col] = sum;
}

// ═══════════════════════════════════════════════════════════
// 4. BIAS ADD: Z[row * N + col] += bias[col]
// ═══════════════════════════════════════════════════════════

kernel void bias_add_kernel(
    device float       *Z [[buffer(0)]],
    device const float *bias [[buffer(1)]],
    constant uint      &N [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint col = gid.x, row = gid.y;
    Z[row * N + col] += bias[col];
}

// ═══════════════════════════════════════════════════════════
// 5. RELU FORWARD: A[i] = max(0, Z[i])  (also copies Z for backward)
// ═══════════════════════════════════════════════════════════

kernel void relu_kernel(
    device const float *Z [[buffer(0)]],
    device float       *A [[buffer(1)]],
    uint id [[thread_position_in_grid]])
{
    A[id] = max(0.0f, Z[id]);
}

// ═══════════════════════════════════════════════════════════
// 6. RELU BACKWARD: dZ[i] = dA[i] * (Z[i] > 0 ? 1 : 0)
// ═══════════════════════════════════════════════════════════

kernel void relu_backward_kernel(
    device float       *dA [[buffer(0)]],
    device const float *Z  [[buffer(1)]],
    uint id [[thread_position_in_grid]])
{
    dA[id] = (Z[id] > 0.0f) ? dA[id] : 0.0f;
}

// ═══════════════════════════════════════════════════════════
// 7. MSE GRADIENT: d_out[i] = (pred[i] - target[i]) * scale
// ═══════════════════════════════════════════════════════════

kernel void mse_grad_kernel(
    device const float *pred   [[buffer(0)]],
    device const float *target [[buffer(1)]],
    device float       *d_out  [[buffer(2)]],
    constant float     &scale  [[buffer(3)]],
    uint id [[thread_position_in_grid]])
{
    d_out[id] = (pred[id] - target[id]) * scale;
}

// ═══════════════════════════════════════════════════════════
// 8. SGD UPDATE: W[i] -= lr * grad[i]
// ═══════════════════════════════════════════════════════════

kernel void sgd_kernel(
    device float       *W    [[buffer(0)]],
    device const float *grad [[buffer(1)]],
    constant float     &lr   [[buffer(2)]],
    uint id [[thread_position_in_grid]])
{
    W[id] = W[id] - lr * grad[id];
}

// ═══════════════════════════════════════════════════════════
// 9. SUM ROWS: db[j] = sum_i M[i * N + j] (bias gradient)
// ═══════════════════════════════════════════════════════════

kernel void sum_rows_kernel(
    device const float *M   [[buffer(0)]],
    device float       *db  [[buffer(1)]],
    constant uint      &rows [[buffer(2)]],
    constant uint      &cols [[buffer(3)]],
    uint col [[thread_position_in_grid]])
{
    if (col >= cols) return;
    float s = 0.0f;
    for (uint r = 0; r < rows; r++) {
        s += M[r * cols + col];
    }
    db[col] = s;
}

// ═══════════════════════════════════════════════════════════
// 10. MSE LOSS: losses[i] = (pred[i] - target[i])^2
// ═══════════════════════════════════════════════════════════

kernel void mse_loss_kernel(
    device const float *pred   [[buffer(0)]],
    device const float *target [[buffer(1)]],
    device float       *losses [[buffer(2)]],
    uint id [[thread_position_in_grid]])
{
    float e = pred[id] - target[id];
    losses[id] = e * e;
}
