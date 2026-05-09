#!/usr/bin/env bash
# fuzz_phase_a.sh - non-interactive "stage + pre-snapshot" half of one cycle.
#
# Usage:
#   tools/garmin/fuzz_phase_a.sh [<mutation_path>]
#
# With no arg: control cycle (no file staged). With path: stages that file
# in /Volumes/GARMIN/GARMIN/NewFiles/.
# Prints the cycle dir to stdout (last line) so phase_b can find it.

set -eu
mutation="${1:-}"
watch="/Volumes/GARMIN"
[[ -d "$watch/GARMIN" ]] || { echo "ERROR: watch not mounted at $watch" >&2; exit 1; }

label="control"
if [[ -n "$mutation" ]]; then
  [[ -f "$mutation" ]] || { echo "ERROR: $mutation missing" >&2; exit 1; }
  label="$(basename "$mutation" .fit)"
fi
cycle_dir="$HOME/garmin_recon/fuzz/cycle_$(date +%Y%m%d_%H%M%S)_${label}"
mkdir -p "$cycle_dir"

echo "=== phase A: cycle $label ==="
echo "  cycle_dir: $cycle_dir"
[[ -n "$mutation" ]] && cp "$mutation" "$cycle_dir/mutation.fit"

# pre.sha256
find "$watch/GARMIN" -type f -print0 2>/dev/null | xargs -0 shasum -a 256 \
    > "$cycle_dir/pre.sha256" 2>/dev/null || true

# pre.evntlogs.txt
: > "$cycle_dir/pre.evntlogs.txt"
for f in "$watch/GARMIN/EVNTLOGS"/*.TXT; do
  [[ -e "$f" ]] || continue
  echo "===== $(basename "$f") =====" >> "$cycle_dir/pre.evntlogs.txt"
  cat "$f" >> "$cycle_dir/pre.evntlogs.txt"
done
[[ -f "$watch/GARMIN/Debug/SNS_ERR.TXT" ]] && {
  echo "===== SNS_ERR.TXT =====" >> "$cycle_dir/pre.evntlogs.txt"
  cat "$watch/GARMIN/Debug/SNS_ERR.TXT" >> "$cycle_dir/pre.evntlogs.txt"
}

if [[ -n "$mutation" ]]; then
  mkdir -p "$watch/GARMIN/NewFiles"
  cp "$mutation" "$watch/GARMIN/NewFiles/${label}.fit"
  sync
  echo "  staged: $watch/GARMIN/NewFiles/${label}.fit"
else
  echo "  control cycle - nothing staged"
fi

echo "  pre.sha256:    $(wc -l < $cycle_dir/pre.sha256) files"
echo "  pre.evntlogs:  $(wc -l < $cycle_dir/pre.evntlogs.txt) lines"
echo
echo "=== EJECT NOW: diskutil eject $watch (then say 'done') ==="
echo "$cycle_dir"
