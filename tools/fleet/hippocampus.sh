#!/usr/bin/env bash
# hippocampus.sh — weekly pattern distillation
#
# The empire's organism gets long-term memory: this script reads the
# raw event streams from the past 7 days, distills them via Claude
# Haiku, and posts a 200-word summary to brockbro2 every Sunday after
# the audit.
#
# Inputs (last 7 days only):
#   - ~/.fleet/self_healer/events.jsonl    — autonomic events
#   - ~/.ledatic/drift/audit.log           — drift audit history
#   - ~/.ledatic/attest/daily.log          — daily attest history
#   - ~/.fleet/slack_listener/dispatch.log — commands the leader issued
#   - git log --since=7.days across rail-https + ledatic-site         — what shipped
#   - mtime-recent files in ~/.claude/projects/.../memory/             — what was learned
#
# Output:
#   - Slack post to brockbro2 with the digest
#   - ~/.ledatic/hippocampus/digest_<date>.md — local archive
#
# Wiring: ~/Library/LaunchAgents/com.ledatic.hippocampus.plist runs
# Sun 09:30 (right after drift_audit at 09:00).

set -uo pipefail

STATE_DIR="${HOME}/.ledatic/hippocampus"
mkdir -p "$STATE_DIR"

ANTHROPIC_KEY_FILE="${HOME}/.fleet/anthropic_key"
SLACK_TOKEN_FILE="${HOME}/.fleet/slack_token"
SLACK_CHANNEL="D0ATHQ1BQD7"
RAIL_REPO="${HOME}/projects/rail-https"
SITE_REPO="${HOME}/projects/ledatic-site"
DDA_REPO="${HOME}/projects/dda-poc"
MEMORY_DIR="${HOME}/.claude/projects/-Users-ledaticempire/memory"

NOW_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
WEEK_AGO_EPOCH=$(date -u -v-7d +%s 2>/dev/null || date -u -d '7 days ago' +%s)
DIGEST_FILE="$STATE_DIR/digest_$(date -u +%Y%m%d).md"

[ -s "$ANTHROPIC_KEY_FILE" ] || { echo "no anthropic key"; exit 1; }
[ -s "$SLACK_TOKEN_FILE" ]  || { echo "no slack token"; exit 1; }

ANTHROPIC_KEY=$(tr -d '\n' < "$ANTHROPIC_KEY_FILE")
SLACK_TOKEN=$(tr -d '\n' < "$SLACK_TOKEN_FILE")

# ── gather ─────────────────────────────────────────────────────────
# Each gatherer writes a labelled section to /tmp/hippocampus_input.

INPUT=$(mktemp)
trap 'rm -f "$INPUT"' EXIT

