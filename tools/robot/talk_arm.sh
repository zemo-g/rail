#!/bin/bash
# tools/robot/talk_arm.sh
#
# Conversational REPL for the PHYSICAL Hiwonder MaxArm. Drop-in
# replacement for talk.sh: same user interface, same world-state file,
# same /tmp/arm_commands.log, same conversational engine
# (call_substrate.sh or Spur-arm endpoint). Differs from talk.sh in
# that the candidate Rail program imports tools/robot/arm_real.rail
# (frame-emitting driver) instead of tools/robot/arm_sim.rail. The
# fault codes match so the narration logic is unchanged.
#
# Slash commands (additional to talk.sh's set):
#   /estop       send arm_emergency_stop and refuse further commands
#                until /resume
#   /resume      clear e-stop, allow new commands
#   /home        send Home Cmd to the arm
#   /calibrate   walk through named-point calibration (uses
#                tools/robot/calibrate.rail)
#   /readxyz     send FUNC_READ_XYZ and print the response
#
# Safety:
# - Ctrl-C at any input prompt sends e-stop and exits.
# - On first launch, if ~/.robot/maxarm_calib.txt is missing or older
#   than 30 days, warn the user.
# - DEVICE env var overrides device discovery.
# - DRY_RUN=1 keeps the substrate prompt loop but doesn't open the
#   serial port (useful for offline rehearsal).
#
# Run:
#   bash tools/robot/talk_arm.sh
#   DEVICE=/dev/cu.usbserial-A1234 bash tools/robot/talk_arm.sh
#   DRY_RUN=1 bash tools/robot/talk_arm.sh

set -u
SPEC_BASE="tools/robot/talk_spec_base.txt"
STATE_FILE="/tmp/robot_world.txt"
HISTORY_FILE="/tmp/robot_history.txt"
CMD_LOG="/tmp/arm_commands.log"
CANDIDATE_RAIL="/tmp/talk_arm_candidate.rail"
SIM_OUT="/tmp/talk_arm_sim.out"
ESTOP_SENTINEL="/tmp/talk_arm_estopped"
CALIB_FILE="$HOME/.robot/maxarm_calib.txt"

export PORT="${PORT:-8082}"
export TEMPERATURE="${TEMPERATURE:-0.4}"
export MAX_TOKENS="${MAX_TOKENS:-512}"
export ENABLE_THINKING="${ENABLE_THINKING:-false}"
DRY_RUN="${DRY_RUN:-0}"

# ----------------------------------------------------------------------
# Device discovery.
# ----------------------------------------------------------------------

discover_device() {
  if [ -n "${DEVICE:-}" ]; then
    echo "$DEVICE"
    return
  fi
  for pat in /dev/cu.usbserial-* /dev/cu.SLAB_USBtoUART* /dev/cu.wchusbserial*; do
    for d in $pat; do
      if [ -e "$d" ]; then
        echo "$d"
        return
      fi
    done
  done
  echo ""
}

# ----------------------------------------------------------------------
# Calibration freshness.
# ----------------------------------------------------------------------

check_calib() {
  if [ ! -f "$CALIB_FILE" ]; then
    echo "[robot] No calibration file at $CALIB_FILE."
    echo "[robot] Default offsets (cx=0, cy=0, cz=0) will be used."
    echo "[robot] Run /calibrate before high-precision pickups."
    return
  fi
  # If older than 30 days, warn.
  if [ -n "$(find "$CALIB_FILE" -mtime +30 2>/dev/null)" ]; then
    echo "[robot] Calibration file is older than 30 days. Consider /calibrate."
  fi
}

load_calib() {
  cx=0; cy=0; cz=0
  if [ -f "$CALIB_FILE" ]; then
    cx=$(grep '^cx=' "$CALIB_FILE" 2>/dev/null | head -1 | cut -d= -f2)
    cy=$(grep '^cy=' "$CALIB_FILE" 2>/dev/null | head -1 | cut -d= -f2)
    cz=$(grep '^cz=' "$CALIB_FILE" 2>/dev/null | head -1 | cut -d= -f2)
    [ -z "$cx" ] && cx=0
    [ -z "$cy" ] && cy=0
    [ -z "$cz" ] && cz=0
  fi
}

