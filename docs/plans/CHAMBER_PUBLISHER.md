# Chamber publisher — one renderer, three targets

## Premise

Right now `/holo` renders the volumetric chamber on the client GPU via WGSL. Every device that loads the page does the work itself. M1 Air struggles. Mac mini struggles. iOS Safari silently corrupts. The conventional fix is to route weak clients to a 2D fallback, which is what we shipped — but that means weak clients see fundamentally different content from strong clients.

Rail's structural advantage: the chamber renderer can be **one source file** that compiles to wherever the work should live.

## Architecture

```
                          render.rail / chamber.rail
                                    │
            ┌───────────────────────┼───────────────────────┐
            │                       │                       │
       compile to               compile to              compile to
       ARM64 native              WebAssembly              WGSL
       (Mini server)             (browser CPU)         (browser GPU)
            │                       │                       │
            ▼                       ▼                       ▼
       runs once per             runs in jsc /          runs in /holo
       pulse, renders            mobile.html as         when WebGPU is
       512×512 RGB,              CPU fallback           strong enough
       attaches to
       beacon frame
```

**Server (Mini, ARM64)** owns the canonical render. Once per pulse, after the physics step, Mini calls `chamber_render(state, camera, out_rgb)`. The result attaches to the beacon frame as a new payload section. Any client that reads the new field gets a finished, byte-correct chamber visual without doing any rendering itself.

**Browser CPU (WebAssembly)** runs the same `chamber_render` for clients that don't trust the server image (audit path) or want to render at a different camera angle than the server's canonical iso. ~4× slower than native; runs at 1 Hz instead of 30 Hz, but produces bit-identical output to the server when given the same inputs.

