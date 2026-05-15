#!/usr/bin/env bash
# sign_attestation.sh — Pi-side signer for arbitrary attestations
#
# Reuses the fleet0 witness Ed25519 key to sign a canonical message
# binding (digest, pulse_id, value_hex, witnessed_at).  Distinct
# message-namespace prefix ("attest|v1|...") keeps attestation sigs
# from colliding with beacon witness sigs ("<pid>|<vhex>|<wat>").
#
# Usage: sign_attestation.sh <digest_hex> <pulse_id> <value_hex>
#
# Emits one JSON object on stdout.  No filesystem side effects.

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <digest_hex> <pulse_id> <value_hex>" >&2
  exit 2
fi

digest_hex=$1
pulse_id=$2
value_hex=$3

WITNESS_DIR=${WITNESS_DIR:-$HOME/.ledatic/witness}
SK=${SK:-$WITNESS_DIR/witness.sk}
WITNESS_NAME=${WITNESS_NAME:-$(hostname)}

[ -f "$SK" ] || { echo "missing witness key: $SK" >&2; exit 3; }

case "$digest_hex" in
  *[!0-9a-fA-F]*|"") echo "bad digest_hex" >&2; exit 4 ;;
esac
case "$pulse_id" in
  *[!0-9]*|"") echo "bad pulse_id" >&2; exit 4 ;;
esac
case "$value_hex" in
  *[!0-9a-fA-F]*|"") echo "bad value_hex" >&2; exit 4 ;;
esac

witnessed_at=$(date -u +%s)
msg="attest|v1|${digest_hex}|${pulse_id}|${value_hex}|${witnessed_at}"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf '%s' "$msg" > "$tmp"
sig=$(openssl pkeyutl -sign -inkey "$SK" -rawin -in "$tmp" 2>/dev/null | base64 -w0)

pk_fp=$(openssl pkey -in "$SK" -pubout -outform DER 2>/dev/null \
  | sha256sum | cut -c1-16)

printf '{"kind":"attestation","version":1,"digest_sha256":"%s","pulse_id":%s,"value_hex":"%s","witnessed_at":%s,"sig":"%s","pk_fp":"%s","witness":"%s"}\n' \
  "$digest_hex" "$pulse_id" "$value_hex" "$witnessed_at" "$sig" "$pk_fp" "$WITNESS_NAME"
