// tensor_gpu_lib.m — Metal tensor ops as a shared library
// Build: clang -shared -framework Metal -framework Foundation -fobjc-arc tensor_gpu_lib.m -o libtensor_gpu.dylib
//
// Exports C ABI functions Rail can call via dlopen/dlsym:
//   tgl_init() -> int        : 0 on success, -1 on failure
//   tgl_matmul_f64(const double *A, const double *B, double *C, int M, int K, int N) -> int
//   tgl_relu_f64(const double *X, double *Y, int N) -> int
//
// The f64 variants take double-precision Rail float_arr contents.
// Internally converts to f32 for Metal, writes back as f64.
//
// Pointers point directly into Rail's float_arr payload — unified memory
// on Apple Silicon means no host-GPU copy for the logical data, but we
// still need a f32 staging buffer (Metal doesn't support f64 compute).

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static id<MTLDevice>         g_device = nil;
static id<MTLCommandQueue>   g_queue = nil;
static id<MTLLibrary>        g_lib = nil;
static id<MTLComputePipelineState> g_matmul = nil;
static id<MTLComputePipelineState> g_relu = nil;
static int g_initialized = 0;

// ────────────────────────────────────────────────────────────────────
// Initialization: compile shader, create pipelines
// ────────────────────────────────────────────────────────────────────

int tgl_init(void) {
    if (g_initialized) return 0;
    fprintf(stderr, "tgl_init: step 1 - MTLCreateSystemDefaultDevice\n");

    g_device = MTLCreateSystemDefaultDevice();
    if (!g_device) return -1;
    fprintf(stderr, "tgl_init: step 2 - shader compile check\n");

    // Compile shader if not cached
    int rc = system("test -f /tmp/tensor_gpu.metallib || (xcrun metal -c /Users/ledaticempire/projects/rail/tools/metal/tensor_gpu.metal -o /tmp/tensor_gpu.air 2>/dev/null && xcrun metallib /tmp/tensor_gpu.air -o /tmp/tensor_gpu.metallib 2>/dev/null)");
    (void)rc;
    fprintf(stderr, "tgl_init: step 3 - load library\n");

    NSError *err = nil;
    g_lib = [g_device newLibraryWithURL:[NSURL fileURLWithPath:@"/tmp/tensor_gpu.metallib"] error:&err];
    if (!g_lib) return -1;

    g_matmul = [g_device newComputePipelineStateWithFunction:[g_lib newFunctionWithName:@"matmul"] error:&err];
    if (!g_matmul) return -1;

    g_relu = [g_device newComputePipelineStateWithFunction:[g_lib newFunctionWithName:@"tensor_relu"] error:&err];
    if (!g_relu) return -1;

    g_queue = [g_device newCommandQueue];
    g_initialized = 1;
    return 1; // tagged Rail int 0
}

// ────────────────────────────────────────────────────────────────────
// Matmul: C[M×N] = A[M×K] × B[K×N]
// Inputs: f64 arrays (Rail float_arr payload + 8-byte header offset)
// The offset +1 convention: Rail's float_arr_get uses idx+1 because
// the first slot is the count. Callers should pass pointer AFTER the
// count header, or we add the offset here.
// ────────────────────────────────────────────────────────────────────

int tgl_matmul_f64(const double *A, const double *B, double *C, long Mt, long Kt, long Nt) {
    if (!g_initialized) { if (tgl_init() != 0) return -1; }

    // Rail passes tagged ints: n*2+1. Untag by (n-1)/2.
    int M = (int)((Mt - 1) >> 1);
    int K = (int)((Kt - 1) >> 1);
    int N = (int)((Nt - 1) >> 1);

    // Rail float_arr layout: [count@0, double@8, double@16, ...]
    // Skip 8 bytes (count header) to get to the actual data.
    const double *Aptr = A + 1;
    const double *Bptr = B + 1;
    double *Cptr = C + 1;

    @autoreleasepool {
        uint32_t sA = M * K, sB = K * N, sC = M * N;
        id<MTLBuffer> bufA = [g_device newBufferWithLength:sA*4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufB = [g_device newBufferWithLength:sB*4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufC = [g_device newBufferWithLength:sC*4 options:MTLResourceStorageModeShared];

        // f64 → f32 copy (Metal doesn't support f64 compute on most hardware)
        float *pA = (float*)bufA.contents;
        float *pB = (float*)bufB.contents;
        for (int i = 0; i < sA; i++) pA[i] = (float)Aptr[i];
        for (int i = 0; i < sB; i++) pB[i] = (float)Bptr[i];

        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:g_matmul];
        [enc setBuffer:bufA offset:0 atIndex:0];
        [enc setBuffer:bufB offset:0 atIndex:1];
        [enc setBuffer:bufC offset:0 atIndex:2];
        uint32_t mu = M, ku = K, nu = N;
        [enc setBytes:&mu length:4 atIndex:3];
        [enc setBytes:&ku length:4 atIndex:4];
        [enc setBytes:&nu length:4 atIndex:5];
        [enc dispatchThreadgroups:MTLSizeMake((N+15)/16, (M+15)/16, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
        [enc endEncoding];
        [cmd commit]; [cmd waitUntilCompleted];

        float *pC = (float*)bufC.contents;
        for (int i = 0; i < sC; i++) Cptr[i] = (double)pC[i];
    }
    return 1; // tagged Rail int 0
}

// ────────────────────────────────────────────────────────────────────
// ReLU: Y[N] = max(0, X[N])
// ────────────────────────────────────────────────────────────────────

int tgl_relu_f64(const double *X, double *Y, long Nt) {
    if (!g_initialized) { if (tgl_init() != 0) return -1; }

    int N = (int)((Nt - 1) >> 1);
    const double *Xptr = X + 1;
    double *Yptr = Y + 1;

    @autoreleasepool {
        id<MTLBuffer> bufA = [g_device newBufferWithLength:N*4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufC = [g_device newBufferWithLength:N*4 options:MTLResourceStorageModeShared];
        float *pA = (float*)bufA.contents;
        for (int i = 0; i < N; i++) pA[i] = (float)Xptr[i];

        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:g_relu];
        [enc setBuffer:bufA offset:0 atIndex:0];
        [enc setBuffer:bufC offset:0 atIndex:1];
        uint32_t nu = N;
        [enc setBytes:&nu length:4 atIndex:2];
        [enc dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
        [enc endEncoding];
        [cmd commit]; [cmd waitUntilCompleted];

        float *pC = (float*)bufC.contents;
        for (int i = 0; i < N; i++) Yptr[i] = (double)pC[i];
    }
    return 1; // tagged Rail int 0
}
