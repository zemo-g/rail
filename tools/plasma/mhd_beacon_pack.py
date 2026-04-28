#!/usr/bin/env python3
"""mhd_beacon_pack.py — pack Rail beacon dumps to /tmp/plasma_live.bin

The Rail driver (tools/plasma/mhd_beacon.rail) writes:
  - /tmp/mhd_beacon/planes.f32  — 6 × N² little-endian f32 planes,
                                   plane-major C-row-major order.
                                   Written by Rail's float_arr_to_f32_file
                                   primitive in a single fwrite call.
  - /tmp/mhd_beacon/meta.txt    — 9 ASCII lines of frame metadata.

This script assembles them into the canonical binary frame format that
entropy_beacon.sh + the Pi witness Ed25519 chain + the homepage ticker
already speak.

  Header (16 B):    uint32  N, N, NFIELDS=6, frame_id   (little-endian)
  Metrics (32 B):   float32 mass, energy, divB, rho_min, dt, sim_time, m0, e0
  Planes (~384 KB): float32[6][N][N]  plane-major C-row-major  (passthrough)

The 2026-04-28 14:14Z rollback was caused by the previous version of
this packer reading 6 ASCII plane files that the Rail driver built via
per-cell `cat` concatenation — the bump arena leaked.  This version
reads the f32 binary blob directly so the Rail side stays linear.
"""
import os
import struct

N = 128
NFIELDS = 6
PLANE_BYTES = NFIELDS * N * N * 4   # 393216

DUMP_DIR = "/tmp/mhd_beacon"
META_PATH = os.path.join(DUMP_DIR, "meta.txt")
PLANES_PATH = os.path.join(DUMP_DIR, "planes.f32")
# Default to a side path so this packer can run alongside the legacy
# mhd_ot_beacon.py without clobbering its frame.  Override with the
# MHD_BEACON_OUT env var when actually driving live /tmp/plasma_live.bin.
OUT_PATH = os.environ.get("MHD_BEACON_OUT", "/tmp/plasma_live_rail.bin")
TMP_PATH = OUT_PATH + ".tmp"


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

    with open(PLANES_PATH, "rb") as f:
        planes = f.read()
    if len(planes) != PLANE_BYTES:
        raise SystemExit(f"planes.f32: got {len(planes)} bytes, expected {PLANE_BYTES}")

    header = struct.pack("<IIII", N, N, NFIELDS, frame_id)
    metrics = struct.pack(
        "<8f", mass, energy, divb, rho_min, dt, sim_time, m0, e0
    )

    with open(TMP_PATH, "wb") as out:
        out.write(header)
        out.write(metrics)
        out.write(planes)
    os.replace(TMP_PATH, OUT_PATH)


if __name__ == "__main__":
    main()
