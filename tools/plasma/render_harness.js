// render_harness.js — Tier 3-A WASM gate for tools/plasma/render.wasm.
//
// Run with Apple's JavaScriptCore CLI (ships with macOS):
//   JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc
//   $JSC tools/plasma/render_harness.js
//
// This validates the JS-side ABI for Tier 3-B by exercising the same
// glue calls (float_arr_new / seed_ot / scalar metrics) that the
// browser harness uses, but in a headless CLI so we can verify
// without driving a browser.

"use strict";

const WASM_PATH = "tools/plasma/render.wasm";

// ── Rail-WASM i64 ABI helpers ────────────────────────────────────────
const tagInt   = n => (BigInt(n) << 1n) | 1n;
const untagInt = b => Number(b >> 1n);

const _scratch = new ArrayBuffer(8);
const _f64v    = new Float64Array(_scratch);
const _i64v    = new BigInt64Array(_scratch);
function f64ToBits(x) { _f64v[0] = x; return _i64v[0]; }
function bitsToF64(b) { _i64v[0] = b; return _f64v[0]; }

const handleToPtr = h => Number(h >> 1n);

// ── WASI stubs ───────────────────────────────────────────────────────
const wasi = {
  fd_write:  (_fd, _iovs, _iovs_len, _nwritten) => 0,
  proc_exit: (_code) => {},
};

// ── Run ──────────────────────────────────────────────────────────────
function panic(msg) { print("FAIL: " + msg); quit(1); }

