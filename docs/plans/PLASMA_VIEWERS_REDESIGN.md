# Plasma viewers — unified design pass

Date: 2026-05-10
Scope: `tools/plasma/{mobile.html, live4k.html, holo.html}`
Goal: three viewers, one identity. Plasma is the hero; diagnostics are
opt-in. Each viewer differentiates by what it can render, not by what
chrome it puts around the canvas.

---

## 1. The single design rule

**Default state: nothing on screen but the simulation, a small home
mark, and a single "details" affordance.**

Everything else (pulse_id, value_hex, mass, energy, ∇·B, sim_time,
camera presets, annotations) lives behind one toggle. Press `i` or
click the affordance to slide in a diagnostic drawer. Click outside
or press `esc` to close. Diagnostics are *available* but not in the
way.

This single rule resolves 80% of the current visual noise.

---

## 2. Shared layer — `tools/plasma/_shared/viewer.css`

Single stylesheet, token-driven, loaded by all three viewers. Each
viewer keeps a small inline `<style>` block only for canvas-specific
sizing rules (mobile centers a square; live4k/holo go fullbleed).

### 2.1 Tokens (CSS custom properties on `:root`)

```css
:root {
  /* palette — pulled from viridis to bind chrome to simulation */
  --bg:           #04060a;            /* deeper than #000 — neutral, not pure black */
  --fg:           #e6f0ff;            /* primary text */
  --fg-dim:       hsl(214, 30%, 78%); /* secondary text */
  --fg-mute:      hsl(214, 22%, 56%); /* tertiary text, hashes */
  --accent:       #FDE725;            /* viridis end (yellow) — sparing use */
  --accent-cool:  #21918C;            /* viridis mid (teal) — main interactive */
  --accent-deep:  #3B528B;            /* viridis early (blue-violet) */
  --err:          #ff7d6b;
  --warn:         #ffb84d;
  --ok:           #6f6;

  /* surfaces */
  --panel-bg:     hsla(218, 56%, 7%, 0.66);
  --panel-edge:   hsla(214, 80%, 70%, 0.18);
  --hairline:     hsla(214, 80%, 70%, 0.10);
  --shadow-text:  0 1px 12px rgba(0,0,0,0.96);

  /* type */
  --font-display: 'Sora', system-ui, -apple-system, sans-serif;
  --font-body:    'Sora', system-ui, -apple-system, sans-serif;
  --font-mono:    'IBM Plex Mono', ui-monospace, Menlo, monospace;

  /* sizing */
  --space-1: 0.25rem;
  --space-2: 0.5rem;
  --space-3: 0.75rem;
  --space-4: 1rem;
  --space-6: 1.5rem;
  --radius:  4px;
}
```

**Why this palette.** Cyan-only chrome over viridis-rendered physics
makes the chrome and the data feel unrelated. Pulling --accent-cool
from viridis-mid (`#21918C`) and --accent from viridis-end (`#FDE725`)
binds the two halves visually. Yellow is reserved for "live / verified
/ active" only — sparing use keeps it precious.

### 2.2 Component classes

```
.viewer-root           — the page container (replaces ad-hoc <body>)
.viewer-stage          — the canvas hero region; sets stacking + breathing room
.viewer-mark           — small top-left brand: "ledatic / plasma"
.viewer-back           — bottom-left "← ledatic.org" home link
.viewer-status         — bottom-right: just live-dot + pulse_id (the smallest possible "this is live" signal)
.viewer-details-btn    — top-right floating "i" / "details" button
.viewer-drawer         — slide-in diagnostic panel (right side, ~22rem wide)
.viewer-drawer.open    — visible state
.viewer-drawer .group  — diagnostic section header
.viewer-drawer .row    — label / value pair
.viewer-drawer .spark  — the small inline charts already in holo
.viewer-drawer .hash   — value_hex etc, monospace, word-break, full opacity
```

**Hierarchy.** `.viewer-mark` uses --font-display at 13px; `.viewer-back`
and `.viewer-status` use --font-mono at 10px, opacity 0.55. The
diagnostic drawer is the only place mono numerics appear at full
opacity. This creates real hierarchy: brand > navigation > status >
diagnostics.

### 2.3 Default-hidden, peek-on-hover

```
.viewer-mark, .viewer-back, .viewer-status {
  opacity: 0.55;
  transition: opacity 220ms ease;
}
.viewer-root:hover .viewer-mark,
.viewer-root:hover .viewer-back,
.viewer-root:hover .viewer-status { opacity: 0.95; }
```

The chrome fades to almost-invisible after a few seconds of stillness;
hover or any pointer movement brings it back. On touch devices we
gate this behind a tap-to-reveal toggle (no hover). Net effect: the
plasma owns the screen.

---

## 3. Per-viewer differentiation

The three viewers should feel like the same product showing different
faces — not three separate apps.

| Viewer       | Hero            | Drawer contents                                                         | Camera affordance         |
|--------------|-----------------|--------------------------------------------------------------------------|---------------------------|
| mobile.html  | Centered square | pulse_id · step · ρ-range · timestamp · value_hex · verify link         | None (canvas is fixed)    |
| live4k.html  | Full-bleed 2D   | + solver/renderer descriptors, error log moved into drawer "diagnostics"| None                      |
| holo.html    | Full-bleed 3D   | + 4 conservation panels (mass / energy / ∇·B / ρ_min·dt) with sparklines | iso/front/side/top inline |

