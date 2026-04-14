// tensor_gpu_lib.m — Metal tensor ops as a shared library (v2)
//
// Build:
//   clang -shared -fobjc-arc -framework Metal -framework Foundation \
//     -install_name /Users/ledaticempire/projects/rail/tools/metal/libtensor_gpu.dylib \
//     tensor_gpu_lib.m -o libtensor_gpu.dylib
//
// Exports (C ABI, all return 1 on success / -1 on failure):
//   tgl_init(int)                                       — idempotent init
//   tgl_matmul_f64       (A,B,C, M,K,N)                 — C = A @ B
//   tgl_matmul_relu_f64  (A,B,bias,C, M,K,N)            — C = relu(A@B + bias)  (fused)
//   tgl_add_f64          (A,B,C, N)                     — C = A + B
//   tgl_mul_f64          (A,B,C, N)                     — C = A * B  (hadamard)
//   tgl_scale_f64        (A,C, scalar, N)               — C = A * scalar        (scalar is first 8 bytes of a double*)
//   tgl_relu_f64         (X,Y, N)                       — Y = max(0,X)
//   tgl_relu_backward_f64(X,grad,out, N)                — out = (X>0) ? grad : 0
//   tgl_sigmoid_f64      (X,Y, N)
//   tgl_exp_f64          (X,Y, N)
//   tgl_tanh_f64         (X,Y, N)
//   tgl_softmax_rows_f64 (X,Y, rows, cols)              — row-wise softmax
//   tgl_transpose_f64    (A,B, M,N)                     — B = A^T, shape N×M
//   tgl_sgd_update_f64   (w, grad, lr, N)               — w -= lr*grad (in place)
//   tgl_adam_update_f64  (w, g, m, v, hyp, N)           — fused Adam; hyp=[lr,β1,β2,ε,bc1,bc2], m/v updated in place
//   tgl_cross_entropy_f64(probs, targets_f64, losses, batch, vocab)
//
// All *_f64 entry points accept pointers into Rail float_arr payload.
// Rail float_arr layout: [count@0, double@8, double@16, ...].
// We offset by +1 double so A actually points at data, not the count header.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>

static id<MTLDevice>               g_device = nil;
static id<MTLCommandQueue>         g_queue = nil;
static id<MTLLibrary>              g_lib = nil;
static int g_initialized = 0;

// All pipeline states, keyed by name; lazy-built.
static NSMutableDictionary<NSString*, id<MTLComputePipelineState>> *g_pipes = nil;

// Simple buffer pool: up to POOL_MAX reusable MTLBuffers. Keyed by byte size.
// First-fit: linear scan, take smallest buffer ≥ requested size.
#define POOL_MAX 32
typedef struct {
    id<MTLBuffer> buf;   // retained
    NSUInteger    size;  // bytes
    int           in_use;
} pool_slot_t;
static pool_slot_t g_pool[POOL_MAX];
static int         g_pool_count = 0;

// ObjC runtime warmup — Rail's process isn't a Cocoa app, so class lists need
// forcing. Touching a constant NSString triggers __objc_classlist processing.
__attribute__((constructor))
static void _tgl_ctor(void) {
    volatile NSString *s = @"tgl_init_warmup";
    (void)s;
}

// ────────────────────────────────────────────────────────────────────
// Buffer pool — minimize newBufferWithLength on hot paths.
// ────────────────────────────────────────────────────────────────────

static id<MTLBuffer> pool_acquire(NSUInteger bytes) {
    // Best-fit to reduce fragmentation. Pick smallest free slot ≥ bytes.
    int best = -1;
    for (int i = 0; i < g_pool_count; i++) {
        if (g_pool[i].in_use) continue;
        if (g_pool[i].size < bytes) continue;
        if (best < 0 || g_pool[i].size < g_pool[best].size) best = i;
    }
    if (best >= 0) {
        g_pool[best].in_use = 1;
        return g_pool[best].buf;
    }
    // Miss — allocate. Round up to 4KB page to improve reuse.
    NSUInteger rounded = (bytes + 4095) & ~((NSUInteger)4095);
    id<MTLBuffer> b = [g_device newBufferWithLength:rounded options:MTLResourceStorageModeShared];
    if (!b) return nil;
    if (g_pool_count < POOL_MAX) {
        g_pool[g_pool_count].buf = b;
        g_pool[g_pool_count].size = rounded;
        g_pool[g_pool_count].in_use = 1;
        g_pool_count++;
    }
    return b;
}

static void pool_release(id<MTLBuffer> b) {
    for (int i = 0; i < g_pool_count; i++) {
        if (g_pool[i].buf == b) { g_pool[i].in_use = 0; return; }
    }
    // Not in pool (pool was full) — drop on the floor, ARC frees it.
}