# ----------------------------------------------------------------------
# State file (identical to talk.sh's format).
# ----------------------------------------------------------------------

init_state() {
  cat > "$STATE_FILE" <<'EOT'
ax=0
ay=0
az=0
grip=0
held=0
obx=10
oby=0
obz=5
present=1
ball_origin_x=10
ball_origin_y=0
ball_origin_z=5
last_object=ball
EOT
}

get() {
  grep "^$1=" "$STATE_FILE" | head -1 | cut -d'=' -f2-
}

setv() {
  k="$1"; v="$2"
  if grep -q "^$k=" "$STATE_FILE"; then
    sed -i '' "s|^$k=.*|$k=$v|" "$STATE_FILE"
  else
    echo "$k=$v" >> "$STATE_FILE"
  fi
}

show_state() {
  ax=$(get ax); ay=$(get ay); az=$(get az)
  grip=$(get grip); held=$(get held)
  obx=$(get obx); oby=$(get oby); obz=$(get obz); present=$(get present)

  grip_word="open"; [ "$grip" = "1" ] && grip_word="closed"
  held_word="nothing"; [ "$held" = "1" ] && held_word="the ball"

  ball_loc="not in this world"
  if [ "$present" = "1" ]; then
    if [ "$held" = "1" ]; then
      ball_loc="held by the arm at (${ax},${ay},${az})"
    else
      ball_loc="at (${obx},${oby},${obz})"
    fi
  fi

  echo "[state]"
  echo "  device       : $DEVICE_PATH"
  echo "  arm position : (${ax}, ${ay}, ${az})"
  echo "  grip         : $grip_word"
  echo "  holding      : $held_word"
  echo "  ball         : $ball_loc"
  echo "  calib offsets: cx=$cx cy=$cy cz=$cz mm"
}

# ----------------------------------------------------------------------
# E-stop: write sentinel + spawn a one-shot Rail call to halt the arm.
# ----------------------------------------------------------------------

estop_now() {
  echo "[robot] ESTOP -- releasing suction and freezing."
  : > "$ESTOP_SENTINEL"
  if [ "$DRY_RUN" = "1" ]; then
    echo "[robot] (DRY_RUN: no wire commands sent.)"
    return
  fi
  cat > "/tmp/talk_arm_estop.rail" <<EOT
import "tools/robot/arm_real.rail"

main =
  let fd = arm_open "$DEVICE_PATH"
  if fd < 0 then
    let _ = print "[estop] open failed"
    1
  else
    let r = arm_emergency_stop fd
    let _ = arm_close fd
    let _ = print (cat ["[estop] result=", show r])
    0
EOT
  ./rail_native run /tmp/talk_arm_estop.rail 2>&1 | head -5
}

trap 'estop_now; exit 130' INT

# ----------------------------------------------------------------------
# Prompt building (re-uses talk.sh helpers).
# ----------------------------------------------------------------------

build_state_block() {
  ax=$(get ax); ay=$(get ay); az=$(get az)
  grip=$(get grip); held=$(get held)
  obx=$(get obx); oby=$(get oby); obz=$(get obz); present=$(get present)
  ox=$(get ball_origin_x); oy=$(get ball_origin_y); oz=$(get ball_origin_z)
  last_obj=$(get last_object)

  grip_word="open"; [ "$grip" = "1" ] && grip_word="closed"
  held_word="empty"; [ "$held" = "1" ] && held_word="ball"

  cat <<EOT

# CURRENT WORLD STATE (use this to resolve pronouns and "here"/"there")

arm_position: ($ax, $ay, $az)
grip: $grip_word
holding: $held_word
ball_present: $present
ball_position: ($obx, $oby, $obz)
ball_origin: ($ox, $oy, $oz)
last_mentioned_object: $last_obj
EOT
}

build_history_block() {
  if [ -s "$HISTORY_FILE" ]; then
    tail -n 8 "$HISTORY_FILE"
    echo ""
  fi
}

