# Dormant: 3D Metal MHD volume solver

These files are not deleted, only parked. They were active during the
2026-04-16 Rail Plasma 3D push (128³ Metal compute + volume raymarcher,
60 fps on M4 Pro) but never wired into the public site or the daily
deploy after the 2026-04-20 stack consolidation.

  - `plasma_3d.metal`     — Metal compute kernel (128³ ideal MHD,
                             Lax-Friedrichs, periodic BCs)
  - `plasma_3d.rail`      — Rail driver that builds + dispatches the
                             Metal kernel and reads back state
  - `plasma_3d_host.m`    — Cocoa window + volume raymarcher

Why dormant rather than deleted: the volume raymarcher and Metal
double-buffered dispatch pattern are reusable seed material for any
future 3D extension of the unified kernel (`stdlib/mhd_kernel.rail`).
The numerics are identical-LF to the 2D case, so revival is mostly a
matter of plugging the unified kernel's MUSCL+minmod path into the
Metal compute body and adding a 3D source-pack module modeled on
`stdlib/mhd_mpd.rail`.

To revive: copy these back to `tools/plasma/`, replace the LF kernel
body with the MUSCL path from `mhd_axisym.metal`, and parameterize
the BCs (drop periodic + add inlet/outlet/wall in three dimensions).
