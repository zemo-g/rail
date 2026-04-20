#!/bin/bash
# tb_autojoin.sh — walk-away Thunderbolt Bridge reconciler.
#
# Runs as root under launchd every 30 s (com.ledatic.tb_autojoin).
# Plug a cable → fabric self-joins.  Unplug → stub is cleaned.
# No interactive steps, no Rail dependency.
#
# Per-pass log at /var/log/tb_autojoin.log (one line per enN with verdict
# + one summary line).  launchctl captures any accidental stderr to
# /var/log/tb_autojoin.launchd.err.
#
# Opt out: rm ~/.fleet/tb-ip  — next pass logs and exits without touching
# anything.

set -u

LOG="/var/log/tb_autojoin.log"
LOG_MAX=1048576                  # 1 MiB
TB_IP_FILE="/Users/ledaticempire/.fleet/tb-ip"

# ── Rotate log if oversized ─────────────────────────────────────────────────
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt "$LOG_MAX" ]; then
  mv -f "$LOG" "${LOG}.prev"
fi

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '%s %s\n' "$(ts)" "$*" >> "$LOG"; }

# ── Read desired IP ─────────────────────────────────────────────────────────
TB_IP=$(cat "$TB_IP_FILE" 2>/dev/null | tr -d '[:space:]')
if [ -z "$TB_IP" ]; then
  log "no-ip-configured skip"
  exit 0
fi

# ── Classify candidate interfaces ───────────────────────────────────────────
# Real TB peer:
#   flags include UP, RUNNING, PROMISC
#   AND media is `autoselect` OR (media is `none` AND options contain CHANNEL_IO)
# Skip en0/en1 (Wi-Fi / built-in).
real_peers=""
for iface in $(ifconfig -l | tr ' ' '\n' | grep -E '^en[0-9]+$'); do
  case "$iface" in
    en0|en1) continue ;;
  esac
  info=$(ifconfig "$iface" 2>/dev/null)
  [ -z "$info" ] && continue

  flags_line=$(printf '%s' "$info" | grep -E '^[[:space:]]*flags=' | head -1)
  case "$flags_line" in
    *UP*RUNNING*PROMISC*|*PROMISC*UP*RUNNING*|*UP*PROMISC*RUNNING*|*RUNNING*UP*PROMISC*|*RUNNING*PROMISC*UP*|*PROMISC*RUNNING*UP*) ;;
    *) log "$iface stub reason=flags"; continue ;;
  esac

  media=$(printf '%s' "$info" | awk '/^[[:space:]]*media:/ {print $2; exit}')
  options=$(printf '%s' "$info" | awk '/^[[:space:]]*options=/ {print $0; exit}')

  case "$media" in
    autoselect)
      real_peers="$real_peers $iface"
      log "$iface real reason=media-autoselect"
      ;;
    none)
      case "$options" in
        *CHANNEL_IO*)
          real_peers="$real_peers $iface"
          log "$iface real reason=media-none+channel_io"
          ;;
        *)
          log "$iface stub reason=media-none-no-channel_io"
          ;;
      esac
      ;;
    *)
      log "$iface stub reason=media-$media"
      ;;
  esac
done
real_peers=$(printf '%s' "$real_peers" | awk '{$1=$1};1')

# ── Snapshot current bridge0 members ────────────────────────────────────────
if ifconfig bridge0 >/dev/null 2>&1; then
  members=$(ifconfig bridge0 | awk '/^[[:space:]]*member:/ {print $2}' | tr '\n' ' ')
  bridge_exists=1
else
  members=""
  bridge_exists=0
fi

# ── Ensure bridge0 exists ───────────────────────────────────────────────────
if [ "$bridge_exists" -eq 0 ]; then
  if ifconfig bridge0 create >/dev/null 2>&1; then
    log "bridge0 created"
  else
    log "bridge0 create failed — abort"
    exit 1
  fi
fi

# ── Ensure IP on bridge0 (only set if it doesn't already match) ─────────────
current_ip=$(ifconfig bridge0 2>/dev/null | awk '/inet / {print $2; exit}')
if [ "$current_ip" != "$TB_IP" ]; then
  ifconfig bridge0 inet "$TB_IP" netmask 255.255.255.0 up >/dev/null 2>&1
  log "bridge0 ip set current=$current_ip desired=$TB_IP"
fi

# ── Add missing real peers ──────────────────────────────────────────────────
added=""
for peer in $real_peers; do
  case " $members " in
    *" $peer "*) ;;
    *) if ifconfig bridge0 addm "$peer" >/dev/null 2>&1; then
         added="$added $peer"
       fi
       ;;
  esac
done
added=$(printf '%s' "$added" | awk '{$1=$1};1')

# ── Remove stale members ────────────────────────────────────────────────────
removed=""
for m in $members; do
  case " $real_peers " in
    *" $m "*) ;;
    *) if ifconfig bridge0 deletem "$m" >/dev/null 2>&1; then
         removed="$removed $m"
       fi
       ;;
  esac
done
removed=$(printf '%s' "$removed" | awk '{$1=$1};1')

# ── Unstick TB Bridge service if bridge0 is inactive AND we have peers ──────
status=$(ifconfig bridge0 2>/dev/null | awk '/^[[:space:]]*status:/ {print $2; exit}')
if [ -n "$real_peers" ] && [ "$status" != "active" ]; then
  log "bridge0 inactive with peers — toggling Thunderbolt Bridge service"
  networksetup -setnetworkserviceenabled "Thunderbolt Bridge" off >/dev/null 2>&1
  networksetup -setnetworkserviceenabled "Thunderbolt Bridge" on  >/dev/null 2>&1
fi

# ── Summary ─────────────────────────────────────────────────────────────────
log "pass ip=$TB_IP peers=[$real_peers] added=[$added] removed=[$removed] status=${status:-none}"
exit 0
