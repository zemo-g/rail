#!/usr/bin/env bash
# attest_witness_pubkey.sh — physicify the witness pubkey itself.
#
# The fleet0 witness signs every release/build/attestation. Anyone
# verifying a downstream attestation has to trust that the public key
# at https://ledatic.org/attest/fleet0.pub.pem really IS the key the
# witness uses. Today that trust comes from one source: TLS to
# ledatic.org. This script adds a second source: a self-signed
# attestation that binds (sha256(pubkey), beacon_pulse_id) with the
# same Ed25519 key the pubkey represents.
#
# Anyone with both files can:
#   1. fetch the pubkey
#   2. fetch the attestation
#   3. compute sha256 of the pubkey, compare with the claimed digest
#   4. verify the attestation's witness signature against the pubkey
#
# If steps 1+2 returned the same key as before (e.g. cached locally),
# but the attestation is FRESH (recent pulse_id), the user knows the
# Pi witness was alive and intentionally re-vouched for this key at
# that pulse. A key swap or revocation would manifest as a different
# attestation OR a stale pulse_id.
#
# Run this whenever the witness key changes (rare) or on a regular
# cadence to refresh the binding (daily / weekly).
#
# Output: releases/witness-fleet0/{fleet0.pub.pem, fleet0.pub.pem.attestation.json}
# Publish: tools/attest/publish.rail releases/witness-fleet0

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PUBKEY=${PUBKEY:-$HOME/.ledatic/witness/fleet0.pub.pem}
[ -f "$PUBKEY" ] || { echo "missing pubkey at $PUBKEY" >&2; exit 3; }

dest="releases/witness-fleet0"
mkdir -p "$dest"

# Compile attest.rail once and reuse the binary (saves ~20s).
attest_bin=$(mktemp -t attest.XXXXXX)
trap 'rm -f "$attest_bin"' EXIT
./rail_native tools/attest/attest.rail >/dev/null
cp -p /tmp/rail_out "$attest_bin"
codesign --sign - --force "$attest_bin" >/dev/null 2>&1 || true

cp -p "$PUBKEY" "$dest/fleet0.pub.pem"
"$attest_bin" "$dest/fleet0.pub.pem" "$dest/fleet0.pub.pem.attestation.json"

echo "----"
echo "verify locally:"
echo "  ./rail_native run tools/attest/verify.rail \\"
echo "    $dest/fleet0.pub.pem \\"
echo "    $dest/fleet0.pub.pem.attestation.json"
echo "publish:"
echo "  ./rail_native run tools/attest/publish.rail $dest"
