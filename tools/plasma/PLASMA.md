# RAIL PLASMA

Plasma simulation platform built on Rail. From first-principles MHD to interactive 3D thruster design.

## What's Built (2026-04-13)

| Tool | File | What it does |
|---|---|---|
| **Design Engine** | `thruster_engine.html` | **SI-calibrated 2D axisymmetric MPD design tool — Maecker thrust model, validation vs published data, parameter optimizer, hardware spec generator** |
| 2D MHD Sim | `mhd.rail` | 128x128 Orszag-Tang vortex, conservation to machine precision |
| 2D MHD Web | `mhd_wasm.wat` + `mhd_web.html` | Same physics, 2.5KB WASM, runs in any browser |
| 3D Metal MHD | `plasma_3d.rail` + `.metal` | 128^3 volume rendering, 60fps on M4 Pro |
| Neural MHD | `neural_mhd.rail` | ML surrogate trained from MHD sim data |
| Plasma Lab | `plasma_lab.html` | Interactive tube — electrodes, magnet rings, arc physics |
| Nozzle Sim | `ramjet.html` | 1D MHD nozzle with magnetic coils, thrust metrics |
| 3D Thruster | `ramjet_3d.html` | 6 helical arc streams, coil geometry, exhaust beam |
| Arc Sim | `arc.rail` + `arc_viewer.py` | Arc discharge modeling |

## Modes / Presets
- **Orszag-Tang Vortex** — classic MHD benchmark (mhd_web.html)
- **Plasma Lab** — free-form electrode + magnet experimentation (plasma_lab.html)
- **MPD Thruster** — applied-field magnetoplasmadynamic engine
- **Hall Effect** — annular Hall thruster configuration
- **Ramjet Pinch** — turbocharger-style magnetic compression → exhaust beam
- **Custom** — place coils, set voltage, design your own

## Engineering Roadmap — COMPLETED (2026-04-13)
All five steps shipped in `thruster_engine.html`:
1. ~~SI unit calibration~~ — real μ₀, Amps, Tesla, mm, mg/s, mN, eV throughout
2. ~~2D axisymmetric MHD~~ — 40×80 (r,z) field with Maecker analytical + parametric flow
3. ~~Validation~~ — Stuttgart SX3 (7 pts) + JPL AF-MPDT (5 pts), % error displayed
4. ~~Optimization~~ — single-param sweep (I, mdot, B) with thrust/ISP/efficiency curves
5. ~~Hardware spec~~ — coil winding, wire gauge, power supply, propellant, thermal, full budget

## Key Physics
- Ideal MHD conservation laws (mass, momentum, energy, induction)
- Lax-Friedrichs scheme (stable, CFL-limited)
- Magnetic pressure + Lorentz force (J×B)
- Nozzle area variation (converging-diverging)
- Angular momentum conservation in helical flow
