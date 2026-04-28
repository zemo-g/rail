#!/usr/bin/env python3
"""mhd_beacon_pack.py — pack Rail beacon dumps to /tmp/plasma_live.bin

The Rail driver (tools/plasma/mhd_beacon.rail) writes six ASCII plane
files plus a metadata file each frame; this script assembles them into
the canonical binary frame format that entropy_beacon.sh + the Pi
witness Ed25519 chain + the homepage ticker speak.  The output is
byte-identical to what the legacy mhd_ot_beacon.py produced.

  Header (16 B):    uint32  N, N, NFIELDS=6, frame_id   (little-endian)
  Metrics (32 B):   float32 mass, energy, divB, rho_min, dt, sim_time, m0, e0
  Planes (~384 KB): float32[6][N][N]  in plane-major C order
"""
import os
import struct

N = 128
NFIELDS = 6
DUMP_DIR = "/tmp/mhd_beacon"
META_PATH = os.path.join(DUMP_DIR, "meta.txt")
# Default to a side path so this packer can run alongside the legacy
# mhd_ot_beacon.py without clobbering its frame.  Override with the
# MHD_BEACON_OUT env var when you actually want to drive the live
# /tmp/plasma_live.bin (i.e., after the launchd swap to mhd_beacon.sh).
OUT_PATH = os.environ.get("MHD_BEACON_OUT", "/tmp/plasma_live_rail.bin")
TMP_PATH = OUT_PATH + ".tmp"


def _read_plane(field):
    path = os.path.join(DUMP_DIR, f"plane_{field}.txt")
    with open(path) as f:
        vals = [float(x) for x in f.read().split()]
    if len(vals) != N * N:
        raise SystemExit(f"plane {field}: got {len(vals)} floats, expected {N*N}")
    return vals


def main():
    with open(META_PATH) as f:
        m = [line.strip() for line in f if line.strip()]
    if len(m) < 9:
        raise SystemExit(f"meta.txt: got {len(m)} fields, expected 9")
    frame_id = int(m[0])
    dt, sim_time = float(m[1]), float(m[2])
    m0, e0 = float(m[3]), float(m[4])
    mass, energy = float(m[5]), float(m[6])
    divb, rho_min = float(m[7]), float(m[8])

    header = struct.pack("<IIII", N, N, NFIELDS, frame_id)
    metrics = struct.pack(
        "<8f", mass, energy, divb, rho_min, dt, sim_time, m0, e0
    )

    # Planes are written in Rail as one float per line per cell, with the
    # row index varying fastest (mk_dump_prim_rows iterates y outer, x inner
    # via mk_dump_prim_row).  This matches numpy's C-row-major layout for
    # arr[y, x], which is what the legacy beacon produced.
    planes = bytearray()
    for f in range(NFIELDS):
        vals = _read_plane(f)
        planes.extend(struct.pack(f"<{N*N}f", *vals))

    with open(TMP_PATH, "wb") as out:
        out.write(header)
        out.write(metrics)
        out.write(bytes(planes))
    os.replace(TMP_PATH, OUT_PATH)


if __name__ == "__main__":
    main()
