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

# Compile the recovery-chain flush helper too. Re-uses the same md5 cache
# pattern as self_train so we only recompile when flywheel/flush.rail changes.
FLUSH_HASH_FILE="/tmp/rail_flush_hash"
FLUSH_SRC_HASH=$(md5 -q flywheel/flush.rail 2>/dev/null || md5sum flywheel/flush.rail | cut -d' ' -f1)
FLUSH_OLD_HASH=$(cat "$FLUSH_HASH_FILE" 2>/dev/null || echo "")
if [ "$FLUSH_SRC_HASH" != "$FLUSH_OLD_HASH" ] || [ ! -f /tmp/rail_flush_bin ]; then
    echo "Compiling flush.rail..."
    ./rail_native flywheel/flush.rail
    if [ -f /tmp/rail_out ] && [ $(stat -f%z /tmp/rail_out 2>/dev/null || echo 0) -gt 10000 ]; then
        cp /tmp/rail_out /tmp/rail_flush_bin
        echo "$FLUSH_SRC_HASH" > "$FLUSH_HASH_FILE"
        echo "Compiled. ($(stat -f%z /tmp/rail_flush_bin) bytes)"
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

    # Recovery snapshot (Empire transplant Session 2): rotate flywheel
    # data files into .backup / .backup.prev with size + line guards.
    # Skipped silently if /tmp/rail_flush_bin is missing.
    if [ -x /tmp/rail_flush_bin ]; then
        /tmp/rail_flush_bin 2>&1 || true
    fi

    # Brief pause between rounds (fresh arena on next start)
    sleep $PAUSE
done
