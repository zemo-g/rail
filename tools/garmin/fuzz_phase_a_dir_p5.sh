#!/usr/bin/env bash
# fuzz_phase_a_dir_p5.sh - Pass-5: stage a SPECIFIC mutation file into a
# specific directory.
#
# Usage:
#   tools/garmin/fuzz_phase_a_dir_p5.sh <target_subdir> <src_fit>
#
# Drops <src_fit> into /Volumes/GARMIN/GARMIN/<target_subdir>/.
# Records pre-snapshot. Prints cycle_dir to stdout (last line).

set -eu
target_subdir="${1:?usage: fuzz_phase_a_dir_p5.sh <target_subdir> <src_fit>}"
src_fit="${2:?need src_fit}"
watch="/Volumes/GARMIN"
[[ -d "$watch/GARMIN" ]] || { echo "ERROR: watch not mounted at $watch" >&2; exit 1; }
[[ -f "$src_fit" ]] || { echo "ERROR: $src_fit missing" >&2; exit 1; }

label="p5-$(basename "$src_fit" .fit)-$(echo "$target_subdir" | tr / -)"
cycle_dir="$HOME/garmin_recon/fuzz/cycle_$(date +%Y%m%d_%H%M%S)_${label}"
mkdir -p "$cycle_dir"

echo "=== phase A (P5): $label ==="
echo "  cycle_dir: $cycle_dir"
echo "  target:    $watch/GARMIN/$target_subdir/"
echo "  source:    $src_fit"
cp "$src_fit" "$cycle_dir/mutation.fit"
echo "$target_subdir" > "$cycle_dir/target_subdir"

find "$watch/GARMIN" -type f -print0 2>/dev/null | xargs -0 shasum -a 256 \
    > "$cycle_dir/pre.sha256" 2>/dev/null || true

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

mkdir -p "$watch/GARMIN/$target_subdir"
cp "$src_fit" "$watch/GARMIN/$target_subdir/$(basename "$src_fit")"
sync
echo "  staged: $watch/GARMIN/$target_subdir/$(basename "$src_fit")"
echo
echo "$cycle_dir"
