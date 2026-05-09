// chamber_dump.js — render the chamber via render.wasm, dump 128×128
// RGB8 bytes to stdout (3 bytes per pixel × 16384 pixels = 49152 bytes
// total, written as binary).  Pipe to a file:
//
//   jsc tools/plasma/chamber_dump.js > /tmp/chamber.bin
//   convert -size 128x128 -depth 8 rgb:/tmp/chamber.bin /tmp/chamber.png
//   open /tmp/chamber.png

"use strict";
const wasmBytes = readFile("tools/plasma/render.wasm", "binary");
const mod  = new WebAssembly.Module(wasmBytes);
const inst = new WebAssembly.Instance(mod, {
  wasi_snapshot_preview1: { fd_write: () => 0, proc_exit: () => {} },
});
const ex = inst.exports;

const N = 128, CH = 6, STATE_N = N * N * CH;
const tagInt = n => (BigInt(n) << 1n) | 1n;
const handleToPtr = h => Number(h >> 1n);
const _b = new ArrayBuffer(8);
const _f = new Float64Array(_b);
const _i = new BigInt64Array(_b);
const f64ToBits = x => { _f[0] = x; return _i[0]; };

// Allocate state, seed OT, allocate output, render.
const state = ex.float_arr_new(tagInt(STATE_N), f64ToBits(0));
ex.seed_ot(state, tagInt(0));
const IMG_BYTES = 49152;
const out = ex.float_arr_new(tagInt(IMG_BYTES), f64ToBits(0));
print("memory pages:", ex.memory.buffer.byteLength / 65536);
print("state ptr:", handleToPtr(state).toString(16), " out ptr:", handleToPtr(out).toString(16));
try {
  ex.chamber_render(state, out);
  print("chamber_render returned ok");
} catch (e) {
  print("chamber_render trap:", e.message || e);
  quit(1);
}

// Read back as f64 cells (each cell is a byte value 0-255 stored as float),
// narrow to a u8 buffer, write to stdout as raw bytes via the WASI fd.
const ptr = handleToPtr(out);
const f64 = new Float64Array(ex.memory.buffer, ptr + 8, IMG_BYTES);
const u8 = new Uint8Array(IMG_BYTES);
for (let i = 0; i < IMG_BYTES; i++) {
  let v = f64[i];
  if (v < 0) v = 0; else if (v > 255) v = 255;
  u8[i] = v | 0;
}

// jsc has a `writeFile(path, data)` builtin (undocumented but real);
// use it to dump the raw bytes.  It accepts an ArrayBuffer / typed
// array directly without text encoding.
writeFile("/tmp/chamber.bin", u8.buffer);
print("wrote /tmp/chamber.bin (" + IMG_BYTES + " bytes)");
