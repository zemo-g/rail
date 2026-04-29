// mhd_ot_2d_256_host.m — host driver for the 256² OT MHD Metal kernel.
//
// Initializes Orszag-Tang vortex (canonical IC: ρ₀=25/(36π), p₀=5/(12π),
// v=(-sin y, sin x), B=(-sin y, sin 2x)/√(4π)), runs LF on Metal, and
// every STEPS_PER_FRAME steps writes /tmp/plasma_ot256.bin in the same
// 16-byte-header + 32-byte-metrics + planes layout the existing 128²
// beacon uses — so the same viewer / frame_attest_publisher pattern
// works unmodified at 256².
//
// Build:
//   xcrun metal -c mhd_ot_2d_256.metal -o /tmp/mhd_ot_2d_256.air
//   xcrun metallib /tmp/mhd_ot_2d_256.air -o /tmp/mhd_ot_2d_256.metallib
//   clang -framework Metal -framework Foundation -fobjc-arc \
//     mhd_ot_2d_256_host.m -o /tmp/mhd_ot_2d_256
//
// Run:
//   /tmp/mhd_ot_2d_256                 # writes /tmp/plasma_ot256.bin
//   OT256_OUT=/tmp/foo.bin /tmp/mhd_ot_2d_256

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/time.h>

#define N 256
#define NN (N*N)
#define GAMMA 1.6666666666666667
#define L 6.283185307179586
#define DX (L / (double)N)
#define CFL 0.3
#define STEPS_PER_FRAME 4
#define T_RESET 3.141592653589793
#define RHO_FLOOR 1e-6
#define P_FLOOR 1e-6

static double now_s(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec * 1e-6;
}

static void init_ot(float *U /* host-side, 6*NN floats */) {
    const double rho0 = 25.0 / (36.0 * M_PI);
    const double p0   = 5.0  / (12.0 * M_PI);
    const double Bn   = 1.0 / sqrt(4.0 * M_PI);
    for (int j = 0; j < N; ++j) {
        for (int i = 0; i < N; ++i) {
            double x = (double)i * DX;
            double y = (double)j * DX;
            double rho = rho0;
            double vx  = -sin(y);
            double vy  =  sin(x);
            double Bx  = -sin(y) * Bn;
            double By  =  sin(2.0 * x) * Bn;
            double v2  = vx*vx + vy*vy;
            double b2  = Bx*Bx + By*By;
            double E   = p0 / (GAMMA - 1.0) + 0.5 * rho * v2 + 0.5 * b2;
            int k = j * N + i;
            U[0*NN + k] = (float)rho;
            U[1*NN + k] = (float)(rho * vx);
            U[2*NN + k] = (float)(rho * vy);
            U[3*NN + k] = (float)E;
            U[4*NN + k] = (float)Bx;
            U[5*NN + k] = (float)By;
        }
    }
}

static double total_mass(const float *U) {
    double s = 0.0;
    for (int k = 0; k < NN; ++k) s += U[0*NN + k];
    return s * DX * DX;
}
static double total_energy(const float *U) {
    double s = 0.0;
    for (int k = 0; k < NN; ++k) s += U[3*NN + k];
    return s * DX * DX;
}
static double max_divb(const float *U) {
    double mx = 0.0;
    const float *Bx = U + 4*NN;
    const float *By = U + 5*NN;
    for (int j = 0; j < N; ++j) {
        for (int i = 0; i < N; ++i) {
            int ip = (i+1)%N, im = (i+N-1)%N;
            int jp = (j+1)%N, jm = (j+N-1)%N;
            double dBx = ((double)Bx[j*N+ip] - (double)Bx[j*N+im]) / (2.0 * DX);
            double dBy = ((double)By[jp*N+i] - (double)By[jm*N+i]) / (2.0 * DX);
            double d = fabs(dBx + dBy);
            if (d > mx) mx = d;
        }
    }
    return mx;
}
static double min_rho(const float *U) {
    double m = U[0];
    for (int k = 1; k < NN; ++k) if (U[k] < m) m = U[k];
    return m;
}

