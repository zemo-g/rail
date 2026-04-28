#!/usr/bin/env bash
# daily.sh — physicify the production state every morning
#
# Re-attests the current rail_native (test pass + self-host fixed point)
# against the live entropy beacon, publishes to /builds/latest and
# /selfhost/latest.  A stale or drifted production binary becomes
# self-evident the next morning the cron runs.
#
# Logs to ~/.ledatic/attest/daily.log + .err.  Idempotent — safe to
# re-run; each run produces a fresh attestation bound to a new pulse.
#
# Wiring: ~/Library/LaunchAgents/com.ledatic.attest_daily.plist runs
# this at 06:00 local each day.

set -euo pipefail

cd /Users/ledaticempire/projects/rail-https
mkdir -p ~/.ledatic/attest

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "[$ts] daily attest run starting" >> ~/.ledatic/attest/daily.log

run() {
  local label=$1; shift
  echo "[$(date -u +%H:%M:%SZ)] $label ..." >> ~/.ledatic/attest/daily.log
  if "$@" >> ~/.ledatic/attest/daily.log 2>&1; then
    echo "[$(date -u +%H:%M:%SZ)] $label ok" >> ~/.ledatic/attest/daily.log
  else
    echo "[$(date -u +%H:%M:%SZ)] $label FAIL" >> ~/.ledatic/attest/daily.log
    return 1
  fi
}

# Generate fresh attestations.  attest_test_run + attest_selfhost both
# write under builds/<short>/ + selfhost/<short>/, keyed by HEAD's
# short SHA.  Re-runs against the same commit overwrite that day's
# evidence — the most recent run is the canonical record for that SHA.
run "test_run"  ./tools/attest/attest_test_run.sh
run "selfhost"  ./tools/attest/attest_selfhost.sh

# Publish individual SHA records, then mirror them to /builds/latest
# and /selfhost/latest so consumers don't need to know today's SHA.
short=$(git rev-parse --short HEAD)
dirty=""
git diff --quiet 2>/dev/null || dirty="-dirty"
short="${short}${dirty}"

run "publish builds/$short"   ./tools/attest/publish.sh "builds/$short"
run "publish selfhost/$short" ./tools/attest/publish.sh "selfhost/$short"

# "latest" pointers — small JSON blobs that name the current SHA.  A
# consumer GETs /builds/latest, reads .short, then GETs the per-SHA
# record.  Production drift = "latest" stays pointed at an old SHA,
# self-evident in the timestamp.
TOKEN=$(cat ~/.ledatic/entropy/beacon_token)
publish_latest() {
  local kind=$1
  local body
  body=$(python3 -c "
import json, time
print(json.dumps({
  'kind': 'ledatic.${kind}.latest',
  'short': '${short}',
  'updated_utc': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
}))
")
  curl -sS -X PUT \
    -H "x-beacon-token: $TOKEN" \
    -H "content-type: application/json" \
    --data-binary "$body" \
    --max-time 15 \
    "https://ledatic.org/${kind}/latest/index.json" \
    -o /dev/null -w '%{http_code}'
}

builds_code=$(publish_latest builds)
selfhost_code=$(publish_latest selfhost)
echo "[$(date -u +%H:%M:%SZ)] /builds/latest=$builds_code /selfhost/latest=$selfhost_code" \
  >> ~/.ledatic/attest/daily.log

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "[$ts] daily attest run done" >> ~/.ledatic/attest/daily.log
