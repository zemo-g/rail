// mhd_axisym.metal — 2D Axisymmetric MHD compute shader for MPD thruster design
// Grid: NR×NZ in cylindrical (r,z). 5 conserved variables.
// MUSCL + minmod limiter + Rusanov interface flux + positivity-preserving floors.
// Lorentz force source terms + cylindrical 1/r geometric sources + Spitzer Ohmic.
//
// Conserved state per cell: [ρ, ρ·v_r, ρ·v_z, E, B_θ]
// Applied fields (B_z, B_r) are static — computed from coil geometry on host.
//
// 2026-04-28 rewrite: replaces the original Lax-Friedrichs integrator that
// had drifted under operator pressure (no flux limiter, no positivity
// reconstruction).  The numerics here mirror stdlib/mhd_kernel.rail's
// MUSCL path exactly so the Rail reference and the Metal kernel are
// algorithmically equivalent.  The host-side dt computation MUST honor
// CFL ≤ ~0.3 against the actual fast-magnetosonic wave speed; do NOT
// reintroduce the legacy 500 m/s minimum-speed floor or the 5e-8 s
// hard dt ceiling — those were the root cause of the 4-day divergence
// that retired the previous build.

#include <metal_stdlib>
using namespace metal;

#define NR 256
#define NZ 512
#define NCELLS (NR * NZ)
#define NFIELDS 5
#define GAMMA 1.6666666666666667f
#define GAMMA_M1 0.6666666666666667f
#define MU0 1.2566370614359172e-6f
#define INV_MU0 795774.7154594768f

#define RHO_FLOOR 1e-8f
#define P_FLOOR 1e-6f

struct Params {
    float dt;
    float dr;
    float dz;
    float r_min;
    float r_max;
    float z_max;
    float I_arc;
    float B_applied;
    float mdot;
    float m_ion;
    float gamma;
    float gamma_m1;
    float inlet_rho;
    float inlet_vz;
    float inlet_p;
    float inlet_T_eV;
    uint  nr, nz;
    uint  ncells;
    uint  pad;
};

inline uint idx(uint j, uint i) { return j * NZ + i; }

struct Cell {
    float rho, mr, mz, e, bt;
};

inline Cell load_cell(device const float *s, uint k) {
    Cell c;
    c.rho = s[k];
    c.mr  = s[NCELLS + k];
    c.mz  = s[2*NCELLS + k];
    c.e   = s[3*NCELLS + k];
    c.bt  = s[4*NCELLS + k];
    return c;
}

inline void store_cell(device float *s, uint k, Cell c) {
    s[k]            = c.rho;
    s[NCELLS + k]   = c.mr;
    s[2*NCELLS + k] = c.mz;
    s[3*NCELLS + k] = c.e;
    s[4*NCELLS + k] = c.bt;
}

inline float cell_pressure(Cell c) {
    float irho = 1.0f / max(c.rho, RHO_FLOOR);
    float ke = 0.5f * (c.mr*c.mr + c.mz*c.mz) * irho;
    float me = 0.5f * c.bt * c.bt * INV_MU0;
    return max(GAMMA_M1 * (c.e - ke - me), P_FLOOR);
}

// Fast-magnetosonic + |v|: the upper bound used by Rusanov dissipation.
inline float wave_speed(Cell c) {
    float irho = 1.0f / max(c.rho, RHO_FLOOR);
    float vr = c.mr * irho;
    float vz = c.mz * irho;
    float p = cell_pressure(c);
    float a2 = GAMMA * p * irho;
    float va2 = c.bt * c.bt * irho * INV_MU0;
    return sqrt(vr*vr + vz*vz) + sqrt(a2 + va2);
}

struct Flux { float f[NFIELDS]; };

inline Flux flux_r(Cell c) {
    Flux fr;
    float irho = 1.0f / max(c.rho, RHO_FLOOR);
    float vr = c.mr * irho;
    float vz = c.mz * irho;
    float p = cell_pressure(c);
    float pm = 0.5f * c.bt * c.bt * INV_MU0;
    float pt = p + pm;
    fr.f[0] = c.mr;
    fr.f[1] = c.mr * vr + pt;
    fr.f[2] = c.mr * vz;
    fr.f[3] = (c.e + pt) * vr;
    fr.f[4] = vr * c.bt;
    return fr;
}

