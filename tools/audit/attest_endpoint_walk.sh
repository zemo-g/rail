#!/usr/bin/env bash
# tools/audit/attest_endpoint_walk.sh
#
# Endpoint audit walker — Phase 1 of docs/plans/ATTEST_ENDPOINT_AUDIT.md.
# Probes each public attestation surface, reports per-class verdict + counters.
#
# READ-ONLY. No healing. No chain write yet (Phase 2 — gated on Studio :9101
# /lab/entry route from the Lakes lab integration plan).
#
# Exit code: 0 if every class PASS, 1 if any class FAIL, 2 on probe error.
#
# Run: bash tools/audit/attest_endpoint_walk.sh
# Quiet (only summary + failing classes): bash tools/audit/attest_endpoint_walk.sh -q

set -u  # NOT -e — every class must run, even if one fails

QUIET=0
LAB_MODE=0
while (( $# )); do
  case "$1" in
    -q)    QUIET=1; shift ;;
    --lab) LAB_MODE=1; QUIET=1; shift ;;
    *)     echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

BASE="${LEDATIC_BASE:-https://ledatic.org}"
NOW=$(date -u +%s)
RAIL_DIR="${HOME}/projects/rail"
# Pi witness host — private fleet address, kept out of the public tree.
# Optional: only used for a local cross-check of the public 'pi alive' badge.
# Set FLEET_PI_HOST, or put the bare host in ~/.fleet/pi_host.
FLEET_PI_HOST="${FLEET_PI_HOST:-$(cat "$HOME/.fleet/pi_host" 2>/dev/null || true)}"

total_pass=0
total_fail=0
first_fail=""
failing_classes=()

log()     { (( QUIET )) || echo "  $*"; }
header()  { (( QUIET )) || echo "--- $* ---"; }
verdict() {
  local class=$1 result=$2
  if [[ "$result" == "PASS" ]]; then
    total_pass=$((total_pass + 1))
    (( QUIET )) || echo "CLASS=$class VERDICT=PASS"
  else
    total_fail=$((total_fail + 1))
    failing_classes+=("$class")
    [[ -z "$first_fail" ]] && first_fail=$class
    echo "CLASS=$class VERDICT=FAIL"
  fi
}

json_int() { grep -oE "\"$2\":[0-9]+" <<<"$1" | grep -oE '[0-9]+$' | head -1; }
json_str() { grep -oE "\"$2\":\"[^\"]*\"" <<<"$1" | sed "s/\"$2\":\"//;s/\"$//" | head -1; }

# ============================================================================
# CLASS: beacon — pulse advances; frame addressable
# ============================================================================
class_beacon() {
  local p1 p2 sleep_s=11
  p1=$(curl -sf "$BASE/entropy/pulse")
  local pulse1; pulse1=$(json_int "$p1" pulse_id)
  log "pulse before: $pulse1"
  sleep "$sleep_s"
  p2=$(curl -sf "$BASE/entropy/pulse")
  local pulse2; pulse2=$(json_int "$p2" pulse_id)
  log "pulse after ${sleep_s}s: $pulse2"
  if [[ -z "$pulse1" || -z "$pulse2" ]]; then
    log "FAIL: pulse fetch returned empty"
    verdict beacon FAIL; return
  fi
  if (( pulse2 > pulse1 )); then
    # Also confirm frame endpoint responds
    local frame_code
    frame_code=$(curl -sf -o /dev/null -w '%{http_code}' "$BASE/entropy/frame/current")
    if [[ "$frame_code" == "200" ]]; then
      verdict beacon PASS
    else
      log "FAIL: frame/current returned $frame_code"
      verdict beacon FAIL
    fi
  else
    log "FAIL: pulse_id did not advance ($pulse1 -> $pulse2 in ${sleep_s}s)"
    verdict beacon FAIL
  fi
}

# ============================================================================
# CLASS: witness — latest signed pulse age < 10min
# ============================================================================
class_witness() {
  local payload age witnessed
  payload=$(curl -sf "$BASE/witness/fleet0/latest")
  if [[ -z "$payload" ]]; then
    log "FAIL: empty payload"; verdict witness FAIL; return
  fi
  witnessed=$(json_int "$payload" witnessed_at)
  if [[ -z "$witnessed" ]]; then
    log "FAIL: no witnessed_at"; verdict witness FAIL; return
  fi
  age=$(( NOW - witnessed ))
  log "witness age: ${age}s"
  if (( age < 600 )); then
    verdict witness PASS
  else
    log "FAIL: witness stale (${age}s > 600s)"
    verdict witness FAIL
  fi
}

