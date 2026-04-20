#!/usr/bin/env python3
"""mhd_ot_beacon.py — 2D ideal-MHD Orszag-Tang solver for the ledatic.org
entropy beacon.

Continuously writes /tmp/plasma_live.bin in the binary frame format the
entropy_beacon.sh pipeline expects:

  uint32 W   uint32 H   uint32 NFIELDS   uint32 frame_id
  float32[8] metrics   (mass, energy, divB_max, rho_min, dt, sim_time, 0, 0)
  float32[NFIELDS * W * H] planes   (ρ, vx, vy, p, Bx, By)

Physics: Orszag-Tang initial condition on a periodic 2π × 2π domain, ideal
MHD (γ = 5/3), Lax-Friedrichs scheme with CFL-adaptive dt. Resets at t = π
to keep the beacon a live-looking chaotic field forever.

Numerical safeguards:
  - Pressure floor (no negative p).
  - Density floor (no rho → 0 that would explode v = ρv / ρ).
  - CFL adaptive dt with safety factor 0.3.
  - Reinitialize on any NaN or if sim_time exceeds π.

Runtime: numpy array ops — ~3-5 ms/step at 128², ~10 Hz frame rate with
STEPS_PER_FRAME = 4.
"""

import os
import struct
import sys
import time

import numpy as np

N = 128                                # grid
L = 2.0 * np.pi
DX = L / N
GAMMA = 5.0 / 3.0
FRAME_PATH = "/tmp/plasma_live.bin"
FRAME_TMP = FRAME_PATH + ".tmp"
STEPS_PER_FRAME = 4                    # solver steps per published frame
TARGET_FPS = 4                         # cap publish rate (CF write budget)
T_RESET = np.pi                        # reset after t = π so sim always live
CFL = 0.3
RHO_FLOOR = 1e-6
P_FLOOR = 1e-6


def init_state():
    """Orszag-Tang vortex initial conditions (canonical dimensionless units)."""
    x = np.linspace(0.0, L, N, endpoint=False)
    X, Y = np.meshgrid(x, x, indexing="ij")
    rho = np.full((N, N), 25.0 / (36.0 * np.pi), dtype=np.float64)
    vx = -np.sin(Y)
    vy = np.sin(X)
    p = np.full((N, N), 5.0 / (12.0 * np.pi), dtype=np.float64)
    Bx = -np.sin(Y) / np.sqrt(4.0 * np.pi)
    By = np.sin(2.0 * X) / np.sqrt(4.0 * np.pi)
    return rho, vx, vy, p, Bx, By


def primitive_to_conservative(rho, vx, vy, p, Bx, By):
    mx = rho * vx
    my = rho * vy
    b2 = Bx * Bx + By * By
    v2 = vx * vx + vy * vy
    E = p / (GAMMA - 1.0) + 0.5 * rho * v2 + 0.5 * b2
    return rho, mx, my, E, Bx, By


def conservative_to_primitive(U):
    rho, mx, my, E, Bx, By = U
    rho = np.maximum(rho, RHO_FLOOR)
    vx = mx / rho
    vy = my / rho
    b2 = Bx * Bx + By * By
    v2 = vx * vx + vy * vy
    p = (GAMMA - 1.0) * (E - 0.5 * rho * v2 - 0.5 * b2)
    p = np.maximum(p, P_FLOOR)
    return rho, vx, vy, p, Bx, By


def fluxes(U):
    """x- and y-direction fluxes for ideal MHD, 6-variable state."""
    rho, vx, vy, p, Bx, By = conservative_to_primitive(U)
    b2 = Bx * Bx + By * By
    pt = p + 0.5 * b2                                      # total pressure
    mx, my = rho * vx, rho * vy
    E = p / (GAMMA - 1.0) + 0.5 * rho * (vx * vx + vy * vy) + 0.5 * b2
    vdotb = vx * Bx + vy * By

    Fx = (
        mx,
        mx * vx + pt - Bx * Bx,
        mx * vy - Bx * By,
        (E + pt) * vx - Bx * vdotb,
        np.zeros_like(rho),
        vx * By - vy * Bx,
    )
    Fy = (
        my,
        my * vx - Bx * By,
        my * vy + pt - By * By,
        (E + pt) * vy - By * vdotb,
        vy * Bx - vx * By,
        np.zeros_like(rho),
    )
    return Fx, Fy


def max_wave_speed(rho, vx, vy, p, Bx, By):
    """Fast magnetosonic wave speed + flow, max across grid."""
    a2 = GAMMA * p / rho
    b2 = (Bx * Bx + By * By) / rho
    cf = np.sqrt(a2 + b2)
    return float(np.max(np.sqrt(vx * vx + vy * vy) + cf))


