// fp16_probe.m — fp16 vs fp32 matmul throughput probe on M1 Ultra
//
// Answers Option A decision-gate (MIXED_PRECISION_SCOPE.md): does fp16 give
// at least 1.6x matmul speedup vs fp32 on Studio's GPU? If not, Option A
// (fp16 Metal kernels only) isn't worth pursuing.
//
// Standalone — does NOT touch tensor_gpu.metal or libtensor_gpu.dylib. Shader
// source is embedded; runtime compile; measures wall time across d=512/1024/2048.
//
// Build:
//   clang -O2 -framework Metal -framework Foundation -fobjc-arc \
//       tools/metal/probes/fp16_probe.m -o tools/metal/probes/fp16_probe
//
// Run (DO NOT run concurrent with lm_v3_chunked training — both use Metal):
//   ./tools/metal/probes/fp16_probe

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <sys/time.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

static NSString *kShaderSource = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"#define TILE 16\n"
"\n"
"kernel void matmul_f32(\n"
"    device const float *A  [[buffer(0)]],\n"
"    device const float *B  [[buffer(1)]],\n"
"    device float       *C  [[buffer(2)]],\n"
"    constant uint      &M  [[buffer(3)]],\n"
"    constant uint      &K  [[buffer(4)]],\n"
"    constant uint      &N  [[buffer(5)]],\n"
"    uint2 gid [[thread_position_in_grid]],\n"
"    uint2 lid [[thread_position_in_threadgroup]])\n"
"{\n"
"    uint row = gid.y; uint col = gid.x;\n"
"    threadgroup float As[TILE][TILE];\n"
"    threadgroup float Bs[TILE][TILE];\n"
"    float sum = 0.0f;\n"
"    uint numTiles = (K + TILE - 1) / TILE;\n"
"    for (uint t = 0; t < numTiles; t++) {\n"
"        uint aCol = t * TILE + lid.x;\n"
"        uint bRow = t * TILE + lid.y;\n"
"        As[lid.y][lid.x] = (row < M && aCol < K) ? A[row * K + aCol] : 0.0f;\n"
"        Bs[lid.y][lid.x] = (bRow < K && col < N) ? B[bRow * N + col] : 0.0f;\n"
"        threadgroup_barrier(mem_flags::mem_threadgroup);\n"
"        for (uint i = 0; i < TILE; i++) sum += As[lid.y][i] * Bs[i][lid.x];\n"
"        threadgroup_barrier(mem_flags::mem_threadgroup);\n"
"    }\n"
"    if (row < M && col < N) C[row * N + col] = sum;\n"
"}\n"
"\n"
"// fp16 kernel: half-precision operands, fp32 accumulator (standard practice —\n"
"// full-fp16 reductions accumulate enough rounding error to diverge training).\n"
"kernel void matmul_f16(\n"
"    device const half  *A  [[buffer(0)]],\n"
"    device const half  *B  [[buffer(1)]],\n"
"    device half        *C  [[buffer(2)]],\n"
"    constant uint      &M  [[buffer(3)]],\n"
"    constant uint      &K  [[buffer(4)]],\n"
"    constant uint      &N  [[buffer(5)]],\n"
"    uint2 gid [[thread_position_in_grid]],\n"
"    uint2 lid [[thread_position_in_threadgroup]])\n"
"{\n"
"    uint row = gid.y; uint col = gid.x;\n"
"    threadgroup half As[TILE][TILE];\n"
"    threadgroup half Bs[TILE][TILE];\n"
"    float sum = 0.0f;\n"
"    uint numTiles = (K + TILE - 1) / TILE;\n"
"    for (uint t = 0; t < numTiles; t++) {\n"
"        uint aCol = t * TILE + lid.x;\n"
"        uint bRow = t * TILE + lid.y;\n"
"        As[lid.y][lid.x] = (row < M && aCol < K) ? A[row * K + aCol] : (half)0.0;\n"
"        Bs[lid.y][lid.x] = (bRow < K && col < N) ? B[bRow * N + col] : (half)0.0;\n"
"        threadgroup_barrier(mem_flags::mem_threadgroup);\n"
"        for (uint i = 0; i < TILE; i++) sum += (float)As[lid.y][i] * (float)Bs[i][lid.x];\n"
"        threadgroup_barrier(mem_flags::mem_threadgroup);\n"
"    }\n"
"    if (row < M && col < N) C[row * N + col] = (half)sum;\n"
"}\n";

static double ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

// IEEE 754 f32 → f16 conversion for host-side buffer fill.
static uint16_t f32_to_f16(float f) {
    union { float f; uint32_t u; } v; v.f = f;
    uint32_t sign = (v.u >> 31) & 0x1;
    int32_t  exp  = (int32_t)((v.u >> 23) & 0xFF) - 127 + 15;
    uint32_t mant = v.u & 0x7FFFFF;
    if (exp <= 0)  return (uint16_t)(sign << 15);
    if (exp >= 31) return (uint16_t)((sign << 15) | (0x1F << 10));
    return (uint16_t)((sign << 15) | ((uint32_t)exp << 10) | (mant >> 13));
}

