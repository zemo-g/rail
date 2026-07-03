// ikernel_harness.m — minimal integer-kernel dispatcher for the
// attested-GPU track (twin-kernel attestation PoC, 2026-07-03).
//
// Reads Rail-emitted MSL from a file, JIT-compiles it with the OS
// Metal runtime compiler (no xcrun), dispatches, writes results back
// as text.  Deliberately dumb: every input and output is
// human-readable text so every byte of the pipeline can be inspected
// and hashed by the Rail driver.
//
// build: clang -fobjc-arc -O2 -framework Metal -framework Foundation \
//        -o ikernel_harness ikernel_harness.m
// usage: ikernel_harness <kernel.metal> <fn_name> <A.txt> <B.txt> <rows> <d> <out.txt>
//
// A.txt: rows*d int32 values, whitespace-separated
// B.txt: d int32 values
// out.txt: rows int64 values, one per line
// stderr: gpu_dispatch_ms=<float> (commit->complete only, excludes
//         process spawn / Metal init / text I/O)

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static int read_ints(const char *path, int32_t *dst, long n) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    for (long i = 0; i < n; i++) {
        if (fscanf(f, "%d", &dst[i]) != 1) { fclose(f); return -1; }
    }
    fclose(f);
    return 0;
}

int main(int argc, const char **argv) {
    if (argc != 8) {
        fprintf(stderr, "usage: ikernel_harness <kernel.metal> <fn> <A.txt> <B.txt> <rows> <d> <out.txt>\n");
        return 2;
    }
    @autoreleasepool {
        long rows = atol(argv[5]);
        long d    = atol(argv[6]);
        if (rows <= 0 || d <= 0) { fprintf(stderr, "bad rows/d\n"); return 2; }

        int32_t *A = malloc(rows * d * sizeof(int32_t));
        int32_t *B = malloc(d * sizeof(int32_t));
        if (!A || !B) { fprintf(stderr, "malloc failed\n"); return 2; }
        if (read_ints(argv[3], A, rows * d) != 0) { fprintf(stderr, "bad A file\n"); return 2; }
        if (read_ints(argv[4], B, d) != 0)        { fprintf(stderr, "bad B file\n"); return 2; }

        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { fprintf(stderr, "no Metal device\n"); return 3; }

        NSError *err = nil;
        NSString *src = [NSString stringWithContentsOfFile:@(argv[1])
                                                  encoding:NSUTF8StringEncoding
                                                     error:&err];
        if (!src) { fprintf(stderr, "cannot read MSL: %s\n", err.localizedDescription.UTF8String); return 3; }

        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
        if (!lib) { fprintf(stderr, "metal compile failed: %s\n", err.localizedDescription.UTF8String); return 3; }

        id<MTLFunction> fn = [lib newFunctionWithName:@(argv[2])];
        if (!fn) { fprintf(stderr, "kernel fn '%s' not found\n", argv[2]); return 3; }

        id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:fn error:&err];
        if (!pso) { fprintf(stderr, "pipeline failed: %s\n", err.localizedDescription.UTF8String); return 3; }

        id<MTLBuffer> bufA = [dev newBufferWithBytes:A length:rows * d * sizeof(int32_t)
                                             options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufB = [dev newBufferWithBytes:B length:d * sizeof(int32_t)
                                             options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufO = [dev newBufferWithLength:rows * sizeof(int64_t)
                                              options:MTLResourceStorageModeShared];

        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pso];
        [enc setBuffer:bufA offset:0 atIndex:0];
        [enc setBuffer:bufB offset:0 atIndex:1];
        [enc setBuffer:bufO offset:0 atIndex:2];
        NSUInteger tg = MIN((NSUInteger)256, pso.maxTotalThreadsPerThreadgroup);
        [enc dispatchThreads:MTLSizeMake(rows, 1, 1)
       threadsPerThreadgroup:MTLSizeMake(tg, 1, 1)];
        [enc endEncoding];

        double t0 = CFAbsoluteTimeGetCurrent();
        [cb commit];
        [cb waitUntilCompleted];
        double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;

        if (cb.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "GPU execution failed (status %ld)\n", (long)cb.status);
            return 4;
        }

        FILE *out = fopen(argv[7], "w");
        if (!out) { fprintf(stderr, "cannot open out file\n"); return 2; }
        int64_t *O = (int64_t *)bufO.contents;
        for (long i = 0; i < rows; i++) fprintf(out, "%lld\n", (long long)O[i]);
        fclose(out);

        fprintf(stderr, "gpu_dispatch_ms=%.3f\n", ms);
        free(A);
        free(B);
    }
    return 0;
}