# ============================================================================
# CLASS: fleet — status.json fresh AND pi-alive matches our own probe
# ============================================================================
class_fleet() {
  local payload asof age pi_alive_pub pi_health_local token
  payload=$(curl -sf "$BASE/fleet/status.json")
  asof=$(json_int "$payload" asof_unix)
  if [[ -z "$asof" ]]; then
    log "FAIL: no asof_unix"; verdict fleet FAIL; return
  fi
  age=$(( NOW - asof ))
  # JSON keys are alphabetical: alive,host,name,uptime — so alive appears
  # BEFORE name. Use python to pluck the pi node's alive deterministically.
  pi_alive_pub=$(python3 -c "
import sys, json
d=json.loads('''$payload''')
for n in d.get('nodes', []):
    if n.get('name')=='pi':
        print('true' if n.get('alive') else 'false')
        break
" 2>/dev/null)
  log "status age: ${age}s; pi: ${pi_alive_pub}"
  if (( age > 300 )); then
    log "FAIL: status stale (${age}s > 300s)"; verdict fleet FAIL; return
  fi
  token=$(cat ~/.fleet/token 2>/dev/null || true)
  if [[ -z "$token" ]]; then
    log "WARN: no ~/.fleet/token; can't cross-check pi"
  elif [[ -z "$FLEET_PI_HOST" ]]; then
    log "no FLEET_PI_HOST; skipping local pi cross-check"
  else
    pi_health_local=$(curl -sf --max-time 3 -H "X-Fleet-Token: $token" "http://$FLEET_PI_HOST:9101/health" 2>/dev/null || echo "")
    log "our pi probe: ${pi_health_local:-(unreachable)}"
    if [[ -n "$pi_health_local" && "$pi_alive_pub" != *"true"* ]]; then
      log "FAIL: pi reachable from us but status says alive:false"
      verdict fleet FAIL; return
    fi
  fi
  verdict fleet PASS
}

# ============================================================================
# CLASS: builds_badge — sha matches origin/master HEAD; reasonable freshness
# ============================================================================
class_builds_badge() {
  local payload msg badge_sha badge_count head_sha
  payload=$(curl -sf "$BASE/attest/badge/builds.json")
  msg=$(json_str "$payload" message)
  log "badge: $msg"
  # message: "sha · X/Y · pulse N" or "sha-dirty · X/Y · pulse N"
  badge_sha=$(awk -F' · ' '{print $1}' <<<"$msg" | awk -F- '{print $1}')
  badge_count=$(awk -F' · ' '{print $2}' <<<"$msg")
  head_sha=$(cd "$RAIL_DIR" && git rev-parse --short origin/master 2>/dev/null)
  log "head_sha=$head_sha badge_sha=$badge_sha badge_count=$badge_count"
  if [[ "$badge_sha" == "$head_sha" ]]; then
    verdict builds_badge PASS
  else
    log "FAIL: badge sha $badge_sha != origin/master $head_sha (stale or never re-published)"
    verdict builds_badge FAIL
  fi
}

# ============================================================================
# CLASS: selfhost_badge — sha matches HEAD; color matches actual drift state
# ============================================================================
class_selfhost_badge() {
  local payload msg color badge_sha head_sha
  payload=$(curl -sf "$BASE/attest/badge/selfhost.json")
  msg=$(json_str "$payload" message)
  color=$(json_str "$payload" color)
  log "badge: $msg (color=$color)"
  badge_sha=$(awk -F' · ' '{print $1}' <<<"$msg" | awk -F- '{print $1}')
  head_sha=$(cd "$RAIL_DIR" && git rev-parse --short origin/master 2>/dev/null)
  log "head_sha=$head_sha badge_sha=$badge_sha"
  if [[ "$badge_sha" != "$head_sha" ]]; then
    log "FAIL: selfhost badge sha $badge_sha != origin/master $head_sha"
    verdict selfhost_badge FAIL; return
  fi
  # Same-sha: color should reflect current truth. We can cheaply re-verify:
  cd "$RAIL_DIR"
  ./rail_native self >/dev/null 2>&1
  if cmp -s rail_native /tmp/rail_self; then
    if [[ "$color" == "brightgreen" || "$color" == "green" ]]; then
      verdict selfhost_badge PASS
    else
      log "FAIL: local self == byte-identical, but badge color=$color"
      verdict selfhost_badge FAIL
    fi
  else
    if [[ "$color" == "red" ]]; then
      verdict selfhost_badge PASS  # honestly red
    else
      log "FAIL: local self DIVERGED, but badge color=$color"
      verdict selfhost_badge FAIL
    fi
  fi
}

# ============================================================================
# CLASS: static — verify.sh + fleet0.pub.pem sha matches on-disk
# ============================================================================
class_static() {
  local r_verify l_verify r_pub l_pub
  r_verify=$(curl -sf "$BASE/attest/verify.sh" | shasum -a 256 | awk '{print $1}')
  l_verify=$(shasum -a 256 "$RAIL_DIR/tools/attest/verify.sh" 2>/dev/null | awk '{print $1}')
  r_pub=$(curl -sf "$BASE/attest/fleet0.pub.pem" | shasum -a 256 | awk '{print $1}')
  l_pub=$(shasum -a 256 ~/.ledatic/witness/fleet0.pub.pem 2>/dev/null | awk '{print $1}')
  log "verify.sh: remote=${r_verify:0:12} local=${l_verify:0:12}"
  log "fleet0.pub.pem: remote=${r_pub:0:12} local=${l_pub:0:12}"
  if [[ -z "$r_verify" || -z "$l_verify" ]]; then
    log "FAIL: verify.sh missing on remote or locally"
    verdict static FAIL; return
  fi
  if [[ "$r_verify" == "$l_verify" && "$r_pub" == "$l_pub" ]]; then
    verdict static PASS
  else
    log "FAIL: static asset hash mismatch"
    verdict static FAIL
  fi
}

# ============================================================================
# CLASS: pages — /system /ot /case-campaign-intel reference live-data scripts
# ============================================================================
class_pages() {
  local html missing=""
  # Pages required to have a live-data widget. /case-campaign-intel
  # was historically claimed to have one in memory, but it's actually
  # a static marketing page — confirmed 2026-05-27, no widget ever built.
  for page in system ot; do
    html=$(curl -sf "$BASE/$page")
    if ! grep -qE '/?_shared/([a-z-]+-(live|attest|cite)|pulse-clock|proof-tray)\.js' <<<"$html"; then
      missing+=" $page"
    fi
  done
  if [[ -z "$missing" ]]; then
    verdict pages PASS
  else
    log "FAIL: pages without live-data refs:$missing"
    verdict pages FAIL
  fi
}

# ============================================================================
# CLASS: releases — latest tag artifact sha matches attestation sha
# ============================================================================
class_releases() {
  local tag artifact_sha attest_sha
  tag=$(cd "$RAIL_DIR" && git tag --list 'v*' | sort -V | tail -1)
  log "latest tag: $tag"
  if [[ -z "$tag" ]]; then
    log "FAIL: no v* tags"; verdict releases FAIL; return
  fi
  rm -f /tmp/audit_rn /tmp/audit_rn.att
  curl -sf "$BASE/releases/$tag/rail_native" -o /tmp/audit_rn 2>/dev/null
  curl -sf "$BASE/releases/$tag/rail_native.attestation.json" -o /tmp/audit_rn.att 2>/dev/null
  if [[ ! -s /tmp/audit_rn || ! -s /tmp/audit_rn.att ]]; then
    log "FAIL: $tag artifact or attestation missing"
    verdict releases FAIL; return
  fi
  artifact_sha=$(shasum -a 256 /tmp/audit_rn | awk '{print $1}')
  # tolerate whitespace around ":" in JSON; pick the first sha256 value (artifact.sha256)
  attest_sha=$(grep -oE '"sha256"[[:space:]]*:[[:space:]]*"[0-9a-f]+"' /tmp/audit_rn.att | head -1 | grep -oE '[0-9a-f]{64}')
  log "artifact_sha=${artifact_sha:0:16}  attest_sha=${attest_sha:0:16}"
  if [[ "$artifact_sha" == "$attest_sha" && -n "$artifact_sha" ]]; then
    verdict releases PASS
  else
    log "FAIL: $tag artifact != attestation"
    verdict releases FAIL
  fi
}

# ============================================================================
# CLASS: dda — index reachable + well-formed JSON
# ============================================================================
class_dda() {
  local idx
  idx=$(curl -sf "$BASE/dda/index.json")
  if [[ -z "$idx" ]]; then
    log "FAIL: dda/index.json unreachable"
    verdict dda FAIL; return
  fi
  if grep -q '"kind"' <<<"$idx" || grep -q '"version"' <<<"$idx"; then
    verdict dda PASS
  else
    log "FAIL: dda/index.json malformed (no kind/version)"
    verdict dda FAIL
  fi
}

# ============================================================================
# RUN
# ============================================================================
(( QUIET )) || echo "=== ATTEST ENDPOINT AUDIT — $(date -u +%FT%TZ) ==="
(( QUIET )) || echo "base: $BASE"
(( QUIET )) || echo

header beacon;          class_beacon
header witness;         class_witness
header fleet;           class_fleet
header builds_badge;    class_builds_badge
header selfhost_badge;  class_selfhost_badge
header static;          class_static
header pages;           class_pages
header releases;        class_releases
header dda;             class_dda

echo
echo "=== SUMMARY ==="
echo "PASS=$total_pass FAIL=$total_fail FIRST_FAIL=${first_fail:-none}"
if (( total_fail > 0 )); then
  printf 'FAILING_CLASSES='
  IFS=,; echo "${failing_classes[*]}"
fi

if (( LAB_MODE == 1 )); then
  echo "===RAIL_LAB_COUNTERS==="
  echo "{\"counter\": \"classes_total\", \"value\": $((total_pass + total_fail))}"
  echo "{\"counter\": \"classes_pass\", \"value\": $total_pass}"
  echo "{\"counter\": \"classes_fail\", \"value\": $total_fail}"
  echo "===END==="
  if (( total_fail == 0 )); then
    echo "===VERDICT=== PASS"
    exit 0
  else
    echo "===VERDICT=== FALSIFIED"
    exit 0  # exit 0 in --lab mode: runner succeeded, verdict is the falsification claim
  fi
fi

[[ $total_fail -eq 0 ]] && exit 0 || exit 1