call_substrate_for_turn() {
  user_msg="$1"
  spec_full=$(mktemp /tmp/talk_arm_spec.XXXXXX.txt)
  cat "$SPEC_BASE" > "$spec_full"
  build_state_block >> "$spec_full"
  user_full="$(build_history_block)User: $user_msg"
  PORT=$PORT TEMPERATURE=$TEMPERATURE MAX_TOKENS=$MAX_TOKENS \
    ENABLE_THINKING=$ENABLE_THINKING \
    sh tools/robot/call_substrate.sh "$spec_full" "$user_full"
  rm -f "$spec_full"
}

# ----------------------------------------------------------------------
# Script execution: wraps the LLM-emitted script in a candidate that
# imports arm_real.rail and runs against the connected device.
# ----------------------------------------------------------------------

int_arg() {
  v="$1"
  if [ "$v" -lt 0 ]; then
    n=$(( 0 - v ))
    echo "(0 - $n)"
  else
    echo "$v"
  fi
}

run_script() {
  llm_script="$1"

  if [ -f "$ESTOP_SENTINEL" ]; then
    echo "[robot] e-stopped. /resume to continue."
    return 1
  fi

  ax=$(get ax); ay=$(get ay); az=$(get az)
  grip=$(get grip); held=$(get held)
  obx=$(get obx); oby=$(get oby); obz=$(get obz); present=$(get present)

  ax_a=$(int_arg "$ax"); ay_a=$(int_arg "$ay"); az_a=$(int_arg "$az")
  grip_a=$(int_arg "$grip"); held_a=$(int_arg "$held")
  obx_a=$(int_arg "$obx"); oby_a=$(int_arg "$oby"); obz_a=$(int_arg "$obz")
  present_a=$(int_arg "$present")
  cx_a=$(int_arg "$cx"); cy_a=$(int_arg "$cy"); cz_a=$(int_arg "$cz")

  if [ "$DRY_RUN" = "1" ]; then
    # In dry-run, fall back to the sim so the user can rehearse the
    # full REPL loop without a serial device. Identical fault codes.
    cat > "$CANDIDATE_RAIL" <<EOT
import "tools/robot/arm_sim.rail"

-- BEGIN LLM SCRIPT --
$llm_script
-- END LLM SCRIPT --

main =
  let _ = print_cmds script
  let _ = print_sim (run_sim_from_state script $ax_a $ay_a $az_a $grip_a $held_a $obx_a $oby_a $obz_a $present_a)
  0
EOT
  else
    cat > "$CANDIDATE_RAIL" <<EOT
import "tools/robot/arm_real.rail"

-- BEGIN LLM SCRIPT --
$llm_script
-- END LLM SCRIPT --

main =
  let _ = print_cmds script
  let fd = arm_open "$DEVICE_PATH"
  if fd < 0 then
    let _ = print "SIM_RESULT ex=$ax_a ey=$ay_a ez=$az_a grip=$grip_a held=$held_a obx=$obx_a oby=$oby_a obz=$obz_a present=$present_a fault=9 steps=0"
    1
  else
    let st = real_run_from_state fd script $ax_a $ay_a $az_a $grip_a $held_a $obx_a $oby_a $obz_a $present_a $cx_a $cy_a $cz_a
    let _ = print_sim st
    let _ = arm_close fd
    0
EOT
  fi

  rm -f /tmp/rail_out "$SIM_OUT"
  ./rail_native "$CANDIDATE_RAIL" > /tmp/talk_arm_compile.log 2>&1
  if [ ! -x /tmp/rail_out ]; then
    echo "[robot] My script didn't compile. (Compiler error at /tmp/talk_arm_compile.log.)"
    return 1
  fi
  /tmp/rail_out > "$SIM_OUT" 2>&1
  return 0
}

