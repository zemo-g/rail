#!/usr/bin/env bash
# RUNG 28 admission-time LIVE pulse fetch + pin.
#
# Fetches the current ledatic.org entropy pulse and PINS it to flat files the trainer reads:
#   out/pulse.json     -- the full pulse record (audit trail)
#   out/pulse_id.txt   -- the monotone pulse_id (no trailing newline)
#   out/pulse_hex.txt  -- the 32-byte value_hex (no trailing newline)
#
# The pulse is PUBLIC READ-ONLY INPUT, not a signing surface. The recency provenance is the pin's
# (a real published pulse with a monotone pulse_id and a prev-chained value_hex); reproducibility is
# preserved by freezing it so the trainer + both witnesses consume the SAME pulse.
#
# A pure-Rail HTTPS path exists (stdlib/https_client.rail: https_get); the shell wrapper uses curl
# only as the transport so validate stays light + offline-tolerant. If the live fetch fails, we fall
# back to the recorded pulse (rungs/r28/pulse_fallback.json) and log the substitution loudly --
# recency is then the fallback pulse's, clearly stated, never silently faked.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO" || exit 1
mkdir -p out

PULSE_URL="https://ledatic.org/entropy/pulse"
FALLBACK="$HERE/pulse_fallback.json"

extract() { # $1 = json, $2 = key  -> value (string or number, unquoted)
  printf '%s' "$1" | python3 -c "import json,sys; v=json.load(sys.stdin).get('$2',''); print(v)"
}

json=""
if json=$(curl -fsS --max-time 8 "$PULSE_URL" 2>/dev/null) && [ -n "$json" ]; then
  src="LIVE"
else
  echo "[fetch_pulse] WARNING: live fetch of $PULSE_URL failed/offline." >&2
  echo "[fetch_pulse] FALLING BACK to recorded pulse $FALLBACK (recency = recorded pulse's, logged)." >&2
  if [ ! -f "$FALLBACK" ]; then
    echo "[fetch_pulse] FATAL: no fallback pulse available." >&2
    exit 1
  fi
  json=$(cat "$FALLBACK")
  src="FALLBACK(recorded)"
fi

pid=$(extract "$json" pulse_id)
phex=$(extract "$json" value_hex)

# sanity: pulse_id must be a positive integer, value_hex must be 64 lowercase hex chars
if ! printf '%s' "$pid" | grep -Eq '^[0-9]+$'; then
  echo "[fetch_pulse] FATAL: bad pulse_id '$pid'" >&2; exit 1
fi
if ! printf '%s' "$phex" | grep -Eq '^[0-9a-f]{64}$'; then
  echo "[fetch_pulse] FATAL: bad value_hex '$phex'" >&2; exit 1
fi

printf '%s' "$json" > out/pulse.json
printf '%s' "$pid"  > out/pulse_id.txt    # NO trailing newline (trainer reads exactly this)
printf '%s' "$phex" > out/pulse_hex.txt
echo "[fetch_pulse] pinned $src pulse: id=$pid value_hex=${phex:0:16}... -> out/pulse_{id,hex}.txt"
