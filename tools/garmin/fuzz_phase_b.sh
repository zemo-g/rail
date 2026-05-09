#!/usr/bin/env bash
# fuzz_phase_b.sh - non-interactive "post-snapshot + diff" half of a cycle.
#
# Usage:
#   tools/garmin/fuzz_phase_b.sh [<cycle_dir>]
#
# With no arg: picks the most recently created cycle dir.
# Verifies the watch is back in Mass Storage mode, then snapshots, diffs,
# categorises, and prints a verdict.

set -eu
watch="/Volumes/GARMIN"
[[ -d "$watch/GARMIN" ]] || {
  echo "ERROR: watch not mounted at $watch" >&2
  echo "       (toggle USB Mode -> Mass Storage on the watch and replug)" >&2
  exit 1
}

if [[ $# -ge 1 ]]; then
  cycle_dir="$1"
else
  cycle_dir=$(ls -dt "$HOME/garmin_recon/fuzz/cycle_"* 2>/dev/null | head -1)
fi
[[ -d "$cycle_dir" ]] || { echo "ERROR: no cycle dir" >&2; exit 1; }
label=$(basename "$cycle_dir" | sed -E 's/^cycle_[0-9_]+_(.+)$/\1/')

echo "=== phase B: cycle $label ==="
echo "  cycle_dir: $cycle_dir"

# Sleep 5s to let the watch flush its post-boot EVNTLOGS write before we
# snapshot - eliminates the timing race that gave us evnt_lines=0 readings
# on fast-replug cycles in Pass 4.
sleep 5

# post.sha256
find "$watch/GARMIN" -type f -print0 2>/dev/null | xargs -0 shasum -a 256 \
    > "$cycle_dir/post.sha256" 2>/dev/null || true

# post.evntlogs
: > "$cycle_dir/post.evntlogs.txt"
for f in "$watch/GARMIN/EVNTLOGS"/*.TXT; do
  [[ -e "$f" ]] || continue
  echo "===== $(basename "$f") =====" >> "$cycle_dir/post.evntlogs.txt"
  cat "$f" >> "$cycle_dir/post.evntlogs.txt"
done
[[ -f "$watch/GARMIN/Debug/SNS_ERR.TXT" ]] && {
  echo "===== SNS_ERR.TXT =====" >> "$cycle_dir/post.evntlogs.txt"
  cat "$watch/GARMIN/Debug/SNS_ERR.TXT" >> "$cycle_dir/post.evntlogs.txt"
}

# Diffs
diff "$cycle_dir/pre.sha256" "$cycle_dir/post.sha256" > "$cycle_dir/sha.diff" 2>&1 || true
diff "$cycle_dir/pre.evntlogs.txt" "$cycle_dir/post.evntlogs.txt" > "$cycle_dir/evnt.diff" 2>&1 || true

# Real-content changes (excluding new/removed files which are also legitimate)
content_changed=$(diff <(sort "$cycle_dir/pre.sha256") <(sort "$cycle_dir/post.sha256") \
                   | awk '/^</{p[$2]=1} /^>/{q[$2]=1} END{for (f in p) if (q[f]) print f}' \
                   | wc -l | tr -d ' ')
new_files=$(comm -13 <(awk '{print $2}' "$cycle_dir/pre.sha256" | sort) \
                       <(awk '{print $2}' "$cycle_dir/post.sha256" | sort) | wc -l | tr -d ' ')
removed_files=$(comm -23 <(awk '{print $2}' "$cycle_dir/pre.sha256" | sort) \
                          <(awk '{print $2}' "$cycle_dir/post.sha256" | sort) | wc -l | tr -d ' ')
new_evnt_lines=$(grep -cE '^>' "$cycle_dir/evnt.diff" || true)
crash_signal=$(grep -ciE 'reset|crash|fault|panic|hardfault|memmanage|busfault' "$cycle_dir/evnt.diff" || true)

# Verdict
if (( crash_signal > 0 )); then
  verdict="CRASHED"
elif (( content_changed > 1 || new_files > 1 || removed_files > 1 )); then
  verdict="rejected (state-touched)"
elif (( new_evnt_lines > 0 )); then
  verdict="ignored (event-logged only)"
else
  verdict="ignored (silent)"
fi
echo "$verdict" > "$cycle_dir/verdict"

echo "  content-changed files: $content_changed"
echo "  new files:             $new_files"
echo "  removed files:         $removed_files"
echo "  new event-log lines:   $new_evnt_lines"
echo "  crash-keyword hits:    $crash_signal"
echo "  verdict:               $verdict"
echo
echo '=== content-changed files ==='
diff <(sort "$cycle_dir/pre.sha256") <(sort "$cycle_dir/post.sha256") \
  | awk '/^</{p[$2]=1} /^>/{q[$2]=1} END{for (f in p) if (q[f]) print "  " f}'
echo
echo '=== new event-log lines (head 30) ==='
grep -E '^>' "$cycle_dir/evnt.diff" | head -30 | sed 's/^/  /'