static void write_frame(const char *out_path, uint32_t frame_id,
                        const float *U, double sim_time, double dt,
                        double m0, double e0)
{
    char tmp_path[512];
    snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", out_path);
    FILE *f = fopen(tmp_path, "wb");
    if (!f) { perror("fopen"); return; }

    // Convert conservatives → primitives (ρ, vx, vy, p, Bx, By) for the
    // planes (mirrors the existing beacon binary format).
    static float planes[6 * NN];
    for (int k = 0; k < NN; ++k) {
        double rho = fmax((double)U[0*NN+k], RHO_FLOOR);
        double mx  = (double)U[1*NN + k];
        double my  = (double)U[2*NN + k];
        double E   = (double)U[3*NN + k];
        double Bx  = (double)U[4*NN + k];
        double By  = (double)U[5*NN + k];
        double vx  = mx / rho;
        double vy  = my / rho;
        double v2  = vx*vx + vy*vy;
        double b2  = Bx*Bx + By*By;
        double p   = fmax((GAMMA - 1.0)*(E - 0.5*rho*v2 - 0.5*b2), P_FLOOR);
        planes[0*NN + k] = (float)rho;
        planes[1*NN + k] = (float)vx;
        planes[2*NN + k] = (float)vy;
        planes[3*NN + k] = (float)p;
        planes[4*NN + k] = (float)Bx;
        planes[5*NN + k] = (float)By;
    }

    uint32_t header[4] = { N, N, 6, frame_id };
    fwrite(header, sizeof(header), 1, f);

    float metrics[8];
    metrics[0] = (float)total_mass(U);
    metrics[1] = (float)total_energy(U);
    metrics[2] = (float)max_divb(U);
    metrics[3] = (float)min_rho(U);
    metrics[4] = (float)dt;
    metrics[5] = (float)sim_time;
    metrics[6] = (float)m0;
    metrics[7] = (float)e0;
    fwrite(metrics, sizeof(metrics), 1, f);

    fwrite(planes, sizeof(planes), 1, f);
    fclose(f);
    rename(tmp_path, out_path);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *out_path = getenv("OT256_OUT");
        if (!out_path) out_path = "/tmp/plasma_ot256.bin";

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr, "no Metal device\n"); return 1; }
        NSError *err = nil;

        // Build metallib if missing — same pattern as tools/metal/tensor_gpu.m.
        const char *self_dir = "/Users/user/projects/rail/tools/plasma";
        char build_cmd[1024];
        snprintf(build_cmd, sizeof(build_cmd),
                 "test -f /tmp/mhd_ot_2d_256.metallib || "
                 "(xcrun metal -c %s/mhd_ot_2d_256.metal -o /tmp/mhd_ot_2d_256.air "
                 "&& xcrun metallib /tmp/mhd_ot_2d_256.air -o /tmp/mhd_ot_2d_256.metallib)",
                 self_dir);
        (void)system(build_cmd);

        id<MTLLibrary> lib = [device newLibraryWithURL:
            [NSURL fileURLWithPath:@"/tmp/mhd_ot_2d_256.metallib"] error:&err];
        if (!lib) { fprintf(stderr, "metallib: %s\n", [[err description] UTF8String]); return 1; }

        id<MTLFunction> f_flux = [lib newFunctionWithName:@"compute_fluxes"];
        id<MTLFunction> f_step = [lib newFunctionWithName:@"lf_step"];
        id<MTLFunction> f_wave = [lib newFunctionWithName:@"wavespeed"];
        if (!f_flux || !f_step || !f_wave) { fprintf(stderr, "missing kernel\n"); return 1; }

        id<MTLComputePipelineState> p_flux = [device newComputePipelineStateWithFunction:f_flux error:&err];
        id<MTLComputePipelineState> p_step = [device newComputePipelineStateWithFunction:f_step error:&err];
        id<MTLComputePipelineState> p_wave = [device newComputePipelineStateWithFunction:f_wave error:&err];

        id<MTLCommandQueue> queue = [device newCommandQueue];

        size_t buf_bytes = 6 * NN * sizeof(float);
        id<MTLBuffer> bU_a = [device newBufferWithLength:buf_bytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> bU_b = [device newBufferWithLength:buf_bytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> bFx  = [device newBufferWithLength:buf_bytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> bFy  = [device newBufferWithLength:buf_bytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> bWS  = [device newBufferWithLength:NN * sizeof(float) options:MTLResourceStorageModeShared];

        float *U_host = bU_a.contents;
        init_ot(U_host);
        double m0 = total_mass(U_host);
        double e0 = total_energy(U_host);
        fprintf(stderr, "init: m0=%.6e e0=%.6e divB=%.3e\n", m0, e0, max_divb(U_host));

        double sim_time = 0.0;
        uint32_t frame_id = 0;
        id<MTLBuffer> in = bU_a, out = bU_b;
        double t_start = now_s();

        for (;;) {
            // Compute CFL-adapted dt from current state (download wavespeed buffer).
            {
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                [enc setComputePipelineState:p_wave];
                [enc setBuffer:in offset:0 atIndex:0];
                [enc setBuffer:bWS offset:0 atIndex:1];
                [enc dispatchThreadgroups:MTLSizeMake((N+15)/16, (N+15)/16, 1)
                    threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
                [enc endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
            }
            float *ws = bWS.contents;
            float vmax = 0.0f;
            for (int k = 0; k < NN; ++k) if (ws[k] > vmax) vmax = ws[k];
            double dt = CFL * DX / fmax((double)vmax, 1e-3);

            for (int s = 0; s < STEPS_PER_FRAME; ++s) {
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                {
                    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                    [enc setComputePipelineState:p_flux];
                    [enc setBuffer:in offset:0 atIndex:0];
                    [enc setBuffer:bFx offset:0 atIndex:1];
                    [enc setBuffer:bFy offset:0 atIndex:2];
                    [enc dispatchThreadgroups:MTLSizeMake((N+15)/16, (N+15)/16, 1)
                        threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
                    [enc endEncoding];
                }
                {
                    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                    [enc setComputePipelineState:p_step];
                    [enc setBuffer:in offset:0 atIndex:0];
                    [enc setBuffer:bFx offset:0 atIndex:1];
                    [enc setBuffer:bFy offset:0 atIndex:2];
                    [enc setBuffer:out offset:0 atIndex:3];
                    float dt_f = (float)dt;
                    [enc setBytes:&dt_f length:sizeof(float) atIndex:4];
                    [enc dispatchThreadgroups:MTLSizeMake((N+15)/16, (N+15)/16, 1)
                        threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
                    [enc endEncoding];
                }
                [cb commit];
                [cb waitUntilCompleted];
                id<MTLBuffer> tmp = in; in = out; out = tmp;
                sim_time += dt;
            }

            float *U_now = in.contents;
            // Sanity check — NaN or sim_time overrun → reset to OT IC.
            int bad = 0;
            for (int c = 0; c < 6 && !bad; ++c) {
                for (int k = 0; k < NN; ++k) {
                    if (!isfinite(U_now[c*NN + k])) { bad = 1; break; }
                }
            }
            if (bad || sim_time > T_RESET) {
                init_ot(U_now);
                sim_time = 0.0;
                fprintf(stderr, "reset (bad=%d t=%.3f)\n", bad, sim_time);
            }

            write_frame(out_path, frame_id, U_now, sim_time, dt, m0, e0);
            if ((frame_id % 50) == 0) {
                double now = now_s();
                double fps = frame_id > 0 ? (double)frame_id / (now - t_start) : 0.0;
                fprintf(stderr, "frame=%u t=%.4f dt=%.3e m=%.6e e=%.6e divB=%.3e fps=%.2f\n",
                        frame_id, sim_time, dt,
                        total_mass(U_now), total_energy(U_now),
                        max_divb(U_now), fps);
            }
            frame_id++;
        }
        return 0;
    }
}
