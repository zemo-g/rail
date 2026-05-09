#!/usr/bin/env bash
# auto_cycler_p7.sh - Pass-5 variant: queue is "subdir <space> src_fit_path"
# pairs, one per line.

set -u
queue=$HOME/garmin_recon/fuzz/auto_cycler_queue_p7.txt
watch="/Volumes/GARMIN"

[[ -f "$queue" ]] || { echo "ERROR: $queue missing" >&2; exit 1; }
mkdir -p "$HOME/garmin_recon/fuzz"

cur_cycle_dir=""
state="UNKNOWN"
last_emit=$(date +%s)

resume_dir=$(ls -dt $HOME/garmin_recon/fuzz/cycle_*_p7-*/ 2>/dev/null | head -10 |
             while read d; do
               d=${d%/}
               [[ -f "$d/target_subdir" && ! -f "$d/verdict" ]] && echo "$d" && break
             done | head -1)
if [[ -n "$resume_dir" ]]; then
  cur_cycle_dir="$resume_dir"
  label=$(basename "$cur_cycle_dir" | sed -E 's/^cycle_[0-9_]+_(.+)$/\1/')
  echo "RESUMED $label"
  state="ARMED"
elif [[ -d "$watch/GARMIN" ]]; then
  state="READY"
fi

while true; do
  now=$(date +%s)
  if [[ -d "$watch/GARMIN" ]]; then
    cur_state="MOUNTED"
  else
    pid=$(python3 -c "import usb.core; d=usb.core.find(idVendor=0x091E); print(f'0x{d.idProduct:04x}' if d else 'none')" 2>/dev/null)
    if [[ "$pid" == "0x0003" ]]; then
      cur_state="GARMIN_MODE"
    else
      cur_state="UNMOUNTED"
    fi
  fi

  case "$state:$cur_state" in
    READY:MOUNTED|UNKNOWN:MOUNTED)
      next=$(head -1 "$queue" 2>/dev/null)
      if [[ -z "$next" ]]; then
        echo "QUEUE_EMPTY"
        exit 0
      fi
      target_subdir=$(echo "$next" | awk '{print $1}')
      src_fit=$(echo "$next" | awk '{print $2}')
      result=$(/Users/user/projects/rail/tools/garmin/fuzz_phase_a_dir_p7.sh "$target_subdir" "$src_fit" 2>&1)
      cur_cycle_dir=$(echo "$result" | tail -1)
      label=$(basename "$cur_cycle_dir" | sed -E 's/^cycle_[0-9_]+_(.+)$/\1/')
      tail -n +2 "$queue" > "$queue.tmp" && mv "$queue.tmp" "$queue"
      echo "STAGED $label  ($(wc -l < $queue | tr -d ' ') left)"
      state="ARMED"
      last_emit=$now
      ;;
    ARMED:UNMOUNTED|ARMED:GARMIN_MODE)
      echo "UNPLUGGED"
      state="CYCLING"
      last_emit=$now
      ;;
    CYCLING:GARMIN_MODE)
      if (( now - last_emit > 60 )); then
        echo "NOT_MSC 0x0003 - flip USB Mode -> Mass Storage on the watch"
        last_emit=$now
      fi
      ;;
    CYCLING:MOUNTED)
      echo "REMOUNTED - running phase B (with 5s flush wait)"
      verdict_out=$(/Users/user/projects/rail/tools/garmin/fuzz_phase_b.sh "$cur_cycle_dir" 2>&1)
      verdict=$(cat "$cur_cycle_dir/verdict" 2>/dev/null || echo 'unknown')
      label=$(basename "$cur_cycle_dir" | sed -E 's/^cycle_[0-9_]+_(.+)$/\1/')
      changed=$(echo "$verdict_out" | grep -E 'content-changed' | awk '{print $NF}')
      evnt=$(echo "$verdict_out" | grep -E 'new event-log lines' | awk '{print $NF}')
      echo "CYCLE_DONE $label  verdict=[$verdict]  changed=$changed  evnt_lines=$evnt"
      state="READY"
      last_emit=$now
      ;;
    *)
      if (( now - last_emit > 1800 )); then
        echo "STALL state=$state cur=$cur_state"
        last_emit=$now
      fi
      ;;
  esac
  sleep 15
done
