// seed kernel for labrat fp16 task — matmul_blocked variant
// Goal: add a matmul_blocked_f16 kernel below matmul_blocked_f32 with
// half operands, fp32 accumulator (registers stay float), cast back to
// half on store. Same blocked algorithm.

#include <metal_stdlib>
using namespace metal;

#define BTILE 64
#define BT 16
#define BP 4

kernel void matmul_blocked_f32(
    device const float *A     [[buffer(0)]],
    device const float *B     [[buffer(1)]],
    device float       *C     [[buffer(2)]],
    constant uint      &M     [[buffer(3)]],
    constant uint      &K     [[buffer(4)]],
    constant uint      &N     [[buffer(5)]],
    uint2 gid [[threadgroup_position_in_grid]],
    uint2 lid [[thread_position_in_threadgroup]])
{
    uint block_row = gid.y * BTILE;
    uint block_col = gid.x * BTILE;
    uint row_base = block_row + lid.y * BP;
    uint col_base = block_col + lid.x * BP;

    float acc[BP][BP];
    for (uint i = 0; i < BP; i++)
        for (uint j = 0; j < BP; j++)
            acc[i][j] = 0.0f;

    threadgroup float As[BTILE][BTILE];
    threadgroup float Bs[BTILE][BTILE];

    uint numTiles = (K + BTILE - 1) / BTILE;
    for (uint t = 0; t < numTiles; t++) {
        uint tile_k = t * BTILE;
        for (uint i = 0; i < BP; i++) {
            for (uint j = 0; j < BP; j++) {
                uint ar = block_row + lid.y * BP + i;
                uint ac = tile_k + lid.x * BP + j;
                As[lid.y * BP + i][lid.x * BP + j] = (ar < M && ac < K) ? A[ar * K + ac] : 0.0f;

                uint br = tile_k + lid.y * BP + i;
                uint bc = block_col + lid.x * BP + j;
                Bs[lid.y * BP + i][lid.x * BP + j] = (br < K && bc < N) ? B[br * N + bc] : 0.0f;
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint k = 0; k < BTILE; k++) {
            float a_col[BP];
            float b_row[BP];
            for (uint i = 0; i < BP; i++) a_col[i] = As[lid.y * BP + i][k];
            for (uint j = 0; j < BP; j++) b_row[j] = Bs[k][lid.x * BP + j];
            for (uint i = 0; i < BP; i++)
                for (uint j = 0; j < BP; j++)
                    acc[i][j] += a_col[i] * b_row[j];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    for (uint i = 0; i < BP; i++) {
        for (uint j = 0; j < BP; j++) {
            uint r = row_base + i;
            uint c = col_base + j;
            if (r < M && c < N) C[r * N + c] = acc[i][j];
        }
    }
}

kernel void matmul_blocked_f16(
    device const half *A     [[buffer(0)]],
    device const half *B     [[buffer(1)]],
    device half       *C     [[buffer(2)]],
    constant uint      &M     [[buffer(3)]],
    constant uint      &K     [[buffer(4)]],
    constant uint      &N     [[buffer(5)]],
    uint2 gid [[threadgroup_position_in_grid]],
    uint2 lid [[thread_position_in_threadgroup]])
{
    uint block_row = gid.y * BTILE;
    uint block_col = gid.x * BTILE;
    uint row_base = block_row + lid.y * BP;
    uint col_base = block_col + lid.x * BP;

    float acc[BP][BP];
    for (uint i = 0; i < BP; i++)
        for (uint j = 0; j < BP; j++)
            acc[i][j] = 0.0f;

    threadgroup half As[BTILE][BTILE];
    threadgroup half Bs[BTILE][BTILE];

    uint numTiles = (K + BTILE - 1) / BTILE;
    for (uint t = 0; t < numTiles; t++) {
        uint tile_k = t * BTILE;
        for (uint i = 0; i < BP; i++) {
            for (uint j = 0; j < BP; j++) {
                uint ar = block_row + lid.y * BP + i;
                uint ac = tile_k + lid.x * BP + j;
                As[lid.y * BP + i][lid.x * BP + j] = (ar < M && ac < K) ? A[ar * K + ac] : half(0.0f);

                uint br = tile_k + lid.y * BP + i;
                uint bc = block_col + lid.x * BP + j;
                Bs[lid.y * BP + i][lid.x * BP + j] = (br < K && bc < N) ? B[br * N + bc] : half(0.0f);
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint k = 0; k < BTILE; k++) {
            half a_col[BP];
            half b_row[BP];
            for (uint i = 0; i < BP; i++) a_col[i] = As[lid.y * BP + i][k];
            for (uint j = 0; j < BP; j++) b_row[j] = Bs[k][lid.x * BP + j];
            for (uint i = 0; i < BP; i++)
                for (uint j = 0; j < BP; j++)
                    acc[i][j] += float(a_col[i]) * float(b_row[j]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    for (uint i = 0; i < BP; i++) {
        for (uint j = 0; j < BP; j++) {
            uint r = row_base + i;
            uint c = col_base + j;
            if (r < M && c < N) C[r * N + c] = half(acc[i][j]);
        }
    }
}
