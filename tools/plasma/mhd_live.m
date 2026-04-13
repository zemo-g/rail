// mhd_live.m — Headless Metal compute for 2D axisymmetric MHD
// Writes downsampled frames to /tmp/plasma_live.bin for HTTP streaming.
// Reads control input from /tmp/plasma_ctrl.json.
//
// Build:
//   xcrun metal -c mhd_axisym.metal -o /tmp/mhd_axisym.air
//   xcrun metallib /tmp/mhd_axisym.air -o /tmp/mhd_axisym.metallib
//   clang -framework Metal -framework Foundation -framework CoreGraphics mhd_live.m -o mhd_live
//
// Run:
//   ./mhd_live    (writes /tmp/plasma_live.bin at ~30fps)

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include <unistd.h>
#include <sys/time.h>

#define NR 256
#define NZ 512
#define NCELLS (NR * NZ)
#define NFIELDS 5
#define DS 4
#define DSR (NR/DS)
#define DSZ (NZ/DS)
#define DS_CELLS (DSR * DSZ)
#define DS_FIELDS 6
#define GAMMA_F 1.6666666666666667f
#define GAMMA_M1_F 0.6666666666666667f
#define MU0_F 1.2566370614359172e-6f
#define KB_F 1.38064852e-23f
#define EV_F 1.602176634e-19f
#define AMU_F 1.66053906660e-27f

typedef struct __attribute__((packed)) {
    float dt, dr, dz, r_min, r_max, z_max;
    float I_arc, B_applied, mdot, m_ion;
    float gamma, gamma_m1;
    float inlet_rho, inlet_vz, inlet_p, inlet_T_eV;
    uint32_t nr, nz, ncells, pad;
} Params;

typedef struct {
    float rc, ra, L;         // geometry (m)
    float I, mdot, B;        // operating point (A, kg/s, T)
    float gas_mass;           // AMU
    float nozzle;             // throat position 0-1
    int   num_coils;
    float coil_z[8];          // coil positions (fraction of L)
    float coil_s[8];          // coil strengths (0-2)
} ControlInput;

// ═══════════════════════════════════════════════════════════

static double now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

static ControlInput default_control(void) {
    ControlInput c;
    c.rc = 0.005f; c.ra = 0.025f; c.L = 0.08f;
    c.I = 200; c.mdot = 10e-6f; c.B = 0.1f;
    c.gas_mass = 39.948f;
    c.nozzle = 0.5f;
    c.num_coils = 2;
    c.coil_z[0] = 0.3f; c.coil_s[0] = 1.0f;
    c.coil_z[1] = 0.6f; c.coil_s[1] = 0.7f;
    return c;
}

static ControlInput read_control(void) {
    ControlInput ctrl = default_control();
    NSData *data = [NSData dataWithContentsOfFile:@"/tmp/plasma_ctrl.json"];
    if (!data) return ctrl;

    NSError *err = nil;
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (!d) return ctrl;

    if (d[@"rc"])   ctrl.rc   = [d[@"rc"] floatValue];
    if (d[@"ra"])   ctrl.ra   = [d[@"ra"] floatValue];
    if (d[@"L"])    ctrl.L    = [d[@"L"] floatValue];
    if (d[@"I"])    ctrl.I    = [d[@"I"] floatValue];
    if (d[@"mdot"]) ctrl.mdot = [d[@"mdot"] floatValue];
    if (d[@"B"])    ctrl.B    = [d[@"B"] floatValue];
    if (d[@"gas_mass"]) ctrl.gas_mass = [d[@"gas_mass"] floatValue];
    if (d[@"nozzle"])   ctrl.nozzle   = [d[@"nozzle"] floatValue];

    NSArray *coils = d[@"coils"];
    if (coils && [coils count] > 0) {
        ctrl.num_coils = (int)MIN([coils count], 8);
        for (int i = 0; i < ctrl.num_coils; i++) {
            NSDictionary *c = coils[i];
            ctrl.coil_z[i] = [c[@"z"] floatValue];
            ctrl.coil_s[i] = [c[@"s"] floatValue];
        }
    }
    return ctrl;
}

