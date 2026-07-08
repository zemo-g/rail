#!/bin/bash
# Fleet self-healer — Mini node
# Detects & repairs the class of failures we hit on 2026-04-18:
#   - bridge0 alias 10.42.0.1 vanishes when Internet Sharing toggles  # leak-guard-allow (fabric convention, private range)
#   - new TB peer interfaces appear but don't auto-join bridge0
#   - token file ends up world-readable or empty
#   - fleet agent crashes silently
#   - WAN loss (alert only — no auto-fix, service order is a GUI thing)
#
# Safety:
#   - narrow passwordless sudo via /etc/sudoers.d/fleet-healer
#   - dry-run mode via SELF_HEALER_DRYRUN=1
#   - rate-limit: same fix ≤3 in 10 min
#   - circuit breaker: 10 failures/hr → pause + Slack scream
#   - never touches: plists, binaries, LaunchDaemon state, fleet token content
#   - only mutates: bridge0 aliases/members, token file perms
#
# Subcommands:
#   heal.sh             → single pass (default; used by LaunchAgent)
#   heal.sh loop        → continuous loop with sleep (unused under LaunchAgent)
#   heal.sh status      → human readable recent events
#   heal.sh test        → dry-run all checks, no fixes
#   heal.sh events N    → show last N events
#   heal.sh reset       → clear circuit breaker + rate limit counters

set -uo pipefail

STATE_DIR="${HOME}/.fleet/self_healer"
STATE_FILE="${STATE_DIR}/state.json"
LOG_FILE="${STATE_DIR}/heal.log"
EVENTS_FILE="${STATE_DIR}/events.jsonl"
HEARTBEAT_FILE="${STATE_DIR}/heartbeat"
BREAKER_FILE="${STATE_DIR}/breaker"
TOKEN_FILE="${HOME}/.fleet/token"

EXPECTED_TB_ALIAS=$(cat "${HOME}/.fleet/tb-ip" 2>/dev/null | tr -d '[:space:]')
EXPECTED_MASK="255.255.255.0"
# Fleet nodes are machine-local config (topology is sensitive), NOT committed.
# One "name:tb_ip:ts_ip" per line; '#'/blank lines ignored. Probed TB-first
# (sub-ms fabric), Tailscale fallback; a node is OK if EITHER answers. TS-only
# = TB degraded (alerted). Agents bind 0.0.0.0 so both paths answer.
#   ~/.fleet/fleet_nodes            critical nodes (always-on; degraded screams)
#   ~/.fleet/fleet_nodes_besteffort laptops that sleep (quiet when fully absent)
read_nodes() { [ -f "$1" ] && grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null; }
FLEET_NODES=(); while IFS= read -r l; do FLEET_NODES+=("$l"); done < <(read_nodes "${HOME}/.fleet/fleet_nodes")
FLEET_NODES_BESTEFFORT=(); while IFS= read -r l; do FLEET_NODES_BESTEFFORT+=("$l"); done < <(read_nodes "${HOME}/.fleet/fleet_nodes_besteffort")
RATE_WINDOW_SEC=600      # 10 minutes
RATE_MAX_SAME_FIX=3
BREAKER_WINDOW_SEC=3600  # 1 hour
BREAKER_MAX_FAILURES=10

# TB-degraded state machine (added 2026-06-22). A node reachable ONLY via
# Tailscale is PRESENT but its Thunderbolt fabric is dark — the failure that
# hid the Air's broken TB pin (en4 stub) for weeks. Alert on sustained
# degradation + on recovery, rate-limited.
TB_DEGRADED_DIR="${STATE_DIR}/tbstate"
TB_DEGRADED_THRESHOLD=2      # consecutive TS-only ticks before alerting (~3 min @90s)
TB_REMIND_SEC=21600         # re-remind every 6h while still degraded

mkdir -p "$STATE_DIR"
touch "$LOG_FILE" "$EVENTS_FILE"

DRYRUN="${SELF_HEALER_DRYRUN:-0}"
CMD="${1:-run}"

