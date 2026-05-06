#!/usr/bin/env bash
# slack_listener.sh — the empire's ears
#
# Polls brockbro2 DM for inbound messages, dispatches whitelisted
# commands, replies in the same DM. State file tracks last_seen_ts so
# each invocation only processes new messages.
#
# Wired as ~/Library/LaunchAgents/com.ledatic.slack_listener.plist with
# StartInterval=30 — one poll + dispatch per invocation, keeps the
# script crash-resilient and stateless in process.
#
# Whitelist (v1 — read-only-ish):
#   status        — fleet + drift summary
#   audit         — invoke drift_audit.sh
#   audit dry     — drift_audit.sh --dry
#   bump <ver>    — site_bump_pr.sh (idempotent — skips if no drift)
#   tail <log>    — last 20 lines of a known log
#   help          — list commands
#
# Anything not in the whitelist is silently ignored. Bot's own messages
# are filtered out so the listener doesn't hear itself.
#
# Logs to ~/.fleet/slack_listener/{listener.log, dispatch.log}.

set -uo pipefail

STATE_DIR="${HOME}/.fleet/slack_listener"
STATE_FILE="${STATE_DIR}/last_seen_ts"
LOG="${STATE_DIR}/listener.log"
DISPATCH_LOG="${STATE_DIR}/dispatch.log"
TOKEN_FILE="${HOME}/.fleet/slack_token"
CHANNEL="D0ATHQ1BQD7"   # brockbro2 DM
RAIL_REPO="${HOME}/projects/rail-https"

mkdir -p "$STATE_DIR"

ts_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '[%s] %s\n' "$(ts_iso)" "$*" >> "$LOG"; }

[ -s "$TOKEN_FILE" ] || { log "no slack token; exit"; exit 1; }
TOKEN=$(tr -d '\n' < "$TOKEN_FILE")

# Cache the bot's own user_id once per invocation. We filter our own
# messages so we don't echo-loop.
BOT_USER=$(curl -s --max-time 5 -X POST "https://slack.com/api/auth.test" \
  -H "Authorization: Bearer $TOKEN" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("user_id",""))' 2>/dev/null)
[ -z "$BOT_USER" ] && { log "auth.test failed"; exit 1; }

# Bootstrap: first run sets last_seen_ts to NOW so we don't replay
# the entire DM history. Subsequent runs use the file.
if [ ! -s "$STATE_FILE" ]; then
  printf '%s' "$(date +%s)" > "$STATE_FILE"
  log "first run — initialised last_seen_ts to now (no replay)"
  exit 0
fi
LAST_SEEN=$(cat "$STATE_FILE")

# ── fetch messages newer than LAST_SEEN ────────────────────────────
resp=$(curl -s --max-time 8 \
  "https://slack.com/api/conversations.history?channel=$CHANNEL&oldest=$LAST_SEEN&limit=50" \
  -H "Authorization: Bearer $TOKEN")

if ! echo "$resp" | grep -q '"ok":true'; then
  log "history fetch failed: $(echo "$resp" | head -c 200)"
  exit 1
fi

# Extract messages where user != bot, sorted oldest-first. ts is a
# string with high precision ("1234567890.123456") — we keep it as
# a string for the state file but use python for filtering.
new_msgs=$(echo "$resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
bot = '$BOT_USER'
msgs = []
for m in d.get('messages', []):
    if m.get('user') == bot or m.get('bot_id'):
        continue
    if m.get('subtype'):  # join/leave/etc
        continue
    txt = (m.get('text') or '').strip()
    if not txt:
        continue
    msgs.append((m['ts'], txt))
msgs.sort()
for ts, txt in msgs:
    print(f'{ts}\t{txt}')
")

if [ -z "$new_msgs" ]; then
  exit 0
fi

# ── slack post helper ──────────────────────────────────────────────
post_reply() {
  local thread_ts="$1" text="$2"
  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({
    'channel': '$CHANNEL',
    'thread_ts': '$thread_ts',
    'text': sys.argv[1],
    'mrkdwn': True,
}))
" "$text")
  curl -s --max-time 8 -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$payload" >/dev/null 2>&1 || true
}

# ── command dispatch ───────────────────────────────────────────────
dispatch() {
  local text="$1" thread_ts="$2"
  # Strip optional "@empire" or leading bang prefix
  local cmd
  cmd=$(echo "$text" | sed -E 's/^@empire[[:space:]]+//; s/^![[:space:]]*//' | tr -d '\r')
  local first
  first=$(echo "$cmd" | awk '{print tolower($1)}')

  case "$first" in
    help|h|"?")
      post_reply "$thread_ts" "*empire commands*
