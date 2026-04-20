#!/bin/bash
# audit_cf_token.sh — report the scope of the CF API token in ~/Desktop/rings.
# Read-only probe.  Doesn't change anything.
#
# Usage:
#   bash tools/deploy/audit_cf_token.sh

set -u

TOKEN_FILE="$HOME/Desktop/rings"
if [ ! -f "$TOKEN_FILE" ]; then
  echo "no token at $TOKEN_FILE"
  exit 1
fi

TOKEN=$(cat "$TOKEN_FILE" | tr -d '[:space:]')
if [ -z "$TOKEN" ]; then
  echo "empty token file"
  exit 1
fi

echo "=== CF token audit ==="
echo "--- verify ---"
curl -sm 10 "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer $TOKEN" | head -c 500
echo; echo

echo "--- this token's details ---"
TOKEN_ID=$(curl -sm 10 "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer $TOKEN" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')

if [ -z "$TOKEN_ID" ]; then
  echo "could not extract token id — check verify response above"
  exit 1
fi

echo "token id: $TOKEN_ID"
echo
curl -sm 10 "https://api.cloudflare.com/client/v4/user/tokens/$TOKEN_ID" \
  -H "Authorization: Bearer $TOKEN" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
if not data.get('success'):
    print('API call failed:', data.get('errors'))
    sys.exit(1)
r = data['result']
print('name:', r.get('name'))
print('status:', r.get('status'))
print('issued:', r.get('issued_on'))
print('not_before:', r.get('not_before'))
print('expires:', r.get('expires_on'))
print()
print('permissions:')
for p in r.get('policies', []):
    effect = p.get('effect', '?')
    res    = p.get('resources', {})
    perms  = p.get('permission_groups', [])
    for pg in perms:
        name = pg.get('name', '?')
        scope_keys = list(res.keys())
        print(f'  {effect:>5}  {name:<40}  scope={scope_keys[:3]}')
print()
broad = False
for p in r.get('policies', []):
    for pg in p.get('permission_groups', []):
        name = pg.get('name', '').lower()
        if any(bad in name for bad in ['edit account', 'all zones', 'zone:edit', 'dns:edit', 'workers:edit all', 'wildcard']):
            broad = True
            print(f'  ⚠️  broad scope: {pg.get(\"name\")}')
if broad:
    print()
    print('Recommendation: rotate to a narrower token.')
    print('Required scopes for deploy flow: KV:Write, Cache:Purge.  Nothing else.')
" 2>&1