// ────────────────────────────────────────────────────────────────────
// Pipeline state lookup (lazy build)
// ────────────────────────────────────────────────────────────────────

static id<MTLComputePipelineState> pso(NSString *name) {
    id<MTLComputePipelineState> p = g_pipes[name];
    if (p) return p;
    NSError *err = nil;
    id<MTLFunction> fn = [g_lib newFunctionWithName:name];
    if (!fn) return nil;
    p = [g_device newComputePipelineStateWithFunction:fn error:&err];
    if (!p) return nil;
    g_pipes[name] = p;
    return p;
}

// ────────────────────────────────────────────────────────────────────
// Initialization: compile shader if needed, open library.
// ────────────────────────────────────────────────────────────────────

int tgl_init(int dummy) {
    (void)dummy;
    if (g_initialized) return 1;

    g_device = MTLCreateSystemDefaultDevice();
    if (!g_device) return -1;

    int rc = system("test -f /tmp/tensor_gpu.metallib || "
                    "(xcrun metal -c /Users/ledaticempire/projects/rail/tools/metal/tensor_gpu.metal -o /tmp/tensor_gpu.air 2>/dev/null && "
                    " xcrun metallib /tmp/tensor_gpu.air -o /tmp/tensor_gpu.metallib 2>/dev/null)");
    (void)rc;

    NSError *err = nil;
    g_lib = [g_device newLibraryWithURL:[NSURL fileURLWithPath:@"/tmp/tensor_gpu.metallib"] error:&err];
    if (!g_lib) return -1;

    g_queue = [g_device newCommandQueue];
    g_pipes = [NSMutableDictionary dictionary];
    g_initialized = 1;
    return 1;
}

static inline int ensure_init(void) {
    if (!g_initialized) return tgl_init(0);
    return 1;
}

// ────────────────────────────────────────────────────────────────────
// Helpers for the common f64 → f32 → GPU → f32 → f64 pipeline.
// ────────────────────────────────────────────────────────────────────

static inline void f64_to_f32(const double *src, float *dst, int n) {
    for (int i = 0; i < n; i++) dst[i] = (float)src[i];
}
static inline void f32_to_f64(const float *src, double *dst, int n) {
    for (int i = 0; i < n; i++) dst[i] = (double)src[i];
}

// Dispatch a 1D "gid < n" kernel with N threads. Threadgroup 256 covers typical sizes.
static void dispatch_1d(id<MTLComputeCommandEncoder> enc, uint32_t n) {
    NSUInteger tg = 256;
    if (n < tg) tg = n;
    [enc dispatchThreads:MTLSizeMake(n, 1, 1)
      threadsPerThreadgroup:MTLSizeMake(tg, 1, 1)];
}

// ────────────────────────────────────────────────────────────────────
// MATMUL: C[M×N] = A[M×K] × B[K×N]
// ────────────────────────────────────────────────────────────────────

int tgl_matmul_f64(const double *A, const double *B, double *C, int M, int K, int N) {
    if (ensure_init() != 1) return -1;
    const double *Aptr = A + 1, *Bptr = B + 1;
    double *Cptr = C + 1;

    @autoreleasepool {
        uint32_t sA = M*K, sB = K*N, sC = M*N;
        id<MTLBuffer> bufA = pool_acquire(sA*4);
        id<MTLBuffer> bufB = pool_acquire(sB*4);
        id<MTLBuffer> bufC = pool_acquire(sC*4);

        f64_to_f32(Aptr, (float*)bufA.contents, sA);
        f64_to_f32(Bptr, (float*)bufB.contents, sB);

        id<MTLComputePipelineState> p = pso(@"matmul_blocked");
        if (!p) p = pso(@"matmul");
        if (!p) return -1;

        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:p];
        [enc setBuffer:bufA offset:0 atIndex:0];
        [enc setBuffer:bufB offset:0 atIndex:1];
        [enc setBuffer:bufC offset:0 atIndex:2];
        uint32_t mu=M, ku=K, nu=N;
        [enc setBytes:&mu length:4 atIndex:3];
        [enc setBytes:&ku length:4 atIndex:4];
        [enc setBytes:&nu length:4 atIndex:5];
        [enc dispatchThreadgroups:MTLSizeMake((N+63)/64, (M+63)/64, 1)
           threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
        [enc endEncoding];
        [cmd commit]; [cmd waitUntilCompleted];

        f32_to_f64((float*)bufC.contents, Cptr, sC);
        pool_release(bufA); pool_release(bufB); pool_release(bufC);
    }
    return 1;
}