inline Flux flux_z(Cell c) {
    Flux fz;
    float irho = 1.0f / max(c.rho, RHO_FLOOR);
    float vr = c.mr * irho;
    float vz = c.mz * irho;
    float p = cell_pressure(c);
    float pm = 0.5f * c.bt * c.bt * INV_MU0;
    float pt = p + pm;
    fz.f[0] = c.mz;
    fz.f[1] = c.mz * vr;
    fz.f[2] = c.mz * vz + pt;
    fz.f[3] = (c.e + pt) * vz;
    fz.f[4] = -vz * c.bt;
    return fz;
}

// ═══════════════════════════════════════════════════════════
// MUSCL + MINMOD RECONSTRUCTION + RUSANOV INTERFACE FLUX
// ═══════════════════════════════════════════════════════════

inline float minmod(float a, float b) {
    if (a > 0.0f && b > 0.0f) return min(a, b);
    if (a < 0.0f && b < 0.0f) return max(a, b);
    return 0.0f;
}

inline Cell slope(Cell cm, Cell c0, Cell cp) {
    Cell s;
    s.rho = minmod(c0.rho - cm.rho, cp.rho - c0.rho);
    s.mr  = minmod(c0.mr  - cm.mr,  cp.mr  - c0.mr );
    s.mz  = minmod(c0.mz  - cm.mz,  cp.mz  - c0.mz );
    s.e   = minmod(c0.e   - cm.e,   cp.e   - c0.e  );
    s.bt  = minmod(c0.bt  - cm.bt,  cp.bt  - c0.bt );
    return s;
}

inline Cell recon_left(Cell c, Cell s) {
    Cell u;
    u.rho = c.rho + 0.5f * s.rho;
    u.mr  = c.mr  + 0.5f * s.mr;
    u.mz  = c.mz  + 0.5f * s.mz;
    u.e   = c.e   + 0.5f * s.e;
    u.bt  = c.bt  + 0.5f * s.bt;
    if (u.rho < RHO_FLOOR) u.rho = c.rho;  // positivity guard at recon
    return u;
}

inline Cell recon_right(Cell c, Cell s) {
    Cell u;
    u.rho = c.rho - 0.5f * s.rho;
    u.mr  = c.mr  - 0.5f * s.mr;
    u.mz  = c.mz  - 0.5f * s.mz;
    u.e   = c.e   - 0.5f * s.e;
    u.bt  = c.bt  - 0.5f * s.bt;
    if (u.rho < RHO_FLOOR) u.rho = c.rho;
    return u;
}

inline Flux rusanov(Flux fL, Flux fR, Cell uL, Cell uR, float alpha) {
    Flux f;
    f.f[0] = 0.5f * (fL.f[0] + fR.f[0]) - 0.5f * alpha * (uR.rho - uL.rho);
    f.f[1] = 0.5f * (fL.f[1] + fR.f[1]) - 0.5f * alpha * (uR.mr  - uL.mr );
    f.f[2] = 0.5f * (fL.f[2] + fR.f[2]) - 0.5f * alpha * (uR.mz  - uL.mz );
    f.f[3] = 0.5f * (fL.f[3] + fR.f[3]) - 0.5f * alpha * (uR.e   - uL.e  );
    f.f[4] = 0.5f * (fL.f[4] + fR.f[4]) - 0.5f * alpha * (uR.bt  - uL.bt );
    return f;
}

inline Flux iface_flux_r(Cell uL, Cell uR) {
    Flux fL = flux_r(uL);
    Flux fR = flux_r(uR);
    float alpha = max(wave_speed(uL), wave_speed(uR));
    return rusanov(fL, fR, uL, uR, alpha);
}

