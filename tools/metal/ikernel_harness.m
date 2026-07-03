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
// usage: ikernel_harness <kernel.metal> <fn_name> <A.txt> <B.txt> <rows> <d> <out.txt> [i64]
//
// A.txt: rows*d int32 values, whitespace-separated (int64 with the
//        trailing "i64" flag -- for kernels in the mul_shr overflow
//        regime where inputs exceed int32)
// B.txt: d values, same dtype as A
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

static int read_longs(const char *path, int64_t *dst, long n) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    for (long i = 0; i < n; i++) {
        long long v;
        if (fscanf(f, "%lld", &v) != 1) { fclose(f); return -1; }
        dst[i] = (int64_t)v;
    }
    fclose(f);
    return 0;
}

int main(int argc, const char **argv) {
    if (argc < 8) {
        fprintf(stderr, "usage: ikernel_harness <kernel.metal> <fn> <A.txt> <B.txt> <rows> <d> <out.txt> [i64] [reps=N] [on=N]\n");
        return 2;
    }
    @autoreleasepool {
        long rows = atol(argv[5]);
        long d    = atol(argv[6]);
        int  i64  = 0;
        long reps = 1;      // dispatches per timing run (all encoded in one command buffer)
        long on   = 0;      // output element count; default rows
        for (int i = 8; i < argc; i++) {
            if (strcmp(argv[i], "i64") == 0) i64 = 1;
            else if (strncmp(argv[i], "reps=", 5) == 0) reps = atol(argv[i] + 5);
            else if (strncmp(argv[i], "on=", 3) == 0)   on = atol(argv[i] + 3);
        }
        if (on <= 0) on = rows;
        if (reps <= 0) reps = 1;
        if (rows <= 0 || d <= 0) { fprintf(stderr, "bad rows/d\n"); return 2; }

        size_t esz = i64 ? sizeof(int64_t) : sizeof(int32_t);
        void *A = malloc(rows * d * esz);
        void *B = malloc(d * esz);
        if (!A || !B) { fprintf(stderr, "malloc failed\n"); return 2; }
        int rc = i64
            ? (read_longs(argv[3], A, rows * d) | read_longs(argv[4], B, d))
            : (read_ints(argv[3], A, rows * d)  | read_ints(argv[4], B, d));
        if (rc != 0) { fprintf(stderr, "bad input file\n"); return 2; }

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

        id<MTLBuffer> bufA = [dev newBufferWithBytes:A length:rows * d * esz
                                             options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufB = [dev newBufferWithBytes:B length:d * esz
                                             options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufO = [dev newBufferWithLength:on * sizeof(int64_t)
                                              options:MTLResourceStorageModeShared];

        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pso];
        [enc setBuffer:bufA offset:0 atIndex:0];
        [enc setBuffer:bufB offset:0 atIndex:1];
        [enc setBuffer:bufO offset:0 atIndex:2];
        NSUInteger tg = MIN((NSUInteger)256, pso.maxTotalThreadsPerThreadgroup);
        // reps identical dispatches in one command buffer amortize launch
        // overhead for timing; the kernel is idempotent so the result is
        // unchanged.  gpu_dispatch_ms reports total/reps.
        for (long r = 0; r < reps; r++) {
            [enc dispatchThreads:MTLSizeMake(rows, 1, 1)
           threadsPerThreadgroup:MTLSizeMake(tg, 1, 1)];
        }
        [enc endEncoding];

        double t0 = CFAbsoluteTimeGetCurrent();
        [cb commit];
        [cb waitUntilCompleted];
        double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0 / (double)reps;

        if (cb.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "GPU execution failed (status %ld)\n", (long)cb.status);
            return 4;
        }

        FILE *out = fopen(argv[7], "w");
        if (!out) { fprintf(stderr, "cannot open out file\n"); return 2; }
        int64_t *O = (int64_t *)bufO.contents;
        for (long i = 0; i < on; i++) fprintf(out, "%lld\n", (long long)O[i]);
        fclose(out);

        fprintf(stderr, "gpu_dispatch_ms=%.3f\n", ms);
        free(A);
        free(B);
    }
    return 0;
}
