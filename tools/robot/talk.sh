#!/bin/bash
# tools/robot/talk.sh
#
# Conversational REPL for the robot-arm flywheel. The user types
# casual natural-language commands ("grab it", "take it to B",
# "go home"). Each turn:
#
#   1. Builds a system prompt = base DSL spec + current world state
#   2. Builds a user prompt = recent history + this turn
#   3. Calls substrate via tools/robot/call_substrate.sh
#   4. If response starts with "ASK: ", prints as a clarifying reply
#   5. Otherwise wraps the LLM-emitted `script` in a runnable Rail
#      program with the current state, compiles, runs the sim,
#      parses SIM_RESULT
#   6. Logs every issued Cmd to /tmp/arm_commands.log
#   7. Updates world state and narrates the diff
#   8. Appends turn to /tmp/robot_history.txt
#
# Slash commands:
#   /reset        reset world state and history
#   /state        show current world state
#   /commands     show the Cmd log so far
#   /history      show recent conversation
#   /quit | /q    exit
#
# Run:
#   bash tools/robot/talk.sh

set -u
SPEC_BASE="tools/robot/talk_spec_base.txt"
STATE_FILE="/tmp/robot_world.txt"
HISTORY_FILE="/tmp/robot_history.txt"
CMD_LOG="/tmp/arm_commands.log"
CANDIDATE_RAIL="/tmp/talk_candidate.rail"
SIM_OUT="/tmp/talk_sim.out"

export PORT="${PORT:-8082}"
export TEMPERATURE="${TEMPERATURE:-0.4}"
export MAX_TOKENS="${MAX_TOKENS:-512}"
export ENABLE_THINKING="${ENABLE_THINKING:-false}"

# ----------------------------------------------------------------------
# State file management.
# Layout: simple key=value lines.
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
    # In-place edit (BSD sed)
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
  echo "  arm position : (${ax}, ${ay}, ${az})"
  echo "  grip         : $grip_word"
  echo "  holding      : $held_word"
  echo "  ball         : $ball_loc"
}

# ----------------------------------------------------------------------
# Prompt building.
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

  # Combine spec base + dynamic state into a single system prompt file.
  spec_full=$(mktemp /tmp/talk_spec.XXXXXX.txt)
  cat "$SPEC_BASE" > "$spec_full"
  build_state_block >> "$spec_full"

  # Build user prompt: prior history + this turn.
  user_full="$(build_history_block)User: $user_msg"

  PORT=$PORT TEMPERATURE=$TEMPERATURE MAX_TOKENS=$MAX_TOKENS \
    ENABLE_THINKING=$ENABLE_THINKING \
    sh tools/robot/call_substrate.sh "$spec_full" "$user_full"

  rm -f "$spec_full"
}

# ----------------------------------------------------------------------
# Script execution: wrap the LLM-emitted `script = [...]` in a runnable
# program that inherits current state, runs the sim, prints CMDS + SIM.
# ----------------------------------------------------------------------

# Emit a Rail int literal that survives Rail's "negatives-are-subtraction"
# parsing quirk.
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

  ax=$(get ax); ay=$(get ay); az=$(get az)
  grip=$(get grip); held=$(get held)
  obx=$(get obx); oby=$(get oby); obz=$(get obz); present=$(get present)

  ax_a=$(int_arg "$ax"); ay_a=$(int_arg "$ay"); az_a=$(int_arg "$az")
  grip_a=$(int_arg "$grip"); held_a=$(int_arg "$held")
  obx_a=$(int_arg "$obx"); oby_a=$(int_arg "$oby"); obz_a=$(int_arg "$obz")
  present_a=$(int_arg "$present")

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

  rm -f /tmp/rail_out "$SIM_OUT"
  ./rail_native "$CANDIDATE_RAIL" > /tmp/talk_compile.log 2>&1
  if [ ! -x /tmp/rail_out ]; then
    echo "[robot] My script didn't compile. (Compiler error logged at /tmp/talk_compile.log.)"
    return 1
  fi

  /tmp/rail_out > "$SIM_OUT" 2>&1
  return 0
}