// Fused matmul+bias+relu: C = relu(A@B + bias_broadcast_rowwise)
// bias is a length-N float array (one per output column). Pass NULL header too.
int tgl_matmul_relu_f64(const double *A, const double *B, const double *bias,
                        double *C, int M, int K, int N) {
    if (ensure_init() != 1) return -1;
    const double *Aptr = A + 1, *Bptr = B + 1, *Bsptr = bias + 1;
    double *Cptr = C + 1;

    @autoreleasepool {
        uint32_t sA = M*K, sB = K*N, sC = M*N;
        id<MTLBuffer> bufA = pool_acquire(sA*4);
        id<MTLBuffer> bufB = pool_acquire(sB*4);
        id<MTLBuffer> bufBias = pool_acquire(N*4);
        id<MTLBuffer> bufC = pool_acquire(sC*4);

        f64_to_f32(Aptr, (float*)bufA.contents, sA);
        f64_to_f32(Bptr, (float*)bufB.contents, sB);
        f64_to_f32(Bsptr, (float*)bufBias.contents, N);

        id<MTLComputePipelineState> p = pso(@"matmul_bias_relu");
        if (!p) return -1;

        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:p];
        [enc setBuffer:bufA offset:0 atIndex:0];
        [enc setBuffer:bufB offset:0 atIndex:1];
        [enc setBuffer:bufBias offset:0 atIndex:2];
        [enc setBuffer:bufC offset:0 atIndex:3];
        uint32_t mu=M, ku=K, nu=N;
        [enc setBytes:&mu length:4 atIndex:4];
        [enc setBytes:&ku length:4 atIndex:5];
        [enc setBytes:&nu length:4 atIndex:6];
        [enc dispatchThreadgroups:MTLSizeMake((N+15)/16, (M+15)/16, 1)
           threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
        [enc endEncoding];
        [cmd commit]; [cmd waitUntilCompleted];

        f32_to_f64((float*)bufC.contents, Cptr, sC);
        pool_release(bufA); pool_release(bufB);
        pool_release(bufBias); pool_release(bufC);
    }
    return 1;
}

// Fused matmul+bias+gelu — transformer FFN hidden layer.
int tgl_matmul_gelu_f64(const double *A, const double *B, const double *bias,
                        double *C, int M, int K, int N) {
    if (ensure_init() != 1) return -1;
    const double *Aptr = A+1, *Bptr = B+1, *Bsptr = bias+1;
    double *Cptr = C+1;
    @autoreleasepool {
        uint32_t sA = M*K, sB = K*N, sC = M*N;
        id<MTLBuffer> bA = pool_acquire(sA*4);
        id<MTLBuffer> bB = pool_acquire(sB*4);
        id<MTLBuffer> bBias = pool_acquire(N*4);
        id<MTLBuffer> bC = pool_acquire(sC*4);
        f64_to_f32(Aptr, (float*)bA.contents, sA);
        f64_to_f32(Bptr, (float*)bB.contents, sB);
        f64_to_f32(Bsptr, (float*)bBias.contents, N);

        id<MTLComputePipelineState> p = pso(@"matmul_bias_gelu");
        if (!p) return -1;
        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:p];
        [enc setBuffer:bA offset:0 atIndex:0];
        [enc setBuffer:bB offset:0 atIndex:1];
        [enc setBuffer:bBias offset:0 atIndex:2];
        [enc setBuffer:bC offset:0 atIndex:3];
        uint32_t mu=M, ku=K, nu=N;
        [enc setBytes:&mu length:4 atIndex:4];
        [enc setBytes:&ku length:4 atIndex:5];
        [enc setBytes:&nu length:4 atIndex:6];
        [enc dispatchThreadgroups:MTLSizeMake((N+15)/16,(M+15)/16,1)
           threadsPerThreadgroup:MTLSizeMake(16,16,1)];
        [enc endEncoding];
        [cmd commit]; [cmd waitUntilCompleted];

        f32_to_f64((float*)bC.contents, Cptr, sC);
        pool_release(bA); pool_release(bB); pool_release(bBias); pool_release(bC);
    }
    return 1;
}

