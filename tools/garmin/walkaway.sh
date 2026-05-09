#!/usr/bin/env bash
# tools/garmin/walkaway.sh — plug the watch in, walk away, come back to a report.
#
# READ-ONLY. Polls for the mount, snapshots SHA-256 of every file, diffs against
# the 2026-04-28 baseline, pulls GARMIN/DEBUG (crash/error logs), runs dump.sh
# for a FIT summary, and ejects cleanly. Writes everything under
# ~/garmin_recon/walkaway_<timestamp>/.
#
# Usage:
#   tools/garmin/walkaway.sh                    # default mount, 5-min wait
#   TIMEOUT=600 tools/garmin/walkaway.sh        # wait up to 10 minutes
#   tools/garmin/walkaway.sh /Volumes/GARMIN    # explicit mount path
#
# Run from rail repo root (or any cwd — script cd's to repo root for dump.sh).

set -u

mount=${1:-/Volumes/GARMIN}
timeout=${TIMEOUT:-300}
ts=$(date +%Y-%m-%d_%H%M%S)
out="$HOME/garmin_recon/walkaway_$ts"
baseline="$HOME/garmin_recon/snapshot_2026-04-28.sha256"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)

mkdir -p "$out"
exec > >(tee "$out/run.log") 2>&1

echo "[walkaway] $(date) — waiting up to ${timeout}s for $mount/GARMIN"
elapsed=0
while [[ ! -d "$mount/GARMIN" ]]; do
  sleep 5
  elapsed=$((elapsed + 5))
  if (( elapsed >= timeout )); then
    echo "[walkaway] timeout — no watch detected" >&2
    exit 1
  fi
done
echo "[walkaway] mounted after ${elapsed}s"

# 1. Identity
if [[ -f "$mount/GARMIN/GarminDevice.xml" ]]; then
  cp "$mount/GARMIN/GarminDevice.xml" "$out/GarminDevice.xml"
  pn=$(grep -oE '<PartNumber>[^<]+' "$out/GarminDevice.xml" | head -1 | sed 's|<PartNumber>||')
  ver=$(grep -oE '<SoftwareVersion>[^<]+' "$out/GarminDevice.xml" | head -1 | sed 's|<SoftwareVersion>||')
  uid=$(grep -oE '<Id>[^<]+' "$out/GarminDevice.xml" | head -1 | sed 's|<Id>||')
  echo "[walkaway] device: PN=$pn ver=$ver id=$uid"
else
  pn="?"; ver="?"; uid="?"
  echo "[walkaway] WARN: GarminDevice.xml missing"
fi

# 2. Fresh SHA-256 tree, paths relative to mount root
echo "[walkaway] hashing tree..."
( cd "$mount" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 ) > "$out/snapshot.sha256"
file_count=$(wc -l < "$out/snapshot.sha256" | tr -d ' ')
echo "[walkaway] hashed $file_count files"

# 3. Normalize baseline to mount-relative paths
sed 's|/Users/user/garmin_recon/snapshot_2026-04-28/|./|' "$baseline" | sort -k2 > "$out/baseline.sha256"
sort -k2 "$out/snapshot.sha256" > "$out/snapshot.sorted"

# 4. Diff
diff "$out/baseline.sha256" "$out/snapshot.sorted" > "$out/diff.txt" || true
added=$(grep -c '^> ' "$out/diff.txt" || true)
removed=$(grep -c '^< ' "$out/diff.txt" || true)
echo "[walkaway] diff vs 2026-04-28: $added added/changed, $removed removed/changed"

# 5. Pull DEBUG/ (crash + error logs — high value, often updated)
if [[ -d "$mount/GARMIN/DEBUG" ]]; then
  cp -r "$mount/GARMIN/DEBUG" "$out/DEBUG"
  dbg_count=$(find "$out/DEBUG" -type f | wc -l | tr -d ' ')
  echo "[walkaway] pulled GARMIN/DEBUG ($dbg_count files)"
else
  dbg_count=0
fi

# 6. FIT summary (existing dump.sh — must run from repo root)
echo "[walkaway] running FIT dump..."
( cd "$repo_root" && "$script_dir/dump.sh" "$mount" ) > "$out/fit_summary.txt" 2>&1 || \
  echo "[walkaway] dump.sh exited non-zero (continuing)"

# 7. Report
cat > "$out/REPORT.md" <<EOF
# Walkaway report — $ts

## Device
- PartNumber: $pn
- SoftwareVersion: $ver
- Unit ID: $uid

## Snapshot diff vs 2026-04-28 baseline
- Files on device: $file_count
- Added/changed: $added
- Removed/changed: $removed
- Full diff: \`diff.txt\`

## Crash + error logs
- Files pulled from GARMIN/DEBUG: $dbg_count
- See \`DEBUG/\` directory

## FIT summary
- See \`fit_summary.txt\`

## Files in this report
\`\`\`
$(ls -la "$out")
\`\`\`
EOF
echo "[walkaway] report written: $out/REPORT.md"

# 8. Eject
echo "[walkaway] ejecting..."
if diskutil eject "$mount"; then
  echo "[walkaway] ejected cleanly — safe to unplug"
else
  echo "[walkaway] WARN: eject failed; unmount manually before unplugging" >&2
fi

echo "[walkaway] done. cat $out/REPORT.md"
