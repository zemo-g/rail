# Plasma renderer on Rail-WASM (Tier 3 design)

## Goal

The viewer's compute layer is Rail compiled to WASM. Decoder, derived-field
computation (vorticity, |J|, LIC accumulator, particle integrator) — all
expressed in Rail, compiled to WebAssembly via the existing WASM backend,
glued to a WebGL2/WebGPU rasterizer in the browser.

## Why this is on-thesis

The site's claim is *Rail runs on Rail. The rest runs on physics.* Today
that holds on the **server**: the public beacon is `tools/plasma/mhd_beacon.rail`,
hashing is `stdlib/sha256.rail`, attestation signing is pure-Rail Ed25519
(`b393a50`), the publisher is Rail-native (`90bae75`).

The viewer side breaks the symmetry — it's hand-rolled JS doing the
post-processing. Tier 3 closes the loop: the *same Rail toolchain* that
generates the pulse generates its visualization compute. A reader can then
walk a single chain, in one language, from physics → bytes → public hash
→ pixel.

## What's already shipped (the substrate is here)

- WASM backend in compile.rail — closures, ADTs, pattern match, arena
  mark/reset all work (`07959b4`, `2d90df6`, `eb1c40f`)
- `tools/plasma/mhd_wasm.rail` — MHD running in WASM end-to-end
- `stdlib/tensor.rail` semantics + foreign-call patterns
- The browser-side glue pattern: `tools/plasma/mhd_web.html` already loads
  Rail-built WASM and reads/writes its linear memory

## Current gap (Tier 0 baseline → Tier 3)

`tools/plasma/live4k.html` (Tier 0) does post-processing in GLSL. The
fragment shader computes vorticity, schlieren, LIC accumulation per pixel
each frame. That's correct and fast, but:

1. The compute is opaque to anyone not reading GLSL.
2. The same code can't be re-used by a CLI Rail tool that wants the same
   derived fields (e.g. for headless benchmark renders, or for the witness
   chain to verify what the public is seeing).
3. It's not Rail.

Tier 3 moves the *non-rasterization* compute into Rail-WASM, shared with
the same Rail code path that any host tool would call.

## Architecture

```
  ┌────────────────────────────┐    fetch every 2s    ┌────────────────────┐
  │ ledatic.org/entropy/frame  │─────────────────────▶│ browser            │
  │  393264-byte f32 frame     │                       │                    │
  └────────────────────────────┘                       │  ┌──────────────┐  │
                                                       │  │ Rail-WASM    │  │
   ┌──────────────────────────┐  rebuilt from same     │  │  module      │  │
   │ tools/plasma/render.rail │  source, no glue drift │  │  (.wasm)     │  │
   │  decode_frame            │◀──── compile to ──────▶│  │              │  │
   │  vorticity               │      WASM via          │  │  exports:    │  │
   │  current_density (∇×B)   │      ./rail_native     │  │   decode     │  │
   │  schlieren               │      wasm render.rail  │  │   derive     │  │
   │  lic_accumulate          │                        │  │   particles  │  │
   │  particle_step           │                        │  └──────┬───────┘  │
   │  derive_metrics          │                        │         │          │
   └──────────────────────────┘                        │         │ writes   │
                                                       │         ▼          │
                                                       │  SharedArrayBuffer │
                                                       │  (linear memory)   │
                                                       │         │          │
                                                       │         │ uploads  │
                                                       │         ▼          │
                                                       │  WebGL2/WebGPU     │
                                                       │  fragment shader   │
                                                       │  (rasterize only)  │
                                                       └────────────────────┘
```

The fragment shader becomes a *thin presenter* — Lanczos upsample, tone
map, composite. All physics-derived fields come from Rail-WASM textures.

## Modules to build

### `tools/plasma/render.rail`

Pure functions over `ByteVec`/`FloatArr`:

```
decode_frame : ByteVec -> Frame
  -- parses the 48-byte header + 6 channel planes into a Frame record

vorticity    : Frame -> FloatArr
  -- ∂vy/∂x − ∂vx/∂y, central differences, periodic boundary

current_density : Frame -> FloatArr
  -- |J| = |∇×B| in 2D, central differences

schlieren    : Frame -> FloatArr
  -- |∇ρ| magnitude

lic_accumulate : Frame -> FloatArr -> FloatArr -> FloatArr
  -- step the LIC accumulator buffer along (Bx, By); blend with prev frame's
  -- accumulator for temporal coherence (this is the part GLSL can't do well)

particle_step : Frame -> ParticleArr -> ParticleArr
  -- integrate N particles through the velocity field one tick

derive_metrics : Frame -> MetricsBlob
  -- pack a small struct (kinetic_energy, magnetic_energy, |∇·B|_max,
  -- mean_vorticity, etc.) for the HUD
```

Each function is a Rail tail-recursive fold over the frame buffer. None
need closures across WASM boundary; arguments are linear-memory pointers.

### `stdlib/wasm_export.rail` (already exists conceptually)

- Standard ABI: each exported function takes `(ptr, len)` pairs, returns
  `(ptr, len)`. Memory is the WASM linear memory; arena_mark/arena_reset
  scopes the per-call work. We already use this pattern in mhd_wasm.

### `tools/plasma/render_glue.js`

Thin adapter:

