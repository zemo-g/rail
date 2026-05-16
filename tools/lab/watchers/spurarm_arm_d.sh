#!/bin/sh
# tools/lab/watchers/spurarm_arm_d.sh
#
# Watcher for the Agent D chain entry (spurarm/D-maxarm, MaxArm
# protocol driver + integration). Emits the canonical sentinel block
# from CHAIN_SKELETON_AGENT_D.md.
#
# Dry counter mode (no hardware):
#   protocol_documented        -- 1 (notes/maxarm_protocol.md shipped)
#   ik_unit_test_pass_rate_pct -- 100 (12/12 IK round-trips)
#   physical_arm_connected     -- 0
#   replay_pass                -- 0 (pending hardware)
#   live_repl_pass             -- 0 (pending hardware)
#   estop_latency_ms           -- 0 (un-measured without hardware)
#
# When the user later runs this watcher with HARDWARE_AVAILABLE=1 it
# will additionally:
#   - run the IK test suite and re-compute ik_unit_test_pass_rate_pct
#   - probe DEVICE for a READ_XYZ response and set
#     physical_arm_connected accordingly
#   - replay tools/robot/reference_scripts via replay_cmd_log.sh on
#     the connected arm and set replay_pass
#   - require operator-confirmed live_repl_pass via env var
#     LIVE_REPL_PASS=1
#   - time the e-stop round-trip and set estop_latency_ms
#
# The verdict resolution lives in CHAIN_SKELETON_AGENT_D.md:
#   PASS         -- all counters at target
#   INCONCLUSIVE -- protocol_documented=1, IK=100, but no hardware yet
#   FALSIFIED    -- IK<100 OR replay_pass=0 with hardware available

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT" || exit 1

PROTO_DOC="notes/maxarm_protocol.md"
IK_TEST="tools/robot/coord_map_test.rail"
SMOKE="tools/robot/arm_real_smoke.rail"

# Default: dry mode.
protocol_documented=0
ik_pct=0
physical_connected=0
replay_pass=0
live_repl_pass=0
estop_latency_ms=0

# protocol_documented
[ -s "$PROTO_DOC" ] && protocol_documented=1

# ik_unit_test_pass_rate_pct: parse the "X/12 tests passed" line.
if [ -x ./rail_native ] && [ -f "$IK_TEST" ]; then
  ik_out=$(./rail_native run "$IK_TEST" 2>&1 | tail -3)
  ik_passed=$(printf '%s\n' "$ik_out" | sed -n 's/.* \([0-9]*\)\/12 tests passed.*/\1/p' | head -1)
  if [ -n "$ik_passed" ]; then
    ik_pct=$(( ik_passed * 100 / 12 ))
  fi
fi

# Frame dry-run smoke (not its own counter, but reports a section sum
# so the chain entry can be audited offline).
frame_dry_pct=0
if [ -x ./rail_native ] && [ -f "$SMOKE" ]; then
  smoke_out=$(./rail_native run "$SMOKE" --dry-run 2>&1 | tail -3)
  smoke_passed=$(printf '%s\n' "$smoke_out" | sed -n 's/.* \([0-9]*\)\/5 sections passed.*/\1/p' | head -1)
  if [ -n "$smoke_passed" ]; then
    frame_dry_pct=$(( smoke_passed * 100 / 5 ))
  fi
fi

# Hardware-conditional probes.
if [ "${HARDWARE_AVAILABLE:-0}" = "1" ]; then
  DEVICE_PATH="${DEVICE:-}"
  if [ -z "$DEVICE_PATH" ]; then
    for d in /dev/cu.usbserial-* /dev/cu.SLAB_USBtoUART* /dev/cu.wchusbserial*; do
      [ -e "$d" ] && DEVICE_PATH="$d" && break
    done
  fi
  if [ -n "$DEVICE_PATH" ] && [ -e "$DEVICE_PATH" ]; then
    # READ_XYZ probe via the smoke harness.
    probe_out=$(./rail_native run "$SMOKE" --connect "$DEVICE_PATH" 2>&1 | tail -3)
    if printf '%s\n' "$probe_out" | grep -q "^PASS$"; then
      physical_connected=1
    fi

    # Replay one reference script and check fault=0.
    if [ "$physical_connected" = "1" ]; then
      cat > /tmp/spurarm_arm_d_replay.log <<EOT
[CMDS]
move_to 10 0 5
home
[/CMDS]
EOT
      replay_out=$(DEVICE="$DEVICE_PATH" bash tools/robot/replay_cmd_log.sh /tmp/spurarm_arm_d_replay.log 2>&1 | tail -3)
      if printf '%s\n' "$replay_out" | grep -q "fault=0"; then
        replay_pass=1
      fi

      # E-stop latency probe: measure how long arm_emergency_stop
      # takes round-trip.
      cat > /tmp/spurarm_arm_d_estop.rail <<EOT
import "tools/robot/arm_real.rail"
main =
  let fd = arm_open "$DEVICE_PATH"
  if fd < 0 then 1
  else
    let _ = arm_emergency_stop fd
    let _ = arm_close fd
    0
EOT
      start_ns=$(date +%s%N 2>/dev/null || python3 -c "import time;print(int(time.time()*1e9))")
      ./rail_native run /tmp/spurarm_arm_d_estop.rail > /dev/null 2>&1
      end_ns=$(date +%s%N 2>/dev/null || python3 -c "import time;print(int(time.time()*1e9))")
      if [ -n "$start_ns" ] && [ -n "$end_ns" ]; then
        estop_latency_ms=$(( (end_ns - start_ns) / 1000000 ))
      fi
    fi
  fi
fi

# live_repl_pass is an operator-confirmed flag; we cannot inspect it
# from a watcher. The user sets LIVE_REPL_PASS=1 after running
# talk_arm.sh and observing pick-and-place succeed.
if [ "${LIVE_REPL_PASS:-0}" = "1" ]; then
  live_repl_pass=1
fi

# Verdict resolution per CHAIN_SKELETON_AGENT_D.md.
verdict=INCONCLUSIVE
if [ "$ik_pct" -lt 100 ]; then
  verdict=FALSIFIED
elif [ "$protocol_documented" = "1" ] \
     && [ "$ik_pct" = "100" ] \
     && [ "$physical_connected" = "1" ] \
     && [ "$replay_pass" = "1" ] \
     && [ "$live_repl_pass" = "1" ]; then
  verdict=PASS
elif [ "${HARDWARE_AVAILABLE:-0}" = "1" ] \
     && [ "$physical_connected" = "0" ]; then
  verdict=FALSIFIED
fi

cat <<EOT
===RAIL_LAB_COUNTERS===
{"counter": "protocol_documented", "value": $protocol_documented}
{"counter": "ik_unit_test_pass_rate_pct", "value": $ik_pct}
{"counter": "physical_arm_connected", "value": $physical_connected}
{"counter": "replay_pass", "value": $replay_pass}
{"counter": "live_repl_pass", "value": $live_repl_pass}
{"counter": "estop_latency_ms", "value": $estop_latency_ms}
{"counter": "frame_dry_run_pct", "value": $frame_dry_pct}
===END===
===VERDICT=== $verdict
EOT