// Compute applied B-field from coils (host-side, written to GPU buffer)
static void compute_applied_field(float *Bz_buf, float *Br_buf, ControlInput ctrl) {
    float dr = (ctrl.ra - ctrl.rc) / NR;
    float dz = ctrl.L / NZ;

    for (uint32_t j = 0; j < NR; j++) {
        float r = ctrl.rc + (j + 0.5f) * dr;
        float r_norm = (float)j / (NR - 1);
        for (uint32_t i = 0; i < NZ; i++) {
            float z = (i + 0.5f) * dz;
            uint32_t k = j * NZ + i;

            float bz = 0, br = 0;
            for (int ci = 0; ci < ctrl.num_coils; ci++) {
                float zc = ctrl.coil_z[ci] * ctrl.L;
                float s = ctrl.coil_s[ci] * ctrl.B;
                float sigma_z = 0.08f * ctrl.L;
                float dz_c = z - zc;
                float gauss = expf(-dz_c * dz_c / (2 * sigma_z * sigma_z));

                // Axial field (dominant inside solenoid)
                bz += s * gauss * (1.0f - 0.3f * r_norm * r_norm);
                // Radial field (from field divergence ∇·B=0 correction)
                br += -s * gauss * dz_c / (sigma_z * sigma_z) * r * 0.15f;
            }
            Bz_buf[k] = bz;
            Br_buf[k] = br;
        }
    }
}

// Initialize MHD state for MPD thruster
static void init_state(float *state, ControlInput ctrl) {
    float dr = (ctrl.ra - ctrl.rc) / NR;
    float dz = ctrl.L / NZ;
    float m_ion = ctrl.gas_mass * AMU_F;
    float T_eV = 2.0f; // initial temperature estimate
    float T_K = T_eV * EV_F / KB_F;

    // Inlet conditions from mass flow
    float A = M_PI * (ctrl.ra * ctrl.ra - ctrl.rc * ctrl.rc);
    float v_inlet = 500.0f; // m/s initial guess
    float rho_inlet = ctrl.mdot / (v_inlet * A);
    float p_inlet = rho_inlet * KB_F * T_K / m_ion;

    for (uint32_t j = 0; j < NR; j++) {
        float r = ctrl.rc + (j + 0.5f) * dr;
        for (uint32_t i = 0; i < NZ; i++) {
            uint32_t k = j * NZ + i;
            float zf = (float)i / NZ;

            float rho = rho_inlet * (1.0f - 0.3f * zf); // decreasing density
            float vz = v_inlet * (1.0f + 2.0f * zf);     // accelerating flow
            float vr = 0;
            float p = p_inlet * (1.0f - 0.4f * zf);      // expanding

            // Self-field Bθ from arc current
            float I_enc = ctrl.I * (r*r - ctrl.rc*ctrl.rc) / (ctrl.ra*ctrl.ra - ctrl.rc*ctrl.rc);
            float bt = MU0_F * I_enc / (2 * M_PI * r);

            float ke = 0.5f * rho * (vr*vr + vz*vz);
            float me = 0.5f * bt * bt / MU0_F;
            float e = p / GAMMA_M1_F + ke + me;

            state[0*NCELLS + k] = rho;
            state[1*NCELLS + k] = rho * vr;
            state[2*NCELLS + k] = rho * vz;
            state[3*NCELLS + k] = e;
            state[4*NCELLS + k] = bt;
        }
    }
}

