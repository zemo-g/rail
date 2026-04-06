// plasma_3d.metal — 3D MHD compute + volume raymarcher
// 128³ grid, 8 conserved MHD fields, Lax-Friedrichs scheme
// Launched from Rail via plasma_3d.rail

#include <metal_stdlib>
using namespace metal;

#define GN 128
#define GN2 16384
#define GN3 2097152
#define GAMMA 1.6666666666666667f
#define GAMMA_M1 0.6666666666666667f

struct MHDParams {
    float dt, dx, gamma, gamma_m1;
    uint n, n2, n3, pad;
};

struct RenderParams {
    float4 eye;
    float4 right;
    float4 up;
    float4 fwd;      // xyz=forward, w=half_tan_fov
    float4 domain;   // xyz=center, w=N
    float4 screen;   // xy=resolution, z=rho_min, w=rho_max
};

// ═══════════════════════════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════════════════════════

inline uint wrap(int i) {
    return (i < 0) ? uint(i + GN) : (uint(i) >= uint(GN)) ? uint(i - GN) : uint(i);
}

inline uint cidx(uint x, uint y, uint z) {
    return z * GN2 + y * GN + x;
}

struct Cell { float rho, mx, my, mz, bx, by, bz, e; };

inline Cell load_cell(device const float *s, uint i) {
    Cell c;
    c.rho = s[i];        c.mx = s[GN3+i];     c.my = s[2*GN3+i];
    c.mz = s[3*GN3+i];   c.bx = s[4*GN3+i];   c.by = s[5*GN3+i];
    c.bz = s[6*GN3+i];   c.e  = s[7*GN3+i];
    return c;
}

inline float cell_pressure(Cell c) {
    float irho = 1.0f / max(c.rho, 1e-6f);
    float ke = 0.5f * (c.mx*c.mx + c.my*c.my + c.mz*c.mz) * irho;
    float me = 0.5f * (c.bx*c.bx + c.by*c.by + c.bz*c.bz);
    return max(GAMMA_M1 * (c.e - ke - me), 1e-6f);
}

// ═══════════════════════════════════════════════════════════
// MHD FLUXES (ideal MHD, 8 conserved variables)
// ═══════════════════════════════════════════════════════════

struct Flux { float f[8]; };

inline Flux flux_x(Cell c) {
    Flux fx;
    float irho = 1.0f / max(c.rho, 1e-6f);
    float vx = c.mx*irho, vy = c.my*irho, vz = c.mz*irho;
    float b2 = c.bx*c.bx + c.by*c.by + c.bz*c.bz;
    float p = cell_pressure(c), pt = p + 0.5f*b2;
    float vdb = vx*c.bx + vy*c.by + vz*c.bz;
    fx.f[0] = c.mx;
    fx.f[1] = c.mx*vx + pt - c.bx*c.bx;
    fx.f[2] = c.mx*vy - c.bx*c.by;
    fx.f[3] = c.mx*vz - c.bx*c.bz;
    fx.f[4] = 0.0f;
    fx.f[5] = vx*c.by - vy*c.bx;
    fx.f[6] = vx*c.bz - vz*c.bx;
    fx.f[7] = (c.e + pt)*vx - c.bx*vdb;
    return fx;
}

inline Flux flux_y(Cell c) {
    Flux fy;
    float irho = 1.0f / max(c.rho, 1e-6f);
    float vx = c.mx*irho, vy = c.my*irho, vz = c.mz*irho;
    float b2 = c.bx*c.bx + c.by*c.by + c.bz*c.bz;
    float p = cell_pressure(c), pt = p + 0.5f*b2;
    float vdb = vx*c.bx + vy*c.by + vz*c.bz;
    fy.f[0] = c.my;
    fy.f[1] = c.my*vx - c.by*c.bx;
    fy.f[2] = c.my*vy + pt - c.by*c.by;
    fy.f[3] = c.my*vz - c.by*c.bz;
    fy.f[4] = vy*c.bx - vx*c.by;
    fy.f[5] = 0.0f;
    fy.f[6] = vy*c.bz - vz*c.by;
    fy.f[7] = (c.e + pt)*vy - c.by*vdb;
    return fy;
}

inline Flux flux_z(Cell c) {
    Flux fz;
    float irho = 1.0f / max(c.rho, 1e-6f);
    float vx = c.mx*irho, vy = c.my*irho, vz = c.mz*irho;
    float b2 = c.bx*c.bx + c.by*c.by + c.bz*c.bz;
    float p = cell_pressure(c), pt = p + 0.5f*b2;
    float vdb = vx*c.bx + vy*c.by + vz*c.bz;
    fz.f[0] = c.mz;
    fz.f[1] = c.mz*vx - c.bz*c.bx;
    fz.f[2] = c.mz*vy - c.bz*c.by;
    fz.f[3] = c.mz*vz + pt - c.bz*c.bz;
    fz.f[4] = vz*c.bx - vx*c.bz;
    fz.f[5] = vz*c.by - vy*c.bz;
    fz.f[6] = 0.0f;
    fz.f[7] = (c.e + pt)*vz - c.bz*vdb;
    return fz;
}

