#!/bin/bash
# cf_deploy.sh — refresh OAuth + upload to KV
# Called by deploy_site.rail
# Usage: ./cf_deploy.sh /path/to/file.html

FILE="$1"
CONFIG="$HOME/.wrangler/config/default.toml"
ACCOUNT="2acd6ceb3a0c57f1f2b470433d94bc87"
KV_NS="be34022eeedc4d6fb802087156eb1aae"

# Read current refresh token
REFRESH=$(grep refresh_token "$CONFIG" | cut -d'"' -f2)

# Refresh OAuth
RESPONSE=$(curl -s -X POST "https://dash.cloudflare.com/oauth2/token" \
  -d "grant_type=refresh_token&refresh_token=$REFRESH&client_id=54d11594-84e4-41aa-b438-e81b8fa78ee7")

TOKEN=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['access_token'])" 2>/dev/null)
NEW_REFRESH=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['refresh_token'])" 2>/dev/null)

if [ -z "$TOKEN" ]; then
  echo "REFRESH_FAILED"
  exit 1
fi

# Save new tokens
cat > "$CONFIG" << EOF
oauth_token = "$TOKEN"
expiration_time = "2099-01-01T00:00:00.000Z"
refresh_token = "$NEW_REFRESH"
scopes = [ "account:read", "user:read", "workers:write", "workers_kv:write", "offline_access" ]
EOF

# Upload to KV
RESULT=$(curl -s -X PUT \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: text/plain" \
  --data-binary "@$FILE" \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/storage/kv/namespaces/$KV_NS/values/index.html")

if echo "$RESULT" | grep -q '"success":true'; then
  echo "OK"
else
  echo "UPLOAD_FAILED"
fi
