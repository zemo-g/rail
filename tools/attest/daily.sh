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

set -uo pipefail

cd $HOME/projects/rail
mkdir -p ~/.ledatic/attest

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "[$ts] daily attest run starting" >> ~/.ledatic/attest/daily.log

# run() — never aborts the script on inner failure.  Failure attestation
# is the whole point: we publish red attestations the same way as green,
# so production drift becomes a citable physical event rather than a
# silent "cron didn't run today."
run() {
  local label=$1; shift
  echo "[$(date -u +%H:%M:%SZ)] $label ..." >> ~/.ledatic/attest/daily.log
  if "$@" >> ~/.ledatic/attest/daily.log 2>&1; then
    echo "[$(date -u +%H:%M:%SZ)] $label ok" >> ~/.ledatic/attest/daily.log
  else
    local rc=$?
    echo "[$(date -u +%H:%M:%SZ)] $label FAIL rc=$rc" >> ~/.ledatic/attest/daily.log
  fi
}

# Generate fresh attestations.  attest_test_run + attest_selfhost write
# their result.json regardless of pass/fail (status field carries the
# verdict), so a failure still produces a signed record we can publish.
run "test_run"  ./tools/attest/attest_test_run.sh
run "selfhost"  ./tools/attest/attest_selfhost.sh

# Publish whatever landed — pass OR fail.  A red day attests as red.
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
