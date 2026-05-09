#!/usr/bin/env bash
# report_attestation_publisher.sh — sign + publish a Ledatic AI report manifest.
#
# Adapted from frame_attest_ot256_publisher.sh (same SSH-to-fleet0 pattern).
# Produces a Provenance Tier manifest binding (model identity, prompt hash,
# response hash, timestamp) to an Ed25519 signature from fleet0, chained to
# the public entropy beacon.
#
# Usage:
#   report_attestation_publisher.sh <report_id> <model_name> <weights_hash> \
#                                   <prompt_file> <response_file> <generated_at> [client_id]
#
# Output:
#   stdout: full manifest JSON (suitable for redirection to a file)
#   stderr: one-line status
#
# Exit codes: 0 = success, 2 = bad input, 3 = beacon unreachable,
#             4 = witness unreachable, 5 = PUT failed.

set -euo pipefail

if [ "$#" -lt 6 ]; then
    echo "usage: $0 <report_id> <model_name> <weights_hash> <prompt_file> <response_file> <generated_at> [client_id]" >&2
    exit 2
fi

REPORT_ID=$1
MODEL_NAME=$2
WEIGHTS_HASH=$3
PROMPT_FILE=$4
RESPONSE_FILE=$5
GENERATED_AT=$6
CLIENT_ID=${7:-demo}

BEACON_URL=${BEACON_URL:-https://ledatic.org/entropy/pulse}
BEACON_TOKEN_FILE=${BEACON_TOKEN_FILE:-$HOME/.ledatic/entropy/beacon_token}
WITNESS_HOST=${WITNESS_HOST:-zemog@100.87.231.45}
SIGNER=${SIGNER:-/home/zemog/.ledatic/witness/sign_attestation.sh}
SITE=${SITE:-https://ledatic.org}

[ -f "$PROMPT_FILE" ]      || { echo "no prompt file at $PROMPT_FILE" >&2; exit 2; }
[ -f "$RESPONSE_FILE" ]    || { echo "no response file at $RESPONSE_FILE" >&2; exit 2; }
[ -s "$BEACON_TOKEN_FILE" ] || { echo "no beacon token at $BEACON_TOKEN_FILE" >&2; exit 2; }
TOKEN=$(cat "$BEACON_TOKEN_FILE")

# 1. Pull current beacon pulse — what the witness will chain against.
raw=$(curl -sf --max-time 4 "$BEACON_URL") || { echo "beacon unreachable" >&2; exit 3; }
pulse_id=$(printf '%s' "$raw" | python3 -c "import sys,json;print(json.load(sys.stdin)['pulse_id'])")
value_hex=$(printf '%s' "$raw" | python3 -c "import sys,json;print(json.load(sys.stdin)['value_hex'])")

# 2. Hash prompt + response (the thing the client gave + what the model produced).
prompt_hash=$(shasum -a 256 "$PROMPT_FILE" | awk '{print $1}')
response_hash=$(shasum -a 256 "$RESPONSE_FILE" | awk '{print $1}')
prompt_size=$(stat -f%z "$PROMPT_FILE" 2>/dev/null || stat -c%s "$PROMPT_FILE")
response_size=$(stat -f%z "$RESPONSE_FILE" 2>/dev/null || stat -c%s "$RESPONSE_FILE")

# 3. Build the canonical inner message (what gets digested + signed).
#    Format must be reproducible byte-for-byte by anything that wants to
#    re-derive the digest from the manifest's individual fields.
inner_msg="report|v1|${REPORT_ID}|${MODEL_NAME}|${WEIGHTS_HASH}|${prompt_hash}|${response_hash}|${GENERATED_AT}|${CLIENT_ID}"
digest=$(printf '%s' "$inner_msg" | shasum -a 256 | awk '{print $1}')

# 4. Sign via fleet0 — Pi signs `attest|v1|<digest>|<pulse_id>|<value_hex>|<witnessed_at>`
witness_json=$(ssh -o ConnectTimeout=4 -o BatchMode=yes "$WITNESS_HOST" \
    "$SIGNER $digest $pulse_id $value_hex" 2>/dev/null || true)
if [ -z "$witness_json" ]; then
    echo "witness unreachable / signer failed" >&2
    exit 4
fi

# 5. Compose final manifest JSON.
manifest=$(python3 - "$REPORT_ID" "$MODEL_NAME" "$WEIGHTS_HASH" "$prompt_hash" "$response_hash" \
    "$prompt_size" "$response_size" "$GENERATED_AT" "$CLIENT_ID" "$pulse_id" "$value_hex" \
    "$inner_msg" "$digest" "$witness_json" <<'PY'
import json, sys
(report_id, model_name, weights_hash, prompt_hash, response_hash,
 prompt_size, response_size, generated_at, client_id,
 pulse_id, value_hex, inner_msg, digest, witness_json) = sys.argv[1:]
witness = json.loads(witness_json)
out = {
    "kind": "ledatic.report.provenance",
    "version": 1,
    "report_id": report_id,
    "client_id": client_id,
    "generated_at": generated_at,
    "generation_event": {
        "model": {
            "name": model_name,
            "weights_hash": weights_hash,
        },
        "input": {
            "prompt_sha256": prompt_hash,
            "prompt_size_bytes": int(prompt_size),
        },
        "output": {
            "response_sha256": response_hash,
            "response_size_bytes": int(response_size),
        },
    },
    "attest": {
        "inner_message": inner_msg,
        "inner_digest_sha256": digest,
    },
    "beacon": {
        "pulse_id": int(pulse_id),
        "value_hex": value_hex,
    },
    "witness": witness,
    "links": {
        "verify": f"https://ledatic.org/verify/{report_id}",
        "manifest": f"https://ledatic.org/provenance/manifest/{report_id}",
        "beacon": "https://ledatic.org/entropy/pulse",
        "witness_node": "https://ledatic.org/witness/fleet0/latest",
        "provenance_info": "https://ledatic.org/provenance",
    },
}
print(json.dumps(out, indent=2))
PY
)

# 6. PUT manifest to ledatic.org KV via Worker (x-beacon-token auth, same as
#    /entropy/pulse PUT pattern). Worker stores under KV key `provenance:<id>`.
http_code=$(printf '%s' "$manifest" | curl -sS -X PUT \
    -H "x-beacon-token: $TOKEN" \
    -H "content-type: application/json" \
    --data-binary @- \
    --max-time 15 \
    -o /tmp/manifest_put_response \
    -w '%{http_code}' \
    "$SITE/provenance/manifest/$REPORT_ID" || echo "000")

# 7. Emit manifest on stdout, status on stderr.
printf '%s\n' "$manifest"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "[$ts] report_id=$REPORT_ID pulse=$pulse_id digest=${digest:0:16} put=$http_code" >&2

[ "$http_code" = "200" ] || { echo "PUT failed ($http_code)" >&2; cat /tmp/manifest_put_response >&2; exit 5; }
