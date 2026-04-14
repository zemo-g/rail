// bench_matmul.m — compare tiled vs blocked matmul kernels
// Build: clang -framework Metal -framework Foundation -fobjc-arc bench_matmul.m -o bench_matmul
// Run:   ./bench_matmul

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <sys/time.h>
#include <stdio.h>
#include <stdlib.h>

static double ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSError *err = nil;
        id<MTLLibrary> lib = [device newLibraryWithURL:[NSURL fileURLWithPath:@"/tmp/tensor_gpu.metallib"] error:&err];
        if (!lib) { fprintf(stderr, "%s\n", [[err description] UTF8String]); return 1; }
        id<MTLComputePipelineState> basic = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"matmul"] error:&err];
        id<MTLComputePipelineState> blocked = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"matmul_blocked"] error:&err];
        id<MTLCommandQueue> queue = [device newCommandQueue];

        int sizes[] = {128, 256, 512, 1024};
        for (int si = 0; si < 4; si++) {
            uint32_t sz = sizes[si];
            NSUInteger bytes = sz * sz * sizeof(float);
            id<MTLBuffer> bA = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
            id<MTLBuffer> bB = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
            id<MTLBuffer> bC1 = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
            id<MTLBuffer> bC2 = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
            float *pA = (float*)bA.contents, *pB = (float*)bB.contents;
            for (uint32_t i = 0; i < sz*sz; i++) { pA[i] = (float)rand()/RAND_MAX; pB[i] = (float)rand()/RAND_MAX; }

            int runs = sz <= 512 ? 50 : 10;

            // Basic kernel
            for (int w = 0; w < 2; w++) { // warmup
                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
                [enc setComputePipelineState:basic];
                [enc setBuffer:bA offset:0 atIndex:0];
                [enc setBuffer:bB offset:0 atIndex:1];
                [enc setBuffer:bC1 offset:0 atIndex:2];
                [enc setBytes:&sz length:4 atIndex:3];
                [enc setBytes:&sz length:4 atIndex:4];
                [enc setBytes:&sz length:4 atIndex:5];
                [enc dispatchThreadgroups:MTLSizeMake((sz+15)/16, (sz+15)/16, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
                [enc endEncoding];
                [cmd commit]; [cmd waitUntilCompleted];
            }
            double t0 = ms();
            for (int r = 0; r < runs; r++) {
                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
                [enc setComputePipelineState:basic];
                [enc setBuffer:bA offset:0 atIndex:0];
                [enc setBuffer:bB offset:0 atIndex:1];
                [enc setBuffer:bC1 offset:0 atIndex:2];
                [enc setBytes:&sz length:4 atIndex:3];
                [enc setBytes:&sz length:4 atIndex:4];
                [enc setBytes:&sz length:4 atIndex:5];
                [enc dispatchThreadgroups:MTLSizeMake((sz+15)/16, (sz+15)/16, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
                [enc endEncoding];
                [cmd commit]; [cmd waitUntilCompleted];
            }
            double t_basic = ms() - t0;
            double gf_basic = 2.0 * sz * sz * sz * runs / (t_basic * 1e6);

            // Blocked kernel
            for (int w = 0; w < 2; w++) {
                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
                [enc setComputePipelineState:blocked];
                [enc setBuffer:bA offset:0 atIndex:0];
                [enc setBuffer:bB offset:0 atIndex:1];
                [enc setBuffer:bC2 offset:0 atIndex:2];
                [enc setBytes:&sz length:4 atIndex:3];
                [enc setBytes:&sz length:4 atIndex:4];
                [enc setBytes:&sz length:4 atIndex:5];
                [enc dispatchThreadgroups:MTLSizeMake((sz+63)/64, (sz+63)/64, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
                [enc endEncoding];
                [cmd commit]; [cmd waitUntilCompleted];
            }
            t0 = ms();
            for (int r = 0; r < runs; r++) {
                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
                [enc setComputePipelineState:blocked];
                [enc setBuffer:bA offset:0 atIndex:0];
                [enc setBuffer:bB offset:0 atIndex:1];
                [enc setBuffer:bC2 offset:0 atIndex:2];
                [enc setBytes:&sz length:4 atIndex:3];
                [enc setBytes:&sz length:4 atIndex:4];
                [enc setBytes:&sz length:4 atIndex:5];
                [enc dispatchThreadgroups:MTLSizeMake((sz+63)/64, (sz+63)/64, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
                [enc endEncoding];
                [cmd commit]; [cmd waitUntilCompleted];
            }
            double t_blocked = ms() - t0;
            double gf_blocked = 2.0 * sz * sz * sz * runs / (t_blocked * 1e6);

            // Verify match
            float *p1 = (float*)bC1.contents;
            float *p2 = (float*)bC2.contents;
            float max_err = 0;
            for (uint32_t i = 0; i < sz*sz; i++) {
                float e = fabsf(p1[i] - p2[i]);
                if (e > max_err) max_err = e;
            }

            printf("N=%u: basic=%6.1f GFLOPS  blocked=%6.1f GFLOPS  (%.1fx)  max_err=%.2e\n",
                   sz, gf_basic, gf_blocked, gf_blocked/gf_basic, max_err);
        }
    }
    return 0;
}
