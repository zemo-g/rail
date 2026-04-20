#!/bin/bash
# tailscale_peer_check.sh — detect unexpected peers on the tailnet.
#
# Runs hourly on Mini via com.ledatic.tailscale_peer_check LaunchAgent.
# Compares `tailscale status` against ~/.fleet/allowed_tailnet_peers.
# On drift: posts Slack DM + logs; does not modify anything.
#
# Baseline file format (one Tailscale hostname per line):
#   mini
#   studio
#   homem1air-2
#   fleet0
#
# To reset the baseline after an intended fleet change:
#   tailscale status | awk 'NR>1 {print $2}' | sort > ~/.fleet/allowed_tailnet_peers
#   chmod 600 ~/.fleet/allowed_tailnet_peers

set -u

ALLOWED_FILE="$HOME/.fleet/allowed_tailnet_peers"
LOG="$HOME/.fleet/tailscale_peer_check.log"
SLACK_TOKEN_FILE="$HOME/.fleet/slack_token"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '%s %s\n' "$(ts)" "$*" >> "$LOG"; }

if [ ! -f "$ALLOWED_FILE" ]; then
  log "no allowlist at $ALLOWED_FILE — skipping"
  exit 0
fi

# Tailscale CLI — prefer standalone install, fall back to App Store bundle.
if command -v tailscale >/dev/null 2>&1; then
  TS=tailscale
elif [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
  TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
else
  log "tailscale CLI missing"; exit 0
fi

current=$("$TS" status 2>/dev/null | awk '$2 != "" {print $2}' | sort -u)
allowed=$(sort -u "$ALLOWED_FILE")

added=$(comm -13 <(printf '%s\n' "$allowed") <(printf '%s\n' "$current"))
removed=$(comm -23 <(printf '%s\n' "$allowed") <(printf '%s\n' "$current"))

if [ -z "$added" ] && [ -z "$removed" ]; then
  log "ok — $(printf '%s\n' "$current" | wc -l | tr -d ' ') peers match allowlist"
  exit 0
fi

msg=":warning: Tailscale peer drift on $(hostname -s)"
[ -n "$added" ]   && msg="$msg\nnew: $(printf '%s' "$added" | tr '\n' ' ')"
[ -n "$removed" ] && msg="$msg\ngone: $(printf '%s' "$removed" | tr '\n' ' ')"

log "DRIFT — added=[$added] removed=[$removed]"

if [ -s "$SLACK_TOKEN_FILE" ]; then
  token=$(cat "$SLACK_TOKEN_FILE")
  curl -sm 5 -X POST https://slack.com/api/chat.postMessage \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "{\"channel\":\"brockbro2\",\"text\":\"$(printf '%s' "$msg" | sed 's/"/\\"/g')\"}" \
    >/dev/null 2>&1 && log "slack posted"
fi
