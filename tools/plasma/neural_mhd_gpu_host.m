// neural_mhd_gpu_host.m — Metal GPU-accelerated MLP training for neural MHD surrogate
// Self-contained: generates MHD data, trains on GPU, evaluates conservation
// Built from Rail: ./rail_native run tools/plasma/neural_mhd_gpu.rail

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

// ═══════════════════════════════════════════════════════════
// MHD SIMULATION (double precision, CPU)
// ═══════════════════════════════════════════════════════════

#define NN 64
#define NN2 (NN*NN)
#define NFIELDS 6
#define STATE_SIZE (NFIELDS * NN2)
#define GAMMA_V (5.0/3.0)
#define GAMMA_M1 (2.0/3.0)
#define DX (2.0*M_PI/NN)
#define DX2 (2.0*DX)

static inline int wrap(int i) { return (i < 0) ? i+NN : (i >= NN) ? i-NN : i; }
static inline int idx(int f, int x, int y) { return f*NN2 + wrap(y)*NN + wrap(x); }
#define G(s,f,x,y) (s[idx(f,x,y)])

static void init_state(double *s) {
    for (int y = 0; y < NN; y++) for (int x = 0; x < NN; x++) {
        double xp = x*DX, yp = y*DX;
        double rho = 25.0/(36.0*M_PI);
        double vx = -sin(yp), vy = sin(xp);
        double bx = -sin(yp), by = sin(2.0*xp);
        double p = 5.0/(12.0*M_PI);
        double ke = 0.5*rho*(vx*vx+vy*vy), me = 0.5*(bx*bx+by*by);
        int i = y*NN+x;
        s[0*NN2+i]=rho; s[1*NN2+i]=rho*vx; s[2*NN2+i]=rho*vy;
        s[3*NN2+i]=bx; s[4*NN2+i]=by; s[5*NN2+i]=p/GAMMA_M1+ke+me;
    }
}

static double pressure(double *s, int x, int y) {
    double rho=G(s,0,x,y), mx=G(s,1,x,y), my=G(s,2,x,y);
    double bx=G(s,3,x,y), by=G(s,4,x,y), e=G(s,5,x,y);
    double v2=(mx*mx+my*my)/(rho*rho), b2=bx*bx+by*by;
    double p = GAMMA_M1*(e - 0.5*rho*v2 - 0.5*b2);
    return fmax(p, 1e-10);
}

static void x_flux(double *s, int x, int y, double *f) {
    double rho=G(s,0,x,y), mx=G(s,1,x,y), my=G(s,2,x,y);
    double bx=G(s,3,x,y), by=G(s,4,x,y), e=G(s,5,x,y);
    double vx=mx/rho, vy=my/rho, b2=bx*bx+by*by;
    double p=pressure(s,x,y), pt=p+0.5*b2, vdb=vx*bx+vy*by;
    f[0]=mx; f[1]=mx*vx+pt-bx*bx; f[2]=mx*vy-bx*by;
    f[3]=0; f[4]=vx*by-vy*bx; f[5]=(e+pt)*vx-bx*vdb;
}

static void y_flux(double *s, int x, int y, double *f) {
    double rho=G(s,0,x,y), mx=G(s,1,x,y), my=G(s,2,x,y);
    double bx=G(s,3,x,y), by=G(s,4,x,y), e=G(s,5,x,y);
    double vx=mx/rho, vy=my/rho, b2=bx*bx+by*by;
    double p=pressure(s,x,y), pt=p+0.5*b2, vdb=vx*bx+vy*by;
    f[0]=my; f[1]=my*vx-bx*by; f[2]=my*vy+pt-by*by;
    f[3]=vy*bx-vx*by; f[4]=0; f[5]=(e+pt)*vy-by*vdb;
}

static double max_speed(double *s) {
    double smax = 0;
    for (int i = 0; i < NN2; i++) {
        int x=i%NN, y=i/NN;
        double rho=G(s,0,x,y), mx=G(s,1,x,y), my=G(s,2,x,y);
        double bx=G(s,3,x,y), by=G(s,4,x,y), p=pressure(s,x,y);
        double b2=bx*bx+by*by, cf=sqrt(GAMMA_V*p/rho+b2/rho);
        double v=sqrt((mx*mx+my*my)/(rho*rho))+cf;
        if (v > smax) smax = v;
    }
    return smax;
}

