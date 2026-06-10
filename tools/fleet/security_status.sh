#!/bin/bash
# security_status.sh — one-screen security posture check for the fleet.
# Read-only.  Run from the coordinating node.
#
#   bash tools/fleet/security_status.sh
#
# Edit NODES below for your fleet: the first entry is always the local
# machine; the rest are `name:ssh-target` pairs for each remote node.

set -u

NODES=(
  "local:localhost"
  "node-1:<peer-user>@<peer-host>"
  "node-2:<peer-user>@<peer-host>"
  # "witness:<witness-user>@<witness-host>"   # witness node has no pf / different surface; skipped
)

hr() { printf '%s\n' "────────────────────────────────────────────────────────"; }

run_local() {
  echo "─── LOCAL ───"
  printf 'pf status:  '; sudo pfctl -s info 2>/dev/null | awk -F': +' '/Status/ {print $2; exit}'
  printf 'pf rules:   '; sudo pfctl -s rules 2>/dev/null | grep -c 9101
  echo "  (lines mentioning port 9101)"
  printf 'sshd pw:    '; grep -E "^PasswordAuthentication " /etc/ssh/sshd_config 2>/dev/null | head -1
  printf 'token age:  '; stat -f "%Sm" "$HOME/.fleet/token" 2>/dev/null
  printf 'log perms:  '; stat -f "%Sp %N" /var/log/tb_autojoin.log 2>/dev/null
  printf 'tailnet:    '; tailscale status 2>/dev/null | awk 'NR>1' | wc -l | tr -d ' '; echo ' peers'
}

run_remote() {
  local name="$1" t="$2"
  echo "─── $(printf '%-6s' "$name" | tr '[:lower:]' '[:upper:]') ───"
  ssh -o ConnectTimeout=3 "$t" '
    printf "pf status:  "; sudo -n pfctl -s info 2>/dev/null | awk -F": +" "/Status/ {print \$2; exit}" || echo "(needs sudo password)"
    printf "pf rules:   "; sudo -n pfctl -s rules 2>/dev/null | grep -c 9101 || echo "(needs sudo password)"
    printf "sshd pw:    "; grep -E "^PasswordAuthentication " /etc/ssh/sshd_config 2>/dev/null | head -1
    printf "token age:  "; stat -f "%Sm" ~/.fleet/token 2>/dev/null
    printf "log perms:  "; stat -f "%Sp %N" /var/log/tb_autojoin.log 2>/dev/null
  ' 2>&1 | head -10
}

echo "╔══════════════════════════════════════════════════════╗"
echo "║  LEDATIC FLEET — security status  $(date -u +%Y-%m-%dT%H:%MZ)  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo

run_local
echo

for entry in "${NODES[@]:1}"; do
  IFS=':' read -r name t <<< "$entry"
  run_remote "$name" "$t"
  echo
done

hr
echo "CF token scope:"
bash "$(dirname "$0")/../deploy/audit_cf_token.sh" 2>&1 | sed -n '/permissions:/,/Recommendation/p' | head -20 || echo "(audit_cf_token.sh not available)"
echo
hr
echo "Verify each of the above shows:"
echo "  pf status:  Enabled"
echo "  pf rules:   4+  (inet block + 3 passes, +inet6 same after T1)"
echo "  sshd pw:    PasswordAuthentication no"
echo "  log perms:  -rw-------"
