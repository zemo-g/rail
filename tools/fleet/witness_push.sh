#!/usr/bin/env bash
# witness_push.sh — publishes ~/.ledatic/witness/latest.json to
# https://ledatic.org/witness/<node>/latest via an authenticated PUT.
#
# Runs as its own systemd service alongside witness.sh so upload failures
# (network blip, CF rate limit, token rotation) can't stall the signing
# loop. If there's nothing new since the last push, we skip — cheap no-op.

set -euo pipefail

WITNESS_DIR=${WITNESS_DIR:-$HOME/.ledatic/witness}
LATEST=${LATEST:-$WITNESS_DIR/latest.json}
TOKEN_FILE=${TOKEN_FILE:-$WITNESS_DIR/upload_token}
LAST_MARK=${LAST_MARK:-$WITNESS_DIR/pushed_pulse_id}
NODE=${NODE:-$(hostname)}
PUSH_URL=${PUSH_URL:-https://ledatic.org/witness/${NODE}/latest}
POLL_SEC=${POLL_SEC:-5}

if [ ! -s "$TOKEN_FILE" ]; then
  echo "witness_push: $TOKEN_FILE missing or empty — need beacon token" >&2
  exit 1
fi

TOKEN=$(cat "$TOKEN_FILE")
last_pushed=""
[ -s "$LAST_MARK" ] && last_pushed=$(cat "$LAST_MARK")

echo "witness_push: node=$NODE url=$PUSH_URL poll=${POLL_SEC}s"

while :; do
  if [ ! -s "$LATEST" ]; then
    sleep "$POLL_SEC"
    continue
  fi

  # Extract pulse_id — skip if unchanged. Cheap string grep; avoids spawning
  # python on every tick.
  pulse_id=$(grep -o '"pulse_id":[0-9]*' "$LATEST" | head -1 | cut -d: -f2 || true)
  if [ -z "$pulse_id" ] || [ "$pulse_id" = "$last_pushed" ]; then
    sleep "$POLL_SEC"
    continue
  fi

  http_code=$(curl -sS -X PUT \
    -H "x-beacon-token: $TOKEN" \
    -H "content-type: application/json" \
    --data-binary "@$LATEST" \
    -o /dev/null -w '%{http_code}' \
    --max-time 10 "$PUSH_URL" || echo "000")

  if [ "$http_code" = "200" ]; then
    printf '%s' "$pulse_id" > "$LAST_MARK"
    last_pushed=$pulse_id
  else
    echo "witness_push: PUT $PUSH_URL → $http_code (pulse $pulse_id)" >&2
  fi

  sleep "$POLL_SEC"
done