static void lxf_step(double *s, double *ns, double dt) {
    double cx = dt/DX2, cy = cx;
    double fxr[6], fxl[6], fyu[6], fyd[6];
    for (int i = 0; i < NN2; i++) {
        int x=i%NN, y=i/NN;
        x_flux(s,x+1,y,fxr); x_flux(s,x-1,y,fxl);
        y_flux(s,x,y+1,fyu); y_flux(s,x,y-1,fyd);
        for (int f = 0; f < 6; f++) {
            double avg = (G(s,f,x-1,y)+G(s,f,x+1,y)+G(s,f,x,y-1)+G(s,f,x,y+1))/4.0;
            ns[f*NN2+i] = avg - cx*(fxr[f]-fxl[f]) - cy*(fyu[f]-fyd[f]);
        }
    }
}

// ═══════════════════════════════════════════════════════════
// DATA GENERATION
// ═══════════════════════════════════════════════════════════

#define IN_DIM 30
#define OUT_DIM 6
#define N_STEPS 50
#define N_EXAMPLES (NN2 * N_STEPS)

// Extract 5-cell stencil (center + 4 neighbors) × 6 fields = 30 values
static void extract_stencil(double *s, int x, int y, float *buf) {
    for (int f = 0; f < 6; f++) {
        buf[f]    = (float)G(s,f,x,y);
        buf[f+6]  = (float)G(s,f,x-1,y);
        buf[f+12] = (float)G(s,f,x+1,y);
        buf[f+18] = (float)G(s,f,x,y-1);
        buf[f+24] = (float)G(s,f,x,y+1);
    }
}

static void generate_data(float *X, float *Y) {
    double *s = calloc(STATE_SIZE, sizeof(double));
    double *ns = calloc(STATE_SIZE, sizeof(double));
    init_state(s);

    for (int step = 0; step < N_STEPS; step++) {
        double dt = 0.2 * DX / max_speed(s);
        lxf_step(s, ns, dt);
        for (int i = 0; i < NN2; i++) {
            int x=i%NN, y=i/NN;
            int ex = step*NN2 + i;
            extract_stencil(s, x, y, X + ex*IN_DIM);
            // RESIDUAL: target = next_state - current_state (learn the delta)
            for (int f = 0; f < 6; f++)
                Y[ex*OUT_DIM + f] = (float)(ns[f*NN2 + i] - s[f*NN2 + i]);
        }
        if (step % 10 == 0) printf("  data step %d/%d\n", step, N_STEPS);
        double *tmp = s; s = ns; ns = tmp;
    }
    free(s); free(ns);
}

// ═══════════════════════════════════════════════════════════
// METAL TRAINING
// ═══════════════════════════════════════════════════════════

#define HIDDEN 32
#define BATCH 256
#define TILE 16
#define LR 0.001f
#define MIN(a,b) ((a)<(b)?(a):(b))
#define N_TRAIN 10000

