#!/bin/bash
# rotate_fleet_token.sh — atomic-ish fleet token rotation across all nodes.
#
# Run from the coordinating node:
#   bash tools/fleet/rotate_fleet_token.sh
#
# Flow:
#   1. Generate new 64-hex token.
#   2. Stamp the local ~/.fleet/token (backup prior).
#   3. ssh-push to each remote node (one at a time).  After each push,
#      hit that node's /health with the new token.  On failure, roll
#      back using the backup.
#   4. Print before/after MD5 fingerprints so humans can sanity-check.
#
# Node list: $FLEET_NODES_FILE (default ~/.config/fleet_nodes), one node
# per line in the format  name:ssh_target:ip
#   - name        label used in output
#   - ssh_target  "localhost" for the local node, else user@host for ssh
#   - ip          address the node's fleet agent answers /health on
#
# Example file (RFC 5737 documentation addresses — replace with yours):
#   local:localhost:192.0.2.1
#   node1:user@node1.example:192.0.2.2
#   witness:user@witness.example:192.0.2.3
#
# Requires: passwordless ssh to every remote node.  No sudo needed (the
# token file lives under the user's home).

set -euo pipefail

FLEET_NODES_FILE="${FLEET_NODES_FILE:-$HOME/.config/fleet_nodes}"
if [ ! -s "$FLEET_NODES_FILE" ]; then
  echo "no node list at $FLEET_NODES_FILE" >&2
  echo "write one 'name:ssh_target:ip' entry per line, e.g.:" >&2
  echo "  local:localhost:192.0.2.1" >&2
  echo "  node1:user@node1.example:192.0.2.2" >&2
  exit 2
fi

# Agent port — set FLEET_PORT, or let it default to the same ~/.fleet/port
# file the fleet agent itself reads.
FLEET_PORT="${FLEET_PORT:-$(cat "$HOME/.fleet/port" 2>/dev/null || true)}"
if [ -z "$FLEET_PORT" ]; then
  echo "set FLEET_PORT (or write the agent port to ~/.fleet/port)" >&2
  exit 2
fi

NODES=()
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  NODES+=("$line")
done < "$FLEET_NODES_FILE"

NEW_TOKEN=$(openssl rand -hex 32)
NEW_MD5=$(printf '%s' "$NEW_TOKEN" | md5 -q 2>/dev/null || printf '%s' "$NEW_TOKEN" | md5sum | awk '{print $1}')

echo "=== fleet token rotation ==="
echo "new token md5: $NEW_MD5"
echo
printf "Confirm rotation across %d nodes? [y/N] " "${#NODES[@]}"
read -r ans
case "$ans" in y|Y|yes) ;; *) echo "aborted"; exit 0 ;; esac

ROLLBACK=()

rollback() {
  echo "ROLLBACK in progress…"
  for step in "${ROLLBACK[@]}"; do
    echo "rollback: $step"
    eval "$step" || true
  done
  exit 1
}

stamp_and_verify() {
  local name="$1" ssh_target="$2" ping_ip="$3"
  echo
  echo "--- $name ---"

  local backup_cmd="cp ~/.fleet/token ~/.fleet/token.prerotate && chmod 600 ~/.fleet/token.prerotate"
  local stamp_cmd="printf '%s' '$NEW_TOKEN' > ~/.fleet/token && chmod 600 ~/.fleet/token"
  local restore_cmd="mv -f ~/.fleet/token.prerotate ~/.fleet/token"

  if [ "$ssh_target" = "localhost" ]; then
    eval "$backup_cmd"
    eval "$stamp_cmd"
    ROLLBACK=("$restore_cmd" "${ROLLBACK[@]}")
  else
    ssh "$ssh_target" "$backup_cmd && $stamp_cmd" || { echo "$name: ssh stamp failed"; rollback; }
    ROLLBACK=("ssh $ssh_target '$restore_cmd'" "${ROLLBACK[@]}")
  fi

  # Health check with new token, from the coordinating node.
  local health
  health=$(curl -sm 5 -H "X-Fleet-Token: $NEW_TOKEN" "http://$ping_ip:$FLEET_PORT/health" || echo FAIL)
  case "$health" in
    *'"ok"'*|*'OK'*|*'healthy'*)
      echo "$name: health OK"
      ;;
    *)
      echo "$name: health check failed — response: $health"
      rollback
      ;;
  esac
}

for entry in "${NODES[@]}"; do
  IFS=':' read -r name ssh_t ip <<< "$entry"
  stamp_and_verify "$name" "$ssh_t" "$ip"
done

echo
echo "=== rotation complete ==="
echo "new token md5: $NEW_MD5"
echo "backup tokens at each node's ~/.fleet/token.prerotate (clean up after 7d)"
