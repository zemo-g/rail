// mhd_axisym.metal — 2D Axisymmetric MHD compute shader for MPD thruster design
// Grid: NR×NZ in cylindrical (r,z). 5 conserved variables.
// Lax-Friedrichs scheme + Lorentz force source terms + geometric source (1/r).
//
// Conserved state per cell: [ρ, ρ·v_r, ρ·v_z, E, B_θ]
// Applied fields (B_z, B_r) are static — computed from coil geometry on host.

#include <metal_stdlib>
using namespace metal;

#define NR 256
#define NZ 512
#define NCELLS (NR * NZ)
#define NFIELDS 5
#define GAMMA 1.6666666666666667f
#define GAMMA_M1 0.6666666666666667f
#define MU0 1.2566370614359172e-6f

struct Params {
    float dt;           // timestep
    float dr;           // radial spacing (m)
    float dz;           // axial spacing (m)
    float r_min;        // cathode radius (m)
    float r_max;        // anode radius (m)
    float z_max;        // channel length (m)
    float I_arc;        // arc current (A)
    float B_applied;    // peak applied field (T)
    float mdot;         // mass flow rate (kg/s)
    float m_ion;        // ion mass (kg)
    float gamma;
    float gamma_m1;
    float inlet_rho;    // inlet density
    float inlet_vz;     // inlet velocity
    float inlet_p;      // inlet pressure
    float inlet_T_eV;   // inlet temperature (eV)
    uint  nr, nz;
    uint  ncells;
    uint  pad;
};

// Index: field f, radial j, axial i → f * NCELLS + j * NZ + i
inline uint idx(uint j, uint i) { return j * NZ + i; }

// Load cell state
struct Cell {
    float rho, mr, mz, e, bt; // ρ, ρvr, ρvz, E, Bθ
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
    s[k]           = c.rho;
    s[NCELLS + k]  = c.mr;
    s[2*NCELLS + k]= c.mz;
    s[3*NCELLS + k]= c.e;
    s[4*NCELLS + k]= c.bt;
}

inline float cell_pressure(Cell c) {
    float irho = 1.0f / max(c.rho, 1e-8f);
    float ke = 0.5f * (c.mr*c.mr + c.mz*c.mz) * irho;
    float me = 0.5f * c.bt * c.bt / MU0;
    return max(GAMMA_M1 * (c.e - ke - me), 1e-6f);
}

// r-direction flux: F_r = [ρvr, ρvr²+p*, ρvr·vz, (E+p*)vr, vr·Bθ... (induction)]
struct Flux { float f[NFIELDS]; };

inline Flux flux_r(Cell c) {
    Flux fr;
    float irho = 1.0f / max(c.rho, 1e-8f);
    float vr = c.mr * irho;
    float vz = c.mz * irho;
    float p = cell_pressure(c);
    float pm = 0.5f * c.bt * c.bt / MU0;
    float pt = p + pm; // total pressure (gas + magnetic)

    fr.f[0] = c.mr;                  // mass flux
    fr.f[1] = c.mr * vr + pt;        // r-momentum flux
    fr.f[2] = c.mr * vz;             // z-momentum flux
    fr.f[3] = (c.e + pt) * vr;       // energy flux
    fr.f[4] = vr * c.bt;             // Bθ induction (simplified)
    return fr;
}

inline Flux flux_z(Cell c) {
    Flux fz;
    float irho = 1.0f / max(c.rho, 1e-8f);
    float vr = c.mr * irho;
    float vz = c.mz * irho;
    float p = cell_pressure(c);
    float pm = 0.5f * c.bt * c.bt / MU0;
    float pt = p + pm;

    fz.f[0] = c.mz;                  // mass flux
    fz.f[1] = c.mz * vr;             // r-momentum flux
    fz.f[2] = c.mz * vz + pt;        // z-momentum flux
    fz.f[3] = (c.e + pt) * vz;       // energy flux
    fz.f[4] = -vz * c.bt;            // Bθ induction (Faraday)
    return fz;
}

// ═══════════════════════════════════════════════════════════
// COMPUTE: 2D Axisymmetric MHD Step (Lax-Friedrichs)
// ═══════════════════════════════════════════════════════════

