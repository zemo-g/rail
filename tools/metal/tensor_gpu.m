// tensor_gpu.m — Metal tensor compute server for Rail
//
// Persistent process that accepts tensor operations over stdin (binary protocol).
// Rail's tensor.rail dispatches GPU-eligible ops here instead of CPU loops.
//
// Protocol (binary, little-endian):
//   Request:  [uint32 op] [uint32 M] [uint32 K] [uint32 N] [float32[] A] [float32[] B]
//   Response: [uint32 status] [uint32 count] [float32[] result]
//
// Ops: 0=matmul, 1=add, 2=mul, 3=relu, 4=tanh, 5=exp, 6=sigmoid,
//      7=sgd_update(lr in B[0]), 8=transpose, 9=softmax, 99=quit
//
// Build:
//   xcrun metal -c tensor_gpu.metal -o /tmp/tensor_gpu.air
//   xcrun metallib /tmp/tensor_gpu.air -o /tmp/tensor_gpu.metallib
//   clang -framework Metal -framework Foundation -fobjc-arc tensor_gpu.m -o tensor_gpu
//
// Run:
//   ./tensor_gpu              # reads stdin, writes stdout (binary)
//   ./tensor_gpu --benchmark  # run internal benchmarks

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <sys/time.h>

#define OP_MATMUL    0
#define OP_ADD       1
#define OP_MUL       2
#define OP_RELU      3
#define OP_TANH      4
#define OP_EXP       5
#define OP_SIGMOID   6
#define OP_SGD       7
#define OP_TRANSPOSE 8
#define OP_SOFTMAX   9
#define OP_RELU_BACK 10
#define OP_SCALE     11
#define OP_QUIT      99

static double now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

// Read exactly n bytes from stdin
static int read_exact(void *buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        size_t r = fread((char*)buf + got, 1, n - got, stdin);
        if (r == 0) return -1;
        got += r;
    }
    return 0;
}

// Write exactly n bytes to stdout
static void write_exact(const void *buf, size_t n) {
    fwrite(buf, 1, n, stdout);
    fflush(stdout);
}

// Read text file of space/newline-separated floats into buffer
static int read_text_floats(const char *path, float *buf, int n) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    for (int i = 0; i < n; i++) {
        if (fscanf(f, "%f", &buf[i]) != 1) { fclose(f); return i; }
    }
    fclose(f);
    return n;
}