// Batched matmul: C[b] = A[b] @ B[b] for b in 0..B_DIM-1.
int tgl_matmul_batched_f64(const double *A, const double *B, double *C,
                           int B_DIM, int M, int K, int N) {
    if (ensure_init() != 1) return -1;
    const double *Aptr = A+1, *Bptr = B+1;
    double *Cptr = C+1;
    @autoreleasepool {
        uint32_t sA = B_DIM*M*K, sB = B_DIM*K*N, sC = B_DIM*M*N;
        id<MTLBuffer> bA = pool_acquire(sA*4);
        id<MTLBuffer> bB = pool_acquire(sB*4);
        id<MTLBuffer> bC = pool_acquire(sC*4);
        f64_to_f32(Aptr, (float*)bA.contents, sA);
        f64_to_f32(Bptr, (float*)bB.contents, sB);

        id<MTLComputePipelineState> p = pso(@"matmul_batched");
        if (!p) return -1;
        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:p];
        [enc setBuffer:bA offset:0 atIndex:0];
        [enc setBuffer:bB offset:0 atIndex:1];
        [enc setBuffer:bC offset:0 atIndex:2];
        uint32_t bu=B_DIM, mu=M, ku=K, nu=N;
        [enc setBytes:&bu length:4 atIndex:3];
        [enc setBytes:&mu length:4 atIndex:4];
        [enc setBytes:&ku length:4 atIndex:5];
        [enc setBytes:&nu length:4 atIndex:6];
        [enc dispatchThreads:MTLSizeMake(N, M, B_DIM)
          threadsPerThreadgroup:MTLSizeMake(N<8?N:8, M<8?M:8, 1)];
        [enc endEncoding];
        [cmd commit]; [cmd waitUntilCompleted];

        f32_to_f64((float*)bC.contents, Cptr, sC);
        pool_release(bA); pool_release(bB); pool_release(bC);
    }
    return 1;
}

// Correct parallel sum: one threadgroup per 256 elements produces a
// partial; host finishes on the few remaining.
int tgl_sum_f64(const double *X, double *result_out, int N) {
    if (ensure_init() != 1) return -1;
    const double *Xp = X+1;
    uint32_t n_tg = (N + 255) / 256;
    @autoreleasepool {
        id<MTLBuffer> bX = pool_acquire(N*4);
        id<MTLBuffer> bP = pool_acquire(n_tg*4);
        f64_to_f32(Xp, (float*)bX.contents, N);
        // Zero the partials buffer (pool may hand back stale memory).
        memset(bP.contents, 0, n_tg*4);

        id<MTLComputePipelineState> p = pso(@"tensor_sum_partials");
        if (!p) return -1;
        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:p];
        [enc setBuffer:bX offset:0 atIndex:0];
        [enc setBuffer:bP offset:0 atIndex:1];
        uint32_t nu = N;
        [enc setBytes:&nu length:4 atIndex:2];
        [enc dispatchThreadgroups:MTLSizeMake(n_tg, 1, 1)
           threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
        [enc endEncoding];
        [cmd commit]; [cmd waitUntilCompleted];

        float *pP = (float*)bP.contents;
        double total = 0.0;
        for (uint32_t i = 0; i < n_tg; i++) total += pP[i];
        result_out[0] = total;  // single-element output, not a float_arr
        pool_release(bX); pool_release(bP);
    }
    return 1;
}

// Softmax backward: dx = y * (dy - Σ y_k dy_k)
int tgl_softmax_backward_f64(const double *y, const double *dy, double *dx,
                             int rows, int cols) {
    if (ensure_init() != 1) return -1;
    const double *yp = y+1, *dyp = dy+1;
    double *dxp = dx+1;
    uint32_t n = rows * cols;
    @autoreleasepool {
        id<MTLBuffer> by = pool_acquire(n*4);
        id<MTLBuffer> bdy = pool_acquire(n*4);
        id<MTLBuffer> bdx = pool_acquire(n*4);
        f64_to_f32(yp, (float*)by.contents, n);
        f64_to_f32(dyp, (float*)bdy.contents, n);
        id<MTLComputePipelineState> p = pso(@"softmax_backward");
        if (!p) return -1;
        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:p];
        [enc setBuffer:by offset:0 atIndex:0];
        [enc setBuffer:bdy offset:0 atIndex:1];
        [enc setBuffer:bdx offset:0 atIndex:2];
        uint32_t ru=rows, cu=cols;
        [enc setBytes:&ru length:4 atIndex:3];
        [enc setBytes:&cu length:4 atIndex:4];
        dispatch_1d(enc, rows);
        [enc endEncoding];
        [cmd commit]; [cmd waitUntilCompleted];
        f32_to_f64((float*)bdx.contents, dxp, n);
        pool_release(by); pool_release(bdy); pool_release(bdx);
    }
    return 1;
}

// Fused softmax→CE backward: (probs - one_hot(targets)) / batch.
int tgl_ce_softmax_backward_f64(const double *probs, const double *targets,
                                double *grad, int batch, int vocab) {
    if (ensure_init() != 1) return -1;
    const double *pp = probs+1, *tp = targets+1;
    double *gp = grad+1;
    uint32_t n = batch * vocab;
    @autoreleasepool {
        id<MTLBuffer> bP = pool_acquire(n*4);
        id<MTLBuffer> bT = pool_acquire(batch*4);
        id<MTLBuffer> bG = pool_acquire(n*4);
        f64_to_f32(pp, (float*)bP.contents, n);
        f64_to_f32(tp, (float*)bT.contents, batch);
        id<MTLComputePipelineState> p = pso(@"ce_softmax_backward");
        if (!p) return -1;
        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:p];
        [enc setBuffer:bP offset:0 atIndex:0];
        [enc setBuffer:bT offset:0 atIndex:1];
        [enc setBuffer:bG offset:0 atIndex:2];
        uint32_t bu=batch, vu=vocab;
        [enc setBytes:&bu length:4 atIndex:3];
        [enc setBytes:&vu length:4 atIndex:4];
        dispatch_1d(enc, n);
        [enc endEncoding];
        [cmd commit]; [cmd waitUntilCompleted];
        f32_to_f64((float*)bG.contents, gp, n);
        pool_release(bP); pool_release(bT); pool_release(bG);
    }
    return 1;
}

