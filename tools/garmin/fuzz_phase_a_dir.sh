#!/usr/bin/env bash
# fuzz_phase_a_dir.sh - Stage a FIT into an arbitrary subdirectory of GARMIN/.
#
# Usage:
#   tools/garmin/fuzz_phase_a_dir.sh <target_subdir> [<src_fit>]
#
# Copies <src_fit> (default: ~/garmin_recon/fuzz/fit_corpus_p2/p2_clean_baseline.fit
# - the valid gate-passing baseline) into /Volumes/GARMIN/GARMIN/<target_subdir>/.
# Creates the subdir if missing. Records pre-snapshot to ~/garmin_recon/fuzz/cycle_<ts>_dir-<sanitized>/.
# Prints the cycle dir to stdout (last line) so the auto-cycler can find it.

set -eu
target_subdir="${1:?usage: fuzz_phase_a_dir.sh <target_subdir> [<src_fit>]}"
src_fit="${2:-$HOME/garmin_recon/fuzz/fit_corpus_p2/p2_clean_baseline.fit}"
watch="/Volumes/GARMIN"
[[ -d "$watch/GARMIN" ]] || { echo "ERROR: watch not mounted at $watch" >&2; exit 1; }
[[ -f "$src_fit" ]] || { echo "ERROR: $src_fit missing" >&2; exit 1; }

label="dir-$(echo "$target_subdir" | tr / -)"
cycle_dir="$HOME/garmin_recon/fuzz/cycle_$(date +%Y%m%d_%H%M%S)_${label}"
mkdir -p "$cycle_dir"

echo "=== phase A (dir-target): $label ==="
echo "  cycle_dir: $cycle_dir"
echo "  target:    $watch/GARMIN/$target_subdir/"
echo "  source:    $src_fit"
cp "$src_fit" "$cycle_dir/mutation.fit"
echo "$target_subdir" > "$cycle_dir/target_subdir"

# pre-snapshot
find "$watch/GARMIN" -type f -print0 2>/dev/null | xargs -0 shasum -a 256 \
    > "$cycle_dir/pre.sha256" 2>/dev/null || true

# pre-evntlogs
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

# Stage: mkdir + cp (use the basename of the src plus our label so the watch
# always has a unique name to process).
mkdir -p "$watch/GARMIN/$target_subdir"
cp "$src_fit" "$watch/GARMIN/$target_subdir/p4_${label}.fit"
sync
echo "  staged: $watch/GARMIN/$target_subdir/p4_${label}.fit"
echo
echo "$cycle_dir"