```
const wasm = await WebAssembly.instantiateStreaming(fetch('render.wasm'), { ... });
const mem  = new Float32Array(wasm.instance.exports.memory.buffer);

function tick(rawFrame) {
  const inPtr = wasm.instance.exports.alloc(rawFrame.byteLength);
  new Uint8Array(wasm.instance.exports.memory.buffer)
    .set(new Uint8Array(rawFrame), inPtr);

  const framePtr = wasm.instance.exports.decode_frame(inPtr, rawFrame.byteLength);
  const vortPtr  = wasm.instance.exports.vorticity(framePtr);
  const jPtr     = wasm.instance.exports.current_density(framePtr);
  const licPtr   = wasm.instance.exports.lic_accumulate(framePtr, prevLicPtr, /*alpha*/0.85);
  // ... upload as R32F textures to GL ...
}
```

Each Rail-computed buffer gets uploaded to a WebGL2 texture (same pattern
as `live4k.html` but the **values come from Rail**, not GLSL).

### `tools/plasma/live4k_rail.html`

Replaces `live4k.html` once Tier 3 stabilizes. Same fragment-shader
*presenter* (Lanczos, tone map, composite) — but reads the LIC, vorticity,
|J| textures from the WASM module.

## Phases

### Phase A — bootstrap the WASM render path (1 week)

- Stand up `tools/plasma/render.rail` with `decode_frame` + `vorticity`
  only. Two functions, exhaustive tests against a captured reference frame.
- `./rail_native wasm tools/plasma/render.rail` → `render.wasm`.
- HTML harness that fetches one frame, calls Rail-WASM, dumps vorticity to
  console. Verify: matches a numpy-computed reference within 1e-6.
- **Gate:** byte-exact match between Rail-WASM output and a reference
  Python reduce on the same frame.

### Phase B — full derived field set (1 week)

- Add `current_density`, `schlieren`, `derive_metrics` to render.rail.
- Add per-call benchmark: `current_density` of one frame should run in
  <2 ms in the browser (single 128² pass).
- Compose with `live4k.html`: replace its in-shader `vorticity()` and
  `schlieren()` with samplers reading WASM-output textures. Compare visual
  output side-by-side; should be indistinguishable.
- **Gate:** the Tier 0 viewer's GLSL post-process is fully replaced by
  Rail-WASM compute, and the visual is bit-identical (modulo floating
  precision tolerance).

### Phase C — temporal-coherent LIC (1 week)

- This is the visual showstopper. GLSL can't easily maintain a persistent
  per-pixel LIC accumulator across frames; Rail-WASM trivially can,
  because it owns its linear memory.
- Implement `lic_accumulate`: at each pulse, advance the accumulator by
  one Euler step along the B field, blend with prior. Output texture is
  uploaded; shader just samples it.
- Visual result: the magnetic field line strands *flow over time* exactly
  along the field, not just appear-and-vanish per frame.
- **Gate:** strands visibly flow over a 30-second clip, no shimmer or
  reset between pulses.

### Phase D — particle layer (1 week)

- 200k–1M particles in a typed array inside WASM linear memory.
- `particle_step` — Rail tail-recursive fold over the particle array,
  integrating each through the velocity field. Re-spawn dead particles in
  low-density cells (Rail RNG already in stdlib).
- Render via WebGL2 instanced point draw, position buffer = WASM memory
  slice (zero copy via `Float32Array(mem.buffer, ptr, count*2)`).
- **Gate:** 60fps with 500k particles in Chrome on a M1 Air.

### Phase E — site integration (1 week)

- Replace `entropy.html`'s decorative `beacon.frag` hero with `live4k_rail`.
- Add `/plasma/tv` route — fullscreen 4K, no HUD, designed for ambient
  display.
- Add `/embed/plasma` route — iframe-friendly, transparent background, for
  embedding on partner sites.
- Add corner-mounted 96px live LIC strip to every page in `site.css`.
- **Gate:** every page on ledatic.org has a live link to the plasma chain
  visible in some form.

## Open design questions

1. **Memory budget.** Rail-WASM module + state textures + particle buffer
   should fit in <128 MB browser memory. Check with profiler in Phase B.
2. **SharedArrayBuffer requirements.** COOP/COEP headers needed on the CDN
   (Cloudflare Worker). Verify the worker config supports them; if not,
   fall back to copying buffers (slower but works).
3. **WebGPU migration path.** WebGL2 is fine for Phase A–C. WebGPU lets
   the LIC accumulator run as a compute shader instead, which would
   eliminate the WASM→GPU upload each pulse. Worth revisiting after
   Phase C.
4. **Reference verification.** The same `render.rail` should compile both
   to native ARM64 (for headless verification) and to WASM. A CLI tool
   `tools/plasma/render_check.rail` should pull the live frame, run the
   same derived computation natively, and emit a hash. The browser can
   include that hash in its DOM, letting a reader cross-check.

## Why this is a moat (not just a feature)

Anyone with three weekends can write a WebGL plasma viewer. What they
*can't* easily do:

- Author the post-processing in their own self-hosting language
- Have that same language drive the public attestation chain
- Have the same language compile to both native server and browser WASM
  with byte-equivalent output
- Ship it as a self-verifiable pipeline a reader can audit in one repo

Tier 3 is the part that turns "nice plasma demo" into "the most coherent
self-hosting demo on the web." It's also a natural follow-on to the
attestation work that just landed in v3.7–v3.10 — the same Rail substrate
that signs releases and witnesses pulses now also renders them.

## What today buys

Today's deliverable is Tier 0 (`tools/plasma/live4k.html`) — it's
self-contained, it works against the live beacon, it ships independently.
Tier 3 doesn't block it. Tier 3 grows underneath: each Phase replaces one
GLSL function with a Rail-WASM-derived texture, and the viewer keeps
working through every step of the migration.
