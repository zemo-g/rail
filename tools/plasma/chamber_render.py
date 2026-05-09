"""chamber_render.py — numpy port of render.rail's chamber_render kernel.

Server-side path: mhd_ot_beacon.py calls render_chamber(rho, vx, vy, Bx, By)
once per published frame.  Output is a 128×128 RGB8 image (49152 bytes).

The algorithm mirrors `chamber_render` in tools/plasma/render.rail.  Both
render the same volumetric raymarch through the cylindrical chamber; both
should produce byte-identical output given the same plane field.  WASM
clients can re-render and check against the server's bytes for audit.

Algorithm (matches render.rail line-for-line):
  - For each (px, py) in [0, 128)²:
      build a ray from the iso camera through the pixel
      intersect a cylinder of radius 50, half-height 30 centered at origin
      if miss → background (8, 14, 28)
      if hit  → march 12 steps from t_enter to t_exit:
          sample plane fields at the projected point
          density → viridis-mapped emission
          vorticity proxy (vx*By - vy*Bx) → cyan/magenta tint
          Beer-Lambert opacity: alpha_step = 1 - exp(-sigma * dt)
          accumulate (front-to-back compositing)
      ACES tonemap accumulator → RGB8
"""

import numpy as np

# ── Constants ────────────────────────────────────────────────────────
# Simulation grid stays 128² (matches the MHD solver).  Output image
# is super-sampled to 256² for visible plasma detail at viewer scale.
# Per-frame cost on M1: ~80-120 ms numpy-vectorized.  Wire payload:
# 256*256*3 = 196608 bytes per chamber section.
N = 128                  # solver grid (input)
IMG_W = 256              # rendered image (output)
IMG_H = 256
IMG_BYTES = IMG_W * IMG_H * 3   # 196608

MARCH_STEPS = 8           # fewer steps → less depth-averaging blur

# Camera (iso, fixed for v1)
CAM_OX, CAM_OY, CAM_OZ = 96.0, 96.0, 50.0
FWD_X, FWD_Y, FWD_Z    = -0.6635, -0.6635, -0.3456
RIGHT_X, RIGHT_Y       = -0.7071, 0.7071
UP_X, UP_Y, UP_Z       = -0.244, -0.244, 0.939
VIEW_EXTENT            = 100.0

# Cylinder
CYL_RADIUS  = 50.0
CYL_RADIUS2 = CYL_RADIUS * CYL_RADIUS
CYL_HALFH   = 30.0

# Background colour for cylinder misses (matches render.rail).
BG_RGB = np.array([8, 14, 28], dtype=np.uint8)

# Viridis 5-stop colormap (matches mobile.html + render.rail).
_VIRIDIS_STOPS = np.array([
    [0.00, 0.267, 0.004, 0.329],
    [0.25, 0.231, 0.322, 0.545],
    [0.50, 0.129, 0.565, 0.553],
    [0.75, 0.365, 0.788, 0.388],
    [1.00, 0.992, 0.906, 0.145],
])


def _viridis_lut(n=256):
    """Bake the piecewise-linear 5-stop colormap into an n×3 LUT."""
    out = np.empty((n, 3), dtype=np.float32)
    ts = np.linspace(0.0, 1.0, n, dtype=np.float32)
    for i, t in enumerate(ts):
        for j in range(len(_VIRIDIS_STOPS) - 1):
            lo = _VIRIDIS_STOPS[j]
            hi = _VIRIDIS_STOPS[j + 1]
            if lo[0] <= t <= hi[0]:
                u = (t - lo[0]) / (hi[0] - lo[0] or 1.0)
                out[i, 0] = lo[1] + (hi[1] - lo[1]) * u
                out[i, 1] = lo[2] + (hi[2] - lo[2]) * u
                out[i, 2] = lo[3] + (hi[3] - lo[3]) * u
                break
    return out

_VIRIDIS = _viridis_lut(256)