kernel void mhd2d_step(
    device const float *in        [[buffer(0)]],
    device float       *out       [[buffer(1)]],
    device const float *Bz_field  [[buffer(2)]],  // applied Bz(r,z) from coils
    device const float *Br_field  [[buffer(3)]],  // applied Br(r,z) from coils
    constant Params    &p         [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint j = gid.x;  // radial index
    uint i = gid.y;  // axial index
    if (j >= NR || i >= NZ) return;

    uint k = idx(j, i);
    float r_j = p.r_min + (float(j) + 0.5f) * p.dr;

    // ── Boundary cells: apply BCs directly ──

    // Axis boundary (j=0): symmetry
    if (j == 0) {
        Cell c1 = load_cell(in, idx(1, i));
        Cell c0 = c1;
        c0.mr = -c1.mr;  // reflect radial momentum
        store_cell(out, k, c0);
        return;
    }
    // Wall boundary (j=NR-1): no-penetration
    if (j == NR - 1) {
        Cell c1 = load_cell(in, idx(NR-2, i));
        Cell c0 = c1;
        c0.mr = -c1.mr;
        store_cell(out, k, c0);
        return;
    }
    // Inlet (i=0): fixed inflow
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
    // Outlet (i=NZ-1): zero-gradient extrapolation
    if (i == NZ - 1) {
        Cell c1 = load_cell(in, idx(j, NZ-2));
        store_cell(out, k, c1);
        return;
    }

    // ── Interior: Lax-Friedrichs update ──

    Cell cjp = load_cell(in, idx(j+1, i));
    Cell cjm = load_cell(in, idx(j-1, i));
    Cell cip = load_cell(in, idx(j, i+1));
    Cell cim = load_cell(in, idx(j, i-1));
    Cell c0  = load_cell(in, k);

    Flux frp = flux_r(cjp), frm = flux_r(cjm);
    Flux fzp = flux_z(cip), fzm = flux_z(cim);

    float cr = p.dt / (2.0f * p.dr);
    float cz = p.dt / (2.0f * p.dz);

    Cell cnew;
    // Lax-Friedrichs: average of 4 neighbors - dt/(2dx) × (flux differences)
    for (uint f = 0; f < NFIELDS; f++) {
        float avg = 0.25f * (in[f*NCELLS + idx(j+1,i)] + in[f*NCELLS + idx(j-1,i)] +
                              in[f*NCELLS + idx(j,i+1)] + in[f*NCELLS + idx(j,i-1)]);
        float update = avg - cr * (frp.f[f] - frm.f[f]) - cz * (fzp.f[f] - fzm.f[f]);
        out[f*NCELLS + k] = update;
    }

    // Reload the updated cell for source term application
    cnew = load_cell(out, k);

    // ── Geometric source terms (cylindrical coordinates) ──
    // The (1/r) terms from ∂(rF)/∂r decomposition
    float irho0 = 1.0f / max(c0.rho, 1e-8f);
    float vr0 = c0.mr * irho0;
    float p0 = cell_pressure(c0);
    float pm0 = 0.5f * c0.bt * c0.bt / MU0;

    // -F_r / r geometric source (mass, r-mom, z-mom, energy)
    float inv_r = 1.0f / max(r_j, 1e-6f);
    cnew.rho -= p.dt * c0.rho * vr0 * inv_r;
    cnew.mr  -= p.dt * (c0.mr * vr0) * inv_r;
    // Centrifugal-like: +p_total/r (hoop stress)
    cnew.mr  += p.dt * (p0 + pm0) * inv_r;
    cnew.mz  -= p.dt * c0.mz * vr0 * inv_r;
    cnew.e   -= p.dt * (c0.e + p0 + pm0) * vr0 * inv_r;

    // ── Lorentz force source terms ──
    // Self-field Bθ already in the state
    // Applied field from coil arrays
    float Bz_app = Bz_field[k];
    float Br_app = Br_field[k];

    // Current density from curl B:
    // Jz = (1/μ₀)(1/r)∂(rBθ)/∂r
    // Jr = -(1/μ₀)∂Bθ/∂z
    // Jθ = (1/μ₀)(∂Br/∂z - ∂Bz/∂r) — from applied field
    float Bt_jp = cjp.bt, Bt_jm = cjm.bt;
    float Bt_ip = cip.bt, Bt_im = cim.bt;
    float r_jp = r_j + p.dr, r_jm = r_j - p.dr;

    float Jz_self = (1.0f / MU0) * (r_jp * Bt_jp - r_jm * Bt_jm) / (2.0f * p.dr * r_j);
    float Jr_self = -(1.0f / MU0) * (Bt_ip - Bt_im) / (2.0f * p.dz);

    // Applied field current (from coil geometry gradients)
    uint j_p = (j + 1 < NR) ? j + 1 : NR - 1;
    uint j_m = (j > 0) ? j - 1 : 0;
    uint i_p = (i + 1 < NZ) ? i + 1 : NZ - 1;
    uint i_m = (i > 0) ? i - 1 : 0;
    float Bz_jp = Bz_field[idx(j_p, i)];
    float Bz_jm = Bz_field[idx(j_m, i)];
    float Br_ip = Br_field[idx(j, i_p)];
    float Br_im = Br_field[idx(j, i_m)];
    float Jt_app = (1.0f / MU0) * ((Br_ip - Br_im) / (2.0f * p.dz) - (Bz_jp - Bz_jm) / (2.0f * p.dr));

    // Lorentz force: F = J × B
    // F_r = Jz·Bθ - Jθ·Bz  (self-field pinch + applied field)
    // F_z = Jr·Bθ - Jθ·Br  (electromagnetic thrust)
    float Fr_L = Jz_self * c0.bt - Jt_app * Bz_app;
    float Fz_L = Jr_self * c0.bt + Jt_app * Br_app;

    cnew.mr += p.dt * Fr_L;
    cnew.mz += p.dt * Fz_L;

    // Ohmic heating: η J² (Spitzer resistivity)
    float J2 = Jz_self*Jz_self + Jr_self*Jr_self + Jt_app*Jt_app;
    float T_eV = max(0.5f, cell_pressure(c0) * p.m_ion / (max(c0.rho, 1e-8f) * 1.38e-23f) / 11600.0f);
    float eta = 5.0e-5f / max(T_eV * T_eV * sqrt(T_eV), 0.1f); // Spitzer-like
    cnew.e += p.dt * eta * J2;

    // ── Safety floors + NaN protection ──
    if (isnan(cnew.rho) || isnan(cnew.mr) || isnan(cnew.mz) || isnan(cnew.e) || isnan(cnew.bt)) {
        // Fallback: copy from current state
        store_cell(out, k, c0);
        return;
    }
    cnew.rho = max(cnew.rho, 1e-10f);
    cnew.rho = min(cnew.rho, 1e2f);  // density ceiling
    cnew.mr = clamp(cnew.mr, -1e3f, 1e3f);
    cnew.mz = clamp(cnew.mz, -1e3f, 1e3f);
    cnew.bt = clamp(cnew.bt, -10.0f, 10.0f);
    float ke_new = 0.5f * (cnew.mr*cnew.mr + cnew.mz*cnew.mz) / max(cnew.rho, 1e-10f);
    float me_new = 0.5f * cnew.bt * cnew.bt / MU0;
    cnew.e = max(cnew.e, ke_new + me_new + 1e-6f);
    cnew.e = min(cnew.e, 1e8f);  // energy ceiling

    store_cell(out, k, cnew);
}

// ═══════════════════════════════════════════════════════════
// COMPUTE: Downsample fields for streaming
// Output: 6 fields × (NR/4) × (NZ/4) float32
// Fields: rho, T(eV), |v|, |B|, |J|, p
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

    // Average over DS×DS block
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

    float irho = 1.0f / max(rho, 1e-10f);
    float vr = mr * irho;
    float vz = mz * irho;
    float vmag = sqrt(vr*vr + vz*vz);
    float ke = 0.5f * (mr*mr + mz*mz) * irho;
    float me = 0.5f * bt * bt / MU0;
    float prs = max(GAMMA_M1 * (e - ke - me), 1e-6f);
    float T_eV = prs * p.m_ion / (max(rho, 1e-10f) * 1.38e-23f) / 11600.0f;
    float Bmag = sqrt(bt*bt + bz*bz);

    uint dk = dj * DSZ + di;
    output[0 * DS_CELLS + dk] = rho;
    output[1 * DS_CELLS + dk] = T_eV;
    output[2 * DS_CELLS + dk] = vmag;
    output[3 * DS_CELLS + dk] = Bmag;
    output[4 * DS_CELLS + dk] = vz;
    output[5 * DS_CELLS + dk] = vr;
}