# ── color helpers (interactive only) ───────────────────────────────
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m';  C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_DIM=""; C_RST=""
fi

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

log() {
  local level="$1"; shift
  local msg="$*"
  local ts=$(now_iso)
  printf '%s [%s] %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE"
  case "$level" in
    FIX)   printf '%s[%s]%s %s\n' "$C_GRN" "$level" "$C_RST" "$msg" ;;
    WARN)  printf '%s[%s]%s %s\n' "$C_YLW" "$level" "$C_RST" "$msg" ;;
    ALERT) printf '%s[%s]%s %s\n' "$C_RED" "$level" "$C_RST" "$msg" ;;
    OK)    printf '%s[%s]%s %s\n' "$C_GRN" "$level" "$C_RST" "$msg" ;;
    *)     printf '%s[%s]%s %s\n' "$C_DIM" "$level" "$C_RST" "$msg" ;;
  esac
}

event() {
  local check="$1" status="$2" action="${3:-none}" detail="${4:-}"
  printf '{"t":"%s","check":"%s","status":"%s","action":"%s","detail":%s}\n' \
    "$(now_iso)" "$check" "$status" "$action" "$(printf '%s' "$detail" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '""')" \
    >> "$EVENTS_FILE"
}

# ── rate limiter ───────────────────────────────────────────────────
# Keeps each fix to RATE_MAX_SAME_FIX per RATE_WINDOW_SEC.
can_fix() {
  local fix_key="$1"
  local cutoff=$(( $(now_epoch) - RATE_WINDOW_SEC ))
  local hits=$(awk -F'|' -v k="$fix_key" -v c="$cutoff" '$1==k && $2>=c' \
    "$STATE_DIR/rate.log" 2>/dev/null | wc -l | tr -d ' ')
  [ "$hits" -lt "$RATE_MAX_SAME_FIX" ]
}

record_fix() {
  echo "$1|$(now_epoch)" >> "$STATE_DIR/rate.log"
  # keep file from growing unbounded
  tail -200 "$STATE_DIR/rate.log" > "$STATE_DIR/rate.log.tmp" && \
    mv "$STATE_DIR/rate.log.tmp" "$STATE_DIR/rate.log"
}

# ── circuit breaker ────────────────────────────────────────────────
breaker_tripped() {
  [ -f "$BREAKER_FILE" ] && {
    local trip_time=$(cat "$BREAKER_FILE" 2>/dev/null || echo 0)
    local age=$(( $(now_epoch) - trip_time ))
    [ "$age" -lt "$BREAKER_WINDOW_SEC" ]
  }
}

record_failure() {
  echo "$(now_epoch)" >> "$STATE_DIR/failures.log"
  local cutoff=$(( $(now_epoch) - BREAKER_WINDOW_SEC ))
  awk -v c="$cutoff" '$1>=c' "$STATE_DIR/failures.log" > "$STATE_DIR/failures.log.tmp" && \
    mv "$STATE_DIR/failures.log.tmp" "$STATE_DIR/failures.log"
  local recent=$(wc -l < "$STATE_DIR/failures.log" | tr -d ' ')
  if [ "$recent" -ge "$BREAKER_MAX_FAILURES" ]; then
    now_epoch > "$BREAKER_FILE"
    log ALERT "CIRCUIT BREAKER TRIPPED: $recent failures in last hour. Pausing auto-fixes."
    slack_scream "fleet self-healer: circuit breaker tripped — $recent failures/hr. Manual review needed."
  fi
}