function main() {
  let bytes;
  try {
    bytes = readFile(WASM_PATH, "binary");
  } catch (e) {
    panic(`readFile ${WASM_PATH}: ${e.message}`);
  }
  print(`loaded ${WASM_PATH} (${bytes.byteLength} bytes)`);

  let mod, inst;
  try {
    mod  = new WebAssembly.Module(bytes);
    inst = new WebAssembly.Instance(mod, { wasi_snapshot_preview1: wasi });
  } catch (e) {
    panic(`instantiate: ${e.message || e}`);
  }
  const ex = inst.exports;
  const expected = ["memory", "float_arr_new", "seed_ot",
                    "total_kinetic_energy", "total_magnetic_energy",
                    "max_divb", "mean_vorticity",
                    "vorticity", "current_density", "schlieren"];
  const missing = expected.filter(n => !(n in ex));
  if (missing.length) panic(`missing exports: ${missing.join(",")}`);
  print(`memory: ${ex.memory.buffer.byteLength} bytes (${ex.memory.buffer.byteLength / 65536} pages)`);

  // ── 1. Allocate state buffer ────────────────────────────────────
  const N = 98304;
  const t0 = Date.now();
  const stateHandle = ex.float_arr_new(tagInt(N), f64ToBits(0.0));
  const t1 = Date.now();
  const statePtr = handleToPtr(stateHandle);
  print(`float_arr_new(${N}) → handle=0x${stateHandle.toString(16)} ptr=0x${statePtr.toString(16)}  (${t1-t0} ms)`);

  // length prefix is raw i64, not tagged
  const lenView = new BigInt64Array(ex.memory.buffer, statePtr, 1);
  if (Number(lenView[0]) !== N) panic(`length prefix mismatch: ${lenView[0]} != ${N}`);
  print(`length prefix at ptr+0 = ${lenView[0]} ✓`);

  // Per-frame mark: taken right after state alloc, before any scratch
  // grows.  All later derived-field allocations live above this mark
  // and get freed by arena_reset every frame.
  const frameMark = ex.arena_mark(0n);
  print(`frame mark = 0x${frameMark.toString(16)} (untagged str_ptr = 0x${(Number(frameMark) >> 1).toString(16)})`);

  // ── 2. Seed OT initial condition ────────────────────────────────
  const ts = Date.now();
  try {
    ex.seed_ot(stateHandle, tagInt(0));
  } catch (e) {
    panic(`seed_ot trapped: ${e.message || e}`);
  }
  print(`seed_ot done in ${Date.now() - ts} ms`);

  // ── 3. Read back ────────────────────────────────────────────────
  // After seed_ot, memory may have grown; re-derive view.
  const f64 = new Float64Array(ex.memory.buffer, statePtr + 8, N);
  const rho00 = f64[0];
  const rhoExpected = 2.77777777777778;
  const rhoOk = Math.abs(rho00 - rhoExpected) < 1e-10;
  print(`f64[idx(rho,0,0)] = ${rho00}  (expect ${rhoExpected})  ${rhoOk ? '✓' : '✗'}`);

  // vy at (32, 0) = sin(32 * dx) ≈ 1.0
  const vy_at_32_0 = f64[2*16384 + 0*128 + 32];
  const vyOk = Math.abs(vy_at_32_0 - 1.0) < 1e-3;
  print(`f64[idx(vy,32,0)] = ${vy_at_32_0.toFixed(6)}  (expect ~1.0)  ${vyOk ? '✓' : '✗'}`);

  // ── 4. Scalar metrics ───────────────────────────────────────────
  function fcall(name) {
    const t = Date.now();
    const bits = ex[name](stateHandle);
    const v = bitsToF64(bits);
    return { v, dt: Date.now() - t };
  }
  const ke = fcall("total_kinetic_energy");
  const me = fcall("total_magnetic_energy");
  const mv = fcall("mean_vorticity");
  const md = fcall("max_divb");

  function check(label, got, want, tol) {
    const ok = Math.abs(got - want) <= tol;
    print(`  ${label.padEnd(20)} = ${got.toFixed(6).padStart(14)}  (expect ${want}, tol ${tol})  ${ok ? '✓' : '✗'}`);
    return ok;
  }
  print(`\nScalar metrics:`);
  let allOk = rhoOk && vyOk;
  // Ground truth from native run (handoff 2026-05-02): KE=22755.56,
  // ME=8192, divB=0, <ω>≈0.  (render.rail's "expect ~12288" comment is
  // wrong — analytical ME = 0.5 * <bx²+by²> * N² = 0.5 * 1 * 16384 = 8192.)
  allOk = check("kinetic energy",  ke.v, 22755.56, 0.01) && allOk;
  allOk = check("magnetic energy", me.v, 8192.0,   0.01) && allOk;
  allOk = check("mean vorticity",  mv.v, 0,        1e-6) && allOk;
  allOk = check("max |∇·B|",       md.v, 0,        1e-6) && allOk;
  print(`  timings (ms): KE=${ke.dt} ME=${me.dt} MV=${mv.dt} MD=${md.dt}`);

  // ── 5. Derived field allocation (vorticity creates a 128² scratch) ─
  print(`\nDerived field allocation test:`);
  try {
    const t = Date.now();
    const vh = ex.vorticity(stateHandle);
    const dt = Date.now() - t;
    const vptr = handleToPtr(vh);
    const vf64 = new Float64Array(ex.memory.buffer, vptr + 8, 16384);
    print(`  vorticity → handle=0x${vh.toString(16)} ptr=0x${vptr.toString(16)}  (${dt} ms)`);
    let vmin = +Infinity, vmax = -Infinity, vsum = 0;
    for (let i = 0; i < 16384; i++) {
      const v = vf64[i];
      if (v < vmin) vmin = v;
      if (v > vmax) vmax = v;
      vsum += v;
    }
    print(`  range: [${vmin.toFixed(6)}, ${vmax.toFixed(6)}]  mean=${(vsum/16384).toExponential(3)}`);
  } catch (e) {
    print(`  vorticity TRAP: ${e.message || e}`);
    allOk = false;
  }

  // ── 6. Per-frame arena reset stress (Tier 3-B's per-frame pattern) ──
  // After arena_reset(frameMark), str_ptr rewinds to right after state
  // alloc.  Each frame's vorticity scratch reuses the same 131 KB.
  // Without this, the str heap exhausts within ~6 calls.
  print(`\nArena-reset stress (60 frames of vorticity):`);
  let lastVortPtr = 0;
  let stressOk = true;
  const tStart = Date.now();
  for (let frame = 0; frame < 60; frame++) {
    ex.arena_reset(frameMark);
    let vh;
    try {
      vh = ex.vorticity(stateHandle);
    } catch (e) {
      print(`  TRAP at frame ${frame}: ${e.message || e}`);
      stressOk = false;
      break;
    }
    const vptr = handleToPtr(vh);
    if (frame === 0) lastVortPtr = vptr;
    else if (vptr !== lastVortPtr) {
      print(`  ptr drift at frame ${frame}: 0x${vptr.toString(16)} vs 0x${lastVortPtr.toString(16)}`);
      stressOk = false;
      break;
    }
  }
  const tEnd = Date.now();
  if (stressOk) {
    print(`  60 frames OK, scratch ptr stable at 0x${lastVortPtr.toString(16)}, ${tEnd - tStart} ms total (${((tEnd-tStart)/60).toFixed(1)} ms/frame)`);
  }
  allOk = allOk && stressOk;

  print();
  print((allOk ? "PASS" : "FAIL") + " — Tier 3-A native-WASM gate (jsc)");
  quit(allOk ? 0 : 1);
}

main();