**Holo specifically**:
- The 6 floating annotations (`vortex pair · NE` etc.) → **deleted**.
  They're textbook captions, not signage. Anyone who needs them is
  reading the `_shared/wasm_render.js` source.
- The PiP top-down → **kept**, but moved into the drawer as a section,
  not floating in the corner. It becomes "drawer: also show 2D top-down
  for context."
- Camera presets (iso/front/side/top) → kept inline at top-center but
  styled as text-only links (no boxes), opacity 0.5 default → 0.95 on
  hover. They earn their screen time because they change what you see.
- Audio toggle → moved to drawer footer.

---

## 4. Diagnostic drawer — the one toggle

Trigger: top-right `i` button (12×12 px circle, --accent-cool border)
or hotkey `i` / `?`. Closes on `esc`, click-outside, or re-press.

Animation: 220ms ease `transform: translateX(100%) → 0` (slide from
right). Backdrop `rgba(0,0,0,0.18)` fades in alongside.

Drawer width: `min(22rem, 100vw - 2rem)`. On phones it becomes a
bottom-sheet (`transform: translateY(100%) → 0`) so the canvas stays
in the user's eye line.

Inside the drawer:

```
┌─ STATUS ───────────────────────┐
│  pulse_id    811491            │
│  timestamp   2026-05-10 14:32  │
│  step        47,128            │
│  value_hex   a4f1...c08e       │
│              [verify →]        │
├─ CONSERVATION (holo only) ─────┤
│  mass        1.0000  Δ 1e-14   │
│  energy      0.5000  Δ 4e-15   │
│  ∇·B max     1e-13   ✓         │
│  ρ min · dt  0.05 · 0.001      │
├─ SOLVER ───────────────────────┤
│  2D MHD · Orszag-Tang          │
│  128² · 6-channel f32          │
└────────────────────────────────┘
```

Section headers in `--font-display` 9.5px uppercase, letter-spacing
0.18em, color `--fg-mute`. Rows in `--font-mono` 11.5px. Values right-
aligned, tabular-nums.

---

## 5. Verify link is a first-class affordance

Currently `value_hex` floats in the corner with no call-to-action. Add
a `[verify →]` link directly under it (in the drawer) that links to
`https://ledatic.org/verify/<sha>` or the equivalent. This converts a
mute hash into the only thing that actually matters about the hash:
*you can independently verify it*.

---

## 6. Migration steps (suggested order)

1. **Land `_shared/viewer.css`** with tokens + component classes
   (no consumer changes yet). ~250 lines.
2. **Convert mobile.html first** (smallest, simplest). Strip its
   inline style block; add the new shared classes; move HUD content
   into a drawer skeleton; wire the toggle. Verify on iPhone Safari.
3. **Convert live4k.html.** Move the on-screen errlog into the drawer
   as a "diagnostics" section. Drop the redundant TL solver/renderer
   description (already in drawer's "solver" section).
4. **Convert holo.html — the big one.** Remove 6 floating annotations
   entirely. Move PiP into drawer. Style camera presets as link text.
   Move audio toggle. This file goes from 1972 lines to ~1500.
5. **Smoke test** all three on Studio + iPhone via Tailnet. Confirm
   beacon polls + frame renders are unchanged. (CSS-only refactor;
   render code untouched.)
6. **Deploy.** All three viewers are static-served; deployment paths
   match current ones (worker / KV / wherever they live today).

Each step is independently reversible: viewer.css changes only affect
files that import it. Step 1 can land alone, before any consumer edits.

---

## 7. What we're NOT changing

- The render pipelines themselves (Canvas 2D, WebGL2, WebGPU).
- The beacon contract / frame format / poll cadence.
- The fallback chain (live4k → mobile on touch / no-WebGL2).
- The Rail-WASM `wasm_render.js` layer.
- Any conservation / verification / attestation logic.

This is a chrome-only pass. Every byte of physics code is preserved.

---

## 8. Open questions

- Should the drawer remember its open/closed state in
  `localStorage`? (Power users want it open; first-time visitors
  shouldn't see it.)
- Hotkey `i` collides with browser "italic" in form fields — does
  that matter here (the canvas isn't a form)? `?` is safer.
- Sora is already pulled in by ledatic.org top-level pages but adds
  ~30KB woff2. Worth it for one display-font header? Probably yes —
  hierarchy is the single biggest weakness today.
- Verify-link target: do we have a `/verify/<value_hex>` route, or
  does it have to be `/verify` + hash query string?

---

## 9. Success criteria

After this pass, all three viewers should:

1. Open with a clean canvas; chrome occupies < 5% of screen at rest.
2. Share one stylesheet, one palette, one font stack, one component
   vocabulary.
3. Render diagnostics on demand without ever needing the user to
   memorize what `value_hex` or `m_divb` mean (the drawer self-labels).
4. Feel like part of ledatic.org — the brand mark + back link tie
   them to the site even when they're embedded in a tweet or a kiosk.

If a stranger lands on `/holo` and the only thing they remember is
"the plasma was beautiful, and I knew where to click to see what was
under the hood" — we shipped it.
