// mhd_ot_2d_256.metal — 2D ideal-MHD Orszag-Tang on Metal GPU
//
// Two-pass Lax-Friedrichs step on a 256² periodic grid, 6 conservative
// fields (ρ, ρv_x, ρv_y, E, B_x, B_y).  Pass 1 computes physical fluxes
// at every cell; pass 2 applies the LF update using the precomputed
// fluxes.  All single-precision (f32) — conservation will hold to ~1e-7
// rather than f64's ~1e-15, which is acceptable for a research-grade
// surface.
//
// Build:
//   xcrun metal -c mhd_ot_2d_256.metal -o /tmp/mhd_ot_2d_256.air
//   xcrun metallib /tmp/mhd_ot_2d_256.air -o /tmp/mhd_ot_2d_256.metallib

#include <metal_stdlib>
using namespace metal;

#define N 256u
#define NN 65536u
#define GAMMA       1.6666667f
#define L_DOMAIN    6.2831853f
#define DX_DOMAIN   (L_DOMAIN / float(N))
#define RHO_FLOOR   1e-6f
#define P_FLOOR     1e-6f

inline uint idx2(uint i, uint j) { return j * N + i; }

// Pass 1: read conservatives at this cell, compute primitives + Fx + Fy,
// write 12 floats per cell (6 components × 2 directions).
kernel void compute_fluxes(
    device const float *U  [[buffer(0)]],   // 6*NN
    device float *Fx       [[buffer(1)]],   // 6*NN
    device float *Fy       [[buffer(2)]],   // 6*NN
    uint2 gid              [[thread_position_in_grid]])
{
    if (gid.x >= N || gid.y >= N) return;
    uint k = idx2(gid.x, gid.y);

    float rho = U[0u*NN + k];
    float mx  = U[1u*NN + k];
    float my  = U[2u*NN + k];
    float E   = U[3u*NN + k];
    float Bx  = U[4u*NN + k];
    float By  = U[5u*NN + k];

    rho = fmax(rho, RHO_FLOOR);
    float vx = mx / rho;
    float vy = my / rho;
    float b2 = Bx*Bx + By*By;
    float v2 = vx*vx + vy*vy;
    float p  = fmax((GAMMA - 1.0f) * (E - 0.5f*rho*v2 - 0.5f*b2), P_FLOOR);
    float pt = p + 0.5f * b2;
    float vdotb = vx*Bx + vy*By;

    Fx[0u*NN + k] = rho * vx;
    Fx[1u*NN + k] = rho * vx * vx + pt - Bx * Bx;
    Fx[2u*NN + k] = rho * vx * vy - Bx * By;
    Fx[3u*NN + k] = (E + pt) * vx - Bx * vdotb;
    Fx[4u*NN + k] = 0.0f;
    Fx[5u*NN + k] = vx * By - vy * Bx;

    Fy[0u*NN + k] = rho * vy;
    Fy[1u*NN + k] = rho * vy * vx - Bx * By;
    Fy[2u*NN + k] = rho * vy * vy + pt - By * By;
    Fy[3u*NN + k] = (E + pt) * vy - By * vdotb;
    Fy[4u*NN + k] = vy * Bx - vx * By;
    Fy[5u*NN + k] = 0.0f;
}

// Pass 2: LF update using already-computed neighbor fluxes.
//   U_new = 0.25 * (U[ip,j] + U[im,j] + U[i,jp] + U[i,jm])
//         - 0.5 * (dt/dx) * (Fx[ip,j] - Fx[im,j])
//         - 0.5 * (dt/dx) * (Fy[i,jp] - Fy[i,jm])
kernel void lf_step(
    device const float *U_in [[buffer(0)]],
    device const float *Fx   [[buffer(1)]],
    device const float *Fy   [[buffer(2)]],
    device float *U_out      [[buffer(3)]],
    constant float &dt       [[buffer(4)]],
    uint2 gid                [[thread_position_in_grid]])
{
    if (gid.x >= N || gid.y >= N) return;
    uint i = gid.x, j = gid.y;
    uint ip = (i + 1u) % N;
    uint im = (i + N - 1u) % N;
    uint jp = (j + 1u) % N;
    uint jm = (j + N - 1u) % N;
    float lam = dt / DX_DOMAIN;

    for (uint c = 0u; c < 6u; ++c) {
        uint base = c * NN;
        float u_ip = U_in[base + idx2(ip, j)];
        float u_im = U_in[base + idx2(im, j)];
        float u_jp = U_in[base + idx2(i, jp)];
        float u_jm = U_in[base + idx2(i, jm)];
        float fx_ip = Fx[base + idx2(ip, j)];
        float fx_im = Fx[base + idx2(im, j)];
        float fy_jp = Fy[base + idx2(i, jp)];
        float fy_jm = Fy[base + idx2(i, jm)];
        float avg = 0.25f * (u_ip + u_im + u_jp + u_jm);
        U_out[base + idx2(i, j)] =
            avg - 0.5f * lam * (fx_ip - fx_im)
                - 0.5f * lam * (fy_jp - fy_jm);
    }
}

// Reduction helper: max wave speed over the grid (one threadgroup reduces).
// Used to compute CFL-adapted dt on the host every frame.  We dump the per-
// cell wavespeed and the host reduces in numpy-style on a downloaded buffer
// (cheap, 256 KB at f32).
kernel void wavespeed(
    device const float *U  [[buffer(0)]],
    device float *out      [[buffer(1)]],
    uint2 gid              [[thread_position_in_grid]])
{
    if (gid.x >= N || gid.y >= N) return;
    uint k = idx2(gid.x, gid.y);
    float rho = fmax(U[0u*NN + k], RHO_FLOOR);
    float mx  = U[1u*NN + k];
    float my  = U[2u*NN + k];
    float E   = U[3u*NN + k];
    float Bx  = U[4u*NN + k];
    float By  = U[5u*NN + k];
    float vx = mx / rho, vy = my / rho;
    float v2 = vx*vx + vy*vy;
    float b2 = Bx*Bx + By*By;
    float p = fmax((GAMMA - 1.0f) * (E - 0.5f*rho*v2 - 0.5f*b2), P_FLOOR);
    float a2 = GAMMA * p / rho;
    float ca2 = b2 / rho;
    float cf = sqrt(a2 + ca2);
    out[k] = sqrt(v2) + cf;
}
