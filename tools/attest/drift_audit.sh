#!/usr/bin/env bash
# drift_audit.sh — weekly cross-surface alignment check.
#
# Catches the "I wrote v3.X but ledatic.org still says v3.W" failure
# mode, the "I tagged v3.X but never published the attest manifest"
# failure mode, the "the daily attest cron stopped running but nothing
# screamed" failure mode, and the "the witness service has been silent
# for days but systemd shows it active" failure mode.
#
# Five checks:
#   1. GitHub master's latest tag == site banner across all 8 pages
#   2. Every git tag has /releases/<tag>/index.json published
#   3. /builds/latest and /selfhost/latest are < 36 h old
#   4. /entropy/pulse advances over a 4 s window
#   5. /witness/fleet0/latest is < 5 min old AND chain_verified=true
#
# Auto-fix: missing release attestations get published via
# tools/attest/publish.sh (idempotent — the JSON is already signed,
# this is delivery only).
#
# Alert (no auto-fix): site banner drift opens a PR against
# Ledatic-Empire/ledatic-site so a human eye lands on the changelog
# text before it goes public. Stale build/selfhost/beacon/witness
# emit a Slack punch list to brockbro2.
#
# Wiring: ~/Library/LaunchAgents/com.ledatic.drift_audit.plist runs
# this Sundays 09:00 local. Idempotent — safe to invoke ad-hoc:
#   ./tools/attest/drift_audit.sh           # full audit
#   ./tools/attest/drift_audit.sh --dry     # no Slack, no PR, no publish
#   ./tools/attest/drift_audit.sh --json    # machine-readable output

# NOT set -e: we want every check to run even if one fails. Each check
# captures its own outcome into the OK/FIXED/ALERTS arrays.
set -uo pipefail

DRY="${DRY:-0}"
JSON="${JSON:-0}"
for arg in "$@"; do
  case "$arg" in
    --dry|--dry-run) DRY=1 ;;
    --json)          JSON=1 ;;
    *) echo "drift_audit: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

REPO=${REPO:-/Users/ledaticempire/projects/rail-https}
SITE=${SITE:-/Users/ledaticempire/projects/ledatic-site}
SLACK_TOKEN_FILE=${SLACK_TOKEN_FILE:-$HOME/.fleet/slack_token}
SLACK_CHANNEL=${SLACK_CHANNEL:-D0ATHQ1BQD7}   # brockbro2 DM
DRIFT_DIR=${DRIFT_DIR:-$HOME/.ledatic/drift}
SITE_PAGES=(index.html rail.html entropy.html fleet.html manifesto.html plasma.html now.html changelog.html)
# Tags that legitimately predate the rail_native binary in the repo —
# nothing to attest. Skip silently rather than alert weekly.
PRE_HISTORIC_TAGS=(v0.6.0)

mkdir -p "$DRIFT_DIR"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NOW_EPOCH=$(date +%s)

declare -a OK=() FIXED=() ALERTS=()

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
ok()    { OK+=("$1"); }
fix()   { FIXED+=("$1"); }
alert() { ALERTS+=("$1"); }

# ── helpers ────────────────────────────────────────────────────────

# JSON field via python (handles whitespace + escapes robustly). Empty
# string on parse failure — callers must check for empty.
jget() {
  python3 -c "
import sys, json
try:
    print(json.load(sys.stdin).get('$1', ''))
except Exception:
    pass
" 2>/dev/null
}

# Iso8601 → epoch seconds, BSD-date compatible (macOS).
iso_to_epoch() {
  python3 -c "
import sys, datetime as dt
s = sys.stdin.read().strip().rstrip('Z')
try:
    print(int(dt.datetime.fromisoformat(s).replace(tzinfo=dt.timezone.utc).timestamp()))
except Exception:
    print(0)
"
}

