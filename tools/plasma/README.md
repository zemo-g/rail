# `tools/plasma/` — viewer + Rail-WASM compute substrate

Three viewers (progressive fallback chain) and the Rail-WASM kernels that feed them.

## Viewer chain

| Path                       | Renderer  | Falls back to | Notes |
|----------------------------|-----------|---------------|-------|
| `holo.html`                | WebGPU    | `live4k.html` | Volumetric raymarch, MSAA HDR, audio synth, PiP, particles. Mobile viewports + `pointer: coarse` auto-redirect. |
| `live4k.html`              | WebGL2    | `mobile.html` | LIC strands, vorticity tint, schlieren edges, Lanczos upsample. Falls back if `webgl2` ctx fails OR `EXT_color_buffer_float` missing. |
| `mobile.html`              | Canvas 2D | (terminus)    | f32 → u8 colormap LUT in JS, `putImageData`. No GL features required. Universal. |

`?nofallback=1` on `holo` or `live4k` keeps the current page even if it would normally redirect. Useful for diagnosis on devices that look mobile but actually have working WebGPU.

## Rail-WASM compute substrate

`render.rail` compiles to `render.wasm` via `build_render_wasm.sh`. Ten kernels are exported — see `EXPORTS=(...)` in the build script for the canonical list.

### Kernel surface (alphabetical)

| Export | Purpose | Allocates? |
|---|---|---|
| `arena_mark` | snapshot `$str_ptr` for per-frame scratch reuse | no |
| `arena_reset` | rewind `$str_ptr` to a saved mark | no |
| `current_density` | \|J\| = \|∂By/∂x − ∂Bx/∂y\| over the full grid | yes (128² f64 scratch) |
| `float_arr_*` (`new`/`get`/`set`/`len`) | host-side allocation + per-cell access | new: yes |
| `lic` | streamline-aligned 24-tap noise convolution | small (1-cell acc) |
| `max_divb` | max\|∇·B\| scalar | small |
| `mean_vorticity` | ⟨ω⟩ scalar | small |
| `particle_step` | RK2 advection of K tracers in (vx, vy) | no |
| `schlieren` | \|∇ρ\| over the full grid | yes (128² scratch) |
| `seed_ot` | fill the state buffer with the OT initial condition | no |
| `total_kinetic_energy` | KE scalar | small |
| `total_magnetic_energy` | ME scalar | small |
| `vorticity` | ω = ∂vy/∂x − ∂vx/∂y over the full grid | yes (128² scratch) |

### Per-frame protocol (the `wasmRender` IIFE in `holo.html`)

```
init once:
  state    = float_arr_new(98304, 0)        # 786 432 B,  ρ, vx, vy, p, Bx, By plane-major
  noise    = float_arr_new(16384, 0)        # JS fills with deterministic noise
  lic_out  = float_arr_new(16384, 0)        # caller-allocated scratch — kernel writes in place
  parts    = float_arr_new(2*K, 0)          # interleaved (x, y) tracer positions
  dt_arr   = float_arr_new(1, 0)            # cell 0 holds dt
  frameMark = arena_mark(0)                 # post-state $str_ptr — reset target every frame

every pulse:
  widen f32 → f64 into stateView
  arena_reset(frameMark)
  vh = vorticity(state)        → narrow Float64Array view at vh+8
  lic(state, noise, lic_out)   → in place; read lic_outView
  dtView[0] = real-time-elapsed
  particle_step(state, parts, K, dt_arr) → in place; read partsView
```

### Memory layout (32-page = 2 MB module)

| Region | Bytes | What |
|---|---|---|
| `0x000000..0x010000` | 64 KB | static data + nil sentinel |
| `0x010000..0x014000` | 16 KB | shadow stack |
| `0x014000..0x020000` | 48 KB | string heap (initial; grows past this without bound checks) |
| `0x020000..0x090000` | 448 KB | from-space (active GC heap) |
| `0x090000..0x100000` | 448 KB | to-space (inactive) |
| `0x100000..0x200000` | 1 MB | post-bump scratch headroom |

`float_arr_new` calls `$alloc_str` which has **no bounds checks** — it just bumps `$str_ptr` blindly. Permanent allocations (state, noise, lic_out, etc.) push `$str_ptr` past the GC heap region; that's safe IFF nothing in the call chain triggers GC. For pure-numerics kernels (no cons / closure / ADT / string allocation per frame) this holds. **Don't** add `print` calls inside hot kernels — they allocate strings and will collide with the float_arr scratch.

### Float-typing workaround (load-bearing)

Rail's WASM emitter only marks a function param as float when a Rail-side caller passes a float to that position. Pure-JS callers (the host) leave params unmarked → register-recursive accumulators get garbled.

Workaround everywhere in `render.rail`: thread float values through 1-cell `float_arr` arguments. See `lic_walk`'s `acc_arr` and `particle_step_one`'s `dt_arr`. The original carrier of this pattern is `ke_acc_loop`. **If you write a new kernel that takes a float param, use this pattern.**

## Validators (run from rail repo root)

```bash
./tools/plasma/test_render_wasm.sh                 # Tier 3-A: kernel ABI + 60-frame arena-reset stress
jsc tools/plasma/render_glue_test.js               # Tier 3-B/C/D: per-frame integration vs OT IC ground truth
jsc tools/plasma/render_harness.js                 # Same as test_render_wasm.sh but standalone-callable
```

`jsc` = `/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc`. It runs the same engine as Safari WebKit; passing here is strong evidence in-browser will work. Don't try `pip3 install wasmtime` — system Python's hardened runtime kills it via EXC_GUARD.

## /plasma/tv recordings

Capture: `./capture_recording.sh <seed> <n_frames> [<interval_s>]`. Writes to `recordings/<seed>/`:
- `manifest.json` — `{seed, n_frames, interval_s, captured_unix_start, captured_unix_end, frame_pattern, pulse_pattern}`.
- `frame_NNN.bin` — same byte format as `/entropy/frame/current` returns.
- `pulse_NNN.json` — same as `/entropy/pulse`.

Replay: `holo.html?seed=<id>` swaps `pollFrame`/`pollPulse` to read from the recording dir, looping on overflow. The viewer shows a top-left "TV · seed · N frames" pill.

**Worker-side gotcha** (resolved 2026-05-02): `.bin` was missing from the Worker's MIME table → frames served as `text/html; charset=utf-8` and inflated by UTF-8 escape from 393 264 B → ~675 KB. Fixed by adding `.bin` to MIME table, BINARY_EXT, and LONG_CACHE_EXT in the Worker. **Pattern for any future binary file type: update all three lists.**

## ABI quick reference

All exports: `(param i64...) → (result i64)`. The i64 carries different things by context:
- **Tagged int**: `(BigInt(n) << 1n) | 1n`. Decode: `Number(b >> 1n)`.
- **Float**: raw IEEE-754 bit pattern. Encode: `Float64Array` ↔ `BigInt64Array`.
- **`float_arr` handle**: `(i32_ptr << 1)` (LSB=0). Decode ptr: `Number(h >> 1n)`. Layout at ptr: `[i64 length_raw][f64 d0][f64 d1]…`. Data starts at `ptr + 8`.

WASI imports needed at instantiation (stub both, neither fires in pure-numerics kernels):
- `wasi_snapshot_preview1.fd_write` — `(i32×4) → i32`. Stub: return `0`.
- `wasi_snapshot_preview1.proc_exit` — `(i32) → ()`. Stub: empty.
