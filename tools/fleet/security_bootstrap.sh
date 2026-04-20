#!/bin/bash
# security_bootstrap.sh — one-shot security hardening for a fleet node.
#
# Run once per node (Mini, Studio, Air). Requires sudo.
#
#   sudo bash tools/fleet/security_bootstrap.sh
#
# What it does (all idempotent):
#   1. Install /etc/pf.anchors/ledatic_fleet with the fleet control-plane
#      firewall rules (fleet :9101 + TLS proxies 8443-8445 restricted to
#      loopback/TB/Tailscale).
#   2. Ensure /etc/pf.conf loads that anchor.
#   3. Reload pf and enable it.
#   4. Disable SSH password auth (key-only).  Only touches sshd_config if
#      the directive wasn't already set correctly.  Restarts sshd.
#
# Exit non-zero on any failure.  Safe to re-run.

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Must run as root (sudo)." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# v2 anchor adds IPv6 rules; fall back to v1 if v2 isn't in the tree yet.
if [ -f "$REPO_ROOT/tools/fleet/pf_ledatic_fleet.v2.conf" ]; then
  ANCHOR_SRC="$REPO_ROOT/tools/fleet/pf_ledatic_fleet.v2.conf"
else
  ANCHOR_SRC="$REPO_ROOT/tools/fleet/pf_ledatic_fleet.conf"
fi
ANCHOR_DST="/etc/pf.anchors/ledatic_fleet"

if [ ! -f "$ANCHOR_SRC" ]; then
  echo "anchor source missing: $ANCHOR_SRC" >&2
  exit 1
fi

# ── 1. Install pf anchor ────────────────────────────────────────────────
install -m 0644 -o root -g wheel "$ANCHOR_SRC" "$ANCHOR_DST"
echo "installed $ANCHOR_DST"

# ── 2. Ensure /etc/pf.conf loads the anchor ─────────────────────────────
if ! grep -q '^anchor "ledatic_fleet"' /etc/pf.conf; then
  cat >> /etc/pf.conf <<'EOF'

# Fleet control-plane firewall (loaded from tools/fleet/pf_ledatic_fleet.conf)
anchor "ledatic_fleet"
load anchor "ledatic_fleet" from "/etc/pf.anchors/ledatic_fleet"
EOF
  echo "wired anchor into /etc/pf.conf"
else
  echo "anchor already wired into /etc/pf.conf"
fi

# ── 3. Reload + enable pf ───────────────────────────────────────────────
pfctl -f /etc/pf.conf 2>&1 | sed 's/^/pf: /'
if ! pfctl -s info 2>/dev/null | grep -q "Status: Enabled"; then
  pfctl -e 2>&1 | sed 's/^/pf: /'
else
  echo "pf: already enabled"
fi

# ── 4. SSH key-only ──────────────────────────────────────────────────────
# Preflight: refuse to disable password auth unless at least one user on
# this box has an authorized_keys file with a non-empty public key.
# Without this, turning off PasswordAuthentication locks everyone out.
HAS_KEYS=0
for home in /Users/*; do
  user=$(basename "$home")
  case "$user" in Shared|Guest) continue ;; esac
  ak="$home/.ssh/authorized_keys"
  if [ -s "$ak" ]; then
    # Actually contains something that looks like a key (ssh-*/ecdsa-*/sk-*)
    if grep -qE '^(ssh-|ecdsa-|sk-)' "$ak" 2>/dev/null; then
      HAS_KEYS=1
      echo "sshd: authorized_keys found for $user"
    fi
  fi
done
if [ "$HAS_KEYS" -eq 0 ]; then
  echo "ERR: no user has a valid authorized_keys — refusing to disable password auth" >&2
  echo "     install a public key in ~/.ssh/authorized_keys (chmod 600) and re-run." >&2
  exit 2
fi

SSHD_CONFIG=/etc/ssh/sshd_config
CHANGED_SSHD=0

set_directive() {
  local key="$1" val="$2"
  if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+" "$SSHD_CONFIG"; then
    local current
    current=$(grep -E "^[[:space:]]*${key}[[:space:]]+" "$SSHD_CONFIG" | head -1 | awk '{print $2}' || true)
    if [ "$current" != "$val" ]; then
      # macOS sed needs an empty backup arg
      sed -i '' -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+.*|${key} ${val}|" "$SSHD_CONFIG"
      CHANGED_SSHD=1
      echo "sshd: set ${key} ${val}"
    else
      echo "sshd: ${key} already ${val}"
    fi
  else
    echo "${key} ${val}" >> "$SSHD_CONFIG"
    CHANGED_SSHD=1
    echo "sshd: added ${key} ${val}"
  fi
}

set_directive PasswordAuthentication no
set_directive ChallengeResponseAuthentication no
set_directive KbdInteractiveAuthentication no
set_directive PermitRootLogin no

if [ "$CHANGED_SSHD" -eq 1 ]; then
  # Validate before restart — a broken sshd_config locks you out of the box
  if sshd -t -f "$SSHD_CONFIG"; then
    launchctl kickstart -k system/com.openssh.sshd
    echo "sshd: restarted"
  else
    echo "sshd: config INVALID — aborting restart to preserve access" >&2
    exit 1
  fi
fi

echo "security_bootstrap: OK"