def _aces(x):
    """ACES tonemap (Krzysztof Narkowicz approximation), elementwise."""
    x = np.maximum(x, 0.0)
    num = x * (2.51 * x + 0.03)
    den = x * (2.43 * x + 0.59) + 0.14
    return np.clip(num / den, 0.0, 1.0)


def _grad_field(field):
    """Central-difference gradient with periodic wrap.  Returns (gx, gy)."""
    gx = (np.roll(field, -1, axis=1) - np.roll(field, 1, axis=1)) * 0.5
    gy = (np.roll(field, -1, axis=0) - np.roll(field, 1, axis=0)) * 0.5
    return gx, gy


def render_chamber(rho, vx, vy, Bx, By):
    """Render a 256×256 RGB8 image of the plasma disc.

    Pivot from volumetric raymarch to flat 2D projection: the simulation
    IS 2D, so depth integration was averaging 8 cells per pixel into
    haze.  Direct 2D projection through a circular aperture (top-down
    view of the chamber) gives one sim-cell per output pixel — max
    spatial detail.

    Pipeline:
      1. Per output pixel, map (px, py) → simulation cell via direct
         orthographic projection (the plasma disc fills the image).
      2. Mask to a circular aperture for the chamber silhouette.
      3. Build emission per pixel:
           base   = viridis(log-density)
           tint   = vorticity-driven cyan↔magenta lerp
           edges  = schlieren ∇ρ brightening (shock fronts as bright lines)
           glow   = magnetic |B|² additive blue
      4. Tonemap + saturation + gamma + unsharp + rim glow.
    """
    # ── 1. Pre-compute fields at simulation resolution ────────────────
    drx, dry = _grad_field(rho)
    grad_rho = np.sqrt(drx * drx + dry * dry).astype(np.float32)
    bmag2 = (Bx * Bx + By * By).astype(np.float32)
    dvy_dx, _ = _grad_field(vy)
    _, dvx_dy = _grad_field(vx)
    vort = (dvy_dx - dvx_dy).astype(np.float32)

    # ── 2. Direct 2D projection: each output pixel ↔ one sim cell ──────
    # Map the 256×256 output to a [0, 128) sim-cell coordinate, with the
    # plasma disc inscribed in the image.  Square mapping; cylinder
    # silhouette comes from a circular mask in the next step.
    py_idx = np.arange(IMG_H, dtype=np.float32)
    px_idx = np.arange(IMG_W, dtype=np.float32)
    PY_IDX, PX_IDX = np.meshgrid(py_idx, px_idx, indexing='ij')
    # Map output [0, 256) → sim [0, 128) via integer halving.  Each 2×2
    # output block reads the same sim cell — preserves the cell-aligned
    # detail.
    sx = (PX_IDX * 0.5).astype(np.int32) % N
    sy = ((IMG_H - 1 - PY_IDX) * 0.5).astype(np.int32) % N    # y-flip

    rho_s   = rho[sy, sx].astype(np.float32)
    vort_s  = vort[sy, sx]
    grad_s  = grad_rho[sy, sx]
    bmag2_s = bmag2[sy, sx]

    # Aperture: circular cross-section of the cylinder.  cx, cy in image
    # coords; r in image coords.  Anything outside is background.
    cx = (IMG_W - 1) * 0.5
    cy = (IMG_H - 1) * 0.5
    r_image = np.sqrt((PX_IDX - cx) ** 2 + (PY_IDX - cy) ** 2)
    r_max = min(IMG_W, IMG_H) * 0.47
    inside = r_image <= r_max
    # Soft inner gradient toward the rim for a faint vignette feel.
    rim_d = (r_max - r_image) / r_max
    rim_d = np.clip(rim_d, 0.0, 1.0)

    # ── 3. Per-pixel emission ──────────────────────────────────────────
    # Density colormapping — log-curved for dynamic range.
    rho_log = np.log1p(np.maximum(rho_s - 0.15, 0.0)) * 0.65
    rho_n = np.clip(rho_log, 0.0, 1.0)
    idx = (rho_n * 255).astype(np.int32)
    c_rgb = _VIRIDIS[idx]   # (H, W, 3)

    # Vorticity tint (smooth lerp).
    vort_n = np.clip(vort_s * 8.0, -1.0, 1.0)
    ccw = (vort_n + 1.0) * 0.5
    tint_r = 1.0 - 0.42 * ccw
    tint_g = 0.58 + 0.42 * ccw
    tint_b = np.full_like(tint_r, 0.96, dtype=np.float32)

    # Schlieren edge brightening — ∇ρ peaks at shock fronts.  Strong
    # because there's no longer depth integration to wash it out.
    edge_boost = 1.0 + np.minimum(grad_s * 8.0, 2.0)

    # HDR core overshoot — densest cells push past unity.
    hdr_core = np.maximum(rho_s - 1.8, 0.0) * 0.5

    # Magnetic glow (additive cyan-blue).
    bglow = np.sqrt(bmag2_s) * 0.22

    emission = np.empty_like(c_rgb)
    emission[..., 0] = c_rgb[..., 0] * tint_r * edge_boost + bglow * 0.05 + hdr_core * 0.5
    emission[..., 1] = c_rgb[..., 1] * tint_g * edge_boost + bglow * 0.22 + hdr_core * 0.7
    emission[..., 2] = c_rgb[..., 2] * tint_b * edge_boost + bglow * 0.55 + hdr_core * 0.95

    # Inner-rim vignette (very subtle).
    emission *= (0.85 + 0.15 * rim_d[..., None])

    # ── 4. Tonemap + saturation + gamma + unsharp + rim glow ───────────
    accum_rgb = emission * 0.95
    tm = _aces(accum_rgb)

    # Saturation pump — vortex tints punch through.
    lum = (tm * np.array([0.299, 0.587, 0.114], dtype=np.float32)).sum(-1, keepdims=True)
    tm = lum + (tm - lum) * 1.45

    # Gamma sharpen.
    tm = np.clip(tm, 0.0, 1.0) ** 0.78

    # Unsharp mask — boost edges + filaments.
    blur = (
        np.roll(tm, 1, axis=0) + np.roll(tm, -1, axis=0) +
        np.roll(tm, 1, axis=1) + np.roll(tm, -1, axis=1) +
        tm * 4.0
    ) / 8.0
    tm = np.clip(tm + (tm - blur) * 0.7, 0.0, 1.0)

    # Cylinder rim glow — soft cyan ring at the silhouette.
    rim_band = np.exp(-((r_image - r_max) ** 2) * 0.05)
    rim_color = np.array([0.20, 0.55, 0.85], dtype=np.float32)
    tm += rim_color * rim_band[..., None] * 0.32

    # ── 5. Composite + return ──────────────────────────────────────────
    bg = BG_RGB.astype(np.float32) / 255.0
    rgb = np.where(inside[..., None], np.clip(tm, 0.0, 1.0), bg)
    rgb_u8 = np.clip(rgb * 255.0, 0.0, 255.0).astype(np.uint8)
    return rgb_u8.tobytes(order='C')


if __name__ == '__main__':
    # Smoke test: build an OT IC numerically, render, save PNG.
    import sys
    L = 2.0 * np.pi
    DX = L / N
    x = np.linspace(0.0, L, N, endpoint=False)
    X, Y = np.meshgrid(x, x, indexing='ij')
    rho = np.full((N, N), 25.0 / (36.0 * np.pi), dtype=np.float64)
    vx = -np.sin(Y)
    vy =  np.sin(X)
    Bx = -np.sin(Y) / np.sqrt(4.0 * np.pi)
    By =  np.sin(2.0 * X) / np.sqrt(4.0 * np.pi)

    import time
    t0 = time.perf_counter()
    img = render_chamber(rho, vx, vy, Bx, By)
    t1 = time.perf_counter()
    print(f"rendered {len(img)} bytes in {(t1-t0)*1000:.1f} ms", file=sys.stderr)

    out = '/tmp/chamber_py.bin'
    with open(out, 'wb') as f:
        f.write(img)
    print(f"wrote {out}", file=sys.stderr)