# ── slack alert ────────────────────────────────────────────────────
# Direct to slack.com (TLS 1.3 via macOS LibreSSL). Was using a socat
# proxy at :8444 which silently failed on a TLS version mismatch —
# meaning every prior alert was lost. Earned 2026-05-04.
# Re-earned 2026-06-09: the hardcoded channel ID belonged to the OLD
# bot's DM (token rotated 05-09), so chat.postMessage returned
# channel_not_found and the >/dev/null swallowed it — alerts lost
# AGAIN, same class. Channel now read from ~/.fleet/slack_channel
# (shared with audit_run.sh / tailscale_peer_check / slack_listener)
# and the API response is checked.
slack_scream() {
  local msg="$1"
  local token_path="${HOME}/.fleet/slack_token"
  local channel
  channel=$(cat "${HOME}/.fleet/slack_channel" 2>/dev/null | tr -d '[:space:]')
  [ -z "$channel" ] && { log WARN "no slack_channel; skip alert: $msg"; return; }
  [ -f "$token_path" ] || { log WARN "no slack token; skip alert: $msg"; return; }
  [ "$DRYRUN" = "1" ] && { log WARN "[DRYRUN] would slack: $msg"; return; }
  local bearer=$(cat "$token_path" 2>/dev/null | tr -d '\n')  # value read from file, never a literal (var named to satisfy leak-guard)
  [ -z "$bearer" ] && return
  local resp
  resp=$(curl -s --max-time 5 -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer $bearer" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "{\"channel\":\"$channel\",\"text\":\"🚨 $msg\"}" 2>&1)
  case "$resp" in
    *'"ok":true'*) : ;;
    *) log WARN "SLACK_ALERT_FAILED: $(printf '%s' "$resp" | head -c 160)" ;;
  esac
}

# ── the actual checks ──────────────────────────────────────────────
check_bridge_alias() {
  if ifconfig bridge0 2>/dev/null | grep -q "inet $EXPECTED_TB_ALIAS"; then
    event bridge_alias ok
    return 0
  fi
  log WARN "bridge0 missing $EXPECTED_TB_ALIAS alias"
  if can_fix "bridge_alias"; then
    if [ "$DRYRUN" = "1" ]; then
      log WARN "[DRYRUN] would: sudo ifconfig bridge0 alias $EXPECTED_TB_ALIAS netmask $EXPECTED_MASK"
      event bridge_alias broken dryrun
    else
      if sudo -n /sbin/ifconfig bridge0 alias "$EXPECTED_TB_ALIAS" netmask "$EXPECTED_MASK" 2>>"$LOG_FILE"; then
        record_fix "bridge_alias"
        log FIX "re-added bridge0 alias $EXPECTED_TB_ALIAS"
        event bridge_alias fixed add_alias
      else
        log ALERT "FAILED to re-add bridge0 alias (sudo denied or other)"
        event bridge_alias failed add_alias "sudo failure"
        record_failure
      fi
    fi
  else
    log WARN "rate-limited on bridge_alias fix; alert only"
    event bridge_alias rate_limited
    slack_scream "bridge0 alias $EXPECTED_TB_ALIAS keeps dropping — rate-limited fix. Manual: sudo ifconfig bridge0 alias $EXPECTED_TB_ALIAS netmask $EXPECTED_MASK"
  fi
}