// LayerNorm backward. Caller precomputes mean + rstd per row on forward.
int tgl_layernorm_backward_f64(const double *x, const double *mean,
                               const double *rstd, const double *gamma,
                               const double *dy, double *dx,
                               int rows, int dim) {
    if (ensure_init() != 1) return -1;
    const double *xp = x+1, *mp = mean+1, *rp = rstd+1, *gp = gamma+1, *dyp = dy+1;
    double *dxp = dx+1;
    uint32_t n = rows * dim;
    @autoreleasepool {
        id<MTLBuffer> bX = pool_acquire(n*4);
        id<MTLBuffer> bM = pool_acquire(rows*4);
        id<MTLBuffer> bR = pool_acquire(rows*4);
        id<MTLBuffer> bG = pool_acquire(dim*4);
        id<MTLBuffer> bDy = pool_acquire(n*4);
        id<MTLBuffer> bDx = pool_acquire(n*4);
        f64_to_f32(xp, (float*)bX.contents, n);
        f64_to_f32(mp, (float*)bM.contents, rows);
        f64_to_f32(rp, (float*)bR.contents, rows);
        f64_to_f32(gp, (float*)bG.contents, dim);
        f64_to_f32(dyp, (float*)bDy.contents, n);
        id<MTLComputePipelineState> p = pso(@"layernorm_backward");
        if (!p) return -1;
        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:p];
        [enc setBuffer:bX offset:0 atIndex:0];
        [enc setBuffer:bM offset:0 atIndex:1];
        [enc setBuffer:bR offset:0 atIndex:2];
        [enc setBuffer:bG offset:0 atIndex:3];
        [enc setBuffer:bDy offset:0 atIndex:4];
        [enc setBuffer:bDx offset:0 atIndex:5];
        uint32_t ru=rows, du=dim;
        [enc setBytes:&ru length:4 atIndex:6];
        [enc setBytes:&du length:4 atIndex:7];
        dispatch_1d(enc, rows);
        [enc endEncoding];
        [cmd commit]; [cmd waitUntilCompleted];
        f32_to_f64((float*)bDx.contents, dxp, n);
        pool_release(bX); pool_release(bM); pool_release(bR);
        pool_release(bG); pool_release(bDy); pool_release(bDx);
    }
    return 1;
}

// ────────────────────────────────────────────────────────────────────
// Generic 1-in-1-out kernel dispatch (relu/sigmoid/exp/tanh_fwd)
// ────────────────────────────────────────────────────────────────────

static int unary_op(NSString *kname, const double *X, double *Y, int N) {
    if (ensure_init() != 1) return -1;
    const double *Xptr = X + 1;
    double *Yptr = Y + 1;
    @autoreleasepool {
        id<MTLBuffer> bX = pool_acquire(N*4);
        id<MTLBuffer> bY = pool_acquire(N*4);
        f64_to_f32(Xptr, (float*)bX.contents, N);

        id<MTLComputePipelineState> p = pso(kname);
        if (!p) return -1;
        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:p];
        [enc setBuffer:bX offset:0 atIndex:0];
        [enc setBuffer:bY offset:0 atIndex:1];
        uint32_t nu = N;
        [enc setBytes:&nu length:4 atIndex:2];
        dispatch_1d(enc, N);
        [enc endEncoding];
        [cmd commit]; [cmd waitUntilCompleted];

        f32_to_f64((float*)bY.contents, Yptr, N);
        pool_release(bX); pool_release(bY);
    }
    return 1;
}

int tgl_relu_f64   (const double *X, double *Y, int N) { return unary_op(@"tensor_relu",     X, Y, N); }
int tgl_sigmoid_f64(const double *X, double *Y, int N) { return unary_op(@"tensor_sigmoid",  X, Y, N); }
int tgl_exp_f64    (const double *X, double *Y, int N) { return unary_op(@"tensor_exp",      X, Y, N); }
int tgl_tanh_f64   (const double *X, double *Y, int N) { return unary_op(@"tensor_tanh_fwd", X, Y, N); }

// ────────────────────────────────────────────────────────────────────
// Generic 2-in-1-out kernel dispatch (add/mul)
// ────────────────────────────────────────────────────────────────────

