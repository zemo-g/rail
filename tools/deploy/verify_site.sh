#!/bin/bash
# verify_site.sh — Post-deploy sanity check for ledatic.org
#
# Curls every public URL and asserts:
#   - HTTP status
#   - Content-Type
#   - Presence of marker strings
#   - Security header sanity
#
# Usage: ./tools/deploy/verify_site.sh
# Exit non-zero if any check fails.

set -u
PASS=0
FAIL=0
CB="?cb=$(date +%s%N)"
BASE="https://ledatic.org"

assert() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf "  \033[32mok\033[0m   %s\n" "$name"
  else
    FAIL=$((FAIL + 1))
    printf "  \033[31mFAIL\033[0m %s\n        expected: %s\n        actual:   %s\n" "$name" "$expected" "$actual"
  fi
}

assert_contains() {
  local name="$1"
  local needle="$2"
  local haystack="$3"
  if echo "$haystack" | grep -q -- "$needle"; then
    PASS=$((PASS + 1))
    printf "  \033[32mok\033[0m   %s\n" "$name"
  else
    FAIL=$((FAIL + 1))
    printf "  \033[31mFAIL\033[0m %s\n        missing: %s\n" "$name" "$needle"
  fi
}

check_url() {
  local url="$1"
  local want_status="$2"
  local want_ct="$3"
  echo
  echo "▶ $url"
  local headers
  headers=$(curl -sI "${BASE}${url}${CB}")
  local status
  status=$(echo "$headers" | head -1 | awk '{print $2}')
  local ct
  ct=$(echo "$headers" | grep -i "^content-type:" | head -1 | sed 's/^[^:]*: *//' | tr -d '\r')
  assert "status" "$want_status" "$status"
  assert "content-type" "$want_ct" "$ct"
}

echo "═══ verify_site.sh ═══"

check_url "/" "200" "text/html;charset=UTF-8"
check_url "/main.css" "200" "text/css;charset=UTF-8"
check_url "/main.js" "200" "application/javascript;charset=UTF-8"
check_url "/system" "200" "text/html;charset=UTF-8"
check_url "/system.css" "200" "text/css;charset=UTF-8"
check_url "/system.js" "200" "application/javascript;charset=UTF-8"
check_url "/vt323.woff2" "200" "font/woff2"
check_url "/llms.txt" "200" "text/plain;charset=UTF-8"
check_url "/robots.txt" "200" "text/plain;charset=UTF-8"
check_url "/sitemap.xml" "200" "application/xml;charset=UTF-8"
check_url "/.well-known/security.txt" "200" "text/plain;charset=UTF-8"
check_url "/favicon.ico" "404" "text/plain;charset=UTF-8"

# Redirect checks
echo
echo "▶ HTTP→HTTPS redirect"
RED=$(curl -sI "http://ledatic.org/" | head -1 | awk '{print $2}')
assert "status" "301" "$RED"

echo
echo "▶ www→apex redirect"
RED=$(curl -sI "https://www.ledatic.org/" | head -1 | awk '{print $2}')
assert "status" "301" "$RED"

# Marker string checks (presence in fetched content)
echo
echo "▶ homepage content markers"
HP=$(curl -s "${BASE}/${CB}")
assert_contains "JSON-LD" "application/ld+json" "$HP"
assert_contains "Hire LEDATIC" "Hire LEDATIC" "$HP"
assert_contains "main.css link" "/main.css" "$HP"
assert_contains "main.js script" "/main.js" "$HP"
assert_contains "skip-link" "skip-link" "$HP"
assert_contains "twitter card" "twitter:card" "$HP"
assert_contains "no inline style attrs" "data-s=" "$HP"

echo
echo "▶ /system content markers"
SP=$(curl -s "${BASE}/system${CB}")
assert_contains "system.css link" "/system.css" "$SP"
assert_contains "system.js script" "/system.js" "$SP"
assert_contains "skip-link" "skip-link" "$SP"
assert_contains "VT323 self-hosted" "/vt323.woff2" "$SP"

# Security headers (homepage)
echo
echo "▶ homepage security headers"
HDRS=$(curl -sI "${BASE}/${CB}")
assert_contains "HSTS preload" "strict-transport-security:.*preload" "$HDRS"
assert_contains "X-Frame DENY" "x-frame-options: DENY" "$HDRS"
assert_contains "X-Content-Type nosniff" "x-content-type-options: nosniff" "$HDRS"
assert_contains "Referrer-Policy strict" "referrer-policy: strict-origin" "$HDRS"
assert_contains "Permissions-Policy" "permissions-policy:" "$HDRS"
assert_contains "CSP no inline script" "script-src 'self' 'wasm-unsafe-eval'" "$HDRS"
assert_contains "CSP no inline style" "style-src 'self';" "$HDRS"

# Negative checks (must NOT appear)
echo
echo "▶ negative checks"
if echo "$HP" | grep -q "fonts.googleapis.com"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL homepage references fonts.googleapis.com (should be self-hosted)"
else
  PASS=$((PASS + 1))
  echo "  ok   homepage has no Google Fonts references"
fi

if echo "$HP" | grep -qE 'onclick='; then
  FAIL=$((FAIL + 1))
  echo "  FAIL homepage has inline onclick handler"
else
  PASS=$((PASS + 1))
  echo "  ok   homepage has no inline onclick"
fi

# Summary
echo
echo "═══ result ═══"
TOTAL=$((PASS + FAIL))
printf "  %d/%d passed\n" "$PASS" "$TOTAL"
if [ "$FAIL" -gt 0 ]; then
  printf "  \033[31m%d FAILURES\033[0m\n" "$FAIL"
  exit 1
fi
echo "  ✓ all checks passed"
exit 0