{
  echo "## healer events (last 7 days)"
  echo ""
  if [ -f "$HOME/.fleet/self_healer/events.jsonl" ]; then
    # Filter by ts > week_ago, then aggregate by check + status.
    python3 -c "
import json, sys, datetime as dt, collections
cut = $WEEK_AGO_EPOCH
counts = collections.Counter()
last_alert = {}
with open('$HOME/.fleet/self_healer/events.jsonl') as f:
    for line in f:
        try:
            e = json.loads(line)
            t = dt.datetime.fromisoformat(e['t'].rstrip('Z')).replace(tzinfo=dt.timezone.utc).timestamp()
            if t < cut: continue
            counts[(e['check'], e['status'])] += 1
            if e['status'] in ('alert', 'broken', 'unreachable', 'silent', 'stale', 'down'):
                last_alert[e['check']] = e
        except Exception: pass
print('Counts (check / status / n):')
for (c, s), n in sorted(counts.items(), key=lambda x: -x[1]):
    print(f'  {c:18s} {s:14s} {n}')
if last_alert:
    print()
    print('Latest non-ok per check:')
    for c, e in last_alert.items():
        print(f'  {c}: {e[\"status\"]} at {e[\"t\"]} detail={e.get(\"detail\",\"\")[:60]}')
" || echo "  (events.jsonl read failed)"
  else
    echo "  (no events.jsonl)"
  fi
  echo ""

  echo "## drift audits (last 7 days)"
  echo ""
  if [ -f "$HOME/.ledatic/drift/audit.log" ]; then
    # Find audit blocks (each starts with [drift_audit YYYY-MM-DD...]).
    awk -v cut="$(date -u -v-7d +%Y-%m-%d 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%d)" '
      /^\[drift_audit / {
        d = substr($2, 1, 10)
        in_block = (d >= cut)
      }
      in_block { print }
    ' "$HOME/.ledatic/drift/audit.log" | tail -80
  else
    echo "  (no audit.log yet)"
  fi
  echo ""

  echo "## daily attest (last 7 days)"
  echo ""
  if [ -f "$HOME/.ledatic/attest/daily.log" ]; then
    awk -v cut="$(date -u -v-7d +%Y-%m-%dT 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT)" '
      $0 ~ "^\\["cut { in_block = 1 }
      $0 ~ /^\[20.*daily attest run starting/ {
        d = substr($1, 2, 10)
        in_block = (d >= substr(cut, 1, 10))
      }
      in_block { print }
    ' "$HOME/.ledatic/attest/daily.log" | tail -60
  else
    echo "  (no daily.log)"
  fi
  echo ""

  echo "## leader commands issued (slack_listener)"
  echo ""
  if [ -f "$HOME/.fleet/slack_listener/dispatch.log" ]; then
    tail -30 "$HOME/.fleet/slack_listener/dispatch.log"
  else
    echo "  (no dispatch.log — listener may not have processed any commands)"
  fi
  echo ""

  echo "## git activity (last 7 days)"
  echo ""
  for repo in "$RAIL_REPO" "$SITE_REPO" "$DDA_REPO"; do
    [ -d "$repo/.git" ] || continue
    echo "  $repo:"
    (cd "$repo" && git log --since='7 days ago' --pretty=format:'    %h %s' --no-merges 2>/dev/null | head -25)
    echo ""
  done

  echo "## memory entries written/updated this week"
  echo ""
  if [ -d "$MEMORY_DIR" ]; then
    find "$MEMORY_DIR" -maxdepth 1 -name '*.md' -mtime -7 2>/dev/null \
      | sort | while read -r f; do
        name=$(basename "$f")
        first_line=$(head -3 "$f" | grep -v '^---' | head -1 | tr -d '#')
        printf '  %s — %s\n' "$name" "${first_line:0:80}"
      done
  else
    echo "  (no memory dir)"
  fi
  echo ""
} > "$INPUT"

# ── distill via Claude Haiku ───────────────────────────────────────
# 200-word week-summary. Prompt is a positive role definition (not a
# ban list, per feedback_positive_prompt_roles). Emphasis on patterns
# and what's worth remembering, not a recap of every event.

PROMPT=$(python3 -c "
import json, sys
raw = open('$INPUT').read()
prompt = '''You are the hippocampus of a self-monitoring software organism. Your job is to read the past week of raw operational data and produce a short weekly memo (around 200 words) that captures only the things worth remembering: patterns, surprising states, outliers, what shipped, what almost broke. Skip routine green-state recaps. Lead with the most notable signal.

Format the memo as Slack mrkdwn:
- Open with one sentence of the week's headline.
- Then short labelled lines: *Health:*, *Shipped:*, *Earned:*, *Watch:*.
- End with one forward-looking sentence — what should the leader be thinking about in the coming week.

Raw inputs follow. Do not quote them verbatim; distill.

''' + raw
print(json.dumps({
    'model': 'claude-haiku-4-5-20251001',
    'max_tokens': 800,
    'messages': [{'role': 'user', 'content': prompt}],
}))
")

DIGEST=$(curl -s --max-time 30 https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "$PROMPT" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("content",[{}])[0].get("text","(no content)"))')

if [ -z "$DIGEST" ] || [ "$DIGEST" = "(no content)" ]; then
  echo "hippocampus: empty digest from Claude" >&2
  exit 1
fi

# ── archive locally ────────────────────────────────────────────────
{
  echo "# Weekly digest — $NOW_UTC"
  echo ""
  echo "$DIGEST"
  echo ""
  echo "---"
  echo ""
  echo "## Raw inputs (for audit)"
  echo ""
  cat "$INPUT"
} > "$DIGEST_FILE"

echo "hippocampus: digest written to $DIGEST_FILE"

# ── post to slack ──────────────────────────────────────────────────
SLACK_BODY=$(python3 -c "
import json, sys
header = '*🧠 Weekly digest — $(date -u +%F)*\n\n'
print(json.dumps({
    'channel': '$SLACK_CHANNEL',
    'text': header + sys.argv[1],
    'mrkdwn': True,
}))
" "$DIGEST")

resp=$(curl -s --max-time 10 -X POST "https://slack.com/api/chat.postMessage" \
  -H "Authorization: Bearer $SLACK_TOKEN" \
  -H "Content-Type: application/json; charset=utf-8" \
  -d "$SLACK_BODY")
echo "$resp" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('slack: ok=' + str(d.get('ok')) + (' err=' + d.get('error', '') if not d.get('ok') else ''))
except Exception as e:
    print('slack: parse-failure ' + str(e))
"

exit 0
