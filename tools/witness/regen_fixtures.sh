#!/usr/bin/env bash
# regen_fixtures.sh — refresh tools/witness/fixtures/*.json against the
# live beacon, so the offline viz.html shows plausible recent values.
#
# These are NOT signed records — the sig field is a placeholder.  The
# fixture exists only to keep viz.html productive while
# /witness/<node>/latest is still 404 (i.e., before the witness Worker
# is deployed).  Once the live endpoint serves, the viewer prefers the
# real signed record automatically.

set -euo pipefail

cd "$(dirname "$0")"

BEACON=https://ledatic.org/entropy/pulse
NODES=(fleet0)

pulse=$(curl -sf --max-time 5 "$BEACON" 2>/dev/null || true)
if [ -z "$pulse" ]; then
  echo "beacon unreachable; keeping existing fixtures untouched" >&2
  exit 0
fi

py='
import json, sys
p = json.loads(sys.stdin.read())
print(json.dumps({
  "pulse_id":      p.get("pulse_id"),
  "value_hex":     p.get("value_hex", ""),
  "prev_hex":      p.get("prev_value_hex", ""),
  "beacon_ts":     p.get("timestamp_utc", ""),
  "beacon_unix":   p.get("unix_timestamp", 0),
  "witnessed_at":  p.get("unix_timestamp", 0) + 1,
  "gap":           1,
  "chain_verified": True,
  "sig":           "fixture-placeholder-not-real-signature-shape-only-0123456789abcdef==",
  "pk_fp":         "cac5f21a70564aeb",
  "witness":       "FIXTURE_NODE",
}, indent=2))'

for node in "${NODES[@]}"; do
  rendered=$(printf '%s' "$pulse" | python3 -c "$py" | sed "s|FIXTURE_NODE|$node|")
  printf '%s\n' "$rendered" > "fixtures/${node}.json"
  echo "wrote fixtures/${node}.json (pulse_id=$(printf '%s' "$pulse" | python3 -c "import json,sys;print(json.load(sys.stdin)['pulse_id'])"))"
done