# Update world state from a SIM_RESULT line.
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

# Append each executed Cmd to /tmp/arm_commands.log with a timestamp.
log_commands() {
  # The sim binary prints [CMDS]\n<lines>\n[/CMDS]; pull that range.
  awk '/^\[CMDS\]$/{f=1; next} /^\[\/CMDS\]$/{f=0} f' "$SIM_OUT" |
    while IFS= read -r cmd; do
      [ -z "$cmd" ] && continue
      printf '%s  %s\n' "$(date +%H:%M:%S)" "$cmd" >> "$CMD_LOG"
    done
}

# Build a friendly one-line narration of what happened.
narrate() {
  fault=$(printf '%s\n' "$1" | sed -n 's/.*fault=\([-0-9]*\).*/\1/p')
  ax=$(get ax); ay=$(get ay); az=$(get az)
  grip=$(get grip); held=$(get held)

  if [ "${fault:-0}" -ne 0 ]; then
    case "$fault" in
      1) echo "[robot] That spot is outside my workspace (must be 0..30 on each axis)." ;;
      2) echo "[robot] My grip was already closed." ;;
      3) echo "[robot] My grip was already open." ;;
      4) echo "[robot] I tried to close on something, but the ball isn't in reach." ;;
      5) echo "[robot] I'm not holding anything to release." ;;
      6) echo "[robot] Wait time was negative." ;;
      *) echo "[robot] Something faulted (code $fault)." ;;
    esac
    return
  fi

  grip_word="open"; [ "$grip" = "1" ] && grip_word="closed"
  held_word="empty-handed"; [ "$held" = "1" ] && held_word="holding the ball"

  echo "[robot] Done. I'm at (${ax}, ${ay}, ${az}), grip $grip_word, $held_word."
}

# Track which object the user most recently referred to. Cheap pattern
# match for now — extend when bench v1 introduces more objects.
update_last_object() {
  msg="$1"
  case "$msg" in
    *ball*) setv last_object ball ;;
  esac
}

# ----------------------------------------------------------------------
# Main REPL.
# ----------------------------------------------------------------------

# Init on first launch (or after /reset)
if [ ! -f "$STATE_FILE" ] || [ "${1:-}" = "reset" ]; then
  init_state
  : > "$HISTORY_FILE"
  : > "$CMD_LOG"
fi

# Substrate health check.
if ! curl -sS --max-time 3 "http://localhost:$PORT/v1/models" 2>/dev/null | grep -q '"id"'; then
  echo "[robot] No substrate at localhost:$PORT. Start MLX first:"
  echo "  mlx_lm.server --host 127.0.0.1 --port $PORT --model mlx-community/Qwen3.5-122B-A10B-heretic-v2-2.34bit-msq"
  exit 2
fi

echo "Robot ready. Talk to me. /state /commands /history /reset /quit"
show_state

while true; do
  printf '> '
  if ! IFS= read -r user_msg; then
    echo ""
    exit 0
  fi
  [ -z "$user_msg" ] && continue

  case "$user_msg" in
    /quit|/q) exit 0 ;;
    /reset)
      init_state; : > "$HISTORY_FILE"; : > "$CMD_LOG"
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
  esac

  resp=$(call_substrate_for_turn "$user_msg")

  if [ -z "$resp" ]; then
    echo "[robot] (no response — substrate may be slow; try again?)"
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

  # Strip optional markdown fences (mirror grader.rail behavior).
  llm_script=$(printf '%s\n' "$resp" | awk '
    /^```/ { in_fence = !in_fence; next }
    in_fence { print }
    !/^```/ && !in_fence_seen { print }
  ' | sed '/^[[:space:]]*$/d' | head -40)
  # Fallback: if no fence pattern, use raw response.
  case "$resp" in
    *'```'*) ;;  # used the fenced extractor above
    *) llm_script="$resp" ;;
  esac

  update_last_object "$user_msg"

  if ! run_script "$llm_script"; then
    echo "User: $user_msg" >> "$HISTORY_FILE"
    echo "Robot: (compile error)" >> "$HISTORY_FILE"
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