**Browser GPU (WGSL)** is the future high-end target. Once a Rail-to-WGSL transpiler exists in `tools/compile.rail`, the same kernel runs on the client GPU at full speed. Pre-existing viewers (`/holo` today's WGSL handwritten shader) get replaced by the auto-generated WGSL — single source of truth.

## v1 scope (this implementation)

- **One target**: ARM64 native + WebAssembly. WGSL transpiler is a separate compiler project, deferred.
- **One camera**: fixed iso angle. Parameterizable per-call but server only uses iso.
- **Resolution**: 128×128 RGB8. Matches the simulation grid. 49152 bytes per chamber image, before gzip.
- **Render quality**:
  - Volumetric raymarch through a cylindrical chamber containing the 2D plane field
  - 24 sample steps per ray
  - Beer-Lambert opacity accumulation
  - Density → viridis-mapped emission, vorticity-tinted
  - Cylinder rim highlight
  - Simple ACES tonemap
  - **NOT** in v1: MSAA, bloom, mirrored floor, glass refraction, surface scratches, audio, depth-of-field, particles in the chamber. Those live in /holo's WGSL only.

The v1 visual is a *recognizable* chamber — same camera, same density-driven plasma, same tinted vortices — but visually simpler than /holo. It looks like a pre-rendered preview of the chamber, not the full thing. That's acceptable: it's universal, it's deterministic, it's byte-checkable.

## Beacon contract change

Current frame layout (`tools/plasma/mhd_beacon.rail`):

```
offset  size  field
0       4     u32 w  (= 128)
4       4     u32 h  (= 128)
8       4     u32 channels  (= 6)
12      4     u32 step
16      32    8 × f32 metrics  (mass, energy, divB, rho_min, dt, sim_time, m0, e0)
48      ...   N² × CH × f32 plane data  (= 393216 B at 128² × 6)
393264  END
```

New layout (post-chamber, backward-compatible):

```
... up to 393264                        [unchanged]
393264  4     u32 chamber_w     (= 128 in v1, 0 if no chamber image)
393268  4     u32 chamber_h     (= 128 in v1)
393272  4     u32 chamber_fmt   (= 1 for RGB8, future-proof for RGBA8/JPEG/etc.)
393276  4     u32 chamber_bytes (= 49152 for v1)
393280  ...   chamber image bytes
END at 442432 (= 393264 + 16 + 49152)
```

Old viewers (`mobile.html`, `live4k.html`, `holo.html` as currently shipped) read up to byte 393264 and stop — they parse `w/h/c/step + metrics + plane data` and ignore trailing bytes. **No breakage.** The frame just got 12% larger on the wire.

New viewers check `frame.byteLength >= 393280`. If yes, parse `chamber_w/h/fmt/bytes` and display the image as the primary visual. If no (talking to an older beacon), fall back to current 2D composite path.

## File map

```
tools/plasma/chamber.rail            (NEW)  — chamber renderer kernel
tools/plasma/render.rail             (EDIT) — re-export chamber, no impl change
tools/plasma/mhd_beacon.rail         (EDIT) — call chamber after physics, append
tools/plasma/mhd_beacon_pack.py      (EDIT) — write the 4 new u32 fields + bytes
tools/plasma/mobile.html             (EDIT) — display chamber image when present
tools/plasma/build_render_wasm.sh    (EDIT) — add chamber_render to EXPORTS
tools/plasma/render_glue_test.js     (EDIT) — verify chamber kernel runs in WASM
docs/plans/CHAMBER_PUBLISHER.md      (THIS FILE)
```

`mhd_beacon.rail` lives in this repo per `tools/plasma/`. The Cloudflare Worker passes the binary frame through unmodified — no Worker changes needed.

## Risk + mitigation

| Risk | Mitigation |
|---|---|
| Render time eats Mini's solver budget | Time the kernel; if > 50 ms/pulse, skip rendering on alternate pulses (publish chamber every 2nd pulse, fall through to 2D composite in between). |
| Chamber image bytes balloon the beacon | RGB8 at 128² = 48 KB. Cloudflare auto-gzips. Net wire payload likely +25 KB after compression. |
| Backward compat: old client misreads new frame | The 4 trailing u32 fields are *appended*; old parsers stop at byte 393264 and never see them. Verified contract-compatible. |
| WASM port produces different bytes than native | The render is deterministic (no rand, no time-dependence). Test: run native + WASM with same state, compare output bytes. Must be byte-identical or tolerance < 1 LSB per channel. |
| Visual divergence from /holo's WGSL | Acceptable for v1 — /holo stays the high-end aesthetic, chamber publisher ships the universal recognizable preview. They don't have to match pixel-for-pixel. |

## Build steps (in order)

1. **`chamber.rail` kernel** — write the volumetric raymarcher in Rail. Camera, ray, cylinder intersection, march loop, sample, accumulate, tonemap, write RGB8 byte. Test natively via `./rail_native run tools/plasma/chamber.rail` with the OT IC seeded — produces a 128×128 RGB output written to `/tmp/chamber.bin`.
2. **Native sanity check** — pipe `/tmp/chamber.bin` to ImageMagick (or stb_image equivalent) to dump a PNG. Eyeball the result against /holo's chamber.
3. **Add `chamber_render` to WASM build** — update `build_render_wasm.sh` EXPORTS, rebuild render.wasm, verify export shows up in `wasm-objdump`.
4. **WASM glue test** — extend `render_glue_test.js` to call `chamber_render` and check the first few output bytes match the native run. Bit-identical on the deterministic path.
5. **Beacon publisher hook** — edit `mhd_beacon.rail` (or `mhd_beacon_pack.py` if that's what currently builds the published frame) to call `chamber_render` and append the new section.
6. **Verify on the wire** — `curl -s https://ledatic.org/entropy/frame/current | wc -c` should now print ~442432 instead of 393264.
7. **mobile.html update** — detect the chamber section, draw it as the primary visual via `putImageData` from a `Uint8ClampedArray` view of the chamber bytes. The existing CPU composite (vorticity tint + LIC + glow + particles) becomes a fallback path for legacy frames.

## Plain-words explanation

(For the user who'll approve before I build.)

**Today** — the plasma chamber graphic on `/holo` is computed by the visitor's own browser using their GPU. Strong devices render it fine. Weak devices (M1 Air, Mac mini under load, phones) either glitch or lag, so we route them to a different 2D view.

**The change** — Mini, which already runs the simulation, also renders one image of the chamber for each pulse. The image gets tucked into the beacon's frame data alongside the existing physics numbers. When *anyone* loads the viewer, they download that image and display it directly. No rendering happens in their browser. Phone, M1 Air, Mac mini, Mac Pro — all show the same chamber, all show it instantly.

**Why this is a Rail thing** — usually, the server-side renderer and the client-side renderer are written in different languages. They drift. Bug fixes have to land twice. Rail compiles one file to native (for Mini) AND to WebAssembly (for browsers). One source of truth. The renderer Mini ships with is the same renderer a browser would run as a fallback. There's no drift to worry about, and that's a property only a project that owns its compiler can have.

**What v1 looks like** — recognizable chamber, slightly simpler aesthetic than what desktop /holo currently renders (no MSAA, no bloom, no fancy refraction). One fixed iso camera angle. 128×128 image, ~50 KB extra per beacon frame, basically free on any connection.

**What v2 could add** — multiple camera angles selected by the client. Higher resolution. The full /holo aesthetic. A Rail-to-WGSL transpiler that lets client GPUs run the same Rail kernel for high-end devices. All built on top of the v1 substrate, no rewrite.

**What we're NOT doing** — switching to a video stream from Mini. That would also work but it loses the "anyone can verify the renderer" property. With this design, the renderer is open-source Rail; anyone can compile it and check that what Mini publishes matches what they'd produce themselves. Trust by reproduction, not trust by promise.
