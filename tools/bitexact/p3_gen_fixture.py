#!/usr/bin/env python3
# P3 fixture generator + external float reference oracle.
#
# Writes a SMALL, real-format .safetensors file holding the three GeGLU projection
# matrices (gate_proj / up_proj / down_proj) as BF16 -- the exact same on-disk layout
# and the exact same long tensor key names that Gemma 4 E2B uses -- so the Rail oracle
# (p3_real_geglu.rail) exercises a byte-identical load+parse+decode path on a file that
# fits in CI, instead of the real 10.25 GB model. Layout per the safetensors spec:
#   [8-byte little-endian header length N][N-byte JSON header][raw BF16 data]
#
# It ALSO emits an INDEPENDENT numpy true-float GeGLU reference (/tmp/p3_fix_ref.txt):
# gate@x, up@x, true tanh-gelu, hadamard, down -- computed on the SAME bf16-rounded
# weights the oracle decodes, so the two paths are comparing the same numbers. This is
# the external-reference half (numpy); Rail does the real exact-integer load+forward and
# falsifies its integer result against this float reference.
#
# The real-model capstone (the 10.25 GB version, kept in /tmp as r5b_p3_geglu.rail) is
# documented in the oracle header; this self-contained fixture is the committed, runnable
# proof of the identical code path.
import json, struct
import numpy as np

OUT_ST  = "/tmp/p3_fix.safetensors"
OUT_REF = "/tmp/p3_fix_ref.txt"
F = 24
S = float(1 << F)   # 16777216
D = 4               # hidden (model dim)
H = 8               # intermediate (mlp hidden)

def to_bf16_bytes_and_val(w):
    # truncate float32 to bf16 (top 16 bits); return (lo,hi) bytes + the EXACT stored value.
    u32 = np.float32(w).view(np.uint32)
    u16 = np.uint16(u32 >> np.uint32(16))
    lo  = int(u16 & 0xFF); hi = int((u16 >> 8) & 0xFF)
    val = np.uint32(np.uint32(u16) << np.uint32(16)).view(np.float32).astype(np.float64)
    return lo, hi, float(val)

# deterministic small weights, all exact multiples of 1/16 -> exact in bf16 (decode is lossless),
# so the ACC error isolates the fixed-point tanh-gelu approximation, not weight quantization.
def wg(r, c): return (((r * 5 + c * 3 + 1) % 13) - 6) * 0.0625   # gate  [H,D]  ~ +-0.375
def wu(r, c): return (((r * 3 + c * 7 + 2) % 11) - 5) * 0.0625   # up    [H,D]  ~ +-0.3125
def wd(r, c): return (((r * 7 + c * 5 + 3) %  9) - 4) * 0.0625   # down  [D,H]  ~ +-0.25

def pack(rows, cols, f):
    raw = bytearray()
    vals = np.zeros((rows, cols), dtype=np.float64)
    for r in range(rows):
        for c in range(cols):
            lo, hi, v = to_bf16_bytes_and_val(f(r, c))
            raw.append(lo); raw.append(hi)
            vals[r, c] = v
    return bytes(raw), vals

g_raw, Wg = pack(H, D, wg)   # [H,D]
u_raw, Wu = pack(H, D, wu)   # [H,D]
d_raw, Wd = pack(D, H, wd)   # [D,H]

g_off = (0,              len(g_raw))
u_off = (g_off[1],       g_off[1] + len(u_raw))
d_off = (u_off[1],       u_off[1] + len(d_raw))

# EXACT same long key names as the real Gemma 4 E2B layer-0 MLP -> identical Rail scan path
KG = "model.language_model.layers.0.mlp.gate_proj.weight"
KU = "model.language_model.layers.0.mlp.up_proj.weight"
KD = "model.language_model.layers.0.mlp.down_proj.weight"
meta = {
    KG: {"dtype": "BF16", "shape": [H, D], "data_offsets": list(g_off)},
    KU: {"dtype": "BF16", "shape": [H, D], "data_offsets": list(u_off)},
    KD: {"dtype": "BF16", "shape": [D, H], "data_offsets": list(d_off)},
}
hdr = json.dumps(meta, separators=(",", ":")).encode("utf-8")  # compact, like real safetensors
with open(OUT_ST, "wb") as o:
    o.write(struct.pack("<Q", len(hdr)))
    o.write(hdr)
    o.write(g_raw); o.write(u_raw); o.write(d_raw)

# deterministic fixed-point input x (SAME integer source the Rail oracle uses), then dequant
xi = np.array([((i * 131 + 7) % 2001 - 1000) * 8192 for i in range(D)], dtype=np.int64)
xf = xi.astype(np.float64) / S

gate = Wg @ xf
up   = Wu @ xf
inner = 0.7978845608 * (gate + 0.044715 * gate**3)   # true tanh-gelu
gelu = 0.5 * gate * (1.0 + np.tanh(inner))
h = gelu * up
y = Wd @ h

yi = np.rint(y * S).astype(np.int64)
gate0_fix = int(round(gate[0] * S))

with open(OUT_REF, "w") as o:
    o.write(f"{D}\n")
    o.write(f"{gate0_fix}\n")
    for v in yi:
        o.write(f"{int(v)}\n")

print(f"fixture written: {OUT_ST}  N={len(hdr)} base={8+len(hdr)} data={len(g_raw)+len(u_raw)+len(d_raw)}B")
print(f"offsets g={g_off} u={u_off} d={d_off}")
print(f"ref written: {OUT_REF}  D={D} H={H}")
print(f"gate[0] float={gate[0]:.8f} fix={gate0_fix}")
print(f"y fix: {[int(v) for v in yi]}")
print(f"max|y|={np.max(np.abs(y)):.6f}")
# gate row0 [0..3] decoded fixed (must match Rail bf16 decode -> oracle ok_w spot check)
print(f"gate row0 [0..3] fixed = {[int(round(Wg[0,c]*S)) for c in range(D)]}")
