#!/usr/bin/env bash
# fleet_status_publisher.sh — physicify fleet health
#
# Once a tick, polls each fleet node's /health, fetches the current
# entropy beacon pulse, bundles, has fleet0 sign the bundle hash with
# the same Ed25519 key used for the beacon witness chain, and PUTs to
# https://ledatic.org/fleet/status.json.
#
# A consumer reading /fleet/status.json gets:
#   {kind, pulse_id, value_hex, asof_unix, nodes: [...], sig, pk_fp}
#
# Verifying:
#   sha256(canonical_json_without_sig) || pulse_id || asof_unix
#   → openssl pkeyutl -verify against fleet0.pub.pem
#
# Stale = sig has old asof_unix and/or old pulse_id.  Tamper between
# writer and CDN = sig fails verify.  Either way, self-evident.
#
# Wired by com.ledatic.fleet_attest LaunchAgent (60s cadence).

set -euo pipefail

FLEET_TOKEN_FILE=${FLEET_TOKEN_FILE:-$HOME/.fleet/token}
BEACON_TOKEN_FILE=${BEACON_TOKEN_FILE:-$HOME/.ledatic/entropy/beacon_token}
WITNESS_HOST_FILE=${WITNESS_HOST_FILE:-$HOME/.ledatic/witness/host}
WITNESS_HOST=${WITNESS_HOST:-$(cat "$WITNESS_HOST_FILE" 2>/dev/null || echo "")}
SIGNER=${SIGNER:-<HOME>/.ledatic/witness/sign_fleet_bundle.sh}
SITE=${SITE:-https://ledatic.org}
BEACON_URL=${BEACON_URL:-https://ledatic.org/entropy/pulse}
NODES_FILE=${NODES_FILE:-$HOME/.ledatic/fleet/nodes}

[ -s "$FLEET_TOKEN_FILE" ] || { echo "missing $FLEET_TOKEN_FILE" >&2; exit 2; }
[ -s "$BEACON_TOKEN_FILE" ] || { echo "missing $BEACON_TOKEN_FILE" >&2; exit 2; }
[ -n "$WITNESS_HOST" ] || { echo "no witness host (set WITNESS_HOST or write $WITNESS_HOST_FILE)" >&2; exit 4; }
[ -s "$NODES_FILE" ] || { echo "missing $NODES_FILE (one 'name:ip' per line)" >&2; exit 4; }
FLEET_TOKEN=$(cat "$FLEET_TOKEN_FILE")
BEACON_TOKEN=$(cat "$BEACON_TOKEN_FILE")

NODES=()
while IFS= read -r line; do
  [ -n "$line" ] && NODES+=("$line")
done < "$NODES_FILE"

raw_pulse=$(curl -sf --max-time 4 "$BEACON_URL" || true)
[ -n "$raw_pulse" ] || { echo "beacon unreachable" >&2; exit 3; }
pulse_id=$(printf '%s' "$raw_pulse" | python3 -c "import sys,json;print(json.load(sys.stdin)['pulse_id'])")
value_hex=$(printf '%s' "$raw_pulse" | python3 -c "import sys,json;print(json.load(sys.stdin)['value_hex'])")
asof_unix=$(date -u +%s)

nodes_json=$(python3 - "$FLEET_TOKEN" "${NODES[@]}" <<'PY'
import json, subprocess, sys
token = sys.argv[1]
nodes = []
for spec in sys.argv[2:]:
    name, host = spec.split(":", 1)
    try:
        out = subprocess.run(
            ["curl", "-s", "--max-time", "3",
             "-H", f"X-Fleet-Token: {token}",
             f"http://{host}:9101/health"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
        if out:
            try:
                d = json.loads(out)
                nodes.append({"name": name, "host": host,
                              "alive": bool(d.get("alive")),
                              "uptime": d.get("uptime")})
                continue
            except Exception:
                pass
    except Exception:
        pass
    nodes.append({"name": name, "host": host, "alive": False, "uptime": None})
print(json.dumps(nodes))
PY
)

# Canonical bundle for signing — keys sorted, no sig field yet.
canonical=$(python3 - "$pulse_id" "$value_hex" "$asof_unix" "$nodes_json" <<'PY'
import json, sys
pulse_id = int(sys.argv[1])
value_hex = sys.argv[2]
asof_unix = int(sys.argv[3])
nodes = json.loads(sys.argv[4])
bundle = {
    "kind": "ledatic.fleet.status",
    "version": 1,
    "pulse_id": pulse_id,
    "value_hex": value_hex,
    "asof_unix": asof_unix,
    "nodes": nodes,
}
print(json.dumps(bundle, sort_keys=True, separators=(",", ":")))
PY
)

digest=$(printf '%s' "$canonical" | shasum -a 256 | awk '{print $1}')

inner=$(ssh -o ConnectTimeout=4 -o BatchMode=yes "$WITNESS_HOST" \
  "<HOME>/.ledatic/witness/sign_attestation.sh $digest $pulse_id $value_hex" 2>/dev/null || true)
if [ -z "$inner" ]; then
  echo "witness signer unreachable; publishing unsigned" >&2
  inner='{"kind":"attestation","version":1,"sig":null,"pk_fp":null,"witness":"none"}'
fi

# Final published bundle = canonical + witness inner.  Consumers reconstruct
# the canonical (drop "witness", sort keys, compact separators) and verify.
published=$(python3 - "$canonical" "$inner" <<'PY'
import json, sys
bundle = json.loads(sys.argv[1])
inner = json.loads(sys.argv[2])
bundle["witness"] = inner
print(json.dumps(bundle, sort_keys=True, separators=(",", ":")))
PY
)

code=$(curl -sS -X PUT \
  -H "x-beacon-token: $BEACON_TOKEN" \
  -H "content-type: application/json" \
  --data-binary "$published" \
  --max-time 15 \
  -o /dev/null -w '%{http_code}' \
  "$SITE/fleet/status.json" || echo "000")

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
up=$(printf '%s' "$nodes_json" | python3 -c "import sys,json;d=json.load(sys.stdin);print(sum(1 for n in d if n['alive']))")
total=$(printf '%s' "$nodes_json" | python3 -c "import sys,json;d=json.load(sys.stdin);print(len(d))")
echo "[$ts] pulse=$pulse_id up=$up/$total publish=$code"