inline Flux iface_flux_z(Cell uL, Cell uR) {
    Flux fL = flux_z(uL);
    Flux fR = flux_z(uR);
    float alpha = max(wave_speed(uL), wave_speed(uR));
    return rusanov(fL, fR, uL, uR, alpha);
}

// ═══════════════════════════════════════════════════════════
// COMPUTE: 2D Axisymmetric MHD Step
// MUSCL+minmod+Rusanov interior, BCs at edges, source terms post-update.
// ═══════════════════════════════════════════════════════════

kernel void mhd2d_step(
    device const float *in        [[buffer(0)]],
    device float       *out       [[buffer(1)]],
    device const float *Bz_field  [[buffer(2)]],
    device const float *Br_field  [[buffer(3)]],
    constant Params    &p         [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint j = gid.x;
    uint i = gid.y;
    if (j >= NR || i >= NZ) return;

    uint k = idx(j, i);
    float r_j = p.r_min + (float(j) + 0.5f) * p.dr;

    // ── Boundaries (unchanged from previous build) ──

    if (j == 0) {
        Cell c1 = load_cell(in, idx(1, i));
        Cell c0 = c1;
        c0.mr = -c1.mr;
        store_cell(out, k, c0);
        return;
    }
    if (j == NR - 1) {
        Cell c1 = load_cell(in, idx(NR-2, i));
        Cell c0 = c1;
        c0.mr = -c1.mr;
        store_cell(out, k, c0);
        return;
    }
    if (i == 0) {
        Cell c0;
        c0.rho = p.inlet_rho;
        c0.mr  = 0.0f;
        c0.mz  = p.inlet_rho * p.inlet_vz;
        float ke = 0.5f * p.inlet_rho * p.inlet_vz * p.inlet_vz;
        c0.e   = p.inlet_p / GAMMA_M1 + ke;
        c0.bt  = MU0 * p.I_arc * (r_j * r_j - p.r_min * p.r_min) /
                 (2.0f * 3.14159265f * r_j * (p.r_max * p.r_max - p.r_min * p.r_min));
        store_cell(out, k, c0);
        return;
    }
    if (i == NZ - 1) {
        Cell c1 = load_cell(in, idx(j, NZ-2));
        store_cell(out, k, c1);
        return;
    }

    // ── Interior: MUSCL + minmod + Rusanov ──

    // 5-cell stencil in each direction (need j-2 .. j+2 for slopes at j-1, j, j+1).
    // Clamp at boundaries so the inner stencil reads stay in-grid.
    uint jm2 = (j >= 2) ? j - 2 : 0;
    uint jp2 = min(j + 2, (uint)(NR - 1));
    uint im2 = (i >= 2) ? i - 2 : 0;
    uint ip2 = min(i + 2, (uint)(NZ - 1));

    Cell c0   = load_cell(in, idx(j,    i));
    Cell cjm  = load_cell(in, idx(j-1,  i));
    Cell cjp  = load_cell(in, idx(j+1,  i));
    Cell cjmm = load_cell(in, idx(jm2,  i));
    Cell cjpp = load_cell(in, idx(jp2,  i));
    Cell cim  = load_cell(in, idx(j,    i-1));
    Cell cip  = load_cell(in, idx(j,    i+1));
    Cell cimm = load_cell(in, idx(j,    im2));
    Cell cipp = load_cell(in, idx(j,    ip2));

    // Slopes at j-1, j, j+1 (r-direction) and at i-1, i, i+1 (z-direction).
    Cell sr_jm = slope(cjmm, cjm,  c0  );
    Cell sr_j  = slope(cjm,  c0,   cjp );
    Cell sr_jp = slope(c0,   cjp,  cjpp);
    Cell sz_im = slope(cimm, cim,  c0  );
    Cell sz_i  = slope(cim,  c0,   cip );
    Cell sz_ip = slope(c0,   cip,  cipp);

    // Interface (j+1/2, i): L from cell j with σ_j, R from cell j+1 with σ_{j+1}.
    Flux frp = iface_flux_r(recon_left(c0,  sr_j), recon_right(cjp, sr_jp));
    // Interface (j-1/2, i): L from cell j-1 with σ_{j-1}, R from cell j with σ_j.
    Flux frm = iface_flux_r(recon_left(cjm, sr_jm), recon_right(c0, sr_j));
    Flux fzp = iface_flux_z(recon_left(c0,  sz_i), recon_right(cip, sz_ip));
    Flux fzm = iface_flux_z(recon_left(cim, sz_im), recon_right(c0, sz_i));

    // Forward Euler over interface-flux divergence.  The factor is dt/dx
    // (NOT dt/(2 dx) — these are real interface fluxes, not LF averages).
    float cr = p.dt / p.dr;
    float cz = p.dt / p.dz;

    Cell cnew;
    cnew.rho = c0.rho - cr * (frp.f[0] - frm.f[0]) - cz * (fzp.f[0] - fzm.f[0]);
    cnew.mr  = c0.mr  - cr * (frp.f[1] - frm.f[1]) - cz * (fzp.f[1] - fzm.f[1]);
    cnew.mz  = c0.mz  - cr * (frp.f[2] - frm.f[2]) - cz * (fzp.f[2] - fzm.f[2]);
    cnew.e   = c0.e   - cr * (frp.f[3] - frm.f[3]) - cz * (fzp.f[3] - fzm.f[3]);
    cnew.bt  = c0.bt  - cr * (frp.f[4] - frm.f[4]) - cz * (fzp.f[4] - fzm.f[4]);

    // ── Source terms (cylindrical 1/r geometry + hoop stress) ──
    float irho0 = 1.0f / max(c0.rho, RHO_FLOOR);
    float vr0 = c0.mr * irho0;
    float p0 = cell_pressure(c0);
    float pm0 = 0.5f * c0.bt * c0.bt * INV_MU0;
    float inv_r = 1.0f / max(r_j, 0.5f * p.dr);

    cnew.rho -= p.dt * c0.rho * vr0 * inv_r;
    cnew.mr  -= p.dt * (c0.mr * vr0) * inv_r;
    cnew.mr  += p.dt * (p0 + pm0) * inv_r;       // hoop stress
    cnew.mz  -= p.dt * c0.mz * vr0 * inv_r;
    cnew.e   -= p.dt * (c0.e + p0 + pm0) * vr0 * inv_r;

    // ── Lorentz J × B (self-field + applied-field) ──
    float Bz_app = Bz_field[k];
    float Br_app = Br_field[k];
    float r_jp = r_j + p.dr, r_jm = r_j - p.dr;

    float Jz_self = INV_MU0 * (r_jp * cjp.bt - r_jm * cjm.bt) / (2.0f * p.dr * r_j);
    float Jr_self = -INV_MU0 * (cip.bt - cim.bt) / (2.0f * p.dz);

    uint j_p = (j + 1 < NR) ? j + 1 : NR - 1;
    uint j_m = (j > 0) ? j - 1 : 0;
    uint i_p = (i + 1 < NZ) ? i + 1 : NZ - 1;
    uint i_m = (i > 0) ? i - 1 : 0;
    float Bz_jp = Bz_field[idx(j_p, i)];
    float Bz_jm = Bz_field[idx(j_m, i)];
    float Br_ip = Br_field[idx(j, i_p)];
    float Br_im = Br_field[idx(j, i_m)];
    float Jt_app = INV_MU0 * ((Br_ip - Br_im) / (2.0f * p.dz) - (Bz_jp - Bz_jm) / (2.0f * p.dr));

    cnew.mr += p.dt * (Jz_self * c0.bt - Jt_app * Bz_app);
    cnew.mz += p.dt * (Jr_self * c0.bt + Jt_app * Br_app);

    // ── Spitzer Ohmic heating ──
    float J2 = Jz_self*Jz_self + Jr_self*Jr_self + Jt_app*Jt_app;
    float T_eV = max(0.5f, p0 * p.m_ion / (max(c0.rho, RHO_FLOOR) * 1.38e-23f) / 11600.0f);
    float eta = 5.0e-5f / max(T_eV * sqrt(T_eV) * T_eV, 0.1f);
    float dE_ohmic = p.dt * eta * J2;
    // Substep guard: cap Ohmic heating contribution to half the cell's
    // current internal energy per step.  Replaces the old build's open-
    // loop add that could spike when J got large near current sheets.
    float e_cap = 0.5f * max(c0.e, 1.0f);
    cnew.e += min(dE_ohmic, e_cap);

    // ── Safety floors (last line of defence; positivity-preserving recon
    //    above and pressure floor in fluxes should make this a no-op in
    //    well-behaved regions). ──
    if (isnan(cnew.rho) || isnan(cnew.mr) || isnan(cnew.mz) || isnan(cnew.e) || isnan(cnew.bt)) {
        store_cell(out, k, c0);
        return;
    }
    cnew.rho = clamp(cnew.rho, RHO_FLOOR, 1e2f);
    cnew.mr  = clamp(cnew.mr, -1e3f, 1e3f);
    cnew.mz  = clamp(cnew.mz, -1e3f, 1e3f);
    cnew.bt  = clamp(cnew.bt, -10.0f, 10.0f);
    float ke_new = 0.5f * (cnew.mr*cnew.mr + cnew.mz*cnew.mz) / max(cnew.rho, RHO_FLOOR);
    float me_new = 0.5f * cnew.bt * cnew.bt * INV_MU0;
    cnew.e = clamp(cnew.e, ke_new + me_new + P_FLOOR, 1e8f);

    store_cell(out, k, cnew);
}

// ═══════════════════════════════════════════════════════════
// COMPUTE: Downsample fields for streaming (unchanged from previous build)
// ═══════════════════════════════════════════════════════════

#define DS 4
#define DSR (NR/DS)
#define DSZ (NZ/DS)
#define DS_CELLS (DSR * DSZ)

kernel void downsample(
    device const float *state     [[buffer(0)]],
    device const float *Bz_field  [[buffer(1)]],
    device float       *output    [[buffer(2)]],
    constant Params    &p         [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint dj = gid.x, di = gid.y;
    if (dj >= DSR || di >= DSZ) return;

    float rho_sum = 0, mr_sum = 0, mz_sum = 0, e_sum = 0, bt_sum = 0, bz_sum = 0;
    float count = 0;
    for (uint bj = 0; bj < DS; bj++) {
        for (uint bi = 0; bi < DS; bi++) {
            uint j = dj * DS + bj;
            uint i = di * DS + bi;
            if (j >= NR || i >= NZ) continue;
            uint k = idx(j, i);
            rho_sum += state[k];
            mr_sum  += state[NCELLS + k];
            mz_sum  += state[2*NCELLS + k];
            e_sum   += state[3*NCELLS + k];
            bt_sum  += state[4*NCELLS + k];
            bz_sum  += Bz_field[k];
            count += 1.0f;
        }
    }
    float inv = 1.0f / max(count, 1.0f);
    float rho = rho_sum * inv;
    float mr  = mr_sum * inv;
    float mz  = mz_sum * inv;
    float e   = e_sum * inv;
    float bt  = bt_sum * inv;
    float bz  = bz_sum * inv;

    float irho = 1.0f / max(rho, RHO_FLOOR);
    float vr = mr * irho;
    float vz = mz * irho;
    float vmag = sqrt(vr*vr + vz*vz);
    float ke = 0.5f * (mr*mr + mz*mz) * irho;
    float me = 0.5f * bt * bt * INV_MU0;
    float prs = max(GAMMA_M1 * (e - ke - me), P_FLOOR);
    float T_eV = prs * p.m_ion / (max(rho, RHO_FLOOR) * 1.38e-23f) / 11600.0f;
    float Bmag = sqrt(bt*bt + bz*bz);

    uint dk = dj * DSZ + di;
    output[0 * DS_CELLS + dk] = rho;
    output[1 * DS_CELLS + dk] = T_eV;
    output[2 * DS_CELLS + dk] = vmag;
    output[3 * DS_CELLS + dk] = Bmag;
    output[4 * DS_CELLS + dk] = vz;
    output[5 * DS_CELLS + dk] = vr;
}
