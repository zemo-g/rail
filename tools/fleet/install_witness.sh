#!/usr/bin/env bash
# install_witness.sh — idempotent installer for the entropy-beacon
# witness daemon on a Pi (or any Linux host).
#
# Run ON the Pi after copying this file + witness.sh + witness_push.sh
# + the two .service files into ~/.ledatic/witness/.  The expected layout
# after a successful run:
#
#   ~/.ledatic/witness/witness.sh           (this dir, mode 755)
#   ~/.ledatic/witness/witness_push.sh
#   ~/.ledatic/witness/witness.sk           (Ed25519 private key, mode 600)
#   ~/.ledatic/witness/upload_token         (shared BEACON_TOKEN, mode 600)
#   ~/.ledatic/witness/latest.json          (written by witness.sh)
#   ~/.ledatic/witness/log.jsonl            (history, rotated to 100MB)
#   ~/.ledatic/witness/pushed_pulse_id      (last pushed mark)
#
#   /etc/systemd/system/witness.service       (unit file)
#   /etc/systemd/system/witness_push.service  (unit file)
#
# After install the script enables + starts both services and waits for
# the first round-trip to ledatic.org/witness/<node>/latest to succeed.
#
# Usage:
#   ./install_witness.sh                     # uses current $USER, hostname as node
#   WITNESS_NAME=fleet0 ./install_witness.sh # override node name
#   TOKEN_SRC=<beacon-host>:.ledatic/entropy/beacon_token ./install_witness.sh
#                                            # scp the token from the beacon host first

set -euo pipefail

WITNESS_DIR="$HOME/.ledatic/witness"
NODE_NAME="${WITNESS_NAME:-$(hostname)}"
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

step() { printf '\n▶ %s\n' "$*"; }

step "Layout check (working from $WITNESS_DIR)"
mkdir -p "$WITNESS_DIR"
cd "$WITNESS_DIR"

for f in witness.sh witness_push.sh witness.service witness_push.service; do
  if [ ! -f "$f" ]; then
    echo "ERROR: $f missing in $WITNESS_DIR" >&2
    echo "       Copy from rail repo: tools/fleet/$f" >&2
    exit 2
  fi
done
chmod 755 witness.sh witness_push.sh

step "Ed25519 keypair (generates on first run if absent)"
if [ ! -f witness.sk ]; then
  umask 077
  openssl genpkey -algorithm ED25519 -out witness.sk
  chmod 600 witness.sk
  echo "  generated new keypair"
else
  echo "  reusing existing witness.sk"
fi
PK_FP=$(openssl pkey -in witness.sk -pubout -outform DER 2>/dev/null \
  | sha256sum | cut -c1-16)
echo "  pk_fp=$PK_FP   (record this in tools/fleet/WITNESSES.md if new)"

step "Beacon upload token"
if [ ! -s upload_token ]; then
  if [ -n "${TOKEN_SRC:-}" ]; then
    echo "  pulling token from $TOKEN_SRC"
    scp -p "$TOKEN_SRC" upload_token
    chmod 600 upload_token
  else
    echo "  upload_token missing — populate one of these ways and re-run:"
    echo "    a) cat <token> > $WITNESS_DIR/upload_token && chmod 600 \$_"
    echo "    b) TOKEN_SRC=<beacon-host>:.ledatic/entropy/beacon_token ./install_witness.sh"
    exit 3
  fi
else
  echo "  reusing existing upload_token"
fi

step "Install systemd unit files"
# Patch ExecStart and User= to match the actual install location and
# user, since the bundled .service.example files ship with placeholders.
for unit in witness.service witness_push.service; do
  tmp=$(mktemp)
  sed -e "s|~/\.ledatic/witness|$WITNESS_DIR|g" \
      -e "s|^User=<user>|User=$USER|" \
      "$unit" > "$tmp"
  $SUDO install -m 644 "$tmp" "/etc/systemd/system/$unit"
  rm -f "$tmp"
  echo "  /etc/systemd/system/$unit"
done
$SUDO systemctl daemon-reload

step "Optional WITNESS_NAME override"
if [ "$NODE_NAME" != "$(hostname)" ]; then
  override=/etc/systemd/system/witness.service.d/override.conf
  $SUDO mkdir -p "$(dirname "$override")"
  printf '[Service]\nEnvironment=WITNESS_NAME=%s\n' "$NODE_NAME" \
    | $SUDO tee "$override" >/dev/null
  $SUDO systemctl daemon-reload
  echo "  pinned WITNESS_NAME=$NODE_NAME via $override"
else
  echo "  using hostname as node name: $NODE_NAME"
fi

step "Enable + start services"
$SUDO systemctl enable  witness.service witness_push.service
$SUDO systemctl restart witness.service
$SUDO systemctl restart witness_push.service

step "Wait up to 30 s for the first PUT round-trip"
PUSH_URL="https://ledatic.org/witness/${NODE_NAME}/latest"
ok=0
for i in $(seq 1 6); do
  sleep 5
  if curl -sf --max-time 5 "$PUSH_URL" >/dev/null 2>&1; then
    echo "  $PUSH_URL → 200 (after $((i*5)) s)"
    ok=1
    break
  fi
  echo "  not yet ($((i*5)) s)"
done
if [ "$ok" = 0 ]; then
  echo "  WARNING: $PUSH_URL did not return 200 after 30 s." >&2
  echo "  Check:  journalctl -u witness.service -u witness_push.service -n 50" >&2
  exit 4
fi

step "Verify the published record"
body=$(curl -sf "$PUSH_URL")
echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body"

step "Done"
echo "  Public endpoint:  $PUSH_URL"
echo "  Local logs:       journalctl -u witness.service -u witness_push.service -f"
echo "  Records:          $WITNESS_DIR/log.jsonl"
echo ""
echo "  Next: add this fingerprint to tools/fleet/WITNESSES.md if it's not already there."
echo "    pk_fp:        $PK_FP"
echo "    node:         $NODE_NAME"
echo "    pubkey:"
openssl pkey -in witness.sk -pubout 2>/dev/null