# Find TB peer interfaces that are UP/active but NOT in bridge0.
# New peers (from freshly-connected TB cables) spawn new en<N> interfaces
# that macOS doesn't auto-bridge.
# Hardware-truth real TB-IP ports (AppleThunderboltIPPort children of a
# CONNECTED receptacle). Same derivation as tb_autojoin.sh. Used to gate
# check_bridge_members so it NEVER bridges USB4 ghost channels (en9-12) —
# doing so churns against tb_autojoin and risks an L2 loop (2026-06-22).
hw_real_ports() {
  local connected
  connected=$(system_profiler SPThunderboltDataType 2>/dev/null | LC_ALL=C awk '
    $1=="Status:" {st=$0}
    $1=="Receptacle:" {if (st ~ /Device connected/ && st !~ /No device/) print $2}')
  [ -z "$connected" ] && return 0
  ioreg -rc AppleThunderboltIPPort -l 2>/dev/null | LC_ALL=C awk '
    /AppleThunderboltIPPort / {inport=1; loc=""; next}
    inport && /"IOLocation"/ {s=$0; gsub(/[^0-9]/,"",s); loc=s; next}
    inport && /"BSD Name"/ {match($0,/en[0-9]+/); print loc, substr($0,RSTART,RLENGTH); inport=0}
  ' | while read -r loc bsd; do printf '%s\n' "$connected" | grep -qx "$loc" && printf '%s\n' "$bsd"; done | sort -u | tr '\n' ' '
}

check_bridge_members() {
  local bridge_members=$(ifconfig bridge0 2>/dev/null | awk '/member:/{print $2}')
  local orphans=()
  local real=" $(hw_real_ports) "   # space-padded set of real TB-IP ports
  # M4 Pro Mini: TB interfaces are en2-en12ish. We skip en0/en1 (ethernet/wifi).
  for n in 2 3 4 5 6 7 8 9 10 11 12; do
    local iface="en$n"
    ifconfig "$iface" 2>/dev/null | grep -q "RUNNING" || continue
    # Is it a TB-IP peer interface? Check by seeing if it has no IP of its own
    # (TB peer interfaces get bridged, not IP'd directly).
    # Heuristic: UP+RUNNING, no IPv4, not en0 (WiFi) / en1.
    local has_ip=$(ifconfig "$iface" 2>/dev/null | grep "inet " | grep -v "inet6" | wc -l | tr -d ' ')
    [ "$has_ip" = "0" ] || continue
    # Is it already a bridge member?
    echo "$bridge_members" | grep -qx "$iface" && continue
    # Is it "active" status (TB link up)?
    ifconfig "$iface" 2>/dev/null | grep -q "status: active" || continue
    # Only ever bridge REAL TB-IP ports — never USB4 ghost channels (en9-12).
    case "$real" in *" $iface "*) ;; *) continue ;; esac
    orphans+=("$iface")
  done
  if [ "${#orphans[@]}" -eq 0 ]; then
    event bridge_members ok
    return 0
  fi
  for iface in "${orphans[@]}"; do
    log WARN "TB peer $iface active but not in bridge0"
    local fix_key="bridge_addm_$iface"
    if can_fix "$fix_key"; then
      if [ "$DRYRUN" = "1" ]; then
        log WARN "[DRYRUN] would: sudo ifconfig bridge0 addm $iface"
        event bridge_members broken "dryrun_addm:$iface"
      else
        if sudo -n /sbin/ifconfig bridge0 addm "$iface" 2>>"$LOG_FILE"; then
          record_fix "$fix_key"
          log FIX "added $iface to bridge0"
          event bridge_members fixed "addm:$iface"
        else
          log ALERT "FAILED to addm $iface (sudo?)"
          event bridge_members failed "addm:$iface"
          record_failure
        fi
      fi
    else
      event bridge_members rate_limited "$iface"
    fi
  done
}

# Token file health — never reads/writes the token itself, only perms + size.
check_token_health() {
  if [ ! -f "$TOKEN_FILE" ]; then
    log ALERT "token file missing: $TOKEN_FILE"
    event token missing
    record_failure
    slack_scream "fleet token file missing on Mini — fleet will start failing requests"
    return 1
  fi
  local size=$(stat -f "%z" "$TOKEN_FILE" 2>/dev/null || echo 0)
  if [ "$size" -lt 16 ]; then
    log ALERT "token file suspiciously small ($size bytes) — possible empty-token bypass"
    event token too_small "$size"
    record_failure
    slack_scream "fleet token on Mini is $size bytes — auth bypass risk, rotate immediately"
    return 1
  fi
  local perms=$(stat -f "%Lp" "$TOKEN_FILE" 2>/dev/null || echo "???")
  if [ "$perms" != "600" ]; then
    log WARN "token file perms $perms != 600"
    if [ "$DRYRUN" = "1" ]; then
      log WARN "[DRYRUN] would: chmod 600 $TOKEN_FILE"
      event token perms_bad "dryrun:$perms"
    else
      if chmod 600 "$TOKEN_FILE" 2>>"$LOG_FILE"; then
        log FIX "chmod 600 token file (was $perms)"
        event token fixed "chmod_600:$perms"
      else
        event token failed "chmod:$perms"
        record_failure
      fi
    fi
  else
    event token ok
  fi
}