static int binary_op(NSString *kname, const double *A, const double *B, double *C, int N) {
    if (ensure_init() != 1) return -1;
    const double *Ap = A+1, *Bp = B+1;
    double *Cp = C+1;
    @autoreleasepool {
        id<MTLBuffer> bA = pool_acquire(N*4);
        id<MTLBuffer> bB = pool_acquire(N*4);
        id<MTLBuffer> bC = pool_acquire(N*4);
        f64_to_f32(Ap, (float*)bA.contents, N);
        f64_to_f32(Bp, (float*)bB.contents, N);

        id<MTLComputePipelineState> p = pso(kname);
        if (!p) return -1;
        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:p];
        [enc setBuffer:bA offset:0 atIndex:0];
        [enc setBuffer:bB offset:0 atIndex:1];
        [enc setBuffer:bC offset:0 atIndex:2];
        uint32_t nu = N;
        [enc setBytes:&nu length:4 atIndex:3];
        dispatch_1d(enc, N);
        [enc endEncoding];
        [cmd commit]; [cmd waitUntilCompleted];

        f32_to_f64((float*)bC.contents, Cp, N);
        pool_release(bA); pool_release(bB); pool_release(bC);
    }
    return 1;
}

int tgl_add_f64(const double *A, const double *B, double *C, int N) { return binary_op(@"tensor_add", A,B,C,N); }
int tgl_mul_f64(const double *A, const double *B, double *C, int N) { return binary_op(@"tensor_mul", A,B,C,N); }

// ────────────────────────────────────────────────────────────────────
// Scale: C = A * scalar
// Rail foreign ABI untags ints; for floats we pass as an untagged double*
// pointer whose first 8 bytes hold the scalar.
// ────────────────────────────────────────────────────────────────────

int tgl_scale_f64(const double *A, double *C, const double *scalar_ptr, int N) {
    if (ensure_init() != 1) return -1;
    const double *Ap = A+1;
    double *Cp = C+1;
    // scalar_ptr points at a 1-element float_arr: [count@0, value@8]
    double sv = scalar_ptr[1];
    float sf = (float)sv;

    @autoreleasepool {
        id<MTLBuffer> bA = pool_acquire(N*4);
        id<MTLBuffer> bC = pool_acquire(N*4);
        f64_to_f32(Ap, (float*)bA.contents, N);

        id<MTLComputePipelineState> p = pso(@"tensor_scale");
        if (!p) return -1;
        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:p];
        [enc setBuffer:bA offset:0 atIndex:0];
        [enc setBuffer:bC offset:0 atIndex:1];
        [enc setBytes:&sf length:4 atIndex:2];
        uint32_t nu = N;
        [enc setBytes:&nu length:4 atIndex:3];
        dispatch_1d(enc, N);
        [enc endEncoding];
        [cmd commit]; [cmd waitUntilCompleted];

        f32_to_f64((float*)bC.contents, Cp, N);
        pool_release(bA); pool_release(bC);
    }
    return 1;
}

// ────────────────────────────────────────────────────────────────────
// ReLU backward: out = (X>0) ? grad : 0
// ────────────────────────────────────────────────────────────────────

int tgl_relu_backward_f64(const double *X, const double *grad, double *out, int N) {
    if (ensure_init() != 1) return -1;
    const double *Xp = X+1, *Gp = grad+1;
    double *Op = out+1;
    @autoreleasepool {
        id<MTLBuffer> bX = pool_acquire(N*4);
        id<MTLBuffer> bG = pool_acquire(N*4);
        id<MTLBuffer> bO = pool_acquire(N*4);
        f64_to_f32(Xp, (float*)bX.contents, N);
        f64_to_f32(Gp, (float*)bG.contents, N);

        id<MTLComputePipelineState> p = pso(@"tensor_relu_backward");
        if (!p) return -1;
        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:p];
        [enc setBuffer:bX offset:0 atIndex:0];
        [enc setBuffer:bG offset:0 atIndex:1];
        [enc setBuffer:bO offset:0 atIndex:2];
        uint32_t nu = N;
        [enc setBytes:&nu length:4 atIndex:3];
        dispatch_1d(enc, N);
        [enc endEncoding];
        [cmd commit]; [cmd waitUntilCompleted];

        f32_to_f64((float*)bO.contents, Op, N);
        pool_release(bX); pool_release(bG); pool_release(bO);
    }
    return 1;
}

// ────────────────────────────────────────────────────────────────────
// Row-wise softmax: Y[r,:] = softmax(X[r,:])
// ────────────────────────────────────────────────────────────────────

