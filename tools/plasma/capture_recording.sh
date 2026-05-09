#!/usr/bin/env bash
# capture_recording.sh — record a stretch of the live entropy beacon
# into tools/plasma/recordings/<seed>/ for /plasma/tv replay.
#
# Each tick fetches /entropy/frame/current and /entropy/pulse, captures
# them as numbered binary blobs, and emits a manifest.json with the
# frame count and timing.  The viewer's TV mode (holo.html?seed=<seed>)
# loops over the frames at the original beacon cadence.
#
# Usage:
#   tools/plasma/capture_recording.sh <seed> [n_frames=30] [interval_s=2]
#
# `seed` is any [a-z0-9-]+ string and becomes the URL slug.  Existing
# recordings with the same seed are NOT overwritten — pick a fresh one.

set -euo pipefail

SEED=${1:?missing seed (e.g. 'ot-stable' or '2026-05-02-evening')}
N=${2:-30}
INTERVAL=${3:-2}

cd "$(dirname "$0")"
RDIR="recordings/$SEED"

if [ -d "$RDIR" ]; then
  echo "ERROR: $RDIR already exists. Pick a fresh seed or remove it first." >&2
  exit 2
fi
case "$SEED" in
  [a-z0-9_-]*) ;;
  *) echo "ERROR: seed must be [a-z0-9_-]+" >&2; exit 2 ;;
esac

mkdir -p "$RDIR"
echo "▶ recording $N frames at ${INTERVAL}s into $RDIR/"

FRAME_URL=https://ledatic.org/entropy/frame/current
PULSE_URL=https://ledatic.org/entropy/pulse

start_unix=$(date -u +%s)
last_pulse=""
i=0
while [ "$i" -lt "$N" ]; do
  ts=$(date -u +%s)
  pulse_json=$(curl -sf --max-time 5 "$PULSE_URL?t=$ts" 2>/dev/null || true)
  if [ -z "$pulse_json" ]; then
    echo "  tick $i: pulse fetch failed; retrying" >&2
    sleep "$INTERVAL"
    continue
  fi
  pulse_id=$(printf '%s' "$pulse_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('pulse_id', ''))")
  if [ -z "$pulse_id" ] || [ "$pulse_id" = "$last_pulse" ]; then
    sleep 1
    continue
  fi
  curl -sf --max-time 5 "$FRAME_URL?t=$ts" -o "$RDIR/frame_$(printf '%03d' "$i").bin" || {
    echo "  tick $i: frame fetch failed; retrying" >&2
    sleep "$INTERVAL"
    continue
  }
  printf '%s\n' "$pulse_json" > "$RDIR/pulse_$(printf '%03d' "$i").json"
  echo "  tick $i: pulse_id=$pulse_id  frame=$(stat -f%z "$RDIR/frame_$(printf '%03d' "$i").bin") bytes"
  last_pulse=$pulse_id
  i=$((i + 1))
  sleep "$INTERVAL"
done

end_unix=$(date -u +%s)
python3 - <<PY > "$RDIR/manifest.json"
import json, time, os
seed = "$SEED"
n = $N
interval = $INTERVAL
start = $start_unix
end = $end_unix
print(json.dumps({
  "seed":     seed,
  "n_frames": n,
  "interval_s": interval,
  "captured_unix_start": start,
  "captured_unix_end":   end,
  "frame_pattern": "frame_%03d.bin",
  "pulse_pattern": "pulse_%03d.json",
}, indent=2))
PY

echo "▶ wrote $RDIR/manifest.json"
echo "  serve via:  python3 -m http.server  (from rail/tools/plasma/)"
echo "  view as:    http://localhost:PORT/holo.html?seed=$SEED"