# Probe one node TB-first, then Tailscale. Echoes the path that answered
# ("tb"/"ts"); returns 1 if both are dark.
probe_node() {
  local token="$1" tb_ip="$2" ts_ip="$3" body
  body=$(curl -s --max-time 3 -H "X-Fleet-Token: $token" "http://$tb_ip:9101/health" 2>/dev/null)
  if echo "$body" | grep -q '"alive": true'; then echo tb; return 0; fi
  body=$(curl -s --max-time 3 -H "X-Fleet-Token: $token" "http://$ts_ip:9101/health" 2>/dev/null)
  if echo "$body" | grep -q '"alive": true'; then echo ts; return 0; fi
  return 1
}

# TB-degraded observers. "Present but TB dark" (answers via Tailscale only)
# is a real, alertable degradation; "absent" (both paths dark) is quiet — a
# sleeping laptop is not a fabric failure.
tb_degraded_observe() {  # name tb_ip
  local name="$1" tb_ip="$2" cf af c now last
  mkdir -p "$TB_DEGRADED_DIR" 2>/dev/null
  cf="${TB_DEGRADED_DIR}/${name}.count"; af="${TB_DEGRADED_DIR}/${name}.alerted"
  c=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 )); printf '%s' "$c" > "$cf"
  event tb_fabric degraded "${name}:${c}"
  [ "$c" -lt "$TB_DEGRADED_THRESHOLD" ] && return
  now=$(now_epoch); last=$(cat "$af" 2>/dev/null || echo 0)
  if [ $(( now - last )) -ge "$TB_REMIND_SEC" ]; then
    log ALERT "TB fabric degraded: $name on Tailscale only ($tb_ip dark, $c ticks)"
    slack_scream "fleet self-healer: TB fabric degraded — *$name* reachable only via Tailscale ($tb_ip dark) for $c checks. Check TB cable / bridge0 member / ~/.fleet/tb-members pin on $name (ioreg AppleThunderboltIPPort → receptacle finds the real port)."
    printf '%s' "$now" > "$af"
  fi
}
tb_degraded_clear() {  # name reason(recovered|absent)
  local name="$1" reason="${2:-recovered}" cf af
  cf="${TB_DEGRADED_DIR}/${name}.count"; af="${TB_DEGRADED_DIR}/${name}.alerted"
  if [ "$reason" = "recovered" ] && [ -f "$af" ]; then
    log FIX "TB fabric recovered: $name back on direct Thunderbolt"
    slack_scream "fleet self-healer: TB fabric recovered — *$name* back on direct Thunderbolt. ✓"
  fi
  rm -f "$cf" "$af" 2>/dev/null
}

# Fleet HTTP reachability with current token. Alert-only — never restarts agents.
check_fleet_reach() {
  local token=$(cat "$TOKEN_FILE" 2>/dev/null | tr -d '\n')
  [ -z "$token" ] && return
  local missed=()
  for entry in "${FLEET_NODES[@]}"; do
    local name tb_ip ts_ip path
    IFS=: read -r name tb_ip ts_ip <<< "$entry"
    if path=$(probe_node "$token" "$tb_ip" "$ts_ip"); then
      event fleet_reach ok "$name:$path"
      if [ "$path" = "ts" ]; then
        log WARN "fleet $name on tailscale fallback — TB fabric degraded ($tb_ip dark)"
        tb_degraded_observe "$name" "$tb_ip"
      else
        tb_degraded_clear "$name" recovered
      fi
    else
      missed+=("$name")
      log WARN "fleet unreachable: $name (tb=$tb_ip ts=$ts_ip)"
      event fleet_reach unreachable "$name"
      tb_degraded_clear "$name" absent
    fi
  done
  # Best-effort nodes: observe only, never count toward alerts.
  for entry in "${FLEET_NODES_BESTEFFORT[@]}"; do
    local name tb_ip ts_ip path
    IFS=: read -r name tb_ip ts_ip <<< "$entry"
    if path=$(probe_node "$token" "$tb_ip" "$ts_ip"); then
      event fleet_reach ok "$name:$path"
      if [ "$path" = "ts" ]; then
        # Present (answering) but TB dark = real degradation, worth a scream.
        log WARN "best-effort $name present but TB dark — degraded ($tb_ip)"
        tb_degraded_observe "$name" "$tb_ip"
      else
        tb_degraded_clear "$name" recovered
      fi
    else
      # Both paths dark = asleep/absent. Normal for a laptop; stay quiet.
      event fleet_reach besteffort_down "$name"
      tb_degraded_clear "$name" absent
    fi
  done
  if [ "${#missed[@]}" -ge 2 ]; then
    # ≥2 down = probably a real problem (single-node flap is ok)
    log ALERT "multiple fleet nodes unreachable: ${missed[*]}"
    record_failure
    slack_scream "fleet self-healer: nodes down — ${missed[*]}"
  fi
}