// Write frame header + data to /tmp/plasma_live.bin
// Format: [uint32 DSR][uint32 DSZ][uint32 nfields][uint32 frame_id][float32 metrics×8][float32 data×6×DSR×DSZ]
static void write_frame(float *ds_data, uint32_t frame_id, Params p, float sim_time) {
    FILE *f = fopen("/tmp/plasma_live.bin", "wb");
    if (!f) return;

    uint32_t header[4] = { DSR, DSZ, DS_FIELDS, frame_id };
    fwrite(header, sizeof(uint32_t), 4, f);

    // Metrics: [thrust_mN, ISP, ve, P_watts, eff%, T_eV, sim_time, 0]
    // Compute thrust from exit momentum flux
    // (simplified — integrate ρ·vz² over exit plane from downsampled data)
    float thrust = 0, mdot_exit = 0;
    for (uint32_t dj = 0; dj < DSR; dj++) {
        float vz = ds_data[4 * DS_CELLS + dj * DSZ + (DSZ-1)]; // exit vz
        float rho = ds_data[0 * DS_CELLS + dj * DSZ + (DSZ-1)]; // exit rho
        float r = p.r_min + (dj * DS + DS/2 + 0.5f) * p.dr;
        float dA = 2 * M_PI * r * p.dr * DS;
        thrust += rho * vz * vz * dA;
        mdot_exit += rho * vz * dA;
    }
    float ve = (mdot_exit > 0) ? thrust / mdot_exit : 0;
    float ISP = ve / 9.80665f;
    float V_arc = 20 + p.I_arc * p.z_max / (8000 * M_PI * (p.r_max*p.r_max - p.r_min*p.r_min));
    float P_w = V_arc * p.I_arc;
    float eff = (mdot_exit > 0 && P_w > 0) ? thrust * thrust / (2 * mdot_exit * P_w) * 100 : 0;

    float metrics[8] = {
        thrust * 1000,  // mN
        ISP,
        ve / 1000,      // km/s
        P_w,
        fminf(eff, 99),
        sim_time,
        p.I_arc,
        p.mdot * 1e6f   // mg/s
    };
    fwrite(metrics, sizeof(float), 8, f);

    // Field data
    fwrite(ds_data, sizeof(float), DS_FIELDS * DS_CELLS, f);
    fclose(f);
}

// ═══════════════════════════════════════════════════════════
// MAIN
// ═══════════════════════════════════════════════════════════