int tgl_softmax_rows_f64(const double *X, double *Y, int rows, int cols) {
    if (ensure_init() != 1) return -1;
    const double *Xp = X+1;
    double *Yp = Y+1;
    uint32_t n = rows * cols;

    @autoreleasepool {
        id<MTLBuffer> bX = pool_acquire(n*4);
        id<MTLBuffer> bMax = pool_acquire(rows*4);
        id<MTLBuffer> bY = pool_acquire(n*4);
        id<MTLBuffer> bSum = pool_acquire(rows*4);
        f64_to_f32(Xp, (float*)bX.contents, n);

        id<MTLComputePipelineState> pMax = pso(@"softmax_max");
        id<MTLComputePipelineState> pExp = pso(@"softmax_exp_sum");
        id<MTLComputePipelineState> pNorm = pso(@"softmax_normalize");
        if (!pMax || !pExp || !pNorm) return -1;

        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        uint32_t ru = rows, cu = cols;

        id<MTLComputeCommandEncoder> e1 = [cmd computeCommandEncoder];
        [e1 setComputePipelineState:pMax];
        [e1 setBuffer:bX offset:0 atIndex:0];
        [e1 setBuffer:bMax offset:0 atIndex:1];
        [e1 setBytes:&ru length:4 atIndex:2];
        [e1 setBytes:&cu length:4 atIndex:3];
        dispatch_1d(e1, rows);
        [e1 endEncoding];

        id<MTLComputeCommandEncoder> e2 = [cmd computeCommandEncoder];
        [e2 setComputePipelineState:pExp];
        [e2 setBuffer:bX offset:0 atIndex:0];
        [e2 setBuffer:bY offset:0 atIndex:1];
        [e2 setBuffer:bSum offset:0 atIndex:2];
        [e2 setBuffer:bMax offset:0 atIndex:3];
        [e2 setBytes:&ru length:4 atIndex:4];
        [e2 setBytes:&cu length:4 atIndex:5];
        dispatch_1d(e2, rows);
        [e2 endEncoding];

        id<MTLComputeCommandEncoder> e3 = [cmd computeCommandEncoder];
        [e3 setComputePipelineState:pNorm];
        [e3 setBuffer:bY offset:0 atIndex:0];
        [e3 setBuffer:bSum offset:0 atIndex:1];
        [e3 setBytes:&ru length:4 atIndex:2];
        [e3 setBytes:&cu length:4 atIndex:3];
        [e3 dispatchThreads:MTLSizeMake(cols, rows, 1)
          threadsPerThreadgroup:MTLSizeMake(cols < 16 ? cols : 16, rows < 16 ? rows : 16, 1)];
        [e3 endEncoding];

        [cmd commit]; [cmd waitUntilCompleted];

        f32_to_f64((float*)bY.contents, Yp, n);
        pool_release(bX); pool_release(bMax); pool_release(bY); pool_release(bSum);
    }
    return 1;
}

// ────────────────────────────────────────────────────────────────────
// Transpose: B[N×M] = A[M×N]^T
// ────────────────────────────────────────────────────────────────────

int tgl_transpose_f64(const double *A, double *B, int M, int N) {
    if (ensure_init() != 1) return -1;
    const double *Ap = A+1;
    double *Bp = B+1;
    uint32_t n = M*N;
    @autoreleasepool {
        id<MTLBuffer> bA = pool_acquire(n*4);
        id<MTLBuffer> bB = pool_acquire(n*4);
        f64_to_f32(Ap, (float*)bA.contents, n);

        id<MTLComputePipelineState> p = pso(@"tensor_transpose");
        if (!p) return -1;
        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:p];
        [enc setBuffer:bA offset:0 atIndex:0];
        [enc setBuffer:bB offset:0 atIndex:1];
        uint32_t mu=M, nu=N;
        [enc setBytes:&mu length:4 atIndex:2];
        [enc setBytes:&nu length:4 atIndex:3];
        [enc dispatchThreads:MTLSizeMake(N, M, 1)
          threadsPerThreadgroup:MTLSizeMake(N<16?N:16, M<16?M:16, 1)];
        [enc endEncoding];
        [cmd commit]; [cmd waitUntilCompleted];

        f32_to_f64((float*)bB.contents, Bp, n);
        pool_release(bA); pool_release(bB);
    }
    return 1;
}

// ────────────────────────────────────────────────────────────────────
// SGD update: w -= lr * grad (in-place on weights)
// lr passed by address (scalar_ptr[1] = value).
// ────────────────────────────────────────────────────────────────────

