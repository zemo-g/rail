// seed kernel for labrat fp16 task — matmul_bias_relu variant.
// Goal: add a matmul_bias_relu_f16 kernel below matmul_bias_relu_f32 with
// half operands/output, fp32 accumulator, half cast on store. Bias and
// ReLU semantics preserved.

#include <metal_stdlib>
using namespace metal;

#define TILE 16

kernel void matmul_bias_relu_f32(
    device const float *A    [[buffer(0)]],
    device const float *B    [[buffer(1)]],
    device const float *bias [[buffer(2)]],
    device float       *C    [[buffer(3)]],
    constant uint      &M    [[buffer(4)]],
    constant uint      &K    [[buffer(5)]],
    constant uint      &N    [[buffer(6)]],
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
        As[lid.y][lid.x] = (row < M && aCol < K) ? A[row * K + aCol] : 0.0f;
        Bs[lid.y][lid.x] = (bRow < K && col < N) ? B[bRow * N + col] : 0.0f;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint i = 0; i < TILE; i++) sum += As[lid.y][i] * Bs[i][lid.x];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (row >= M || col >= N) return;
    float biased = sum + bias[col];
    C[row * N + col] = biased > 0.0f ? biased : 0.0f;
}

kernel void matmul_bias_relu_f16(
    device const half *A    [[buffer(0)]],
    device const half *B    [[buffer(1)]],
    device const float *bias [[buffer(2)]],
    device half       *C    [[buffer(3)]],
    constant uint      &M    [[buffer(4)]],
    constant uint      &K    [[buffer(5)]],
    constant uint      &N    [[buffer(6)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 lid [[thread_position_in_threadgroup]])
{
    uint row = gid.y;
    uint col = gid.x;
    threadgroup half As[TILE][TILE];
    threadgroup half Bs[TILE][TILE];
    float sum = 0.0f;
    uint numTiles = (K + TILE - 1) / TILE;
    for (uint t = 0; t < numTiles; t++) {
        uint aCol = t * TILE + lid.x;
        uint bRow = t * TILE + lid.y;
        As[lid.y][lid.x] = (row < M && aCol < K) ? A[row * K + aCol] : half(0.0f);
        Bs[lid.y][lid.x] = (bRow < K && col < N) ? B[bRow * N + col] : half(0.0f);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint i = 0; i < TILE; i++) sum += float(As[lid.y][i]) * float(Bs[i][lid.x]);
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (row >= M || col >= N) return;
    float biased = sum + bias[col];
    C[row * N + col] = half(biased > 0.0f ? biased : 0.0f);
}
