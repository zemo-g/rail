#!/usr/bin/env bash
# attest.sh — physicify an artifact
#
# Given an input file, produce an attestation.json that binds:
#   sha256(input) ⊗ live entropy beacon pulse_id ⊗ Ed25519 sig from fleet0
#
# Bash escape hatch — the canonical path is tools/attest/attest.rail.
# Both share the same Pi-side HTTP signer (com.ledatic.attest_sign on
# fleet0:9102) since v3.9.0; the Pi-side SSH signer is no longer used
# by either path, but sign_attestation.sh still exists on the Pi and
# the Python HTTP server shells out to it.
#
# The attestation proves:
#   - what the artifact's bytes were (sha256)
#   - that the artifact existed at or before pulse_id N (lower-bound on time)
#   - that the binding was witnessed by fleet0 (Ed25519 sig)
#
# Anyone with fleet0's public key + the attestation + the input file can
# verify the whole claim later.  Build steps, releases, briefs, deploys —
# any artifact that wants a physical anchor flows through this primitive.
#
# Usage: attest.sh <input_path> [output_path]
#   default output_path = <input_path>.attestation.json
#
# Env overrides: BEACON_URL, SIGNER_URL, SIGN_TOKEN_PATH

set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 <input_path> [output_path]" >&2; exit 2; }

input=$1
out=${2:-${input}.attestation.json}

[ -f "$input" ] || { echo "no such file: $input" >&2; exit 3; }

BEACON_URL=${BEACON_URL:-https://ledatic.org/entropy/pulse}
SIGNER_URL=${SIGNER_URL:-http://100.87.231.45:9102/sign}
SIGN_TOKEN_PATH=${SIGN_TOKEN_PATH:-$HOME/.ledatic/witness/sign_token}

[ -r "$SIGN_TOKEN_PATH" ] || { echo "missing sign token: $SIGN_TOKEN_PATH" >&2; exit 7; }
sign_token=$(tr -d '\r\n' < "$SIGN_TOKEN_PATH")

digest=$(shasum -a 256 "$input" | awk '{print $1}')
size=$(stat -f%z "$input" 2>/dev/null || stat -c%s "$input")

raw=$(curl -sf --max-time 5 "$BEACON_URL")
[ -n "$raw" ] || { echo "beacon unreachable: $BEACON_URL" >&2; exit 4; }

pulse_id=$(printf '%s' "$raw" | python3 -c "import sys,json;print(json.load(sys.stdin)['pulse_id'])")
value_hex=$(printf '%s' "$raw" | python3 -c "import sys,json;print(json.load(sys.stdin)['value_hex'])")
beacon_ts=$(printf '%s' "$raw" | python3 -c "import sys,json;print(json.load(sys.stdin)['timestamp_utc'])")

inner=$(curl -sf --max-time 10 -H "X-Sign-Token: $sign_token" -H "Content-Type: application/json" \
  -d "{\"digest\":\"$digest\",\"pulse_id\":$pulse_id,\"value_hex\":\"$value_hex\"}" "$SIGNER_URL")
[ -n "$inner" ] || { echo "witness signer returned nothing" >&2; exit 5; }

artifact_name=$(basename "$input")
created_at=$(date -u +%s)

python3 - "$inner" "$artifact_name" "$size" "$beacon_ts" "$created_at" "$BEACON_URL" > "$out" <<'PY'
import json, sys
inner = json.loads(sys.argv[1])
out = {
  "kind": "ledatic.attestation",
  "version": 1,
  "artifact": {
    "name": sys.argv[2],
    "size_bytes": int(sys.argv[3]),
    "sha256": inner["digest_sha256"],
  },
  "beacon": {
    "url": sys.argv[6],
    "pulse_id": inner["pulse_id"],
    "value_hex": inner["value_hex"],
    "timestamp_utc": sys.argv[4],
  },
  "witness": inner,
  "created_at": int(sys.argv[5]),
}
print(json.dumps(out, indent=2))
PY

echo "attestation: $out  pulse_id=$pulse_id  pk_fp=$(python3 -c "import json;print(json.load(open('$out'))['witness']['pk_fp'])")"
