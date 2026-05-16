#!/bin/bash
# tools/robot/replay_cmd_log.sh
#
# Re-execute a /tmp/arm_commands.log (as produced by talk.sh or
# talk_arm.sh) against the connected MaxArm. Useful for:
#   - reproducing a substrate session's actions on the physical arm
#   - smoke-testing the driver from a known-good command sequence
#   - regression-testing after driver edits
#
# Usage:
#   bash tools/robot/replay_cmd_log.sh /tmp/arm_commands.log
#   bash tools/robot/replay_cmd_log.sh /tmp/arm_commands.log --dry-run
#   DEVICE=/dev/cu.usbserial-X bash tools/robot/replay_cmd_log.sh log.log
#
# Log format (one line per Cmd, optionally prefixed with HH:MM:SS):
#   12:34:56  move_to 10 0 5
#   12:34:57  grip_close
#   12:34:58  wait 200 ms
#   12:34:59  home
#
# The script:
#   1. parses each line into a Cmd literal
#   2. concatenates them into a `script = [Cmd, ...]` definition
#   3. wraps in a Rail program that imports arm_real.rail
#      (or arm_sim.rail in --dry-run)
#   4. compiles and runs once -- single process, single arm_open

set -u

if [ $# -lt 1 ]; then
  echo "usage: $0 <command-log> [--dry-run]"
  exit 2
fi

LOG="$1"
DRY="${2:-}"

if [ ! -f "$LOG" ]; then
  echo "[replay] no such file: $LOG"
  exit 2
fi

CANDIDATE="/tmp/replay_candidate.rail"
SIM_OUT="/tmp/replay_sim.out"

# Device discovery (same patterns as talk_arm.sh).
DEVICE_PATH="${DEVICE:-}"
if [ -z "$DEVICE_PATH" ] && [ "$DRY" != "--dry-run" ]; then
  for pat in /dev/cu.usbserial-* /dev/cu.SLAB_USBtoUART* /dev/cu.wchusbserial*; do
    for d in $pat; do
      if [ -e "$d" ]; then DEVICE_PATH="$d"; break 2; fi
    done
  done
  if [ -z "$DEVICE_PATH" ]; then
    echo "[replay] no /dev/cu.usbserial-* device. Pass --dry-run, or set DEVICE=..."
    exit 2
  fi
fi

# Convert log into Rail Cmd literals. Strip timestamps + blank lines.
# The log keeps Cmds in execution order; preserve that.
parse_log() {
  awk '
    { sub(/^[0-9][0-9]:[0-9][0-9]:[0-9][0-9][[:space:]]+/, "") }
    $0 ~ /^[[:space:]]*$/ { next }
    $0 ~ /^\[/ { next }                       # skip [CMDS] / [/CMDS]
    /^move_to[[:space:]]/ {
      x = $2; y = $3; z = $4
      printf "MoveTo %s %s %s", (x ~ /^-/ ? "(0 - " substr(x,2) ")" : x), \
                                 (y ~ /^-/ ? "(0 - " substr(y,2) ")" : y), \
                                 (z ~ /^-/ ? "(0 - " substr(z,2) ")" : z)
      print ","
      next
    }
    /^grip_open$/ { print "SetGrip GripOpen,"; next }
    /^grip_close$/ { print "SetGrip GripClose,"; next }
    /^wait[[:space:]]/ {
      ms = $2
      printf "Wait %s,\n", (ms ~ /^-/ ? "(0 - " substr(ms,2) ")" : ms)
      next
    }
    /^home$/ { print "Home,"; next }
    /^script[[:space:]]*=/ { next }
    /^[[:space:]]*\[/ { next }
    /^[[:space:]]*\]/ { next }
    { print "-- unparsed: " $0 > "/dev/stderr" }
  ' "$LOG"
}

CMDS=$(parse_log | sed 's/,$//')
if [ -z "$CMDS" ]; then
  echo "[replay] no Cmds extracted from $LOG"
  exit 1
fi

# Strip the trailing comma on the last element while preserving the rest.
# parse_log added a comma after every line; remove only the very last.
SCRIPT_BODY=$(printf '%s\n' "$CMDS" | awk 'NR>1{print prev","} {prev=$0} END{print prev}' | sed 's/,,$/,/' | sed '$s/,$//')

# Build the Rail program.
if [ "$DRY" = "--dry-run" ]; then
  cat > "$CANDIDATE" <<EOT
import "tools/robot/arm_sim.rail"

script = [
$SCRIPT_BODY
]

main =
  let _ = print_cmds script
  let _ = print_sim (run_sim script)
  0
EOT
else
  # Real device path baked in. Use default calibration; replay is
  # not a precision task -- the calibration step is part of the
  # talk_arm.sh interactive flow.
  cat > "$CANDIDATE" <<EOT
import "tools/robot/arm_real.rail"

script = [
$SCRIPT_BODY
]

main =
  let _ = print_cmds script
  let fd = arm_open "$DEVICE_PATH"
  if fd < 0 then
    let _ = print "REPLAY_FAIL open"
    1
  else
    let st = real_run_from_state fd script 0 0 0 0 0 (0 - 1) 0 0 0 0 0 0
    let _ = print_sim st
    let _ = arm_close fd
    0
EOT
fi

# Compile and run.
rm -f /tmp/rail_out "$SIM_OUT"
./rail_native "$CANDIDATE" > /tmp/replay_compile.log 2>&1
if [ ! -x /tmp/rail_out ]; then
  echo "[replay] compile failed. See /tmp/replay_compile.log."
  exit 1
fi

/tmp/rail_out > "$SIM_OUT" 2>&1
RC=$?
cat "$SIM_OUT"
exit $RC