static double bench(id<MTLCommandQueue> queue, id<MTLComputePipelineState> ps,
                    id<MTLBuffer> bA, id<MTLBuffer> bB, id<MTLBuffer> bC,
                    uint32_t sz, int runs) {
    for (int w = 0; w < 3; w++) {
        id<MTLCommandBuffer> cmd = [queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:ps];
        [enc setBuffer:bA offset:0 atIndex:0];
        [enc setBuffer:bB offset:0 atIndex:1];
        [enc setBuffer:bC offset:0 atIndex:2];
        [enc setBytes:&sz length:4 atIndex:3];
        [enc setBytes:&sz length:4 atIndex:4];
        [enc setBytes:&sz length:4 atIndex:5];
        [enc dispatchThreadgroups:MTLSizeMake((sz+15)/16, (sz+15)/16, 1)
             threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
        [enc endEncoding];
        [cmd commit]; [cmd waitUntilCompleted];
    }
    double t0 = ms();
    for (int r = 0; r < runs; r++) {
        id<MTLCommandBuffer> cmd = [queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:ps];
        [enc setBuffer:bA offset:0 atIndex:0];
        [enc setBuffer:bB offset:0 atIndex:1];
        [enc setBuffer:bC offset:0 atIndex:2];
        [enc setBytes:&sz length:4 atIndex:3];
        [enc setBytes:&sz length:4 atIndex:4];
        [enc setBytes:&sz length:4 atIndex:5];
        [enc dispatchThreadgroups:MTLSizeMake((sz+15)/16, (sz+15)/16, 1)
             threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
        [enc endEncoding];
        [cmd commit]; [cmd waitUntilCompleted];
    }
    return ms() - t0;
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr, "no Metal device\n"); return 1; }
        printf("Device: %s\n", [[device name] UTF8String]);

        NSError *err = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:kShaderSource options:nil error:&err];
        if (!lib) { fprintf(stderr, "shader compile failed: %s\n", [[err description] UTF8String]); return 1; }

        id<MTLFunction> fn32 = [lib newFunctionWithName:@"matmul_f32"];
        id<MTLFunction> fn16 = [lib newFunctionWithName:@"matmul_f16"];
        id<MTLComputePipelineState> ps32 = [device newComputePipelineStateWithFunction:fn32 error:&err];
        if (!ps32) { fprintf(stderr, "ps32: %s\n", [[err description] UTF8String]); return 1; }
        id<MTLComputePipelineState> ps16 = [device newComputePipelineStateWithFunction:fn16 error:&err];
        if (!ps16) { fprintf(stderr, "ps16: %s\n", [[err description] UTF8String]); return 1; }
        id<MTLCommandQueue> queue = [device newCommandQueue];

        uint32_t sizes[] = {512, 1024, 2048};
        int nsizes = 3;
        printf("\n  N    f32 GFLOPS   f32 ms/run   f16 GFLOPS   f16 ms/run   speedup\n");
        printf("  ---  -----------  -----------  -----------  -----------  -------\n");

        for (int si = 0; si < nsizes; si++) {
            uint32_t sz = sizes[si];
            NSUInteger count = (NSUInteger)sz * sz;
            NSUInteger b32 = count * sizeof(float);
            NSUInteger b16 = count * sizeof(uint16_t);

            id<MTLBuffer> bA32 = [device newBufferWithLength:b32 options:MTLResourceStorageModeShared];
            id<MTLBuffer> bB32 = [device newBufferWithLength:b32 options:MTLResourceStorageModeShared];
            id<MTLBuffer> bC32 = [device newBufferWithLength:b32 options:MTLResourceStorageModeShared];
            id<MTLBuffer> bA16 = [device newBufferWithLength:b16 options:MTLResourceStorageModeShared];
            id<MTLBuffer> bB16 = [device newBufferWithLength:b16 options:MTLResourceStorageModeShared];
            id<MTLBuffer> bC16 = [device newBufferWithLength:b16 options:MTLResourceStorageModeShared];

            float    *pA32 = (float*)bA32.contents,    *pB32 = (float*)bB32.contents;
            uint16_t *pA16 = (uint16_t*)bA16.contents, *pB16 = (uint16_t*)bB16.contents;
            for (NSUInteger i = 0; i < count; i++) {
                float a = ((float)rand() / (float)RAND_MAX) - 0.5f;
                float b = ((float)rand() / (float)RAND_MAX) - 0.5f;
                pA32[i] = a; pB32[i] = b;
                pA16[i] = f32_to_f16(a); pB16[i] = f32_to_f16(b);
            }

            int runs = (sz <= 1024) ? 20 : 5;
            double t32 = bench(queue, ps32, bA32, bB32, bC32, sz, runs);
            double t16 = bench(queue, ps16, bA16, bB16, bC16, sz, runs);
            double flops = 2.0 * (double)sz * (double)sz * (double)sz * (double)runs;
            double gf32 = flops / (t32 * 1e6);
            double gf16 = flops / (t16 * 1e6);
            printf("  %-4u %11.1f %12.2f %12.1f %12.2f %8.2fx\n",
                   sz, gf32, t32/runs, gf16, t16/runs, gf16/gf32);
        }
        printf("\nDecision rule (MIXED_PRECISION_SCOPE.md): Option A is worth pursuing\n");
        printf("only if fp16 speedup >= 1.6x at N=1024.\n");
    }
    return 0;
}