// Write float buffer as text file (one float per line)
static void write_text_floats(const char *path, float *buf, int n) {
    FILE *f = fopen(path, "w");
    if (!f) return;
    for (int i = 0; i < n; i++) fprintf(f, "%.8g\n", buf[i]);
    fclose(f);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr, "No Metal device\n"); return 1; }

        // ── File mode: ./tensor_gpu matmul M K N a.txt b.txt c.txt ──
        if (argc >= 7 && strcmp(argv[1], "matmul") == 0) {
            uint32_t M = atoi(argv[2]), K = atoi(argv[3]), N = atoi(argv[4]);
            const char *pathA = argv[5], *pathB = argv[6], *pathC = argv[7];

            // Compile shader (use cached metallib if exists)
            int rc = system("test -f /tmp/tensor_gpu.metallib || (xcrun metal -c /Users/ledaticempire/projects/rail/tools/metal/tensor_gpu.metal -o /tmp/tensor_gpu.air 2>/dev/null && xcrun metallib /tmp/tensor_gpu.air -o /tmp/tensor_gpu.metallib 2>/dev/null)");
            (void)rc;

            NSError *err = nil;
            id<MTLLibrary> lib = [device newLibraryWithURL:[NSURL fileURLWithPath:@"/tmp/tensor_gpu.metallib"] error:&err];
            if (!lib) { fprintf(stderr, "metallib: %s\n", [[err description] UTF8String]); return 1; }
            id<MTLComputePipelineState> pipe = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"matmul"] error:&err];
            id<MTLCommandQueue> queue = [device newCommandQueue];

            id<MTLBuffer> bufA = [device newBufferWithLength:M*K*4 options:MTLResourceStorageModeShared];
            id<MTLBuffer> bufB = [device newBufferWithLength:K*N*4 options:MTLResourceStorageModeShared];
            id<MTLBuffer> bufC = [device newBufferWithLength:M*N*4 options:MTLResourceStorageModeShared];

            read_text_floats(pathA, (float*)bufA.contents, M*K);
            read_text_floats(pathB, (float*)bufB.contents, K*N);

            id<MTLCommandBuffer> cmd = [queue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:pipe];
            [enc setBuffer:bufA offset:0 atIndex:0];
            [enc setBuffer:bufB offset:0 atIndex:1];
            [enc setBuffer:bufC offset:0 atIndex:2];
            [enc setBytes:&M length:4 atIndex:3];
            [enc setBytes:&K length:4 atIndex:4];
            [enc setBytes:&N length:4 atIndex:5];
            [enc dispatchThreadgroups:MTLSizeMake((N+15)/16, (M+15)/16, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
            [enc endEncoding];
            [cmd commit]; [cmd waitUntilCompleted];

            write_text_floats(pathC, (float*)bufC.contents, M*N);
            return 0;
        }

        // ── Binary elementwise file mode: ./tensor_gpu add N a.txt b.txt c.txt ──
        if (argc >= 6 && (strcmp(argv[1], "add") == 0 || strcmp(argv[1], "mul") == 0)) {
            uint32_t n = atoi(argv[2]);
            const char *pathA = argv[3], *pathB = argv[4], *pathC = argv[5];

            int rc = system("test -f /tmp/tensor_gpu.metallib || (xcrun metal -c /Users/ledaticempire/projects/rail/tools/metal/tensor_gpu.metal -o /tmp/tensor_gpu.air 2>/dev/null && xcrun metallib /tmp/tensor_gpu.air -o /tmp/tensor_gpu.metallib 2>/dev/null)");
            (void)rc;

            NSError *err = nil;
            id<MTLLibrary> lib = [device newLibraryWithURL:[NSURL fileURLWithPath:@"/tmp/tensor_gpu.metallib"] error:&err];
            if (!lib) return 1;
            NSString *kernelName = strcmp(argv[1], "add") == 0 ? @"tensor_add" : @"tensor_mul";
            id<MTLComputePipelineState> pipe = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:kernelName] error:&err];
            id<MTLCommandQueue> queue = [device newCommandQueue];

            id<MTLBuffer> bufA = [device newBufferWithLength:n*4 options:MTLResourceStorageModeShared];
            id<MTLBuffer> bufB = [device newBufferWithLength:n*4 options:MTLResourceStorageModeShared];
            id<MTLBuffer> bufC = [device newBufferWithLength:n*4 options:MTLResourceStorageModeShared];
            read_text_floats(pathA, (float*)bufA.contents, n);
            read_text_floats(pathB, (float*)bufB.contents, n);

            id<MTLCommandBuffer> cmd = [queue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:pipe];
            [enc setBuffer:bufA offset:0 atIndex:0];
            [enc setBuffer:bufB offset:0 atIndex:1];
            [enc setBuffer:bufC offset:0 atIndex:2];
            [enc setBytes:&n length:4 atIndex:3];
            [enc dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [enc endEncoding];
            [cmd commit]; [cmd waitUntilCompleted];

            write_text_floats(pathC, (float*)bufC.contents, n);
            return 0;
        }

        // ── Unary elementwise file mode: ./tensor_gpu relu N a.txt c.txt ──
        if (argc >= 5 && (strcmp(argv[1], "relu") == 0 || strcmp(argv[1], "tanh_fwd") == 0 ||
                          strcmp(argv[1], "exp") == 0 || strcmp(argv[1], "sigmoid") == 0)) {
            uint32_t n = atoi(argv[2]);
            const char *pathA = argv[3], *pathC = argv[4];

            int rc = system("test -f /tmp/tensor_gpu.metallib || (xcrun metal -c /Users/ledaticempire/projects/rail/tools/metal/tensor_gpu.metal -o /tmp/tensor_gpu.air 2>/dev/null && xcrun metallib /tmp/tensor_gpu.air -o /tmp/tensor_gpu.metallib 2>/dev/null)");
            (void)rc;

            NSError *err = nil;
            id<MTLLibrary> lib = [device newLibraryWithURL:[NSURL fileURLWithPath:@"/tmp/tensor_gpu.metallib"] error:&err];
            if (!lib) { fprintf(stderr, "metallib: %s\n", [[err description] UTF8String]); return 1; }

            NSString *kernelName;
            if (strcmp(argv[1], "relu") == 0) kernelName = @"tensor_relu";
            else if (strcmp(argv[1], "tanh_fwd") == 0) kernelName = @"tensor_tanh_fwd";
            else if (strcmp(argv[1], "exp") == 0) kernelName = @"tensor_exp";
            else kernelName = @"tensor_sigmoid";

            id<MTLComputePipelineState> pipe = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:kernelName] error:&err];
            id<MTLCommandQueue> queue = [device newCommandQueue];

            id<MTLBuffer> bufA = [device newBufferWithLength:n*4 options:MTLResourceStorageModeShared];
            id<MTLBuffer> bufC = [device newBufferWithLength:n*4 options:MTLResourceStorageModeShared];
            read_text_floats(pathA, (float*)bufA.contents, n);

            id<MTLCommandBuffer> cmd = [queue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:pipe];
            [enc setBuffer:bufA offset:0 atIndex:0];
            [enc setBuffer:bufC offset:0 atIndex:1];
            [enc setBytes:&n length:4 atIndex:2];
            [enc dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [enc endEncoding];
            [cmd commit]; [cmd waitUntilCompleted];

            write_text_floats(pathC, (float*)bufC.contents, n);
            return 0;
        }

        // Compile shader for binary/benchmark modes
        int rc = system("xcrun metal -c /Users/ledaticempire/projects/rail/tools/metal/tensor_gpu.metal -o /tmp/tensor_gpu.air 2>/dev/null");
        if (rc != 0) { fprintf(stderr, "metal compile failed\n"); return 1; }
        rc = system("xcrun metallib /tmp/tensor_gpu.air -o /tmp/tensor_gpu.metallib 2>/dev/null");
        if (rc != 0) { fprintf(stderr, "metallib failed\n"); return 1; }

        NSError *err = nil;
        id<MTLLibrary> lib = [device newLibraryWithURL:
            [NSURL fileURLWithPath:@"/tmp/tensor_gpu.metallib"] error:&err];
        if (!lib) { fprintf(stderr, "Library: %s\n", [[err description] UTF8String]); return 1; }

        // Load all kernels
        id<MTLComputePipelineState> pipes[20];
        NSString *names[] = {
            @"matmul", @"tensor_add", @"tensor_mul", @"tensor_relu",
            @"tensor_tanh_fwd", @"tensor_exp", @"tensor_sigmoid",
            @"sgd_update", @"tensor_transpose", @"softmax_max",
            @"tensor_relu_backward", @"tensor_scale",
            @"softmax_exp_sum", @"softmax_normalize"
        };
        for (int i = 0; i < 14; i++) {
            id<MTLFunction> fn = [lib newFunctionWithName:names[i]];
            if (!fn) { fprintf(stderr, "No kernel: %s\n", [names[i] UTF8String]); return 1; }
            pipes[i] = [device newComputePipelineStateWithFunction:fn error:&err];
            if (!pipes[i]) { fprintf(stderr, "Pipe %s: %s\n", [names[i] UTF8String], [[err description] UTF8String]); return 1; }
        }

        id<MTLCommandQueue> queue = [device newCommandQueue];

        // Benchmark mode
        if (argc > 1 && strcmp(argv[1], "--benchmark") == 0) {
            fprintf(stderr, "=== Metal Tensor Benchmark ===\n");
            fprintf(stderr, "Device: %s\n", [[device name] UTF8String]);

            // Matmul 512×512
            uint32_t sz = 512;
            NSUInteger bytes = sz * sz * sizeof(float);
            id<MTLBuffer> bufA = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
            id<MTLBuffer> bufB = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
            id<MTLBuffer> bufC = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];

            // Fill with random data
            float *pA = (float*)bufA.contents, *pB = (float*)bufB.contents;
            for (uint32_t i = 0; i < sz * sz; i++) {
                pA[i] = (float)rand() / RAND_MAX;
                pB[i] = (float)rand() / RAND_MAX;
            }

            // Warmup
            for (int w = 0; w < 3; w++) {
                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
                [enc setComputePipelineState:pipes[0]]; // matmul
                [enc setBuffer:bufA offset:0 atIndex:0];
                [enc setBuffer:bufB offset:0 atIndex:1];
                [enc setBuffer:bufC offset:0 atIndex:2];
                [enc setBytes:&sz length:4 atIndex:3];
                [enc setBytes:&sz length:4 atIndex:4];
                [enc setBytes:&sz length:4 atIndex:5];
                [enc dispatchThreads:MTLSizeMake(sz, sz, 1)
                    threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
                [enc endEncoding];
                [cmd commit]; [cmd waitUntilCompleted];
            }

            // Timed runs
            int runs = 20;
            double t0 = now_ms();
            for (int r = 0; r < runs; r++) {
                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
                [enc setComputePipelineState:pipes[0]];
                [enc setBuffer:bufA offset:0 atIndex:0];
                [enc setBuffer:bufB offset:0 atIndex:1];
                [enc setBuffer:bufC offset:0 atIndex:2];
                [enc setBytes:&sz length:4 atIndex:3];
                [enc setBytes:&sz length:4 atIndex:4];
                [enc setBytes:&sz length:4 atIndex:5];
                [enc dispatchThreads:MTLSizeMake(sz, sz, 1)
                    threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
                [enc endEncoding];
                [cmd commit]; [cmd waitUntilCompleted];
            }
            double elapsed = now_ms() - t0;
            double gflops = 2.0 * sz * sz * sz * runs / (elapsed * 1e6);

            // Verify against CPU
            float *pC = (float*)bufC.contents;
            float cpu_val = 0;
            for (uint32_t k = 0; k < sz; k++) cpu_val += pA[k] * pB[k * sz];
            float err_pct = fabsf(pC[0] - cpu_val) / fabsf(cpu_val) * 100;

            fprintf(stderr, "\nMatmul %u×%u:\n", sz, sz);
            fprintf(stderr, "  %.2f ms/op  (%.1f GFLOPS)\n", elapsed / runs, gflops);
            fprintf(stderr, "  CPU verify: err=%.4f%%\n", err_pct);

            // Elementwise 1M
            uint32_t big = 1000000;
            NSUInteger bigBytes = big * sizeof(float);
            id<MTLBuffer> bA = [device newBufferWithLength:bigBytes options:MTLResourceStorageModeShared];
            id<MTLBuffer> bB = [device newBufferWithLength:bigBytes options:MTLResourceStorageModeShared];
            id<MTLBuffer> bC = [device newBufferWithLength:bigBytes options:MTLResourceStorageModeShared];
            float *bpA = (float*)bA.contents;
            for (uint32_t i = 0; i < big; i++) bpA[i] = (float)rand() / RAND_MAX * 2 - 1;

            t0 = now_ms();
            for (int r = 0; r < 100; r++) {
                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
                [enc setComputePipelineState:pipes[3]]; // relu
                [enc setBuffer:bA offset:0 atIndex:0];
                [enc setBuffer:bC offset:0 atIndex:1];
                [enc setBytes:&big length:4 atIndex:2];
                [enc dispatchThreads:MTLSizeMake(big, 1, 1)
                    threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
                [enc endEncoding];
                [cmd commit]; [cmd waitUntilCompleted];
            }
            elapsed = now_ms() - t0;
            fprintf(stderr, "\nReLU 1M elements:\n");
            fprintf(stderr, "  %.3f ms/op  (%.1f GB/s)\n", elapsed / 100, big * 4.0 * 2 * 100 / (elapsed * 1e6));

            fprintf(stderr, "\n=== Benchmark complete ===\n");
            return 0;
        }

        // ── Server mode: read ops from stdin, write results to stdout ──
        fprintf(stderr, "tensor_gpu: ready (%s)\n", [[device name] UTF8String]);

        while (1) {
            uint32_t header[4]; // op, M, K, N
            if (read_exact(header, 16) != 0) break;

            uint32_t op = header[0], M = header[1], K = header[2], N = header[3];

            if (op == OP_QUIT) break;

            if (op == OP_MATMUL) {
                // Read A[M×K] and B[K×N], compute C[M×N]
                uint32_t sA = M * K, sB = K * N, sC = M * N;
                id<MTLBuffer> bufA = [device newBufferWithLength:sA*4 options:MTLResourceStorageModeShared];
                id<MTLBuffer> bufB = [device newBufferWithLength:sB*4 options:MTLResourceStorageModeShared];
                id<MTLBuffer> bufC = [device newBufferWithLength:sC*4 options:MTLResourceStorageModeShared];
                if (read_exact(bufA.contents, sA * 4) != 0) break;
                if (read_exact(bufB.contents, sB * 4) != 0) break;

                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
                [enc setComputePipelineState:pipes[0]];
                [enc setBuffer:bufA offset:0 atIndex:0];
                [enc setBuffer:bufB offset:0 atIndex:1];
                [enc setBuffer:bufC offset:0 atIndex:2];
                [enc setBytes:&M length:4 atIndex:3];
                [enc setBytes:&K length:4 atIndex:4];
                [enc setBytes:&N length:4 atIndex:5];
                [enc dispatchThreadgroups:MTLSizeMake((N+15)/16, (M+15)/16, 1)
                    threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
                [enc endEncoding];
                [cmd commit]; [cmd waitUntilCompleted];

                uint32_t resp[2] = { 0, sC };
                write_exact(resp, 8);
                write_exact(bufC.contents, sC * 4);

            } else if (op >= OP_ADD && op <= OP_SIGMOID) {
                // Elementwise: A[M*K] op → C[M*K]  (N unused, B only for add/mul)
                uint32_t n = M * K;
                id<MTLBuffer> bufA = [device newBufferWithLength:n*4 options:MTLResourceStorageModeShared];
                id<MTLBuffer> bufC = [device newBufferWithLength:n*4 options:MTLResourceStorageModeShared];
                if (read_exact(bufA.contents, n * 4) != 0) break;

                id<MTLBuffer> bufB = nil;
                if (op == OP_ADD || op == OP_MUL) {
                    bufB = [device newBufferWithLength:n*4 options:MTLResourceStorageModeShared];
                    if (read_exact(bufB.contents, n * 4) != 0) break;
                }

                int pipeIdx;
                switch (op) {
                    case OP_ADD: pipeIdx = 1; break;
                    case OP_MUL: pipeIdx = 2; break;
                    case OP_RELU: pipeIdx = 3; break;
                    case OP_TANH: pipeIdx = 4; break;
                    case OP_EXP: pipeIdx = 5; break;
                    case OP_SIGMOID: pipeIdx = 6; break;
                    default: pipeIdx = 3; break;
                }

                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
                [enc setComputePipelineState:pipes[pipeIdx]];
                [enc setBuffer:bufA offset:0 atIndex:0];
                if (bufB) {
                    [enc setBuffer:bufB offset:0 atIndex:1];
                    [enc setBuffer:bufC offset:0 atIndex:2];
                    [enc setBytes:&n length:4 atIndex:3];
                } else {
                    [enc setBuffer:bufC offset:0 atIndex:1];
                    [enc setBytes:&n length:4 atIndex:2];
                }
                [enc dispatchThreads:MTLSizeMake(n, 1, 1)
                    threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
                [enc endEncoding];
                [cmd commit]; [cmd waitUntilCompleted];

                uint32_t resp[2] = { 0, n };
                write_exact(resp, 8);
                write_exact(bufC.contents, n * 4);

            } else if (op == OP_TRANSPOSE) {
                uint32_t sA = M * N, sB = M * N;
                id<MTLBuffer> bufA = [device newBufferWithLength:sA*4 options:MTLResourceStorageModeShared];
                id<MTLBuffer> bufB = [device newBufferWithLength:sB*4 options:MTLResourceStorageModeShared];
                if (read_exact(bufA.contents, sA * 4) != 0) break;

                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
                [enc setComputePipelineState:pipes[8]];
                [enc setBuffer:bufA offset:0 atIndex:0];
                [enc setBuffer:bufB offset:0 atIndex:1];
                [enc setBytes:&M length:4 atIndex:2];
                [enc setBytes:&N length:4 atIndex:3];
                [enc dispatchThreadgroups:MTLSizeMake((N+15)/16, (M+15)/16, 1)
                    threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
                [enc endEncoding];
                [cmd commit]; [cmd waitUntilCompleted];

                uint32_t resp[2] = { 0, sB };
                write_exact(resp, 8);
                write_exact(bufB.contents, sB * 4);
            }
        }

        fprintf(stderr, "tensor_gpu: shutdown\n");
    }
    return 0;
}
