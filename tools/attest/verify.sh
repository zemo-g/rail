#!/usr/bin/env bash
# verify.sh — verify an attestation
#
# Re-derives sha256(input), reconstructs the canonical message
# ("attest|v1|<digest>|<pulse_id>|<value_hex>|<witnessed_at>"), and
# verifies the Ed25519 signature against the fleet0 pubkey.
#
# Optional pubkey path; defaults to ~/.ledatic/witness/fleet0.pub.pem
# which the script will create on first run by fetching the DER pubkey
# from the Pi over SSH (one-time bootstrap).
#
# Usage: verify.sh <input_path> <attestation_path> [pubkey_pem]

set -euo pipefail

[ "$#" -ge 2 ] || { echo "usage: $0 <input_path> <attestation_path> [pubkey_pem]" >&2; exit 2; }

input=$1
att=$2
pub=${3:-$HOME/.ledatic/witness/fleet0.pub.pem}

[ -f "$input" ] || { echo "no input: $input" >&2; exit 3; }
[ -f "$att" ]   || { echo "no attestation: $att" >&2; exit 3; }

if [ ! -f "$pub" ]; then
  mkdir -p "$(dirname "$pub")"
  PUBKEY_URL=${PUBKEY_URL:-https://ledatic.org/attest/fleet0.pub.pem}
  if ! curl -sf --max-time 10 "$PUBKEY_URL" -o "$pub"; then
    echo "could not fetch pubkey from $PUBKEY_URL" >&2
    exit 4
  fi
fi

# Sanity: pubkey fingerprint must match the attestation's pk_fp.
expected_fp=$(python3 -c "import json;print(json.load(open('$att'))['witness']['pk_fp'])")
got_fp=$(openssl pkey -in "$pub" -pubin -outform DER 2>/dev/null | shasum -a 256 | cut -c1-16)
[ "$expected_fp" = "$got_fp" ] || { echo "pk_fp mismatch: expected $expected_fp, got $got_fp" >&2; exit 4; }

# Re-derive digest and check.  Accept either the standard
# `artifact: {sha256, name}` schema OR the frame-attestation
# `frame: {sha256, url}` schema (used by /entropy/frame/* sidecars).
have_digest=$(shasum -a 256 "$input" | awk '{print $1}')
want_digest=$(python3 -c "
import json,sys
a = json.load(open('$att'))
print((a.get('artifact') or a.get('frame') or {}).get('sha256',''))
")
[ -n "$want_digest" ] || { echo "no sha256 in attestation" >&2; exit 5; }
[ "$have_digest" = "$want_digest" ] || { echo "digest mismatch: file=$have_digest att=$want_digest" >&2; exit 5; }

# Reconstruct canonical message and verify Ed25519 sig.
python3 - "$att" > /tmp/attest_msg.bin <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
w = a["witness"]
msg = f'attest|v1|{w["digest_sha256"]}|{w["pulse_id"]}|{w["value_hex"]}|{w["witnessed_at"]}'
sys.stdout.buffer.write(msg.encode())
PY

python3 -c "import json,base64,sys;a=json.load(open('$att'));sys.stdout.buffer.write(base64.b64decode(a['witness']['sig']))" > /tmp/attest_sig.bin

if openssl pkeyutl -verify -pubin -inkey "$pub" -rawin -in /tmp/attest_msg.bin -sigfile /tmp/attest_sig.bin >/dev/null 2>&1; then
  name=$(python3 -c "
import json
a = json.load(open('$att'))
art = a.get('artifact') or a.get('frame') or {}
print(art.get('name') or art.get('url','?'))
")
  pulse=$(python3 -c "import json;print(json.load(open('$att'))['witness']['pulse_id'])")
  echo "ok  artifact=$name  pulse_id=$pulse  pk_fp=$got_fp"
  rm -f /tmp/attest_msg.bin /tmp/attest_sig.bin
  exit 0
else
  echo "BAD signature" >&2
  rm -f /tmp/attest_msg.bin /tmp/attest_sig.bin
  exit 6
fi