# WAN — alert-only; auto-fixing WAN is a service-order GUI thing.
check_wan() {
  local code=$(curl -s --max-time 3 -o /dev/null -w "%{http_code}" https://1.1.1.1/ 2>/dev/null)
  if [ "$code" = "000" ] || [ -z "$code" ]; then
    log WARN "WAN unreachable (curl https://1.1.1.1/ → '$code')"
    event wan down "$code"
    # Only scream if it's been down for >3 consecutive checks
    local consecutive=$(tail -20 "$EVENTS_FILE" | grep '"check":"wan"' | \
      tail -3 | grep -c '"status":"down"')
    if [ "$consecutive" -ge 3 ]; then
      log ALERT "WAN down for 3+ consecutive checks"
      record_failure
      slack_scream "fleet self-healer: Mini WAN down for 3+ min. Check WiFi / service order / router."
    fi
  else
    event wan ok "$code"
  fi
}

# Fleet agent process alive? LaunchAgent KeepAlive handles restart, but we alert
# if it's missing for several ticks.
check_fleet_agent() {
  if launchctl list 2>/dev/null | grep -q com.ledatic.fleet; then
    event fleet_agent ok
  else
    log ALERT "com.ledatic.fleet LaunchAgent not found"
    event fleet_agent missing
    record_failure
    slack_scream "fleet agent LaunchAgent missing on Mini"
  fi
}

# ── attest-surface content liveness (added 2026-05-04) ─────────────
# Catches the failure mode where a service is "active" per systemd /
# launchd but is producing no output (the bash glob crashloop that
# silenced fleet0 for 80 h is the canonical example). Three surfaces:
#   - /entropy/pulse  — beacon advancing every ~2 s? (Mini com.ledatic.mhd)
#   - /witness/fleet0/latest  — Pi witness signing within 5 min?
#   - /builds/latest  — daily attest cron landed in the last 36 h?
#
# Alert-only (no auto-fix). Uses the same "3 consecutive checks" pattern
# as check_wan to avoid flapping on transient blips.
check_attest_surfaces() {
  local now_ep=$(now_epoch)

  # /entropy/pulse — alert if pulse_id same across 3 consecutive ticks
  local p_now
  p_now=$(curl -s --max-time 4 https://ledatic.org/entropy/pulse 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("pulse_id",""))' 2>/dev/null)
  if [ -z "$p_now" ]; then
    event beacon unreachable
    log WARN "/entropy/pulse unreachable"
  else
    local last_p
    last_p=$(grep '"check":"beacon"' "$EVENTS_FILE" | tail -1 | \
      python3 -c 'import sys,json; line=sys.stdin.read().strip(); d=json.loads(line) if line else {}; print(d.get("detail","")[:32])' 2>/dev/null || echo "")
    if [ "$p_now" = "$last_p" ]; then
      log WARN "/entropy/pulse stale: pulse_id $p_now hasn't moved since last tick"
      event beacon stale "$p_now"
      local consecutive=$(grep '"check":"beacon"' "$EVENTS_FILE" | tail -3 | grep -c '"status":"stale"')
      if [ "$consecutive" -ge 3 ]; then
        log ALERT "beacon stalled — pulse $p_now for 3+ ticks (~5 min)"
        record_failure
        slack_scream "fleet self-healer: entropy beacon stalled at pulse $p_now for 5 min. Check com.ledatic.mhd."
      fi
    else
      event beacon ok "$p_now"
    fi
  fi

  # /witness/fleet0/latest — alert if witnessed_at is > 5 min ago
  local w_at
  w_at=$(curl -s --max-time 4 https://ledatic.org/witness/fleet0/latest 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("witnessed_at",""))' 2>/dev/null)
  if [ -z "$w_at" ]; then
    event witness unreachable
    log WARN "/witness/fleet0/latest unreachable"
  else
    local age=$((now_ep - w_at))
    if [ "$age" -gt 300 ]; then
      log WARN "witness silent for ${age}s (witnessed_at $(date -u -r $w_at +%FT%TZ 2>/dev/null))"
      event witness silent "$age"
      # 2 ticks (~3 min) at >5min silence = real problem
      local consecutive=$(grep '"check":"witness"' "$EVENTS_FILE" | tail -3 | grep -c '"status":"silent"')
      if [ "$consecutive" -ge 2 ]; then
        log ALERT "witness chain silent — last sig ${age}s ago"
        record_failure
        slack_scream "fleet self-healer: fleet0 witness chain silent for $((age / 60)) min. Check witness.service on Pi."
      fi
    else
      event witness ok "$age"
    fi
  fi

  # /builds/latest — alert if updated_utc is > 36 h ago. Single check
  # (no flapping concern, daily cron only runs once/day).
  local b_age
  b_age=$(curl -s --max-time 4 https://ledatic.org/builds/latest/index.json 2>/dev/null \
    | python3 -c "
import sys, json, datetime as dt
try:
    d = json.load(sys.stdin)
    u = d['updated_utc'].rstrip('Z')
    ep = int(dt.datetime.fromisoformat(u).replace(tzinfo=dt.timezone.utc).timestamp())
    print(int(dt.datetime.now(dt.timezone.utc).timestamp()) - ep)
except Exception:
    pass
" 2>/dev/null)
  if [ -z "$b_age" ]; then
    event build unreachable
  elif [ "$b_age" -gt 129600 ]; then   # 36h = 129600s
    local h=$((b_age / 3600))
    log WARN "/builds/latest is ${h}h old"
    event build stale "$b_age"
    # alert once per breaker window — don't spam every 90s
    if can_fix "build_stale_alert"; then
      record_fix "build_stale_alert"
      slack_scream "fleet self-healer: /builds/latest is ${h}h old (>36h threshold). Check com.ledatic.attest_daily cron."
    fi
  else
    event build ok "$b_age"
  fi
}

# Reboot-persistence daemons
check_launch_daemons() {
  local missing=()
  for plist in \
    "/Library/LaunchDaemons/com.ledatic.tb-alias.plist" \
    "/Library/LaunchDaemons/com.ledatic.fleet.plist"; do
    # Only alias daemon is mandatory on Mini; fleet plist is a LaunchAgent
    [ "$plist" = "/Library/LaunchDaemons/com.ledatic.fleet.plist" ] && continue
    if [ ! -f "$plist" ]; then
      missing+=("$plist")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log WARN "missing LaunchDaemons: ${missing[*]}"
    event daemons missing "${missing[*]}"
  else
    event daemons ok
  fi
}

# ── single-pass orchestrator ───────────────────────────────────────
# ── log rotation (added 2026-06-22) ─────────────────────────────────────────
# events.jsonl / heal.log / stdout.log had NO cap and grew unbounded (events
# hit 66 MB / 697k lines). Each pass, trim any oversized log to its keep-tail.
# event()/log() use >> (reopen per write), so an mv between writes is safe.
cap_log() {  # path maxlines keeplines
  local f="$1" maxl="$2" keepl="$3" n
  [ -f "$f" ] || return 0
  n=$(wc -l < "$f" 2>/dev/null | tr -d ' '); [ -z "$n" ] && return 0
  if [ "$n" -gt "$maxl" ]; then
    tail -n "$keepl" "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
  fi
}
rotate_logs() {
  cap_log "$EVENTS_FILE"          50000 20000
  cap_log "$LOG_FILE"             20000  8000
  cap_log "$STATE_DIR/stdout.log" 20000  8000
  cap_log "$STATE_DIR/stderr.log"  5000  2000
}

run_pass() {
  now_epoch > "$HEARTBEAT_FILE"
  rotate_logs
  # Breaker state is informational — fixes still run because the rate limiter
  # already prevents hammering per-fix. The bug we hit: old logic skipped
  # bridge_alias fix while breaker was tripped, which is the ONE fix that
  # un-breaks the fleet_reach failures that caused the breaker in the first
  # place. Cascading deadlock. Now breaker only escalates alerts.
  if breaker_tripped; then
    log WARN "circuit breaker tripped — continuing fixes (rate-limited), alert escalation active"
    event pass breaker_tripped continuing
  fi
  check_token_health
  check_bridge_alias
  check_bridge_members
  check_wan
  check_fleet_reach
  check_fleet_agent
  check_launch_daemons
  check_attest_surfaces
}

# ── subcommands ────────────────────────────────────────────────────
cmd_status() {
  echo "=== Fleet Self-Healer Status ==="
  if [ -f "$HEARTBEAT_FILE" ]; then
    local hb=$(cat "$HEARTBEAT_FILE")
    local age=$(( $(now_epoch) - hb ))
    printf "Last heartbeat: %ss ago (%s)\n" "$age" "$(date -r "$hb" 2>/dev/null)"
  else
    echo "Last heartbeat: NEVER"
  fi
  if breaker_tripped; then
    printf "%sCircuit breaker: TRIPPED%s\n" "$C_RED" "$C_RST"
  else
    printf "%sCircuit breaker: armed%s\n" "$C_GRN" "$C_RST"
  fi
  local recent_fail=0
  [ -f "$STATE_DIR/failures.log" ] && recent_fail=$(wc -l < "$STATE_DIR/failures.log" | tr -d ' ')
  printf "Failures (last hour): %s\n" "$recent_fail"
  echo
  echo "=== Last 10 events ==="
  tail -10 "$EVENTS_FILE" 2>/dev/null | while IFS= read -r line; do
    local t=$(echo "$line" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['t'])" 2>/dev/null)
    local c=$(echo "$line" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['check'])" 2>/dev/null)
    local s=$(echo "$line" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['status'])" 2>/dev/null)
    local a=$(echo "$line" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['action'])" 2>/dev/null)
    case "$s" in
      ok)         printf "  %s %s%-18s%s %s %s\n" "$t" "$C_GRN" "$c" "$C_RST" "$s" "$a" ;;
      fixed)      printf "  %s %s%-18s%s %s %s\n" "$t" "$C_BLU" "$c" "$C_RST" "$s" "$a" ;;
      broken|unreachable|down) printf "  %s %s%-18s%s %s %s\n" "$t" "$C_YLW" "$c" "$C_RST" "$s" "$a" ;;
      failed|missing)          printf "  %s %s%-18s%s %s %s\n" "$t" "$C_RED" "$c" "$C_RST" "$s" "$a" ;;
      *) printf "  %s %-18s %s %s\n" "$t" "$c" "$s" "$a" ;;
    esac
  done
}

cmd_test() {
  SELF_HEALER_DRYRUN=1 DRYRUN=1 run_pass
}

cmd_events() {
  local n="${1:-20}"
  tail -"$n" "$EVENTS_FILE" 2>/dev/null
}

cmd_reset() {
  rm -f "$BREAKER_FILE" "$STATE_DIR/failures.log" "$STATE_DIR/rate.log"
  echo "Reset: circuit breaker + rate limits cleared"
}

cmd_loop() {
  while true; do
    run_pass
    sleep 90
  done
}

case "$CMD" in
  run)    run_pass ;;
  loop)   cmd_loop ;;
  status) cmd_status ;;
  test)   cmd_test ;;
  events) shift; cmd_events "$@" ;;
  reset)  cmd_reset ;;
  *) echo "Usage: $0 {run|loop|status|test|events [N]|reset}"; exit 2 ;;
esac