update_state_from_sim() {
  sim_line="$1"
  for key in ex ey ez grip held obx oby obz present fault steps; do
    val=$(printf '%s\n' "$sim_line" | sed -n "s/.*${key}=\([-0-9]*\).*/\1/p")
    [ -n "$val" ] || continue
    case "$key" in
      ex) setv ax "$val" ;;
      ey) setv ay "$val" ;;
      ez) setv az "$val" ;;
      grip) setv grip "$val" ;;
      held) setv held "$val" ;;
      obx) setv obx "$val" ;;
      oby) setv oby "$val" ;;
      obz) setv obz "$val" ;;
      present) setv present "$val" ;;
    esac
  done
}

log_commands() {
  awk '/^\[CMDS\]$/{f=1; next} /^\[\/CMDS\]$/{f=0} f' "$SIM_OUT" |
    while IFS= read -r cmd; do
      [ -z "$cmd" ] && continue
      printf '%s  %s\n' "$(date +%H:%M:%S)" "$cmd" >> "$CMD_LOG"
    done
}

narrate() {
  fault=$(printf '%s\n' "$1" | sed -n 's/.*fault=\([-0-9]*\).*/\1/p')
  ax=$(get ax); ay=$(get ay); az=$(get az)
  grip=$(get grip); held=$(get held)

  if [ "${fault:-0}" -ne 0 ]; then
    case "$fault" in
      1) echo "[robot] That spot is outside my workspace." ;;
      2) echo "[robot] My grip was already closed." ;;
      3) echo "[robot] My grip was already open." ;;
      4) echo "[robot] I tried to close on something, but the ball isn't in reach." ;;
      5) echo "[robot] I'm not holding anything to release." ;;
      6) echo "[robot] Wait time was negative." ;;
      9) echo "[robot] Couldn't open the serial port (device gone? unplugged?)." ;;
      *) echo "[robot] Something faulted (code $fault)." ;;
    esac
    return
  fi
  grip_word="open"; [ "$grip" = "1" ] && grip_word="closed"
  held_word="empty-handed"; [ "$held" = "1" ] && held_word="holding the ball"
  echo "[robot] Done. I'm at (${ax}, ${ay}, ${az}), grip $grip_word, $held_word."
}

update_last_object() {
  msg="$1"
  case "$msg" in
    *ball*) setv last_object ball ;;
  esac
}

# ----------------------------------------------------------------------
# Main REPL.
# ----------------------------------------------------------------------

DEVICE_PATH=$(discover_device)
if [ -z "$DEVICE_PATH" ] && [ "$DRY_RUN" != "1" ]; then
  echo "[robot] No /dev/cu.usbserial-* found. Plug the MaxArm in, or set DRY_RUN=1."
  exit 2
fi
[ -z "$DEVICE_PATH" ] && DEVICE_PATH="(dry-run)"

if [ ! -f "$STATE_FILE" ] || [ "${1:-}" = "reset" ]; then
  init_state
  : > "$HISTORY_FILE"
  : > "$CMD_LOG"
fi
rm -f "$ESTOP_SENTINEL"

if ! curl -sS --max-time 3 "http://localhost:$PORT/v1/models" 2>/dev/null | grep -q '"id"'; then
  echo "[robot] No substrate at localhost:$PORT. Start MLX first:"
  echo "  mlx_lm.server --host 127.0.0.1 --port $PORT --model mlx-community/Qwen3.5-122B-A10B-heretic-v2-2.34bit-msq"
  exit 2
fi

check_calib
load_calib
echo "Robot ready (real arm). /state /commands /history /home /readxyz /estop /resume /calibrate /reset /quit"
[ "$DRY_RUN" = "1" ] && echo "[DRY_RUN] no wire commands will be sent."
show_state

