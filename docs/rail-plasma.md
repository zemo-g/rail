# RAIL PLASMA — MHD Simulator + Neural Surrogate

**What:** A magnetohydrodynamics simulator and neural surrogate, built entirely in Rail, running on Metal. Plasma interacting with magnetic fields — the physics of solar flares and fusion reactors — simulated, learned, and predicted by a single self-hosting language.

**Status:** BUILDING (2026-04-05)

---

## The Physics

Magnetohydrodynamics (MHD) couples fluid dynamics with electromagnetism. Plasma is an electrically conducting fluid — magnetic fields push it, and its motion reshapes the fields. They're locked together.

**6 conserved variables per cell:**
```
ρ     — density (mass per volume)
ρvx   — x-momentum
ρvy   — y-momentum
Bx    — magnetic field x-component
By    — magnetic field y-component
E     — total energy (kinetic + thermal + magnetic)
```

**3 conservation laws (our inductive biases):**
1. **Mass**: ∫ρ dV = const (mass doesn't appear or disappear)
2. **∇·B = 0**: magnetic monopoles don't exist (divergence-free B field)
3. **Total energy**: ∫E dV = const (in ideal MHD, no dissipation)

Law #2 is the hard one. Maintaining ∇·B = 0 numerically is so difficult there's an entire subfield ("divergence cleaning") dedicated to it. A neural surrogate that enforces this structurally would be significant.

**Test problem: Orszag-Tang Vortex**
Smooth initial conditions that evolve into shocks, current sheets, and magnetic islands:
```
Domain: [0, 2π]², periodic boundaries
ρ = γ²,  P = γ,  γ = 5/3
vx = -sin(y),  vy = sin(x)
Bx = -sin(y),  By = sin(2x)
```
By t ≈ π, the vortex develops thin current sheets where the magnetic field reverses direction. These sheets are sites of magnetic reconnection — the same process that causes solar flares.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     RAIL PLASMA                              │
│                                                              │
│  Phase 1: MHD Simulator (Rail, CPU)                         │
│  ├── 2D grid (float_arr, periodic BC)                       │
│  ├── Lax-Friedrichs scheme (stable, simple)                 │
│  ├── Orszag-Tang vortex initial conditions                  │
│  ├── Conservation diagnostics (mass, ∇·B, energy)          │
│  └── Field output (density, B magnitude, current sheets)    │
│           │                                                  │
│           │ generates training data                          │
│           ▼                                                  │
│  Phase 2: Data Pipeline                                      │
│  ├── Run sim at multiple resolutions (64², 128², 256²)      │
│  ├── Save snapshots: 4 frames in → 1 frame out              │
│  ├── Multiple initial conditions (vary amplitudes)           │
│  └── Binary float arrays (no external formats)              │
│           │                                                  │
│           ▼                                                  │
│  Phase 3: Neural Surrogate (Rail + Metal)                    │
│  ├── Uses existing railml.rail tensor ops                    │
│  ├── Uses existing Metal kernels (matmul, elementwise)       │
│  ├── Small ConvNet: input 6×4 fields → output 6 fields      │
│  ├── Conservation loss: mass + ∇·B=0 + energy               │
│  ├── Spectral loss (Kolmogorov weighting)                    │
│  └── Training loop in Rail                                   │
│           │                                                  │
│           ▼                                                  │
│  Phase 4: Real-Time Visualization (Metal render)             │
│  ├── Density as color field                                  │
│  ├── Magnetic field lines overlaid                           │
│  ├── Side-by-side: simulator | surrogate                     │
│  └── Conservation violation heatmap                          │
│                                                              │
│  ALL OF THIS IS RAIL. ONE LANGUAGE. ONE BINARY.              │
└─────────────────────────────────────────────────────────────┘
```

---

## What's Already Built (in tools/railml/)

| Component | Status | File |
|---|---|---|
| Tensor type (shape, strides, indexing) | DONE | railml.rail |
| Matmul (CPU, triple loop) | DONE | railml.rail |
| Elementwise ops (add, sub, mul, scale) | DONE | railml.rail |
| Tensor transpose | DONE | railml.rail |
| Tensor sum, mean | DONE | railml.rail |
| Gradient checking | DONE | railml.rail |
| Metal matmul (naive + tiled) | DONE | metal_kernels.metal |
| Metal elementwise (add, sub, mul, scale) | DONE | metal_kernels.metal |
| Metal activations (relu, gelu, exp, log) | DONE | metal_kernels.metal |

**We have the ML stack. Now we need the physics.**

---

## Phase 1: MHD Simulator

### Numerical Method: Lax-Friedrichs
Simplest stable finite-difference scheme for hyperbolic conservation laws.

For each cell (i,j), each field f:
```
U_new[f,i,j] = (U[f,i-1,j] + U[f,i+1,j] + U[f,i,j-1] + U[f,i,j+1]) / 4
               - dt/(2dx) * (Fx[i+1,j][f] - Fx[i-1,j][f])
               - dt/(2dy) * (Gy[i,j+1][f] - Gy[i,j-1][f])
```

Where Fx, Gy are the MHD flux vectors computed from the conservative state.

**CFL condition:** dt = CFL * dx / max_wave_speed, CFL ≤ 0.2 for 2D

**Fluxes in x:**
```
F[0] = ρvx                           (mass flux)
F[1] = ρvx² + Pt - Bx²              (x-momentum flux)
F[2] = ρvxvy - BxBy                  (y-momentum flux)
F[3] = 0                              (Bx: no x-flux by construction)
F[4] = vxBy - vyBx                   (By induction)
F[5] = (E + Pt)vx - Bx(v·B)         (energy flux)
```
where Pt = P + (Bx² + By²)/2 (total pressure = gas + magnetic)

**Fluxes in y:** (swap x↔y roles)
```
G[0] = ρvy
G[1] = ρvxvy - BxBy
G[2] = ρvy² + Pt - By²
G[3] = vyBx - vxBy
G[4] = 0
G[5] = (E + Pt)vy - By(v·B)
```

**Pressure recovery:**
P = (γ-1) * (E - ρ(vx²+vy²)/2 - (Bx²+By²)/2)

**Wave speed (fast magnetosonic, isotropic upper bound):**
cf = sqrt(γP/ρ + (Bx²+By²)/ρ)

### Data Layout
Single float_arr of size 6 × N × N.
Field f at cell (x,y): index = f × N² + y × N + x.
Periodic boundaries: wrap(i, N) = i mod N.

### Diagnostics (printed every M steps)
- Total mass: Σ ρ (should be constant)
- Total energy: Σ E (should be constant)
- Max |∇·B|: should be ≈ 0 (to machine precision for LxF)
- Min density: if this goes negative, scheme is unstable
- Current step, time, dt

### Output
- Raw field data to `/tmp/mhd_frame_NNNN.dat` (6×N×N floats as text)
- PGM images of density field to `/tmp/mhd_density_NNNN.pgm`
- Python helper for visualization (field overlay, B field lines)

---

## Phase 2: Data Pipeline

Generate training pairs from the simulator:
- Resolution: 128×128
- Input: 4 consecutive frames (24 channels: 6 fields × 4 timesteps)
- Output: 1 next frame (6 channels)
- Vary initial conditions: scale vortex amplitude by 0.5x, 0.75x, 1.0x, 1.25x, 1.5x
- ~500 timesteps per run, ~2500 training pairs total
- Store as binary Rail float arrays

---

## Phase 3: Neural Surrogate

Small ConvNet (not U-Net — start minimal):
- Input: 24 channels (6 fields × 4 frames)
- 3 layers: Conv(24→64, 7×7) → GELU → Conv(64→64, 5×5) → GELU → Conv(64→6, 3×3)
- Output: 6 channels (predicted next frame)
- ~100K params (tiny, fast, provable concept)

**Loss function (proven from The Well experiments):**
```
L = MSE + 10.0 * conservation + 0.1 * spectral

conservation = ((Σ ρ_pred - Σ ρ_target) / N²)²
            + ((max|∇·B_pred|)²)           ← NEW: divergence-free constraint

spectral = Σ |k|^(-5/3) * |FFT(pred) - FFT(target)|²
```

No momentum loss (bigger models exploit it — lesson from The Well experiments).

**Training:** Adam, warmup + cosine decay, conservation + spectral + divergence-free. All in Rail on Metal.

---

## Phase 4: Visualization (stretch goal)

Metal compute shader for the sim + Metal render shader for the display. Same GPU, same frame. Real-time plasma dynamics rendered directly from Rail.

---

## Timeline

| Phase | What | Effort |
|---|---|---|
| 1a | MHD sim, Orszag-Tang, diagnostics | NOW |
| 1b | PGM output, visual verification | 1 day |
| 2 | Data generation pipeline | 1 day |
| 3 | Surrogate training in Rail | 3-5 days |
| 4 | Real-time visualization | stretch |

Phase 1a starts now.