int main(int argc, char *argv[]) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { NSLog(@"No Metal device"); return 1; }
        NSLog(@"Metal device: %@", device.name);

        // Compile shader
        NSLog(@"Compiling mhd_axisym.metal...");
        int rc = system("xcrun metal -c /Users/ledaticempire/projects/rail/tools/plasma/mhd_axisym.metal -o /tmp/mhd_axisym.air 2>&1");
        if (rc != 0) { NSLog(@"metal compile failed"); return 1; }
        rc = system("xcrun metallib /tmp/mhd_axisym.air -o /tmp/mhd_axisym.metallib 2>&1");
        if (rc != 0) { NSLog(@"metallib failed"); return 1; }

        NSError *err = nil;
        id<MTLLibrary> lib = [device newLibraryWithURL:
            [NSURL fileURLWithPath:@"/tmp/mhd_axisym.metallib"] error:&err];
        if (!lib) { NSLog(@"Library: %@", err); return 1; }

        id<MTLComputePipelineState> stepPipe = [device newComputePipelineStateWithFunction:
            [lib newFunctionWithName:@"mhd2d_step"] error:&err];
        if (!stepPipe) { NSLog(@"step pipe: %@", err); return 1; }

        id<MTLComputePipelineState> dsPipe = [device newComputePipelineStateWithFunction:
            [lib newFunctionWithName:@"downsample"] error:&err];
        if (!dsPipe) { NSLog(@"ds pipe: %@", err); return 1; }

        id<MTLCommandQueue> queue = [device newCommandQueue];

        // Allocate buffers
        NSUInteger stateSz = NFIELDS * NCELLS * sizeof(float);
        NSUInteger fieldSz = NCELLS * sizeof(float);
        NSUInteger dsSz = DS_FIELDS * DS_CELLS * sizeof(float);

        id<MTLBuffer> stateA = [device newBufferWithLength:stateSz options:MTLResourceStorageModeShared];
        id<MTLBuffer> stateB = [device newBufferWithLength:stateSz options:MTLResourceStorageModeShared];
        id<MTLBuffer> BzBuf  = [device newBufferWithLength:fieldSz options:MTLResourceStorageModeShared];
        id<MTLBuffer> BrBuf  = [device newBufferWithLength:fieldSz options:MTLResourceStorageModeShared];
        id<MTLBuffer> dsBuf  = [device newBufferWithLength:dsSz options:MTLResourceStorageModeShared];

        // Initialize
        ControlInput ctrl = read_control();
        init_state((float*)stateA.contents, ctrl);
        compute_applied_field((float*)BzBuf.contents, (float*)BrBuf.contents, ctrl);

        BOOL useA = YES;
        float sim_time = 0;
        uint32_t frame_id = 0;
        uint32_t ctrl_check = 0;

        // Compute initial CFL timestep
        float dr = (ctrl.ra - ctrl.rc) / NR;
        float dz = ctrl.L / NZ;
        float m_ion = ctrl.gas_mass * AMU_F;
        // Sound speed from initial T_eV: cs = sqrt(gamma * T_eV * eV / m_ion)
        float T_eV_init = 2.0f;
        float cs = sqrtf(GAMMA_F * T_eV_init * EV_F / m_ion);
        // Alfven speed from peak self-field: Bθ ~ μ₀I/(2πr_mid)
        float r_mid = 0.5f * (ctrl.rc + ctrl.ra);
        float Bt_peak = MU0_F * ctrl.I / (2 * M_PI * r_mid);
        float rho_init = ctrl.mdot / (500.0f * M_PI * (ctrl.ra*ctrl.ra - ctrl.rc*ctrl.rc));
        float va = Bt_peak / sqrtf(MU0_F * rho_init);
        float dt = 0.1f * fminf(dr, dz) / (500.0f + cs + va); // CFL = 0.1 (conservative)
        dt = fminf(dt, 5e-8f); // hard ceiling

        NSLog(@"Starting MHD live compute. NR=%d NZ=%d dt=%.2e", NR, NZ, dt);
        NSLog(@"Geometry: rc=%.1fmm ra=%.1fmm L=%.0fmm I=%.0fA B=%.3fT",
              ctrl.rc*1000, ctrl.ra*1000, ctrl.L*1000, ctrl.I, ctrl.B);
        NSLog(@"Streaming to /tmp/plasma_live.bin (DSR=%d DSZ=%d)", DSR, DSZ);

        int steps_per_frame = 20; // 20 MHD steps per rendered frame

        while (1) {
            double t0 = now_ms();

            // Check for control input updates every 30 frames
            if (++ctrl_check >= 30) {
                ctrl_check = 0;
                ControlInput new_ctrl = read_control();
                // Check if params changed
                if (new_ctrl.I != ctrl.I || new_ctrl.B != ctrl.B ||
                    new_ctrl.mdot != ctrl.mdot || new_ctrl.rc != ctrl.rc ||
                    new_ctrl.ra != ctrl.ra || new_ctrl.L != ctrl.L ||
                    new_ctrl.gas_mass != ctrl.gas_mass) {
                    ctrl = new_ctrl;
                    dr = (ctrl.ra - ctrl.rc) / NR;
                    dz = ctrl.L / NZ;
                    m_ion = ctrl.gas_mass * AMU_F;
                    compute_applied_field((float*)BzBuf.contents, (float*)BrBuf.contents, ctrl);
                    init_state((float*)(useA ? stateA : stateB).contents, ctrl);
                    sim_time = 0;
                    NSLog(@"Config updated: I=%.0fA B=%.3fT mdot=%.1fmg/s",
                          ctrl.I, ctrl.B, ctrl.mdot*1e6);
                }
            }

            // Build params
            float A_inlet = M_PI * (ctrl.ra*ctrl.ra - ctrl.rc*ctrl.rc);
            float v_inlet = 500.0f;
            float rho_inlet = ctrl.mdot / (v_inlet * A_inlet);
            float T_eV = 2.0f;
            float p_inlet = rho_inlet * KB_F * (T_eV * EV_F / KB_F) / m_ion;

            Params params = {
                .dt = dt, .dr = dr, .dz = dz,
                .r_min = ctrl.rc, .r_max = ctrl.ra, .z_max = ctrl.L,
                .I_arc = ctrl.I, .B_applied = ctrl.B, .mdot = ctrl.mdot,
                .m_ion = m_ion,
                .gamma = GAMMA_F, .gamma_m1 = GAMMA_M1_F,
                .inlet_rho = rho_inlet, .inlet_vz = v_inlet,
                .inlet_p = p_inlet, .inlet_T_eV = T_eV,
                .nr = NR, .nz = NZ, .ncells = NCELLS, .pad = 0
            };

            // MHD timesteps
            id<MTLCommandBuffer> cmd = [queue commandBuffer];
            for (int s = 0; s < steps_per_frame; s++) {
                id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
                [enc setComputePipelineState:stepPipe];
                [enc setBuffer:(useA ? stateA : stateB) offset:0 atIndex:0];
                [enc setBuffer:(useA ? stateB : stateA) offset:0 atIndex:1];
                [enc setBuffer:BzBuf offset:0 atIndex:2];
                [enc setBuffer:BrBuf offset:0 atIndex:3];
                [enc setBytes:&params length:sizeof(params) atIndex:4];
                [enc dispatchThreads:MTLSizeMake(NR, NZ, 1)
                    threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
                [enc endEncoding];
                useA = !useA;
                sim_time += dt;
            }

            // Downsample for streaming
            id<MTLBuffer> curState = useA ? stateA : stateB;
            {
                id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
                [enc setComputePipelineState:dsPipe];
                [enc setBuffer:curState offset:0 atIndex:0];
                [enc setBuffer:BzBuf offset:0 atIndex:1];
                [enc setBuffer:dsBuf offset:0 atIndex:2];
                [enc setBytes:&params length:sizeof(params) atIndex:3];
                [enc dispatchThreads:MTLSizeMake(DSR, DSZ, 1)
                    threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
                [enc endEncoding];
            }

            [cmd commit];
            [cmd waitUntilCompleted];

            // Write frame
            write_frame((float*)dsBuf.contents, frame_id++, params, sim_time);

            // Adaptive CFL: compute max wave speed from downsampled data
            float *ds = (float*)dsBuf.contents;
            float smax = 1000; // minimum floor
            BOOL has_nan = NO;
            for (uint32_t dk = 0; dk < DS_CELLS; dk++) {
                float rho_k = ds[0 * DS_CELLS + dk];
                float T_eV_k = ds[1 * DS_CELLS + dk];
                float vmag = ds[2 * DS_CELLS + dk];
                float Bmag = ds[3 * DS_CELLS + dk];
                // NaN check
                if (isnan(vmag) || isnan(rho_k) || isnan(Bmag)) { has_nan = YES; continue; }
                // Sound speed from actual temperature
                float cs_k = sqrtf(GAMMA_F * fmaxf(T_eV_k, 0.1f) * EV_F / m_ion);
                float va_k = Bmag / sqrtf(MU0_F * fmaxf(rho_k, 1e-10f));
                float s = fminf(vmag, 1e6f) + cs_k + va_k;
                if (s > smax && s < 1e8f) smax = s;
            }
            // If NaN detected, reinitialize
            if (has_nan) {
                NSLog(@"NaN detected — reinitializing state");
                init_state((float*)(useA ? stateA : stateB).contents, ctrl);
                sim_time = 0;
                // Reset to conservative dt
                dt = 0.05f * fminf(dr, dz) / (500.0f + cs + va);
                dt = fminf(dt, 1e-8f);
            } else {
                dt = 0.1f * fminf(dr, dz) / smax; // CFL = 0.1
                dt = fminf(dt, 5e-8f);  // hard ceiling
                dt = fmaxf(dt, 1e-10f);
            }

            double elapsed = now_ms() - t0;
            // Target ~33ms per frame (30fps)
            if (elapsed < 33) usleep((uint32_t)((33 - elapsed) * 1000));

            if (frame_id % 60 == 0) {
                NSLog(@"Frame %u  t=%.3es  dt=%.2e  %.1fms/frame",
                      frame_id, sim_time, dt, elapsed);
            }
        }
    }
    return 0;
}
