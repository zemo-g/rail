#!/usr/bin/env bash
# frame_attest_publisher.sh — physicify the plasma frame stream
#
# Every tick (~30 s), reads /tmp/plasma_live.bin, hashes it, asks
# fleet0 to sign sha256(frame_bytes) ⊗ pulse_id ⊗ value_hex, and PUTs
# the attestation to https://ledatic.org/entropy/frame/latest.attestation.json.
#
# Why side-car instead of in-band: the frame endpoint is hit hard (3 Hz
# from the live viewport) and adding a sig to every frame would balloon
# the response.  Side-car: clients who care fetch both files and
# verify; clients who don't get the same fast bytes as today.
#
# Usage:
#   - one-shot: ./frame_attest_publisher.sh
#   - daemon:   under com.ledatic.frame_attest LaunchAgent (StartInterval=30)

set -euo pipefail

FRAME_PATH=${FRAME_PATH:-/tmp/plasma_live.bin}
BEACON_URL=${BEACON_URL:-https://ledatic.org/entropy/pulse}
BEACON_TOKEN_FILE=${BEACON_TOKEN_FILE:-$HOME/.ledatic/entropy/beacon_token}
WITNESS_HOST_FILE=${WITNESS_HOST_FILE:-$HOME/.ledatic/witness/host}
WITNESS_HOST=${WITNESS_HOST:-$(cat "$WITNESS_HOST_FILE" 2>/dev/null || echo "")}
[ -n "$WITNESS_HOST" ] || { echo "no witness host (set WITNESS_HOST or write $WITNESS_HOST_FILE)" >&2; exit 4; }
SIGNER=${SIGNER:-<HOME>/.ledatic/witness/sign_attestation.sh}
SITE=${SITE:-https://ledatic.org}

[ -f "$FRAME_PATH" ] || { echo "no frame at $FRAME_PATH" >&2; exit 2; }
[ -s "$BEACON_TOKEN_FILE" ] || { echo "no beacon token" >&2; exit 2; }
TOKEN=$(cat "$BEACON_TOKEN_FILE")

raw=$(curl -sf --max-time 4 "$BEACON_URL") || { echo "beacon unreachable" >&2; exit 3; }
pulse_id=$(printf '%s' "$raw" | python3 -c "import sys,json;print(json.load(sys.stdin)['pulse_id'])")
value_hex=$(printf '%s' "$raw" | python3 -c "import sys,json;print(json.load(sys.stdin)['value_hex'])")

# Snapshot the frame to a temp so the bytes don't shift mid-hash mid-sign.
tmp=$(mktemp -t frame_attest.XXXXXX)
trap 'rm -f "$tmp"' EXIT
cp "$FRAME_PATH" "$tmp"
size=$(stat -f%z "$tmp" 2>/dev/null || stat -c%s "$tmp")
digest=$(shasum -a 256 "$tmp" | awk '{print $1}')

# Pull the 16-byte header so consumers know the shape.
header=$(python3 - "$tmp" <<'PY'
import struct, sys
with open(sys.argv[1], "rb") as f:
    blob = f.read(16)
w, h, c, fid = struct.unpack("<IIII", blob)
import json
print(json.dumps({"width": w, "height": h, "channels": c, "frame_id": fid}))
PY
)

inner=$(ssh -o ConnectTimeout=4 -o BatchMode=yes "$WITNESS_HOST" \
  "$SIGNER $digest $pulse_id $value_hex" 2>/dev/null || true)
if [ -z "$inner" ]; then
  echo "witness unreachable; skipping this tick" >&2
  exit 0
fi

published=$(python3 - "$digest" "$size" "$pulse_id" "$value_hex" "$header" "$inner" <<'PY'
import json, sys
digest, size, pulse_id, value_hex, header_json, inner_json = sys.argv[1:]
out = {
    "kind": "ledatic.frame.attestation",
    "version": 1,
    "frame": {
        "url": "https://ledatic.org/entropy/frame/current",
        "size_bytes": int(size),
        "sha256": digest,
        "header": json.loads(header_json),
    },
    "beacon": {"pulse_id": int(pulse_id), "value_hex": value_hex},
    "witness": json.loads(inner_json),
}
print(json.dumps(out))
PY
)

code=$(curl -sS -X PUT \
  -H "x-beacon-token: $TOKEN" \
  -H "content-type: application/json" \
  --data-binary "$published" \
  --max-time 15 \
  -o /dev/null -w '%{http_code}' \
  "$SITE/entropy/frame/latest.attestation.json" || echo "000")

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fid=$(printf '%s' "$header" | python3 -c "import json,sys;print(json.load(sys.stdin)['frame_id'])")
echo "[$ts] frame_id=$fid pulse=$pulse_id sha=${digest:0:16} publish=$code"