while true; do
  printf '> '
  if ! IFS= read -r user_msg; then
    echo ""
    # Do NOT auto-estop on EOF: leaves the arm relaxed (gravity drag).
    # Caller wants the arm to hold the last commanded pose; use /estop
    # explicitly when you want to relax.
    exit 0
  fi
  [ -z "$user_msg" ] && continue

  case "$user_msg" in
    /quit|/q) estop_now; exit 0 ;;
    /reset)
      init_state; : > "$HISTORY_FILE"; : > "$CMD_LOG"; rm -f "$ESTOP_SENTINEL"
      echo "[reset] world cleared"
      show_state
      continue ;;
    /state) show_state; continue ;;
    /commands)
      if [ -s "$CMD_LOG" ]; then tail -n 20 "$CMD_LOG"
      else echo "(no commands issued yet)"; fi
      continue ;;
    /history)
      if [ -s "$HISTORY_FILE" ]; then tail -n 20 "$HISTORY_FILE"
      else echo "(no history yet)"; fi
      continue ;;
    /home) run_script "script = [Home]" && grep '^SIM_RESULT' "$SIM_OUT" | head -1 | { read l; update_state_from_sim "$l"; log_commands; narrate "$l"; }; continue ;;
    /readxyz)
      if [ "$DRY_RUN" = "1" ]; then echo "[robot] (DRY_RUN: skipping wire read)"
      else
        cat > /tmp/talk_arm_readxyz.rail <<EOT
import "tools/robot/arm_real.rail"
main =
  let fd = arm_open "$DEVICE_PATH"
  if fd < 0 then 1
  else
    let r = read_arm_xyz fd
    let ok = head r
    let _ = arm_close fd
    if ok == 0 then
      let _ = print "READXYZ no_response"
      1
    else
      let _ = print (cat ["READXYZ ", show (head (tail r)), " ", show (head (tail (tail r))), " ", show (head (tail (tail (tail r))))])
      0
EOT
        ./rail_native run /tmp/talk_arm_readxyz.rail 2>&1 | head -3
      fi
      continue ;;
    /estop) estop_now; continue ;;
    /resume)
      rm -f "$ESTOP_SENTINEL"
      echo "[robot] e-stop cleared."
      continue ;;
    /calibrate)
      if [ "$DRY_RUN" = "1" ]; then
        echo "[robot] (DRY_RUN: skipping calibration)"
      else
        echo "[robot] Move arm to point ORIGIN by hand, then press Enter."
        read _
        ./rail_native run tools/robot/calibrate.rail --device "$DEVICE_PATH" --point ORIGIN --record
      fi
      load_calib
      continue ;;
  esac

  resp=$(call_substrate_for_turn "$user_msg")
  if [ -z "$resp" ]; then
    echo "[robot] (no response from substrate)"
    continue
  fi

  first_line=$(printf '%s\n' "$resp" | head -1)
  case "$first_line" in
    "ASK:"*|"ASK :"*)
      reply=$(printf '%s\n' "$resp" | sed 's/^ASK: *//; s/^ASK : *//')
      echo "[robot] $reply"
      echo "User: $user_msg" >> "$HISTORY_FILE"
      echo "Robot: $reply" >> "$HISTORY_FILE"
      continue
      ;;
  esac

  llm_script=$(printf '%s\n' "$resp" | awk '
    /^```/ { in_fence = !in_fence; next }
    in_fence { print }
    !/^```/ && !in_fence_seen { print }
  ' | sed '/^[[:space:]]*$/d' | head -40)
  case "$resp" in
    *'```'*) ;;
    *) llm_script="$resp" ;;
  esac

  # If the substrate dropped the "script = " prefix and emitted a bare
  # list like "[MoveTo ...]" prepend it so the wrapper compiles.
  first_nonblank=$(printf '%s\n' "$llm_script" | sed -n '/[^[:space:]]/{p;q;}' | sed 's/^[[:space:]]*//')
  case "$first_nonblank" in
    \[*) llm_script="script = $llm_script" ;;
  esac

  update_last_object "$user_msg"

  if ! run_script "$llm_script"; then
    echo "User: $user_msg" >> "$HISTORY_FILE"
    echo "Robot: (compile error or e-stop)" >> "$HISTORY_FILE"
    continue
  fi

  sim_line=$(grep '^SIM_RESULT' "$SIM_OUT" | head -1)
  if [ -z "$sim_line" ]; then
    echo "[robot] My script ran but produced no result line."
    continue
  fi

  update_state_from_sim "$sim_line"
  log_commands
  reply=$(narrate "$sim_line")
  echo "$reply"

  echo "User: $user_msg" >> "$HISTORY_FILE"
  echo "Robot: $reply" >> "$HISTORY_FILE"
done
