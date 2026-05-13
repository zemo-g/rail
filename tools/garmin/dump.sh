#!/usr/bin/env bash
# tools/garmin/dump.sh — Walk a mounted Garmin watch and print a summary
# line per FIT file. Sidesteps a heap-corruption issue when iterating
# many big files in one Rail process by spawning a fresh rail_native run
# per file.
#
# Run from the rail repo root:
#   tools/garmin/dump.sh                       # default mount
#   tools/garmin/dump.sh /Volumes/GARMIN       # explicit mount

set -u
mount=${1:-/Volumes/GARMIN}
base="${mount%/}/GARMIN"

if [[ ! -d "$base" ]]; then
  echo "no Garmin mount at $base — plug the watch in?" >&2
  exit 1
fi

# Compile dump_one once into /tmp, then exec the binary per file.
./rail_native tools/garmin/dump_one.rail >/dev/null
cp /tmp/rail_out /tmp/garmin_dump_one
chmod +x /tmp/garmin_dump_one

for sub in ACTIVITY SUMMARY RECORDS MONITOR SLEEP; do
  dir="$base/$sub"
  [[ -d "$dir" ]] || continue
  files=( "$dir"/*.fit )
  # Glob may not match anything; bash leaves the literal pattern then.
  if [[ ! -e "${files[0]}" ]]; then
    echo "==== $sub (0 files) ===="
    continue
  fi
  echo "==== $sub (${#files[@]} files) ===="
  for f in "${files[@]}"; do
    /tmp/garmin_dump_one "$f"
  done
done
