#!/bin/bash
# mhd_ot_2d_256.sh — wrapper for the 256² OT MHD GPU solver on Studio.
#
# Auto-rebuilds the metallib + host binary if missing or older than source.
# launchd plist com.ledatic.mhd_ot256 runs this on Studio (M1 Ultra, 64-core GPU).
#
# Output: /tmp/plasma_ot256.bin — 16-byte header + 32-byte metrics +
# 6 planes × 256² × f32 (= 1,572,912 bytes total).  Same format as the
# 128² beacon, scaled up.

set -u

RAIL_DIR="${RAIL_DIR:-$HOME/projects/rail}"
SRC_DIR="$RAIL_DIR/tools/plasma"
METALLIB=/tmp/mhd_ot_2d_256.metallib
HOST_BIN=/tmp/mhd_ot_2d_256

# Rebuild metallib if missing or older than .metal source.
if [ ! -f "$METALLIB" ] || [ "$SRC_DIR/mhd_ot_2d_256.metal" -nt "$METALLIB" ]; then
    echo "build: $METALLIB" >&2
    /usr/bin/xcrun metal -c "$SRC_DIR/mhd_ot_2d_256.metal" -o /tmp/mhd_ot_2d_256.air \
        && /usr/bin/xcrun metallib /tmp/mhd_ot_2d_256.air -o "$METALLIB" \
        || { echo "metallib build failed" >&2; exit 2; }
fi

# Rebuild host binary if missing or older than .m source.
if [ ! -x "$HOST_BIN" ] || [ "$SRC_DIR/mhd_ot_2d_256_host.m" -nt "$HOST_BIN" ]; then
    echo "build: $HOST_BIN" >&2
    /usr/bin/clang -O2 \
        -framework Metal -framework Foundation -fobjc-arc \
        "$SRC_DIR/mhd_ot_2d_256_host.m" \
        -o "$HOST_BIN" \
        || { echo "host build failed" >&2; exit 2; }
fi

# Rapid-respawn guard — KeepAlive=true on the plist will retry, but if the
# binary segfaults at startup we'd thrash.  ThrottleInterval handles it.
exec "$HOST_BIN"
