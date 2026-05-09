// _shared/wasm_render.js — Rail-WASM render kernel surface, factored for
// reuse across viewers (holo.html, future Tier-4, etc.).
//
// Usage:
//   const r = createWasmRender({ N: 128, CH: 6, tracerCount: 192 });
//   await r.whenReady;            // resolves true on success, false on failure
//   const vort = r.computeVorticity(f32);   // Float32Array(N*N) | null
//   const lic  = r.computeLIC(f32);          // Float32Array(N*N) | null
//   const part = r.stepParticles(f32, dt);   // Float32Array(2*K)  | null
//
// Each compute method returns null if the WASM module is unavailable
// or if a kernel call has thrown — callers fall through to non-WASM
// rendering paths.  Once a method has thrown, `ready` flips false and
// subsequent calls short-circuit; this avoids spamming a broken module.
//
// The module assumes the kernel surface defined by tools/plasma/render.rail
// (vorticity / lic / particle_step / arena_mark / arena_reset / float_arr_new).
// ABI reference: rail_wasm_abi.md.

(function () {
  'use strict';

  const WASI_STUBS = {
    fd_write:  () => 0,
    proc_exit: () => {},
  };
  const REQUIRED_EXPORTS = [
    'memory', 'float_arr_new',
    'vorticity', 'lic', 'particle_step',
    'arena_mark', 'arena_reset',
  ];

  // ── Rail-WASM i64 ABI helpers (keep local — match render.wasm exactly) ──
  const tagInt      = n => (BigInt(n) << 1n) | 1n;
  const handleToPtr = h => Number(h >> 1n);
  const _bitsBuf = new ArrayBuffer(8);
  const _bitsF64 = new Float64Array(_bitsBuf);
  const _bitsI64 = new BigInt64Array(_bitsBuf);
  const f64ToBits = x => { _bitsF64[0] = x; return _bitsI64[0]; };

  // Default noise generator — same hash basis as the original holo
  // noiseTex.  Caller can override via `config.noiseFill(view, N)`.
  function defaultNoiseFill(view, N) {
    const PLANE_SZ = N * N;
    for (let i = 0; i < PLANE_SZ; i++) {
      const x = i % N, y = (i / N) | 0;
      const h = Math.sin(x * 12.9898 + y * 78.233) * 43758.5453;
      view[i] = h - Math.floor(h);
    }
  }

  // Default particle seeder — jittered grid across the [0, N) domain.
  function defaultParticleSeed(view, K, N) {
    const side = Math.ceil(Math.sqrt(K));
    const cell = N / side;
    let idx = 0;
    for (let gy = 0; gy < side && idx < K; gy++) {
      for (let gx = 0; gx < side && idx < K; gx++) {
        view[2 * idx]     = (gx + 0.5) * cell + (Math.random() - 0.5) * cell * 0.6;
        view[2 * idx + 1] = (gy + 0.5) * cell + (Math.random() - 0.5) * cell * 0.6;
        idx++;
      }
    }
  }

  function createWasmRender(config) {
    const N        = config.N        || 128;
    const CH       = config.CH       || 6;
    const K        = config.tracerCount || 192;
    const wasmURL  = config.wasmURL  || 'render.wasm';
    const cache    = config.cache    || 'force-cache';
    const noiseFill    = config.noiseFill    || defaultNoiseFill;
    const particleSeed = config.particleSeed || defaultParticleSeed;
    const onReady  = config.onReady  || (() => {});
    const onError  = config.onError  || ((kind, err) => {
      console.warn(`wasm_render ${kind}:`, err.message || err);
    });

    const STATE_N  = N * N * CH;
    const PLANE_SZ = N * N;
    const PART_N   = 2 * K;

    let ex = null;
    // Permanent allocations (live across frames; allocated BEFORE frameMark).
    let stateHandle  = 0n, stateView   = null;
    let noiseHandle  = 0n, noiseView   = null;
    let licOutHandle = 0n, licOutView  = null;
    let partHandle   = 0n, partView    = null;
    let dtArrHandle  = 0n, dtView      = null;
    let frameMark    = 0n;
    // Narrowed-to-f32 mirrors for JS consumers.
    const vortF32 = new Float32Array(PLANE_SZ);
    const licF32  = new Float32Array(PLANE_SZ);
    const partF32 = new Float32Array(PART_N);
    let ready = false;

    function disable(kind, err) {
      ready = false;
      onError(kind, err);
    }

    async function init() {
      try {
        const resp = await fetch(wasmURL, { cache });
        if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
        const mod = WebAssembly.instantiateStreaming
          ? await WebAssembly.instantiateStreaming(resp,
              { wasi_snapshot_preview1: WASI_STUBS })
          : await WebAssembly.instantiate(await resp.arrayBuffer(),
              { wasi_snapshot_preview1: WASI_STUBS });
        ex = mod.instance.exports;
        const missing = REQUIRED_EXPORTS.filter(n => !(n in ex));
        if (missing.length) throw new Error(`missing exports: ${missing.join(',')}`);

        // Permanent allocations — order is load-bearing; frameMark MUST be
        // taken last so per-frame arena_reset rewinds to here, not before.
        stateHandle  = ex.float_arr_new(tagInt(STATE_N),  f64ToBits(0));
        stateView    = new Float64Array(ex.memory.buffer, handleToPtr(stateHandle) + 8, STATE_N);
        noiseHandle  = ex.float_arr_new(tagInt(PLANE_SZ), f64ToBits(0));
        noiseView    = new Float64Array(ex.memory.buffer, handleToPtr(noiseHandle) + 8, PLANE_SZ);
        noiseFill(noiseView, N);
        licOutHandle = ex.float_arr_new(tagInt(PLANE_SZ), f64ToBits(0));
        licOutView   = new Float64Array(ex.memory.buffer, handleToPtr(licOutHandle) + 8, PLANE_SZ);
        partHandle   = ex.float_arr_new(tagInt(PART_N),   f64ToBits(0));
        partView     = new Float64Array(ex.memory.buffer, handleToPtr(partHandle) + 8, PART_N);
        particleSeed(partView, K, N);
        dtArrHandle  = ex.float_arr_new(tagInt(1),        f64ToBits(0));
        dtView       = new Float64Array(ex.memory.buffer, handleToPtr(dtArrHandle) + 8, 1);
        frameMark    = ex.arena_mark(0n);
        ready = true;
        onReady({
          state: handleToPtr(stateHandle),
          noise: handleToPtr(noiseHandle),
          lic:   handleToPtr(licOutHandle),
          part:  handleToPtr(partHandle),
          mark:  Number(frameMark),
        });
      } catch (e) {
        disable('init', e);
      }
    }

    const whenReady = init().then(() => ready);

    // ── Per-frame entry points ──────────────────────────────────────
    // Each kernel: widen state → reset arena → run → narrow result.
    // null on any disabled/failure state.

    function widenState(f32) {
      for (let i = 0; i < STATE_N; i++) stateView[i] = f32[i];
    }

    function computeVorticity(f32) {
      if (!ready) return null;
      try {
        widenState(f32);
        ex.arena_reset(frameMark);
        const vh = ex.vorticity(stateHandle);
        const vf64 = new Float64Array(ex.memory.buffer, handleToPtr(vh) + 8, PLANE_SZ);
        for (let i = 0; i < PLANE_SZ; i++) vortF32[i] = vf64[i];
        return vortF32;
      } catch (e) { disable('vorticity', e); return null; }
    }

    function computeLIC(f32) {
      if (!ready) return null;
      try {
        widenState(f32);
        ex.arena_reset(frameMark);
        ex.lic(stateHandle, noiseHandle, licOutHandle);
        for (let i = 0; i < PLANE_SZ; i++) licF32[i] = licOutView[i];
        return licF32;
      } catch (e) { disable('lic', e); return null; }
    }

    function stepParticles(f32, dt) {
      if (!ready) return null;
      try {
        widenState(f32);
        ex.arena_reset(frameMark);
        dtView[0] = dt;
        ex.particle_step(stateHandle, partHandle, tagInt(K), dtArrHandle);
        for (let i = 0; i < PART_N; i++) partF32[i] = partView[i];
        return partF32;
      } catch (e) { disable('particle_step', e); return null; }
    }

    return {
      get ready()        { return ready; },
      get tracerCount()  { return K; },
      get gridN()        { return N; },
      get channels()     { return CH; },
      whenReady,
      computeVorticity, computeLIC, stepParticles,
    };
  }

  // Expose globally for direct <script src=...> consumers; ESM users can
  // import via `window.createWasmRender` or attach a default export shim.
  if (typeof window !== 'undefined') {
    window.createWasmRender = createWasmRender;
  }
  // CommonJS for jsc/node-style harnesses.
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = { createWasmRender };
  }
})();