int tgl_sgd_update_f64(double *weights, const double *grad, const double *lr_ptr, int N) {
    if (ensure_init() != 1) return -1;
    double *wp = weights + 1;
    const double *gp = grad + 1;
    float lrf = (float)lr_ptr[1];
    @autoreleasepool {
        id<MTLBuffer> bW = pool_acquire(N*4);
        id<MTLBuffer> bG = pool_acquire(N*4);
        f64_to_f32(wp, (float*)bW.contents, N);
        f64_to_f32(gp, (float*)bG.contents, N);

        id<MTLComputePipelineState> p = pso(@"sgd_update");
        if (!p) return -1;
        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:p];
        [enc setBuffer:bW offset:0 atIndex:0];
        [enc setBuffer:bG offset:0 atIndex:1];
        [enc setBytes:&lrf length:4 atIndex:2];
        uint32_t nu = N;
        [enc setBytes:&nu length:4 atIndex:3];
        dispatch_1d(enc, N);
        [enc endEncoding];
        [cmd commit]; [cmd waitUntilCompleted];

        f32_to_f64((float*)bW.contents, wp, N);
        pool_release(bW); pool_release(bG);
    }
    return 1;
}

// ────────────────────────────────────────────────────────────────────
// Adam fused in-place update.
//   hyp is a Rail float_arr of length ≥6: [lr, β1, β2, ε, bc1, bc2]
//   m and v are mutated in place (same side as weights).
//   One GPU dispatch per parameter tensor per step.
// ────────────────────────────────────────────────────────────────────

int tgl_adam_update_f64(double *w, const double *g,
                        double *m, double *v,
                        const double *hyp, int N) {
    if (ensure_init() != 1) return -1;
    double *wp = w + 1;
    const double *gp = g + 1;
    double *mp = m + 1;
    double *vp = v + 1;
    const double *hp = hyp + 1;

    float hyp_f[6];
    for (int i = 0; i < 6; i++) hyp_f[i] = (float)hp[i];

    @autoreleasepool {
        id<MTLBuffer> bW = pool_acquire(N*4);
        id<MTLBuffer> bG = pool_acquire(N*4);
        id<MTLBuffer> bM = pool_acquire(N*4);
        id<MTLBuffer> bV = pool_acquire(N*4);
        f64_to_f32(wp, (float*)bW.contents, N);
        f64_to_f32(gp, (float*)bG.contents, N);
        f64_to_f32(mp, (float*)bM.contents, N);
        f64_to_f32(vp, (float*)bV.contents, N);

        id<MTLComputePipelineState> p = pso(@"adam_update");
        if (!p) return -1;
        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:p];
        [enc setBuffer:bW offset:0 atIndex:0];
        [enc setBuffer:bG offset:0 atIndex:1];
        [enc setBuffer:bM offset:0 atIndex:2];
        [enc setBuffer:bV offset:0 atIndex:3];
        [enc setBytes:hyp_f length:sizeof(hyp_f) atIndex:4];
        uint32_t nu = N;
        [enc setBytes:&nu length:4 atIndex:5];
        dispatch_1d(enc, N);
        [enc endEncoding];
        [cmd commit]; [cmd waitUntilCompleted];

        f32_to_f64((float*)bW.contents, wp, N);
        f32_to_f64((float*)bM.contents, mp, N);
        f32_to_f64((float*)bV.contents, vp, N);
        pool_release(bW); pool_release(bG);
        pool_release(bM); pool_release(bV);
    }
    return 1;
}

// ────────────────────────────────────────────────────────────────────
// Cross-entropy: losses[i] = -log(probs[i, targets[i]])
// targets passed as double values (f64) — we cast to uint inside.
// ────────────────────────────────────────────────────────────────────

int tgl_cross_entropy_f64(const double *probs, const double *targets,
                          double *losses, int batch, int vocab) {
    if (ensure_init() != 1) return -1;
    const double *pp = probs + 1, *tp = targets + 1;
    double *lp = losses + 1;
    uint32_t np = batch * vocab;

    @autoreleasepool {
        id<MTLBuffer> bP = pool_acquire(np*4);
        id<MTLBuffer> bT = pool_acquire(batch*4);
        id<MTLBuffer> bL = pool_acquire(batch*4);
        f64_to_f32(pp, (float*)bP.contents, np);
        uint32_t *tg = (uint32_t*)bT.contents;
        for (int i = 0; i < batch; i++) tg[i] = (uint32_t)tp[i];

        id<MTLComputePipelineState> p = pso(@"cross_entropy");
        if (!p) return -1;
        id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:p];
        [enc setBuffer:bP offset:0 atIndex:0];
        [enc setBuffer:bT offset:0 atIndex:1];
        [enc setBuffer:bL offset:0 atIndex:2];
        uint32_t bu = batch, vu = vocab;
        [enc setBytes:&bu length:4 atIndex:3];
        [enc setBytes:&vu length:4 atIndex:4];
        dispatch_1d(enc, batch);
        [enc endEncoding];
        [cmd commit]; [cmd waitUntilCompleted];

        f32_to_f64((float*)bL.contents, lp, batch);
        pool_release(bP); pool_release(bT); pool_release(bL);
    }
    return 1;
}