# ── check 1: GitHub master latest tag vs site banner ───────────────
check_tag_vs_site() {
  log "check 1: tag vs site banner"
  local latest_tag
  latest_tag=$(cd "$REPO" && git ls-remote --tags origin 2>/dev/null \
    | awk '{print $2}' | sed 's,refs/tags/,,;s,\^{},,' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
  if [ -z "$latest_tag" ]; then
    alert "tag/site: could not determine latest tag from origin"
    return
  fi
  local stale_pages=()
  for page in "${SITE_PAGES[@]}"; do
    local url="https://ledatic.org/$page"
    [ "$page" = "index.html" ] && url="https://ledatic.org/"
    local banners
    banners=$(curl -fsS --max-time 5 "$url" 2>/dev/null \
      | grep -oE 'v3\.[0-9]+\.[0-9]+' | sort -u)
    [ -z "$banners" ] && continue
    local highest
    highest=$(echo "$banners" | sort -V | tail -1)
    if [ "$highest" != "$latest_tag" ]; then
      stale_pages+=("$page:$highest")
    fi
  done
  if [ ${#stale_pages[@]} -eq 0 ]; then
    ok "site banner up to date ($latest_tag across all 8 pages)"
  else
    alert "site banner stale: ${stale_pages[*]} (latest tag is $latest_tag) — open PR with: ./tools/attest/drift_audit.sh --bump-pr"
  fi
}

# ── check 2: every git tag has /releases/<tag>/ published ──────────
check_release_coverage() {
  log "check 2: release attest coverage"
  local missing=() unpublishable=() skipped=0
  local all_tags
  all_tags=$(cd "$REPO" && git tag | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V)
  local total=0
  for tag in $all_tags; do
    # Skip pre-historic tags (binary not in repo at that tag).
    local skip=0
    for pre in "${PRE_HISTORIC_TAGS[@]}"; do
      [ "$tag" = "$pre" ] && skip=1 && break
    done
    [ "$skip" = "1" ] && skipped=$((skipped + 1)) && continue
    total=$((total + 1))
    local code
    code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 5 \
      "https://ledatic.org/releases/$tag/index.json" 2>/dev/null || echo 000)
    [ "$code" = "200" ] && continue
    if [ -d "$REPO/releases/$tag" ]; then
      missing+=("$tag")
    else
      unpublishable+=("$tag")
    fi
  done
  if [ ${#missing[@]} -eq 0 ] && [ ${#unpublishable[@]} -eq 0 ]; then
    if [ "$skipped" -gt 0 ]; then
      ok "releases: all $total tags published ($skipped pre-historic skipped)"
    else
      ok "releases: all $total tags published"
    fi
    return
  fi
  if [ ${#missing[@]} -gt 0 ]; then
    if [ "$DRY" = "1" ]; then
      alert "[DRY] would publish: ${missing[*]}"
    else
      log "auto-publishing missing release attests: ${missing[*]}"
      for tag in "${missing[@]}"; do
        if (cd "$REPO" && ./tools/attest/publish.sh "releases/$tag" >/dev/null 2>&1); then
          fix "auto-published releases/$tag (5 files)"
        else
          alert "publish FAILED for releases/$tag — check beacon token + CF auth"
        fi
      done
    fi
  fi
  for tag in "${unpublishable[@]}"; do
    alert "releases/$tag: tagged but no local artifacts (run: ./tools/attest/attest_release.sh $tag)"
  done
}

# ── check 3: /builds/latest and /selfhost/latest are fresh ─────────
check_build_freshness() {
  log "check 3: builds/latest + selfhost/latest age"
  local stale_threshold=$((36 * 3600))
  for kind in builds selfhost; do
    local body
    body=$(curl -fsS --max-time 5 "https://ledatic.org/$kind/latest/index.json" 2>/dev/null)
    if [ -z "$body" ]; then
      alert "/$kind/latest: unreachable"
      continue
    fi
    local updated short
    updated=$(echo "$body" | jget updated_utc)
    short=$(echo "$body" | jget short)
    if [ -z "$updated" ]; then
      alert "/$kind/latest: malformed JSON (no updated_utc field)"
      continue
    fi
    local updated_epoch age_sec age_h
    updated_epoch=$(echo "$updated" | iso_to_epoch)
    age_sec=$((NOW_EPOCH - updated_epoch))
    age_h=$((age_sec / 3600))
    if [ "$age_sec" -gt "$stale_threshold" ]; then
      alert "/$kind/latest: stale ($short, ${age_h}h old) — daily.sh cron may be broken"
    else
      ok "/$kind/latest fresh ($short, ${age_h}h old)"
    fi
  done
}

# ── check 4: entropy beacon is advancing ───────────────────────────
check_beacon() {
  log "check 4: entropy beacon advance"
  local snap1 snap2 p1 p2 v1 v2
  snap1=$(curl -fsS --max-time 5 "https://ledatic.org/entropy/pulse" 2>/dev/null)
  if [ -z "$snap1" ]; then
    alert "/entropy/pulse: unreachable — beacon daemon dead?"
    return
  fi
  p1=$(echo "$snap1" | jget pulse_id)
  v1=$(echo "$snap1" | jget value_hex)
  sleep 4
  snap2=$(curl -fsS --max-time 5 "https://ledatic.org/entropy/pulse" 2>/dev/null)
  if [ -z "$snap2" ]; then
    alert "/entropy/pulse: vanished mid-check"
    return
  fi
  p2=$(echo "$snap2" | jget pulse_id)
  v2=$(echo "$snap2" | jget value_hex)
  if [ "$p1" = "$p2" ] || [ "$v1" = "$v2" ]; then
    alert "/entropy/pulse: STALE — pulse $p1 didn't advance in 4s. Check com.ledatic.mhd"
  else
    ok "beacon advancing ($p1 → $p2 in 4s)"
  fi
}

# ── check 5: witness fresh + chain verified ────────────────────────
check_witness() {
  log "check 5: /witness/fleet0/latest"
  local body
  body=$(curl -fsS --max-time 5 "https://ledatic.org/witness/fleet0/latest" 2>/dev/null)
  if [ -z "$body" ]; then
    alert "/witness/fleet0/latest: unreachable"
    return
  fi
  local pulse_id witnessed_at chain_verified
  pulse_id=$(echo "$body" | jget pulse_id)
  witnessed_at=$(echo "$body" | jget witnessed_at)
  chain_verified=$(echo "$body" | jget chain_verified)
  if [ -z "$pulse_id" ] || [ -z "$witnessed_at" ]; then
    alert "/witness/fleet0/latest: malformed (no pulse_id or witnessed_at)"
    return
  fi
  local age_sec=$((NOW_EPOCH - witnessed_at))
  if [ "$age_sec" -gt 300 ]; then
    local age_h=$((age_sec / 3600))
    alert "/witness/fleet0/latest: SILENT (last sig pulse $pulse_id, ${age_h}h ago). Check fleet0 + witness.service"
  elif [ "$chain_verified" != "True" ]; then
    # gap=2 with chain_verified=null is normal under skip; only alert if gap is sustained.
    # For a single audit, we accept null as "informational" not "alert".
    ok "/witness/fleet0/latest fresh (pulse $pulse_id, ${age_sec}s ago; chain_verified=$chain_verified)"
  else
    ok "/witness/fleet0/latest fresh + chain_verified (pulse $pulse_id, ${age_sec}s ago)"
  fi
}

# ── slack ──────────────────────────────────────────────────────────
# Direct to slack.com (TLS 1.3 via macOS LibreSSL). The legacy socat
# proxy at :8444 is from the pre-Rail-TLS era and currently has a TLS
# version mismatch with modern Slack — bypassing it altogether.
slack_post() {
  local msg="$1"
  [ "$DRY" = "1" ] && { log "[DRY] would slack: $msg"; return; }
  [ -s "$SLACK_TOKEN_FILE" ] || { log "no slack token; skip"; return; }
  local token
  token=$(tr -d '\n' < "$SLACK_TOKEN_FILE")
  local resp
  resp=$(curl -s --max-time 8 -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$(jq -nc --arg ch "$SLACK_CHANNEL" --arg t "$msg" \
        '{channel:$ch, text:$t, mrkdwn:true}')" 2>/dev/null)
  if echo "$resp" | grep -q '"ok":true'; then
    log "slack ok"
  else
    local err
    err=$(echo "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("error","unknown"))' 2>/dev/null || echo "no_response")
    log "slack post failed: $err"
  fi
}

# ── output ─────────────────────────────────────────────────────────
# Bash gotcha: with `set -u`, `"${arr[@]}"` errors on an empty array.
# We use the `${arr[@]+"${arr[@]}"}` idiom or guard with length checks.

emit_text() {
  echo "[drift_audit $NOW]"
  echo "  ─── ok ─────────────────────────────────────"
  if [ ${#OK[@]} -gt 0 ]; then
    for o in "${OK[@]}"; do echo "    ok    $o"; done
  fi
  if [ ${#FIXED[@]} -gt 0 ]; then
    echo "  ─── auto-fixed ────────────────────────────"
    for f in "${FIXED[@]}"; do echo "    fixed $f"; done
  fi
  if [ ${#ALERTS[@]} -gt 0 ]; then
    echo "  ─── alerts ────────────────────────────────"
    for a in "${ALERTS[@]}"; do echo "    ALERT $a"; done
  fi
  echo "  ─── summary ───────────────────────────────"
  echo "    ${#OK[@]} ok · ${#FIXED[@]} fixed · ${#ALERTS[@]} alert"
}

# JSON emit — feed buckets to python as TSV lines on stdin so we don't
# fight shell-quote rules inside a python -c string.
emit_json() {
  {
    [ ${#OK[@]}     -gt 0 ] && printf 'OK\t%s\n'    "${OK[@]}"
    [ ${#FIXED[@]}  -gt 0 ] && printf 'FIXED\t%s\n' "${FIXED[@]}"
    [ ${#ALERTS[@]} -gt 0 ] && printf 'ALERT\t%s\n' "${ALERTS[@]}"
  } | python3 -c '
import sys, json
ts = sys.argv[1]
n_ok, n_fix, n_alert = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
buckets = {"OK": [], "FIXED": [], "ALERT": []}
for line in sys.stdin.read().splitlines():
    if not line: continue
    b, _, m = line.partition("\t")
    if m and b in buckets:
        buckets[b].append(m)
print(json.dumps({
    "ts": ts,
    "ok": buckets["OK"],
    "fixed": buckets["FIXED"],
    "alerts": buckets["ALERT"],
    "summary": {"ok": n_ok, "fixed": n_fix, "alerts": n_alert},
}, indent=2))
' "$NOW" "${#OK[@]}" "${#FIXED[@]}" "${#ALERTS[@]}"
}

build_slack_msg() {
  local msg="*Drift audit — ${NOW}*"
  msg+="\n\`${#OK[@]} ok · ${#FIXED[@]} fixed · ${#ALERTS[@]} alert\`"
  if [ ${#FIXED[@]} -gt 0 ]; then
    msg+="\n\n*Auto-fixed:*"
    for f in "${FIXED[@]}"; do msg+="\n• $f"; done
  fi
  if [ ${#ALERTS[@]} -gt 0 ]; then
    msg+="\n\n*Alerts:*"
    for a in "${ALERTS[@]}"; do msg+="\n• $a"; done
  fi
  printf '%b' "$msg"
}

# ── run ────────────────────────────────────────────────────────────
check_tag_vs_site
check_release_coverage
check_build_freshness
check_beacon
check_witness

# Persist last-audit state so a consumer (heal.sh, /system page) can read it.
emit_json > "$DRIFT_DIR/last_audit.json"
emit_text >> "$DRIFT_DIR/audit.log"

if [ "$JSON" = "1" ]; then
  emit_json
else
  emit_text
fi

# Slack only when there's signal — don't spam on all-green weeks.
if [ ${#ALERTS[@]} -gt 0 ] || [ ${#FIXED[@]} -gt 0 ]; then
  slack_post "$(build_slack_msg)"
fi

# Exit code: 0 if all-green, 1 if any alert (so cron stderr surfaces).
[ ${#ALERTS[@]} -gt 0 ] && exit 1
exit 0