\`status\`         — fleet + drift summary
\`audit\`          — run drift_audit.sh
\`audit dry\`      — drift_audit.sh --dry (no slack/publish)
\`bump <ver>\`     — open site_bump_pr.sh PR (idempotent)
\`tail <log>\`     — last 20 lines of a known log: heal | drift | attest
\`brain <msg>\`    — handled by brain_socket.py (Socket Mode); brain replies in the same thread
\`help\`           — this message"
      ;;

    status)
      local body
      body=$(
        echo "*empire status — $(ts_iso)*"
        echo ""
        echo "*Fleet:*"
        curl -s --max-time 4 https://ledatic.org/fleet/status.json 2>/dev/null \
          | python3 -c "
import sys, json
d = json.load(sys.stdin)
for n in d['nodes']:
    state = '✅' if n['alive'] else '❌'
    print(f\"  {state} {n['name']:7s} {n['host']:18s} uptime={n.get('uptime') or 'n/a'}\")
print(f\"  pulse {d['pulse_id']}, signed_by={d['witness']['witness']}\")
"
        echo ""
        echo "*Last drift audit:*"
        if [ -f "$HOME/.ledatic/drift/last_audit.json" ]; then
          python3 -c "
import json
d = json.load(open('$HOME/.ledatic/drift/last_audit.json'))
print(f\"  {d['ts']}  {d['summary']['ok']} ok · {d['summary']['fixed']} fixed · {d['summary']['alerts']} alert\")
"
        else
          echo "  (no audit run yet)"
        fi
        echo ""
        echo "*Self-healer last events:*"
        tail -3 "$HOME/.fleet/self_healer/events.jsonl" 2>/dev/null \
          | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        e = json.loads(line)
        print(f\"  {e['t']}  {e['check']:18s} {e['status']}\")
    except: pass
"
      )
      post_reply "$thread_ts" "$body"
      ;;

    audit)
      local sub
      sub=$(echo "$cmd" | awk '{print tolower($2)}')
      local args=()
      [ "$sub" = "dry" ] && args=("--dry")
      local out
      out=$("$RAIL_REPO/tools/attest/drift_audit.sh" "${args[@]}" 2>&1 | tail -25)
      post_reply "$thread_ts" "*drift_audit run*
\`\`\`
$out
\`\`\`"
      ;;

    bump)
      local ver
      ver=$(echo "$cmd" | awk '{print $2}')
      if ! [[ "$ver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        post_reply "$thread_ts" "*bump*: bad version \`$ver\` (must be \`vN.N.N\`)"
        return
      fi
      local out
      out=$("$RAIL_REPO/tools/attest/site_bump_pr.sh" "$ver" 2>&1)
      local pr_url
      pr_url=$(echo "$out" | tail -1)
      if [[ "$pr_url" =~ ^https://github.com/.*pull/[0-9]+$ ]]; then
        post_reply "$thread_ts" "*bump $ver*: opened PR
$pr_url"
      else
        post_reply "$thread_ts" "*bump $ver*: $pr_url
\`\`\`
$(echo "$out" | tail -8)
\`\`\`"
      fi
      ;;

    # `brain <msg>` is handled by brain_socket.py via Socket Mode now.
    # Leaving this listener to its read-only fleet ops only.

    tail)
      local which
      which=$(echo "$cmd" | awk '{print tolower($2)}')
      local file=""
      case "$which" in
        heal)   file="$HOME/.fleet/self_healer/heal.log" ;;
        drift)  file="$HOME/.ledatic/drift/audit.log" ;;
        attest) file="$HOME/.ledatic/attest/daily.log" ;;
        *)      post_reply "$thread_ts" "*tail*: unknown log \`$which\` (try: heal | drift | attest)"; return ;;
      esac
      if [ ! -f "$file" ]; then
        post_reply "$thread_ts" "*tail $which*: file not present at $file"
        return
      fi
      local out
      out=$(tail -20 "$file")
      post_reply "$thread_ts" "*tail $which* (last 20)
\`\`\`
$out
\`\`\`"
      ;;

    *)
      # Silent on non-commands. The leader can talk to himself in this
      # DM without us spamming "unknown command" every 30 s.
      log "ignored non-command: ${cmd:0:60}"
      return
      ;;
  esac
  printf '[%s] dispatched: %s\n' "$(ts_iso)" "$cmd" >> "$DISPATCH_LOG"
}

# ── process new messages, advance cursor ───────────────────────────
LATEST_TS="$LAST_SEEN"
while IFS=$'\t' read -r ts text; do
  [ -z "$ts" ] && continue
  log "new msg ts=$ts text=${text:0:80}"
  dispatch "$text" "$ts"
  LATEST_TS="$ts"
done <<< "$new_msgs"

# Slack ts is a unix-ish string ("1234567890.123456"); the API accepts
# this same format as `oldest`. Save the highest ts we saw so the next
# tick starts from there.
printf '%s' "$LATEST_TS" > "$STATE_FILE"
exit 0
