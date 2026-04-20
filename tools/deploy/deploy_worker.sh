#!/bin/bash
# deploy_worker.sh — push tools/deploy/worker.js to Cloudflare as the `ledatic`
# Worker. Preserves bindings (LEDATIC_KV + REPORTS_R2) exactly as configured.
#
# Usage: ./tools/deploy/deploy_worker.sh
# Env:   CF_TOKEN read from ~/Desktop/rings (must have Account:Workers:Edit)

set -e
cd "$(dirname "$0")/../.."

TOKEN=$(cat ~/Desktop/rings)
ACC=2acd6ceb3a0c57f1f2b470433d94bc87
SCRIPT=ledatic
SRC=tools/deploy/worker.js
META=/tmp/ledatic_worker_meta.json
BACKUP_DIR=$HOME/ledatic-site/worker_backups
TS=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

echo "> Backing up current Worker to $BACKUP_DIR/ledatic_worker_$TS.txt"
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$ACC/workers/scripts/$SCRIPT" \
  > "$BACKUP_DIR/ledatic_worker_$TS.txt"

echo "> Writing metadata"
BEACON_TOKEN_VAL=$(cat ~/.ledatic/entropy/beacon_token)
cat > "$META" <<JSON
{
  "main_module": "worker.js",
  "compatibility_date": "2024-01-01",
  "bindings": [
    {"type":"kv_namespace","name":"LEDATIC_KV","namespace_id":"be34022eeedc4d6fb802087156eb1aae"},
    {"type":"r2_bucket","name":"REPORTS_R2","bucket_name":"ledatic-reports"},
    {"type":"secret_text","name":"BEACON_TOKEN","text":"$BEACON_TOKEN_VAL"}
  ]
}
JSON

echo "> Uploading $SRC"
RESP=$(curl -s -X PUT -H "Authorization: Bearer $TOKEN" \
  -F "metadata=@$META;type=application/json" \
  -F "worker.js=@$SRC;filename=worker.js;type=application/javascript+module" \
  "https://api.cloudflare.com/client/v4/accounts/$ACC/workers/scripts/$SCRIPT")

echo "$RESP" | python3 -m json.tool
echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('success') else 1)"