def lax_friedrichs_step(U, dt):
    """One Lax-Friedrichs step with periodic boundaries."""
    Fx, Fy = fluxes(U)
    lam = dt / DX
    new = []
    for k, Uk in enumerate(U):
        fx = Fx[k]
        fy = Fy[k]
        avg = 0.25 * (
            np.roll(Uk, -1, axis=0) + np.roll(Uk, 1, axis=0)
            + np.roll(Uk, -1, axis=1) + np.roll(Uk, 1, axis=1)
        )
        dfx = np.roll(fx, -1, axis=0) - np.roll(fx, 1, axis=0)
        dfy = np.roll(fy, -1, axis=1) - np.roll(fy, 1, axis=1)
        new.append(avg - 0.5 * lam * dfx - 0.5 * lam * dfy)
    return tuple(new)


def total_mass(rho):
    return float(np.sum(rho)) * DX * DX


def total_energy(U):
    return float(np.sum(U[3])) * DX * DX


def max_divb(Bx, By):
    dBx = (np.roll(Bx, -1, axis=0) - np.roll(Bx, 1, axis=0)) / (2.0 * DX)
    dBy = (np.roll(By, -1, axis=1) - np.roll(By, 1, axis=1)) / (2.0 * DX)
    return float(np.max(np.abs(dBx + dBy)))


def write_frame(path_tmp, path_final, frame_id, U, sim_time, dt, m0, e0):
    """Write the binary frame atomically (rename after full write)."""
    rho, vx, vy, p, Bx, By = conservative_to_primitive(U)

    header = struct.pack("<IIII", N, N, 6, frame_id)
    metrics = struct.pack(
        "<8f",
        total_mass(rho),
        total_energy(U),
        max_divb(Bx, By),
        float(rho.min()),
        float(dt),
        float(sim_time),
        float(m0),
        float(e0),
    )

    # Single-precision for network friendliness. min-max normalization
    # happens on the client.
    planes = np.stack(
        [rho.astype(np.float32),
         vx.astype(np.float32),
         vy.astype(np.float32),
         p.astype(np.float32),
         Bx.astype(np.float32),
         By.astype(np.float32)]
    )
    # Flatten planes: [c, j, i] so the beacon reader sees
    # plane-major layout (all of ρ, then all of vx, ...).
    with open(path_tmp, "wb") as f:
        f.write(header)
        f.write(metrics)
        f.write(planes.tobytes(order="C"))
    os.replace(path_tmp, path_final)


def run():
    print(f"mhd_ot_beacon: starting (N={N}, STEPS_PER_FRAME={STEPS_PER_FRAME})", flush=True)

    rho, vx, vy, p, Bx, By = init_state()
    U = primitive_to_conservative(rho, vx, vy, p, Bx, By)
    m0 = total_mass(U[0])
    e0 = total_energy(U)
    sim_time = 0.0
    frame_id = 0
    last_log = time.monotonic()
    last_frame_ts = 0.0

    while True:
        # Reset if sim exited physical window
        bad = any(np.any(~np.isfinite(Uk)) for Uk in U)
        if bad or sim_time > T_RESET:
            if bad:
                print("mhd_ot_beacon: reinit (non-finite state)", flush=True)
            rho, vx, vy, p, Bx, By = init_state()
            U = primitive_to_conservative(rho, vx, vy, p, Bx, By)
            sim_time = 0.0

        dt = CFL * DX / max_wave_speed(*conservative_to_primitive(U))

        for _ in range(STEPS_PER_FRAME):
            U = lax_friedrichs_step(U, dt)
            sim_time += dt

        # Throttle publish rate
        now = time.monotonic()
        gap = now - last_frame_ts
        target_gap = 1.0 / TARGET_FPS
        if gap < target_gap:
            time.sleep(target_gap - gap)
            now = time.monotonic()
        last_frame_ts = now

        write_frame(FRAME_TMP, FRAME_PATH, frame_id, U, sim_time, dt, m0, e0)
        frame_id += 1

        if now - last_log >= 10.0:
            rho_now, _, _, p_now, Bx_now, By_now = conservative_to_primitive(U)
            mass = total_mass(rho_now)
            energy = total_energy(U)
            divb = max_divb(Bx_now, By_now)
            print(
                f"frame {frame_id}  t={sim_time:.4f}  dt={dt:.2e}  "
                f"ρ∈[{rho_now.min():.3f},{rho_now.max():.3f}]  "
                f"p∈[{p_now.min():.3f},{p_now.max():.3f}]  "
                f"|B|max={float(np.sqrt(Bx_now**2+By_now**2).max()):.3f}  "
                f"Δm/m={abs(mass-m0)/m0:.2e}  "
                f"Δe/e={abs(energy-e0)/e0:.2e}  "
                f"max|∇·B|={divb:.2e}",
                flush=True,
            )
            last_log = now


if __name__ == "__main__":
    try:
        run()
    except KeyboardInterrupt:
        print("mhd_ot_beacon: stopped", flush=True)
        sys.exit(0)