// ═══════════════════════════════════════════════════════════
// COMPUTE: 3D Lax-Friedrichs MHD Step
// ═══════════════════════════════════════════════════════════

kernel void mhd3d_step(
    device const float *in  [[buffer(0)]],
    device float       *out [[buffer(1)]],
    constant MHDParams &p   [[buffer(2)]],
    uint3 gid [[thread_position_in_grid]])
{
    if (gid.x >= GN || gid.y >= GN || gid.z >= GN) return;

    uint x = gid.x, y = gid.y, z = gid.z;
    uint i0 = cidx(x, y, z);

    uint ixp = cidx(wrap(int(x)+1), y, z);
    uint ixm = cidx(wrap(int(x)-1), y, z);
    uint iyp = cidx(x, wrap(int(y)+1), z);
    uint iym = cidx(x, wrap(int(y)-1), z);
    uint izp = cidx(x, y, wrap(int(z)+1));
    uint izm = cidx(x, y, wrap(int(z)-1));

    Cell cxp = load_cell(in, ixp), cxm = load_cell(in, ixm);
    Cell cyp = load_cell(in, iyp), cym = load_cell(in, iym);
    Cell czp = load_cell(in, izp), czm = load_cell(in, izm);

    Flux fxp = flux_x(cxp), fxm = flux_x(cxm);
    Flux fyp = flux_y(cyp), fym = flux_y(cym);
    Flux fzp = flux_z(czp), fzm = flux_z(czm);

    float c = p.dt / (2.0f * p.dx);

    for (uint f = 0; f < 8; f++) {
        float avg = (in[f*GN3+ixp] + in[f*GN3+ixm] +
                     in[f*GN3+iyp] + in[f*GN3+iym] +
                     in[f*GN3+izp] + in[f*GN3+izm]) / 6.0f;
        out[f*GN3 + i0] = avg - c*(fxp.f[f]-fxm.f[f] + fyp.f[f]-fym.f[f] + fzp.f[f]-fzm.f[f]);
    }

    // Safety floors
    out[i0] = max(out[i0], 1e-4f);
    out[7*GN3+i0] = max(out[7*GN3+i0], 1e-4f);
}

// ═══════════════════════════════════════════════════════════
// COMPUTE: Current density |j|² = |curl(B)|² for viz
// ═══════════════════════════════════════════════════════════

kernel void compute_viz(
    device const float *state [[buffer(0)]],
    device float *viz [[buffer(1)]],
    uint3 gid [[thread_position_in_grid]])
{
    if (gid.x >= GN || gid.y >= GN || gid.z >= GN) return;
    uint x = gid.x, y = gid.y, z = gid.z;
    uint i0 = cidx(x, y, z);

    uint xp = cidx(wrap(int(x)+1),y,z), xm = cidx(wrap(int(x)-1),y,z);
    uint yp = cidx(x,wrap(int(y)+1),z), ym = cidx(x,wrap(int(y)-1),z);
    uint zp = cidx(x,y,wrap(int(z)+1)), zm = cidx(x,y,wrap(int(z)-1));

    // j = curl(B) — central differences (grid-space)
    float jx = (state[6*GN3+yp]-state[6*GN3+ym]) - (state[5*GN3+zp]-state[5*GN3+zm]);
    float jy = (state[4*GN3+zp]-state[4*GN3+zm]) - (state[6*GN3+xp]-state[6*GN3+xm]);
    float jz = (state[5*GN3+xp]-state[5*GN3+xm]) - (state[4*GN3+yp]-state[4*GN3+ym]);
    viz[i0] = jx*jx + jy*jy + jz*jz;
}