int main(int argc, char **argv) {
    @autoreleasepool {
        printf("\n  NEURAL MHD SURROGATE — Metal GPU Training\n");
        printf("  MLP: %d -> %d (ReLU) -> %d\n", IN_DIM, HIDDEN, OUT_DIM);
        printf("  Grid: %dx%d, %d steps, %d examples\n", NN, NN, N_STEPS, N_EXAMPLES);
        printf("  Batch: %d, LR: %.4f, Steps: %d\n\n", BATCH, LR, N_TRAIN);

        // Generate data
        printf("Generating MHD data...\n");
        float *X_all = calloc(N_EXAMPLES * IN_DIM, sizeof(float));
        float *Y_all = calloc(N_EXAMPLES * OUT_DIM, sizeof(float));
        generate_data(X_all, Y_all);
        printf("  %d examples generated\n", N_EXAMPLES);

        // Normalize data: compute mean/std for inputs and outputs
        float x_mean[IN_DIM], x_std[IN_DIM], y_mean[OUT_DIM], y_std[OUT_DIM];
        memset(x_mean, 0, sizeof(x_mean)); memset(y_mean, 0, sizeof(y_mean));
        for (int i = 0; i < N_EXAMPLES; i++) {
            for (int j = 0; j < IN_DIM; j++) x_mean[j] += X_all[i*IN_DIM+j];
            for (int j = 0; j < OUT_DIM; j++) y_mean[j] += Y_all[i*OUT_DIM+j];
        }
        for (int j = 0; j < IN_DIM; j++) x_mean[j] /= N_EXAMPLES;
        for (int j = 0; j < OUT_DIM; j++) y_mean[j] /= N_EXAMPLES;

        memset(x_std, 0, sizeof(x_std)); memset(y_std, 0, sizeof(y_std));
        for (int i = 0; i < N_EXAMPLES; i++) {
            for (int j = 0; j < IN_DIM; j++) { float d=X_all[i*IN_DIM+j]-x_mean[j]; x_std[j]+=d*d; }
            for (int j = 0; j < OUT_DIM; j++) { float d=Y_all[i*OUT_DIM+j]-y_mean[j]; y_std[j]+=d*d; }
        }
        for (int j = 0; j < IN_DIM; j++) x_std[j] = sqrtf(x_std[j]/N_EXAMPLES) + 1e-8f;
        for (int j = 0; j < OUT_DIM; j++) y_std[j] = sqrtf(y_std[j]/N_EXAMPLES) + 1e-8f;

        // Apply normalization
        for (int i = 0; i < N_EXAMPLES; i++) {
            for (int j = 0; j < IN_DIM; j++) X_all[i*IN_DIM+j] = (X_all[i*IN_DIM+j]-x_mean[j])/x_std[j];
            for (int j = 0; j < OUT_DIM; j++) Y_all[i*OUT_DIM+j] = (Y_all[i*OUT_DIM+j]-y_mean[j])/y_std[j];
        }
        printf("  Data normalized (zero mean, unit variance)\n\n");

        // Metal setup
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { fprintf(stderr, "No Metal\n"); return 1; }
        id<MTLCommandQueue> queue = [dev newCommandQueue];

        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithURL:
            [NSURL fileURLWithPath:@"/tmp/neural_mhd_gpu.metallib"] error:&err];
        if (!lib) { NSLog(@"metallib: %@", err); return 1; }

        // Create pipelines
        id<MTLComputePipelineState> matmulPipe = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"matmul_kernel"] error:&err];
        id<MTLComputePipelineState> matmulATBPipe = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"matmul_at_b_kernel"] error:&err];
        id<MTLComputePipelineState> matmulABTPipe = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"matmul_a_bt_kernel"] error:&err];
        id<MTLComputePipelineState> biasAddPipe = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"bias_add_kernel"] error:&err];
        id<MTLComputePipelineState> reluPipe = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"relu_kernel"] error:&err];
        id<MTLComputePipelineState> reluBkPipe = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"relu_backward_kernel"] error:&err];
        id<MTLComputePipelineState> mseGradPipe = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"mse_grad_kernel"] error:&err];
        id<MTLComputePipelineState> mseLossPipe = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"mse_loss_kernel"] error:&err];
        id<MTLComputePipelineState> sgdPipe = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"sgd_kernel"] error:&err];
        id<MTLComputePipelineState> sumRowsPipe = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"sum_rows_kernel"] error:&err];

        // Allocate GPU buffers (shared memory = zero-copy on Apple Silicon)
        #define BUF(name, n) id<MTLBuffer> name = [dev newBufferWithLength:(n)*sizeof(float) options:MTLResourceStorageModeShared]
        BUF(W1, IN_DIM * HIDDEN);
        BUF(b1, HIDDEN);
        BUF(W2, HIDDEN * OUT_DIM);
        BUF(b2, OUT_DIM);
        BUF(X_batch, BATCH * IN_DIM);
        BUF(Y_batch, BATCH * OUT_DIM);
        BUF(Z1, BATCH * HIDDEN);
        BUF(A1, BATCH * HIDDEN);
        BUF(pred, BATCH * OUT_DIM);
        BUF(d_out, BATCH * OUT_DIM);
        BUF(d_A1, BATCH * HIDDEN);
        BUF(dW1, IN_DIM * HIDDEN);
        BUF(db1, HIDDEN);
        BUF(dW2, HIDDEN * OUT_DIM);
        BUF(db2_buf, OUT_DIM);
        BUF(loss_buf, BATCH * OUT_DIM);

        // Xavier init
        float scale1 = sqrtf(6.0f / (IN_DIM + HIDDEN));
        float scale2 = sqrtf(6.0f / (HIDDEN + OUT_DIM));
        float *w1p = W1.contents, *w2p = W2.contents;
        for (int i = 0; i < IN_DIM*HIDDEN; i++) w1p[i] = ((float)arc4random()/UINT32_MAX*2-1)*scale1;
        for (int i = 0; i < HIDDEN*OUT_DIM; i++) w2p[i] = ((float)arc4random()/UINT32_MAX*2-1)*scale2;
        memset(b1.contents, 0, HIDDEN*sizeof(float));
        memset(b2.contents, 0, OUT_DIM*sizeof(float));

        // Dimension constants
        uint32_t batch_u = BATCH, in_u = IN_DIM, hid_u = HIDDEN, out_u = OUT_DIM;
        float mse_scale = 2.0f / (BATCH * OUT_DIM);
        float lr = LR;

        printf("Training...\n");

        for (int step = 0; step < N_TRAIN; step++) {
            // Load batch
            int offset = (step * BATCH) % N_EXAMPLES;
            memcpy(X_batch.contents, X_all + offset*IN_DIM, BATCH*IN_DIM*sizeof(float));
            memcpy(Y_batch.contents, Y_all + offset*OUT_DIM, BATCH*OUT_DIM*sizeof(float));

            id<MTLCommandBuffer> cmd = [queue commandBuffer];

            // ── FORWARD ──
            // Z1 = X_batch @ W1
            id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:matmulPipe];
            [enc setBuffer:X_batch offset:0 atIndex:0];
            [enc setBuffer:W1 offset:0 atIndex:1];
            [enc setBuffer:Z1 offset:0 atIndex:2];
            [enc setBytes:&batch_u length:4 atIndex:3];
            [enc setBytes:&hid_u length:4 atIndex:4];
            [enc setBytes:&in_u length:4 atIndex:5];
            [enc dispatchThreads:MTLSizeMake(HIDDEN, BATCH, 1) threadsPerThreadgroup:MTLSizeMake(TILE, TILE, 1)];
            [enc endEncoding];

            // Z1 += b1
            enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:biasAddPipe];
            [enc setBuffer:Z1 offset:0 atIndex:0];
            [enc setBuffer:b1 offset:0 atIndex:1];
            [enc setBytes:&hid_u length:4 atIndex:2];
            [enc dispatchThreads:MTLSizeMake(HIDDEN, BATCH, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
            [enc endEncoding];

            // A1 = relu(Z1)
            enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:reluPipe];
            [enc setBuffer:Z1 offset:0 atIndex:0];
            [enc setBuffer:A1 offset:0 atIndex:1];
            uint32_t relu_n = BATCH * HIDDEN;
            [enc dispatchThreads:MTLSizeMake(relu_n, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [enc endEncoding];

            // pred = A1 @ W2
            enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:matmulPipe];
            [enc setBuffer:A1 offset:0 atIndex:0];
            [enc setBuffer:W2 offset:0 atIndex:1];
            [enc setBuffer:pred offset:0 atIndex:2];
            [enc setBytes:&batch_u length:4 atIndex:3];
            [enc setBytes:&out_u length:4 atIndex:4];
            [enc setBytes:&hid_u length:4 atIndex:5];
            [enc dispatchThreads:MTLSizeMake(OUT_DIM, BATCH, 1) threadsPerThreadgroup:MTLSizeMake(MIN(OUT_DIM,(uint32_t)TILE), TILE, 1)];
            [enc endEncoding];

            // pred += b2
            enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:biasAddPipe];
            [enc setBuffer:pred offset:0 atIndex:0];
            [enc setBuffer:b2 offset:0 atIndex:1];
            [enc setBytes:&out_u length:4 atIndex:2];
            [enc dispatchThreads:MTLSizeMake(OUT_DIM, BATCH, 1) threadsPerThreadgroup:MTLSizeMake(OUT_DIM, MIN(BATCH,(uint32_t)256/OUT_DIM), 1)];
            [enc endEncoding];

            // ── LOSS (GPU compute, CPU reduce) ──
            enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:mseLossPipe];
            [enc setBuffer:pred offset:0 atIndex:0];
            [enc setBuffer:Y_batch offset:0 atIndex:1];
            [enc setBuffer:loss_buf offset:0 atIndex:2];
            uint32_t loss_n = BATCH * OUT_DIM;
            [enc dispatchThreads:MTLSizeMake(loss_n, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [enc endEncoding];

            // ── BACKWARD ──
            // d_out = (pred - target) * scale
            enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:mseGradPipe];
            [enc setBuffer:pred offset:0 atIndex:0];
            [enc setBuffer:Y_batch offset:0 atIndex:1];
            [enc setBuffer:d_out offset:0 atIndex:2];
            [enc setBytes:&mse_scale length:4 atIndex:3];
            [enc dispatchThreads:MTLSizeMake(loss_n, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [enc endEncoding];

            // dW2 = A1^T @ d_out  [HIDDEN x OUT_DIM]
            enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:matmulATBPipe];
            [enc setBuffer:A1 offset:0 atIndex:0];
            [enc setBuffer:d_out offset:0 atIndex:1];
            [enc setBuffer:dW2 offset:0 atIndex:2];
            [enc setBytes:&batch_u length:4 atIndex:3];
            [enc setBytes:&out_u length:4 atIndex:4];
            [enc setBytes:&hid_u length:4 atIndex:5];
            [enc dispatchThreads:MTLSizeMake(OUT_DIM, HIDDEN, 1) threadsPerThreadgroup:MTLSizeMake(MIN(OUT_DIM,(uint32_t)16), 16, 1)];
            [enc endEncoding];

            // db2 = sum_rows(d_out)
            enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:sumRowsPipe];
            [enc setBuffer:d_out offset:0 atIndex:0];
            [enc setBuffer:db2_buf offset:0 atIndex:1];
            [enc setBytes:&batch_u length:4 atIndex:2];
            [enc setBytes:&out_u length:4 atIndex:3];
            [enc dispatchThreads:MTLSizeMake(OUT_DIM, 1, 1) threadsPerThreadgroup:MTLSizeMake(OUT_DIM, 1, 1)];
            [enc endEncoding];

            // d_A1 = d_out @ W2^T  [BATCH x HIDDEN]
            enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:matmulABTPipe];
            [enc setBuffer:d_out offset:0 atIndex:0];
            [enc setBuffer:W2 offset:0 atIndex:1];
            [enc setBuffer:d_A1 offset:0 atIndex:2];
            [enc setBytes:&batch_u length:4 atIndex:3];
            [enc setBytes:&hid_u length:4 atIndex:4];
            [enc setBytes:&out_u length:4 atIndex:5];
            [enc dispatchThreads:MTLSizeMake(HIDDEN, BATCH, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
            [enc endEncoding];

            // d_A1 *= (Z1 > 0)
            enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:reluBkPipe];
            [enc setBuffer:d_A1 offset:0 atIndex:0];
            [enc setBuffer:Z1 offset:0 atIndex:1];
            [enc dispatchThreads:MTLSizeMake(relu_n, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [enc endEncoding];

            // dW1 = X^T @ d_A1  [IN_DIM x HIDDEN]
            enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:matmulATBPipe];
            [enc setBuffer:X_batch offset:0 atIndex:0];
            [enc setBuffer:d_A1 offset:0 atIndex:1];
            [enc setBuffer:dW1 offset:0 atIndex:2];
            [enc setBytes:&batch_u length:4 atIndex:3];
            [enc setBytes:&hid_u length:4 atIndex:4];
            [enc setBytes:&in_u length:4 atIndex:5];
            [enc dispatchThreads:MTLSizeMake(HIDDEN, IN_DIM, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
            [enc endEncoding];

            // db1 = sum_rows(d_A1)
            enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:sumRowsPipe];
            [enc setBuffer:d_A1 offset:0 atIndex:0];
            [enc setBuffer:db1 offset:0 atIndex:1];
            [enc setBytes:&batch_u length:4 atIndex:2];
            [enc setBytes:&hid_u length:4 atIndex:3];
            [enc dispatchThreads:MTLSizeMake(HIDDEN, 1, 1) threadsPerThreadgroup:MTLSizeMake(MIN(HIDDEN,(uint32_t)256), 1, 1)];
            [enc endEncoding];

            // ── SGD UPDATE ──
            enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:sgdPipe];
            [enc setBuffer:W1 offset:0 atIndex:0]; [enc setBuffer:dW1 offset:0 atIndex:1];
            [enc setBytes:&lr length:4 atIndex:2];
            uint32_t w1n = IN_DIM*HIDDEN;
            [enc dispatchThreads:MTLSizeMake(w1n,1,1) threadsPerThreadgroup:MTLSizeMake(256,1,1)];
            [enc endEncoding];

            enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:sgdPipe];
            [enc setBuffer:b1 offset:0 atIndex:0]; [enc setBuffer:db1 offset:0 atIndex:1];
            [enc setBytes:&lr length:4 atIndex:2];
            [enc dispatchThreads:MTLSizeMake(HIDDEN,1,1) threadsPerThreadgroup:MTLSizeMake(HIDDEN,1,1)];
            [enc endEncoding];

            enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:sgdPipe];
            [enc setBuffer:W2 offset:0 atIndex:0]; [enc setBuffer:dW2 offset:0 atIndex:1];
            [enc setBytes:&lr length:4 atIndex:2];
            uint32_t w2n = HIDDEN*OUT_DIM;
            [enc dispatchThreads:MTLSizeMake(w2n,1,1) threadsPerThreadgroup:MTLSizeMake(MIN(w2n,(uint32_t)256),1,1)];
            [enc endEncoding];

            enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:sgdPipe];
            [enc setBuffer:b2 offset:0 atIndex:0]; [enc setBuffer:db2_buf offset:0 atIndex:1];
            [enc setBytes:&lr length:4 atIndex:2];
            [enc dispatchThreads:MTLSizeMake(OUT_DIM,1,1) threadsPerThreadgroup:MTLSizeMake(OUT_DIM,1,1)];
            [enc endEncoding];

            [cmd commit];
            [cmd waitUntilCompleted];

            // Print loss (CPU reduce)
            if (step % 100 == 0) {
                float *lp = loss_buf.contents;
                float total = 0;
                for (int i = 0; i < BATCH*OUT_DIM; i++) total += lp[i];
                total /= (BATCH * OUT_DIM);
                printf("  step %d  loss=%.6f\n", step, total);
            }
        }

        // ── SAVE WEIGHTS ──
        {
            FILE *wf = fopen("/tmp/neural_mhd_weights.bin", "wb");
            // Header: in_dim, hidden, out_dim
            int dims[3] = {IN_DIM, HIDDEN, OUT_DIM};
            fwrite(dims, sizeof(int), 3, wf);
            // Weights and biases
            fwrite(W1.contents, sizeof(float), IN_DIM*HIDDEN, wf);
            fwrite(b1.contents, sizeof(float), HIDDEN, wf);
            fwrite(W2.contents, sizeof(float), HIDDEN*OUT_DIM, wf);
            fwrite(b2.contents, sizeof(float), OUT_DIM, wf);
            // Normalization stats
            fwrite(x_mean, sizeof(float), IN_DIM, wf);
            fwrite(x_std, sizeof(float), IN_DIM, wf);
            fwrite(y_mean, sizeof(float), OUT_DIM, wf);
            fwrite(y_std, sizeof(float), OUT_DIM, wf);
            fclose(wf);
            printf("Weights saved to /tmp/neural_mhd_weights.bin\n\n");
        }

        // ── CONSERVATION EVALUATION ──
        printf("\nConservation evaluation...\n");
        double *eval_s = calloc(STATE_SIZE, sizeof(double));
        double *eval_ns = calloc(STATE_SIZE, sizeof(double));
        init_state(eval_s);
        double dt = 0.2 * DX / max_speed(eval_s);
        lxf_step(eval_s, eval_ns, dt);

        double m0=0, e0=0, m_lxf=0, e_lxf=0;
        for (int i=0; i<NN2; i++) { m0+=eval_s[i]; e0+=eval_s[5*NN2+i]; m_lxf+=eval_ns[i]; e_lxf+=eval_ns[5*NN2+i]; }
        printf("  Initial:   mass=%.6f  energy=%.6f\n", m0, e0);
        printf("  LxF truth: mass=%.6f  energy=%.6f\n", m_lxf, e_lxf);

        // Neural prediction on full grid
        float stencil[IN_DIM];
        float *pp = pred.contents;
        double m_nn=0, e_nn=0;
        for (int i = 0; i < NN2; i++) {
            int x=i%NN, y=i/NN;
            extract_stencil(eval_s, x, y, stencil);
            // Normalize input
            for (int j=0; j<IN_DIM; j++) stencil[j] = (stencil[j]-x_mean[j])/x_std[j];
            float *w1c = W1.contents, *b1c = b1.contents;
            float *w2c = W2.contents, *b2c = b2.contents;
            float h[HIDDEN], out[OUT_DIM];
            for (int j=0; j<HIDDEN; j++) {
                float s = b1c[j];
                for (int k=0; k<IN_DIM; k++) s += stencil[k] * w1c[k*HIDDEN+j];
                h[j] = fmaxf(0, s);
            }
            for (int j=0; j<OUT_DIM; j++) {
                float s = b2c[j];
                for (int k=0; k<HIDDEN; k++) s += h[k] * w2c[k*OUT_DIM+j];
                out[j] = s;
            }
            // Denormalize and add residual
            m_nn += eval_s[0*NN2+i] + (double)(out[0]*y_std[0]+y_mean[0]);
            e_nn += eval_s[5*NN2+i] + (double)(out[5]*y_std[5]+y_mean[5]);
        }
        printf("  Neural:    mass=%.6f  energy=%.6f\n", m_nn, e_nn);
        printf("  Mass err:  LxF=%.2e  Neural=%.2e\n", (m_lxf-m0)/m0, (m_nn-m0)/m0);
        printf("  Energy err:LxF=%.2e  Neural=%.2e\n", (e_lxf-e0)/e0, (e_nn-e0)/e0);

        // ── NEURAL SIMULATION: run trained model as physics engine ──
        printf("\nNeural simulation (200 steps)...\n");
        system("mkdir -p /tmp/neural_mhd_frames");

        // Start from initial conditions
        double *sim_s = calloc(STATE_SIZE, sizeof(double));
        double *sim_ns = calloc(STATE_SIZE, sizeof(double));
        init_state(sim_s);

        // Also run LxF in parallel for comparison
        double *lxf_s = calloc(STATE_SIZE, sizeof(double));
        double *lxf_ns2 = calloc(STATE_SIZE, sizeof(double));
        init_state(lxf_s);

        float *w1c = W1.contents, *b1c = b1.contents;
        float *w2c = W2.contents, *b2c = b2.contents;

        for (int t = 0; t < 200; t++) {
            // Neural step: predict next state for each cell
            for (int i = 0; i < NN2; i++) {
                int x=i%NN, y=i/NN;
                float st[IN_DIM];
                extract_stencil(sim_s, x, y, st);
                // Normalize input
                for (int j=0; j<IN_DIM; j++) st[j] = (st[j]-x_mean[j])/x_std[j];
                float h[HIDDEN], out[OUT_DIM];
                for (int j=0; j<HIDDEN; j++) {
                    float v = b1c[j];
                    for (int k=0; k<IN_DIM; k++) v += st[k] * w1c[k*HIDDEN+j];
                    h[j] = fmaxf(0, v);
                }
                for (int j=0; j<OUT_DIM; j++) {
                    float v = b2c[j];
                    for (int k=0; k<HIDDEN; k++) v += h[k] * w2c[k*OUT_DIM+j];
                    // Denormalize output and add to current state (residual)
                    double delta = (double)(v * y_std[j] + y_mean[j]);
                    sim_ns[j*NN2+i] = sim_s[j*NN2+i] + delta;
                }
            }

            // LxF step for comparison
            double lxf_dt = 0.2 * DX / max_speed(lxf_s);
            lxf_step(lxf_s, lxf_ns2, lxf_dt);

            // Dump density frames every 10 steps
            if (t % 10 == 0) {
                char path_nn[256], path_lxf[256];
                snprintf(path_nn, 256, "/tmp/neural_mhd_frames/neural_%03d.dat", t);
                snprintf(path_lxf, 256, "/tmp/neural_mhd_frames/lxf_%03d.dat", t);
                FILE *fn = fopen(path_nn, "w");
                FILE *fl = fopen(path_lxf, "w");
                for (int y=0; y<NN; y++) {
                    for (int x=0; x<NN; x++) {
                        fprintf(fn, "%.6f%s", sim_ns[y*NN+x], x<NN-1?" ":"\n");
                        fprintf(fl, "%.6f%s", lxf_ns2[y*NN+x], x<NN-1?" ":"\n");
                    }
                }
                fclose(fn); fclose(fl);

                double nm=0, lm=0;
                for (int i=0; i<NN2; i++) { nm+=sim_ns[i]; lm+=lxf_ns2[i]; }
                printf("  t=%3d  neural_mass=%.2f  lxf_mass=%.2f\n", t, nm, lm);
            }

            // Clamp to physical ranges (prevents exponential divergence)
            for (int i = 0; i < NN2; i++) {
                sim_ns[0*NN2+i] = fmax(0.01, fmin(5.0, sim_ns[0*NN2+i]));   // density
                sim_ns[5*NN2+i] = fmax(0.1, fmin(50.0, sim_ns[5*NN2+i]));   // energy
                for (int f = 1; f < 5; f++)
                    sim_ns[f*NN2+i] = fmax(-10.0, fmin(10.0, sim_ns[f*NN2+i])); // momentum, B
            }

            // Swap
            double *tmp;
            tmp = sim_s; sim_s = sim_ns; sim_ns = tmp;
            tmp = lxf_s; lxf_s = lxf_ns2; lxf_ns2 = tmp;
        }

        printf("\nFrames saved to /tmp/neural_mhd_frames/\n");

        // Generate comparison visualization
        FILE *viz = fopen("/tmp/neural_mhd_viz.py", "w");
        fprintf(viz, "import numpy as np\nimport matplotlib.pyplot as plt\n");
        fprintf(viz, "fig, axes = plt.subplots(2, 5, figsize=(20,8))\n");
        fprintf(viz, "fig.suptitle('Neural MHD Surrogate vs Lax-Friedrichs', fontsize=16)\n");
        fprintf(viz, "for i, t in enumerate([0, 20, 50, 100, 190]):\n");
        fprintf(viz, "    nn = np.loadtxt(f'/tmp/neural_mhd_frames/neural_{t:03d}.dat')\n");
        fprintf(viz, "    lf = np.loadtxt(f'/tmp/neural_mhd_frames/lxf_{t:03d}.dat')\n");
        fprintf(viz, "    vmin, vmax = min(nn.min(), lf.min()), max(nn.max(), lf.max())\n");
        fprintf(viz, "    axes[0,i].imshow(nn, cmap='inferno', vmin=vmin, vmax=vmax)\n");
        fprintf(viz, "    axes[0,i].set_title(f'Neural t={t}')\n");
        fprintf(viz, "    axes[0,i].axis('off')\n");
        fprintf(viz, "    axes[1,i].imshow(lf, cmap='inferno', vmin=vmin, vmax=vmax)\n");
        fprintf(viz, "    axes[1,i].set_title(f'LxF t={t}')\n");
        fprintf(viz, "    axes[1,i].axis('off')\n");
        fprintf(viz, "plt.tight_layout()\nplt.savefig('/tmp/neural_vs_lxf.png', dpi=150)\n");
        fprintf(viz, "print('Saved /tmp/neural_vs_lxf.png')\nplt.show()\n");
        fclose(viz);

        printf("Run: python3 /tmp/neural_mhd_viz.py\n");

        free(X_all); free(Y_all); free(eval_s); free(eval_ns);
        free(sim_s); free(sim_ns); free(lxf_s); free(lxf_ns2);
        printf("\nDone.\n");
    }
    return 0;
}
