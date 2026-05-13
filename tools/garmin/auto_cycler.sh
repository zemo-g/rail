#!/usr/bin/env bash
# auto_cycler.sh - Persistent watcher that auto-runs eject cycles.
#
# State machine:
#   READY (queue empty, mounted)            -> stage next, ARMED
#   READY (queue empty, mounted, no queue)  -> emit DONE, exit
#   ARMED (file staged, waiting for unplug) -> wait for unmount
#   CYCLING (unmounted, waiting for re-mount)
#   ARMED -> when /Volumes/GARMIN/GARMIN disappears, become CYCLING
#   CYCLING -> when /Volumes/GARMIN/GARMIN reappears, run phase_b on the
#              currently-staged cycle, then stage next (back to ARMED), or DONE.
#
# Output (stdout, one line per important event - each becomes a Claude
# notification):
#   STAGED <label>           file dropped, please unplug
#   UNPLUGGED                  detected unmount; waiting for re-mount
#   REMOUNTED                  watch came back as MSC
#   NOT_MSC <idProduct>        watch in Garmin mode; please flip back
#   CYCLE_DONE <label> <verdict>
#   QUEUE_EMPTY                no more mutations; auto-cycler exiting
#   STALL                      30+ minutes without state change
#
# Reads the queue from ~/garmin_recon/fuzz/auto_cycler_queue.txt
# (one target_subdir per line).

set -u
queue=$HOME/garmin_recon/fuzz/auto_cycler_queue.txt
state_dir=$HOME/garmin_recon/fuzz
watch="/Volumes/GARMIN"

[[ -f "$queue" ]] || { echo "ERROR: $queue missing - populate first" >&2; exit 1; }
mkdir -p "$state_dir"

cur_cycle_dir=""
state="UNKNOWN"
last_emit=$(date +%s)

# Resume detection: find the most-recent cycle dir that has a `target_subdir`
# file but NO `verdict` - that's a previously-staged cycle waiting for the
# eject. Pick it up in ARMED state.
resume_dir=$(ls -dt $HOME/garmin_recon/fuzz/cycle_*/ 2>/dev/null | head -20 |
             while read d; do
               d=${d%/}
               [[ -f "$d/target_subdir" && ! -f "$d/verdict" ]] && echo "$d" && break
             done | head -1)
if [[ -n "$resume_dir" ]]; then
  cur_cycle_dir="$resume_dir"
  label=$(basename "$cur_cycle_dir" | sed -E 's/^cycle_[0-9_]+_(.+)$/\1/')
  echo "RESUMED cycle in progress: $label"
  state="ARMED"
elif [[ -d "$watch/GARMIN" ]]; then
  state="READY"
fi

while true; do
  now=$(date +%s)
  if [[ -d "$watch/GARMIN" ]]; then
    cur_state="MOUNTED"
  else
    # Check whether USB device is in Garmin mode (so we can warn user).
    pid=$(python3 -c "import usb.core; d=usb.core.find(idVendor=0x091E); print(f'0x{d.idProduct:04x}' if d else 'none')" 2>/dev/null)
    if [[ "$pid" == "0x0003" ]]; then
      cur_state="GARMIN_MODE"
    else
      cur_state="UNMOUNTED"
    fi
  fi

  case "$state:$cur_state" in
    READY:MOUNTED|UNKNOWN:MOUNTED)
      # Stage next from queue.
      next=$(head -1 "$queue" 2>/dev/null)
      if [[ -z "$next" ]]; then
        echo "QUEUE_EMPTY"
        exit 0
      fi
      result=$(~/projects/rail/tools/garmin/fuzz_phase_a_dir.sh "$next" 2>&1)
      cur_cycle_dir=$(echo "$result" | tail -1)
      label=$(basename "$cur_cycle_dir" | sed -E 's/^cycle_[0-9_]+_(.+)$/\1/')
      # Pop queue
      tail -n +2 "$queue" > "$queue.tmp" && mv "$queue.tmp" "$queue"
      echo "STAGED $label  (please unplug + replug; queue has $(wc -l < $queue | tr -d ' ') left)"
      state="ARMED"
      last_emit=$now
      ;;
    ARMED:UNMOUNTED|ARMED:GARMIN_MODE)
      echo "UNPLUGGED"
      state="CYCLING"
      last_emit=$now
      ;;
    CYCLING:GARMIN_MODE)
      # User must flip USB Mode back to Mass Storage.
      if (( now - last_emit > 60 )); then
        echo "NOT_MSC 0x0003 - flip Settings > USB Mode > Mass Storage on the watch"
        last_emit=$now
      fi
      ;;
    CYCLING:MOUNTED)
      echo "REMOUNTED - running phase B"
      verdict_out=$(~/projects/rail/tools/garmin/fuzz_phase_b.sh "$cur_cycle_dir" 2>&1)
      verdict=$(cat "$cur_cycle_dir/verdict" 2>/dev/null || echo 'unknown')
      label=$(basename "$cur_cycle_dir" | sed -E 's/^cycle_[0-9_]+_(.+)$/\1/')
      changed=$(echo "$verdict_out" | grep -E 'content-changed' | awk '{print $NF}')
      evnt=$(echo "$verdict_out" | grep -E 'new event-log lines' | awk '{print $NF}')
      echo "CYCLE_DONE $label  verdict=[$verdict]  changed=$changed  evnt_lines=$evnt"
      state="READY"
      last_emit=$now
      ;;
    *)
      # Stall detection
      if (( now - last_emit > 1800 )); then
        echo "STALL state=$state cur=$cur_state"
        last_emit=$now
      fi
      ;;
  esac
  sleep 15
done