// ═══════════════════════════════════════════════════════════
// RENDER: Fullscreen triangle + Volume raymarcher
// ═══════════════════════════════════════════════════════════

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut fullscreen_vertex(uint vid [[vertex_id]]) {
    const float2 pos[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
    VertexOut vout;
    vout.position = float4(pos[vid], 0, 1);
    vout.uv = pos[vid] * 0.5 + 0.5;
    return vout;
}

// Sample a single field via trilinear interpolation
inline float sample_field(device const float *state, uint field_offset, float3 p) {
    float3 cp = clamp(p, float3(0.0), float3(float(GN) - 1.001));
    uint3 i0 = uint3(cp);
    uint3 i1 = min(i0 + 1, uint(GN - 1));
    float3 fr = fract(cp);
    device const float *f = state + field_offset;
    float c000 = f[i0.z*GN2+i0.y*GN+i0.x], c100 = f[i0.z*GN2+i0.y*GN+i1.x];
    float c010 = f[i0.z*GN2+i1.y*GN+i0.x], c110 = f[i0.z*GN2+i1.y*GN+i1.x];
    float c001 = f[i1.z*GN2+i0.y*GN+i0.x], c101 = f[i1.z*GN2+i0.y*GN+i1.x];
    float c011 = f[i1.z*GN2+i1.y*GN+i0.x], c111 = f[i1.z*GN2+i1.y*GN+i1.x];
    float c00 = mix(c000, c100, fr.x), c10 = mix(c010, c110, fr.x);
    float c01 = mix(c001, c101, fr.x), c11 = mix(c011, c111, fr.x);
    return mix(mix(c00, c10, fr.y), mix(c01, c11, fr.y), fr.z);
}

// Multi-stop plasma colormap: dark → blue → cyan → white (density)
inline float3 density_color(float t) {
    t = clamp(t, 0.0f, 1.0f);
    if (t < 0.33f)
        return mix(float3(0.0, 0.0, 0.15), float3(0.1, 0.3, 0.9), t * 3.0f);
    if (t < 0.66f)
        return mix(float3(0.1, 0.3, 0.9), float3(0.3, 0.8, 1.0), (t - 0.33f) * 3.0f);
    return mix(float3(0.3, 0.8, 1.0), float3(1.0, 1.0, 1.0), (t - 0.66f) * 3.0f);
}

// Magnetic field color: dark → orange → yellow-white
inline float3 mag_color(float t) {
    t = clamp(t, 0.0f, 1.0f);
    if (t < 0.5f)
        return mix(float3(0.15, 0.02, 0.0), float3(1.0, 0.4, 0.05), t * 2.0f);
    return mix(float3(1.0, 0.4, 0.05), float3(1.0, 0.9, 0.6), (t - 0.5f) * 2.0f);
}

inline bool intersect_box(float3 orig, float3 invDir, float3 bmin, float3 bmax,
                          thread float &tmin_o, thread float &tmax_o) {
    float3 t0 = (bmin - orig) * invDir;
    float3 t1 = (bmax - orig) * invDir;
    float3 ts = min(t0, t1), tb = max(t0, t1);
    float tmin = max(max(ts.x, ts.y), ts.z);
    float tmax = min(min(tb.x, tb.y), tb.z);
    tmin_o = max(tmin, 0.0f);
    tmax_o = tmax;
    return tmax > max(tmin, 0.0f);
}

fragment float4 volume_fragment(
    VertexOut in [[stage_in]],
    device const float *state [[buffer(0)]],
    constant RenderParams &rp [[buffer(1)]],
    device const float *viz [[buffer(2)]])
{
    float2 uv = in.uv * 2.0 - 1.0;
    uv.x *= rp.screen.x / rp.screen.y;

    float ht = rp.fwd.w;
    float3 dir = normalize(rp.fwd.xyz + uv.x*ht*rp.right.xyz + uv.y*ht*rp.up.xyz);
    float3 origin = rp.eye.xyz;

    float tmin, tmax;
    if (!intersect_box(origin, 1.0f/dir, float3(0), float3(float(GN)), tmin, tmax))
        return float4(0.01, 0.01, 0.03, 1.0);

    float3 accum = float3(0);
    float alpha = 0.0;

    for (float t = tmin; t < tmax && alpha < 0.96; t += 1.0) {
        float3 pos = origin + t * dir;

        // 3-channel sampling
        float rho = sample_field(state, 0, pos);
        float bx = sample_field(state, 4*GN3, pos);
        float by = sample_field(state, 5*GN3, pos);
        float bz = sample_field(state, 6*GN3, pos);
        float b2 = bx*bx + by*by + bz*bz;
        float j2 = sample_field(viz, 0, pos);

        // Normalize
        float rn = clamp((rho - 0.2f) / 2.5f, 0.0f, 1.0f);      // full density
        float rd = clamp((rho - 1.0f) / 1.5f, 0.0f, 1.0f);       // shock excess
        float mn = clamp(b2 / 2.0f, 0.0f, 1.0f);                  // |B|²
        float jn = clamp(sqrt(j2) / 2.0f, 0.0f, 1.0f);            // |j|

        // Color: blue volume + amber B-field + cyan shocks + hot pink current
        float3 col = float3(0.04, 0.08, 0.25) * rn                // blue volume haze
                   + float3(0.2, 0.5, 1.2) * rd                   // cyan shock fronts
                   + float3(1.5, 0.8, 0.05) * mn * 1.5f           // bright amber B-field
                   + float3(2.0, 0.7, 1.2) * jn * jn * 4.0f;     // very hot current sheets

        // Opacity: subtle base + strong features
        float a = rn*0.004f + rd*rd*0.03f + mn*0.02f + jn*jn*0.12f;
        accum += (1.0f - alpha) * col * a;
        alpha += (1.0f - alpha) * a;
    }

    // Subtle radial gradient background
    float vign = 1.0f - length(in.uv - 0.5f) * 0.8f;
    float3 bg = float3(0.01, 0.01, 0.04) * vign;
    return float4(accum + (1.0f - alpha) * bg, 1.0f);
}
