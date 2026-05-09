#!/bin/bash
# launch_arm.sh — launch one orchestrator arm in the background.
#
# Reads runs/<arm_id>/run_card.meta, seed-substitutes the trainer template,
# compiles it to a per-arm binary (serialised via flock so two arms can't
# stomp on /tmp/rail_out), then nohups the binary with stdout/stderr to
# runs/<arm_id>/train.log. Updates run_card.meta with status=running, pid,
# and launched_at.
#
# Idempotent on already-running arms: refuses to launch if status != queued.
#
# Usage:
#   tools/orch/launch_arm.sh runs/<arm_id>
#
# Exit codes:
#   0  arm launched, pid recorded
#   2  bad args / missing run_card
#   3  required key missing in run_card
#   4  status != queued (already launched / completed)
#   5  seed_trainer.sh failed
#   6  trainer compile failed

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
COMPILE_LOCK=/tmp/rail_orch_compile.lock

if [ $# -ne 1 ]; then
  echo "usage: $0 runs/<arm_id>" >&2
  exit 2
fi

RUN_DIR=$1
RUN_CARD=$RUN_DIR/run_card.meta

if [ ! -f "$RUN_CARD" ]; then
  echo "error: $RUN_CARD not found" >&2
  exit 2
fi

# ── Read meta keys ──────────────────────────────────────────────────
get_key() {
  grep "^$1=" "$RUN_CARD" | head -1 | cut -d'=' -f2-
}

ARM_ID=$(get_key arm_id)
TRAINER_TEMPLATE=$(get_key trainer_template)
SEED_OVERRIDE=$(get_key seed_override)
STATUS=$(get_key status)

for k in arm_id trainer_template seed_override status; do
  v=$(get_key "$k")
  if [ -z "$v" ]; then
    echo "error: required key '$k' missing or empty in $RUN_CARD" >&2
    exit 3
  fi
done

if [ "$STATUS" != "queued" ]; then
  echo "error: status='$STATUS' (expected 'queued') in $RUN_CARD; refusing to relaunch" >&2
  exit 4
fi

cd "$REPO_ROOT"

# ── Per-arm paths ───────────────────────────────────────────────────
ARM_TRAINER=$RUN_DIR/trainer.rail
ARM_BINARY=$RUN_DIR/binary
ARM_LOG=$RUN_DIR/train.log
ARM_CKPT_PREFIX=$RUN_DIR/checkpoints/$ARM_ID

mkdir -p "$RUN_DIR/checkpoints"

# ── Seed-substitute trainer template ───────────────────────────────
if ! "$SCRIPT_DIR/seed_trainer.sh" \
       "$TRAINER_TEMPLATE" "$SEED_OVERRIDE" "$ARM_CKPT_PREFIX" "$ARM_TRAINER"; then
  echo "error: seed_trainer.sh failed for $ARM_ID" >&2
  exit 5
fi

# ── Compile under mkdir-based lock so concurrent launches don't race
# /tmp/rail_out. flock isn't available on macOS by default; mkdir is
# atomic and works everywhere. Wait up to 120s for the lock.
COMPILE_LOCK_DIR=${COMPILE_LOCK}.d
echo "[$ARM_ID] compiling (waiting for compile lock)..."
LOCK_WAIT=0
while ! mkdir "$COMPILE_LOCK_DIR" 2>/dev/null; do
  sleep 1
  LOCK_WAIT=$((LOCK_WAIT + 1))
  if [ $LOCK_WAIT -ge 120 ]; then
    echo "error: gave up waiting for compile lock after 120s" >&2
    exit 6
  fi
done
trap 'rmdir "$COMPILE_LOCK_DIR" 2>/dev/null' EXIT INT TERM

rm -f /tmp/rail_out
./rail_native "$ARM_TRAINER" >"$RUN_DIR/compile.log" 2>&1
COMPILE_RC=$?
if [ $COMPILE_RC -eq 0 ] && [ -x /tmp/rail_out ]; then
  cp /tmp/rail_out "$ARM_BINARY"
  chmod +x "$ARM_BINARY"
  rmdir "$COMPILE_LOCK_DIR" 2>/dev/null
  trap - EXIT INT TERM
else
  rmdir "$COMPILE_LOCK_DIR" 2>/dev/null
  trap - EXIT INT TERM
  echo "error: trainer compile failed (rc=$COMPILE_RC, /tmp/rail_out exists=$([ -x /tmp/rail_out ] && echo yes || echo no)); see $RUN_DIR/compile.log" >&2
  exit 6
fi

# ── Launch in background ───────────────────────────────────────────
nohup "$ARM_BINARY" >"$ARM_LOG" 2>&1 &
PID=$!
disown $PID 2>/dev/null || true

# ── Update run_card: status, pid, launched_at, paths ───────────────
LAUNCHED_AT=$(date +%Y-%m-%dT%H:%M:%S%z)
# Use sed -i.bak for macOS portability; remove the .bak after.
sed -i.bak "s|^status=queued\$|status=running|" "$RUN_CARD"
rm -f "$RUN_CARD.bak"
{
  echo "launched_at=$LAUNCHED_AT"
  echo "pid=$PID"
  echo "trainer_path=$ARM_TRAINER"
  echo "binary_path=$ARM_BINARY"
  echo "log_path=$ARM_LOG"
  echo "ckpt_prefix=$ARM_CKPT_PREFIX"
} >> "$RUN_CARD"

echo "[$ARM_ID] launched pid=$PID log=$ARM_LOG"
exit 0
