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
# Resolve the per-node tb-ip file.  launchd runs us as root, so a bare ~
# would be /var/root — and a *quoted* tilde never expands at all (the bug
# that dead-skipped every pass 2026-04-19 → 2026-06-10).  Search root's
# home first, then the console users' homes.
TB_IP_FILE=""
for f in /var/root/.fleet/tb-ip /Users/*/.fleet/tb-ip; do
  [ -f "$f" ] && TB_IP_FILE="$f" && break
done

# ── Rotate log if oversized ─────────────────────────────────────────────────
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt "$LOG_MAX" ]; then
  mv -f "$LOG" "${LOG}.prev"
fi

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() {
  printf '%s %s\n' "$(ts)" "$*" >> "$LOG"
  # Tighten perms on first write — world-readable logs leak fleet topology.
  chmod 600 "$LOG" 2>/dev/null || true
}

# ── Read desired IP ─────────────────────────────────────────────────────────
TB_IP=$(cat "$TB_IP_FILE" 2>/dev/null | tr -d '[:space:]')
if [ -z "$TB_IP" ]; then
  log "no-ip-configured skip"
  exit 0
fi

# ── Classify candidate interfaces ───────────────────────────────────────────
# Real TB peer:
#   flags include UP and RUNNING (PROMISC is set *by* bridge addition —
#   requiring it up front creates a chicken-and-egg that blocks first join)
#   AND media is `autoselect` OR (media is `none` AND options contain CHANNEL_IO)
# Skip en0/en1 (Wi-Fi / built-in).
real_peers=""
for iface in $(ifconfig -l | tr ' ' '\n' | grep -E '^en[0-9]+$'); do
  case "$iface" in
    en0|en1) continue ;;
  esac
  info=$(ifconfig "$iface" 2>/dev/null)
  [ -z "$info" ] && continue

  flags_line=$(printf '%s' "$info" | grep 'flags=' | head -1)
  case "$flags_line" in
    *UP*RUNNING*|*RUNNING*UP*) ;;
    *) log "$iface stub reason=flags"; continue ;;
  esac

  media=$(printf '%s' "$info" | awk '/^[[:space:]]*media:/ {print $2; exit}')
  options=$(printf '%s' "$info" | awk '/^[[:space:]]*options=/ {print $0; exit}')
  status=$(printf '%s' "$info" | awk '/^[[:space:]]*status:/ {print $2; exit}')

  # Reject if explicit status: inactive — TB stubs from prior peers can
  # linger as UP+RUNNING+CHANNEL_IO with media=none but no live link.
  if [ "$status" = "inactive" ]; then
    log "$iface stub reason=status-inactive"
    continue
  fi

  # CHANNEL_IO is the authoritative signal for a TB-fabric interface.
  # macOS reports the media either as `autoselect`, `100baseTX`, or `none`
  # across different driver versions / Apple Silicon combos, so gating on
  # media alone mis-classifies real peers as stubs.  USB-C Ethernet dongles
  # never set CHANNEL_IO — that's our safe discriminator.
  case "$options" in
    *CHANNEL_IO*)
      real_peers="$real_peers $iface"
      log "$iface real reason=channel_io media=$media"
      ;;
    *)
      log "$iface stub reason=no-channel_io media=$media"
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

# ── Unstick TB Bridge service if bridge0 is inactive ────────────────────────
# Rate-limited via a touchfile to avoid thrashing on genuinely unplugged
# nodes.  Only toggle once every 5 minutes.
status=$(ifconfig bridge0 2>/dev/null | awk '/^[[:space:]]*status:/ {print $2; exit}')
TOGGLE_STAMP="/var/run/tb_autojoin.last_toggle"
if [ "$status" != "active" ]; then
  now=$(date +%s)
  last=$(stat -f%m "$TOGGLE_STAMP" 2>/dev/null || echo 0)
  if [ $((now - last)) -ge 300 ]; then
    log "bridge0 inactive — toggling Thunderbolt Bridge service (last=${last})"
    networksetup -setnetworkserviceenabled "Thunderbolt Bridge" off >/dev/null 2>&1
    sleep 1
    networksetup -setnetworkserviceenabled "Thunderbolt Bridge" on  >/dev/null 2>&1
    touch "$TOGGLE_STAMP" 2>/dev/null
  else
    log "bridge0 inactive — toggle rate-limited ($((now - last))s since last)"
  fi
fi

# ── Summary ─────────────────────────────────────────────────────────────────
log "pass ip=$TB_IP peers=[$real_peers] added=[$added] removed=[$removed] status=${status:-none}"
exit 0
