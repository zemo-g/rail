#!/bin/bash
# run_training.sh — Immortal self-training loop
# Each round runs as a fresh process with a clean 256MB arena.
# Progress is file-based — survives crashes, restarts, power cycles.
#
# Usage: ./tools/train/run_training.sh [--port PORT]
#   Ctrl-C to stop. Touch /tmp/rail_st_stop to stop gracefully.

set -e
cd ~/projects/rail

PORT="${1:-8080}"
PAUSE=2

# Compile once (recompile only if source changed)
HASH_FILE="/tmp/rail_st_hash"
SRC_HASH=$(md5 -q tools/train/self_train.rail 2>/dev/null || md5sum tools/train/self_train.rail | cut -d' ' -f1)
OLD_HASH=$(cat "$HASH_FILE" 2>/dev/null || echo "")

if [ "$SRC_HASH" != "$OLD_HASH" ] || [ ! -f /tmp/rail_st_bin ]; then
    echo "Compiling self_train.rail..."
    ./rail_native tools/train/self_train.rail
    if [ -f /tmp/rail_out ] && [ $(stat -f%z /tmp/rail_out 2>/dev/null || echo 0) -gt 100000 ]; then
        cp /tmp/rail_out /tmp/rail_st_bin
        echo "$SRC_HASH" > "$HASH_FILE"
        echo "Compiled. ($(stat -f%z /tmp/rail_st_bin) bytes)"
    else
        echo "ERROR: Compile produced bad binary. Using existing /tmp/rail_st_bin if available."
        if [ ! -f /tmp/rail_st_bin ] || [ $(stat -f%z /tmp/rail_st_bin 2>/dev/null || echo 0) -lt 100000 ]; then
            echo "FATAL: No good binary available. Exiting."
            exit 1
        fi
    fi
fi

rm -f /tmp/rail_st_stop

echo "=== SELF-TRAINING LOOP ==="
echo "  Port: $PORT"
echo "  Stop: touch /tmp/rail_st_stop"
echo ""

while true; do
    # Graceful stop
    if [ -f /tmp/rail_st_stop ]; then
        echo "Stop file detected. Exiting."
        rm -f /tmp/rail_st_stop
        exit 0
    fi

    # Run one round (round counter managed by Rail via progress.txt)
    /tmp/rail_st_bin --port "$PORT" 2>&1 || true

    # Brief pause between rounds (fresh arena on next start)
    sleep $PAUSE
done
