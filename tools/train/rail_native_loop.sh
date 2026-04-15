#!/bin/bash
# tools/train/rail_native_loop.sh — one round of Rail-native training.
#
# launchd invokes this script repeatedly (KeepAlive=true, ThrottleInterval).
# Each invocation: kill-switch check → one training round → exit.
# launchd respawns → next round.
#
# Kill switch: touch ~/.ledatic/data/.rail_train_kill to halt.

set -u

REPO=/Users/ledaticempire/projects/rail
STATE_DIR=$REPO/training/rail_native
LOG_DIR=$STATE_DIR/logs
KILL_FILE=/Users/ledaticempire/.ledatic/data/.rail_train_kill

mkdir -p "$STATE_DIR" "$LOG_DIR" "$(dirname "$KILL_FILE")"

# ── kill switch ───────────────────────────────────────────────────────
if [ -f "$KILL_FILE" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) KILL_SWITCH_PRESENT at $KILL_FILE, exiting" \
    | tee -a "$LOG_DIR/loop.log"
  # Sleep to avoid tight respawn loop while kill switch is set.
  sleep 300
  exit 0
fi

# ── log rotation: keep each file under ~50MB ────────────────────────
for f in "$LOG_DIR"/train.log "$LOG_DIR"/loop.log; do
  if [ -f "$f" ]; then
    size=$(stat -f%z "$f" 2>/dev/null || echo 0)
    if [ "$size" -gt 52428800 ]; then
      mv "$f" "$f.old"
    fi
  fi
done

# ── round ──────────────────────────────────────────────────────────────
ROUND_ID=$(date -u +%Y%m%dT%H%M%SZ)
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ROUND $ROUND_ID start" \
  | tee -a "$LOG_DIR/loop.log"

cd "$REPO"

# Run one training round. Output tagged with round ID for greppability.
./rail_native run tools/train/lm_transformer.rail 2>&1 \
  | awk -v id="$ROUND_ID" '{ print strftime("%Y-%m-%dT%H:%M:%SZ", systime(), 1), id, $0 }' \
  >> "$LOG_DIR/train.log"

EXIT=${PIPESTATUS[0]}

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ROUND $ROUND_ID end exit=$EXIT" \
  | tee -a "$LOG_DIR/loop.log"

exit "$EXIT"
