#!/usr/bin/env python3
"""mhd_beacon_daemon.py — warm packer daemon

Long-running sibling of mhd_beacon_pack.py.  Listens on a FIFO at
/tmp/mhd_beacon/ready; on each signal, reads planes.f32 + meta.txt
and assembles the canonical /tmp/plasma_live.bin frame.  Saves the
~50 ms python interpreter startup cost that mhd_beacon_pack.py paid
on every frame when invoked via fork-exec — at 1.7→7 fps the cold-
start tax was the dominant non-LF cost; eliminating it gets the beacon
into the 12-15 fps band.

The daemon is spawned by mhd_beacon.sh before Rail starts, so the
FIFO has a reader by the time Rail's first frame signals.  If the
daemon falls behind (slow disk, GC pause), Rail's `echo 1 > fifo`
blocks naturally — back-pressure with no extra protocol.

Errors during a single pack are swallowed: keeps the daemon alive
across transient races (e.g. partial meta.txt write window).  The
next frame retries from clean.

Tier 4: per-frame chamber image attached after the planes section.
Pre-rendered server-side via chamber_render.py (~15-30 ms per call)
so every viewer gets the same volumetric chamber visual without
running the raymarcher locally.  See docs/plans/CHAMBER_PUBLISHER.md.
Old viewers stop reading at the planes section and never see the
chamber bytes — append-only contract.
"""
import os
import struct
import sys

N = 128
NFIELDS = 6
PLANE_BYTES = NFIELDS * N * N * 4   # 393216

DUMP_DIR = "/tmp/mhd_beacon"
FIFO_PATH = os.path.join(DUMP_DIR, "ready")
META_PATH = os.path.join(DUMP_DIR, "meta.txt")
PLANES_PATH = os.path.join(DUMP_DIR, "planes.f32")
OUT_PATH = os.environ.get("MHD_BEACON_OUT", "/tmp/plasma_live_rail.bin")
TMP_PATH = OUT_PATH + ".tmp"

# Tier 4 chamber renderer — optional.  Lives next to this file.
try:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from chamber_render import render_chamber, IMG_W as CHAMBER_W, IMG_H as CHAMBER_H
    import numpy as np
    _CHAMBER_OK = True
except Exception as _e:
    print(f"mhd_beacon_daemon: chamber_render unavailable ({_e!r}); "
          f"frames will publish without chamber section",
          flush=True, file=sys.stderr)
    _CHAMBER_OK = False
    CHAMBER_W = CHAMBER_H = 0
CHAMBER_FMT_RGB8 = 1


def pack_one():
    try:
        with open(META_PATH) as f:
            m = [line.strip() for line in f if line.strip()]
        if len(m) < 9:
            return
        frame_id = int(m[0])
        dt, sim_time = float(m[1]), float(m[2])
        m0, e0 = float(m[3]), float(m[4])
        mass, energy = float(m[5]), float(m[6])
        divb, rho_min = float(m[7]), float(m[8])

        with open(PLANES_PATH, "rb") as f:
            planes = f.read()
        if len(planes) != PLANE_BYTES:
            return

        header = struct.pack("<IIII", N, N, NFIELDS, frame_id)
        metrics = struct.pack(
            "<8f", mass, energy, divb, rho_min, dt, sim_time, m0, e0
        )

        # Tier 4: render chamber from the just-unpacked plane fields.
        # Wrap in its own try so a render failure on one frame can't
        # block frames that don't need it.
        chamber_section = b""
        if _CHAMBER_OK:
            try:
                # planes layout: plane-major, [rho, vx, vy, p, Bx, By]
                # each as float32 row-major.
                arr = np.frombuffer(planes, dtype=np.float32).reshape(NFIELDS, N, N)
                rho_a, vx_a, vy_a, _, Bx_a, By_a = arr
                cb = render_chamber(rho_a, vx_a, vy_a, Bx_a, By_a)
                chamber_section = (
                    struct.pack("<IIII", CHAMBER_W, CHAMBER_H, CHAMBER_FMT_RGB8, len(cb))
                    + cb
                )
            except Exception as ce:
                # Drop chamber for this frame; downstream legacy
                # viewers ignore it anyway.
                print(f"mhd_beacon_daemon: chamber failed ({ce!r}) on "
                      f"frame {frame_id}", flush=True, file=sys.stderr)

        with open(TMP_PATH, "wb") as out:
            out.write(header)
            out.write(metrics)
            out.write(planes)
            if chamber_section:
                out.write(chamber_section)
        os.replace(TMP_PATH, OUT_PATH)
    except Exception:
        # Keep the daemon alive across transient errors.  The next
        # frame triggers a fresh pack from clean state.
        pass


def main():
    while True:
        # Blocking open: returns when Rail's `echo 1 > fifo` connects.
        # When the writer closes, our read sees EOF; we close and loop
        # back to open the FIFO again, ready for the next frame.
        fd = os.open(FIFO_PATH, os.O_RDONLY)
        try:
            data = os.read(fd, 64)
        finally:
            os.close(fd)
        if data:
            pack_one()


if __name__ == "__main__":
    main()
