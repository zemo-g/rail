#!/usr/bin/env bash
# frame_attest_ot256_publisher.sh — publish + attest the 256² OT MHD frame
#
# Counterpart to frame_attest_publisher.sh (Mini, 128²) — runs on Studio,
# reads /tmp/plasma_ot256.bin produced by com.ledatic.mhd_ot256, and:
#
#   1. PUTs the raw frame bytes to https://ledatic.org/entropy/frame/ot256/current
#   2. SSHes to fleet0 (Pi witness) to sign sha256(frame) ⊗ pulse_id ⊗ value_hex
#   3. PUTs the signed attestation JSON to /entropy/frame/ot256/latest.attestation.json
#
# Cadence: 30 s via com.ledatic.frame_attest_ot256 LaunchAgent.

set -euo pipefail

FRAME_PATH=${FRAME_PATH:-/tmp/plasma_ot256.bin}
BEACON_URL=${BEACON_URL:-https://ledatic.org/entropy/pulse}
BEACON_TOKEN_FILE=${BEACON_TOKEN_FILE:-$HOME/.ledatic/entropy/beacon_token}
WITNESS_HOST=${WITNESS_HOST:-zemog@100.87.231.45}
SIGNER=${SIGNER:-/home/zemog/.ledatic/witness/sign_attestation.sh}
SITE=${SITE:-https://ledatic.org}
KIND=${KIND:-ot256}

[ -f "$FRAME_PATH" ]            || { echo "no frame at $FRAME_PATH" >&2; exit 2; }
[ -s "$BEACON_TOKEN_FILE" ]     || { echo "no beacon token" >&2; exit 2; }
TOKEN=$(cat "$BEACON_TOKEN_FILE")

raw=$(curl -sf --max-time 4 "$BEACON_URL") || { echo "beacon unreachable" >&2; exit 3; }
pulse_id=$(printf '%s' "$raw" | python3 -c "import sys,json;print(json.load(sys.stdin)['pulse_id'])")
value_hex=$(printf '%s' "$raw" | python3 -c "import sys,json;print(json.load(sys.stdin)['value_hex'])")

# Snapshot — frame_id is overwritten ~3 ms; copy first so hash + bytes match.
tmp=$(mktemp -t frame_ot256.XXXXXX)
trap 'rm -f "$tmp"' EXIT
cp "$FRAME_PATH" "$tmp"
size=$(stat -f%z "$tmp" 2>/dev/null || stat -c%s "$tmp")
digest=$(shasum -a 256 "$tmp" | awk '{print $1}')

header=$(python3 - "$tmp" <<'PY'
import json, struct, sys
with open(sys.argv[1], "rb") as f:
    blob = f.read(48)
W, H, C, fid = struct.unpack("<IIII", blob[:16])
metrics = struct.unpack("<8f", blob[16:48])
print(json.dumps({
    "width": W, "height": H, "channels": C, "frame_id": fid,
    "mass": metrics[0], "energy": metrics[1], "divB_max": metrics[2],
    "rho_min": metrics[3], "dt": metrics[4], "sim_time": metrics[5],
    "m0": metrics[6], "e0": metrics[7],
}))
PY
)

# 1. PUT the raw frame bytes (octet-stream) so /entropy/frame/ot256/current
#    is downloadable as the actual published artifact.  Worker route holds
#    in R2 until the next 30-second tick replaces it.
frame_code=$(curl -sS -X PUT \
    -H "x-beacon-token: $TOKEN" \
    -H "content-type: application/octet-stream" \
    --data-binary "@$tmp" \
    --max-time 30 \
    -o /dev/null -w '%{http_code}' \
    "$SITE/entropy/frame/$KIND/current" || echo "000")

# 2. Sign via fleet0 witness (Pi).  Returns the inner attestation JSON.
inner=$(ssh -o ConnectTimeout=4 -o BatchMode=yes "$WITNESS_HOST" \
    "$SIGNER $digest $pulse_id $value_hex" 2>/dev/null || true)
if [ -z "$inner" ]; then
    echo "[$(date -u +%H:%M:%SZ)] frame_code=$frame_code witness=UNREACHABLE" >&2
    exit 0
fi

# 3. Compose final attestation + PUT.
published=$(python3 - "$digest" "$size" "$pulse_id" "$value_hex" "$header" "$inner" <<'PY'
import json, sys
digest, size, pulse_id, value_hex, header_json, inner_json = sys.argv[1:]
out = {
    "kind": "ledatic.frame.attestation",
    "version": 1,
    "frame": {
        "url": f"https://ledatic.org/entropy/frame/ot256/current",
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

att_code=$(curl -sS -X PUT \
    -H "x-beacon-token: $TOKEN" \
    -H "content-type: application/json" \
    --data-binary "$published" \
    --max-time 15 \
    -o /dev/null -w '%{http_code}' \
    "$SITE/entropy/frame/$KIND/latest.attestation.json" || echo "000")

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fid=$(printf '%s' "$header" | python3 -c "import json,sys;print(json.load(sys.stdin)['frame_id'])")
echo "[$ts] frame_id=$fid pulse=$pulse_id sha=${digest:0:16} frame_put=$frame_code att_put=$att_code"
