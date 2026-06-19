#!/usr/bin/env bash
# verify_reproducible.sh — reproducible-build check for Rail ("check me, don't trust me").
#
# Rebuilds the committed compiler seed (rail_native) from THIS checkout's source using
# Rail's own pure-Rail toolchain — its own AArch64 assembler, Mach-O linker, and ad-hoc
# signer, with NO external as/ld/codesign — then confirms the rebuilt binary is byte-for-
# byte identical to the committed rail_native. A match proves the shipped binary is exactly
# what the shipped source produces, on your machine. No need to trust the maintainer.
#
# Usage:  ./verify_reproducible.sh
# Exit:   0 = reproducible, 1 = MISMATCH, 2 = environment/build error.
#
# Requirements:
#   - Apple Silicon macOS: the committed seed is an arm64 Mach-O and must run to rebuild.
#   - RAM headroom for the in-process linker. Defaults to RAIL_ARENA_MB=6000; below 5000
#     the build falls back to as/ld, which is NOT bit-reproducible and will not match.
set -euo pipefail

cd "$(dirname "$0")"
ARENA="${RAIL_ARENA_MB:-6000}"

sha() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

[ -x ./rail_native ] || { echo "verify: no executable ./rail_native in this checkout"; exit 2; }
if [ "$(uname -sm)" != "Darwin arm64" ]; then
  echo "verify: the committed seed is an arm64 macOS Mach-O — run this on Apple Silicon macOS"; exit 2
fi
if [ "$ARENA" -lt 5000 ] 2>/dev/null; then
  echo "verify: RAIL_ARENA_MB=$ARENA < 5000 selects the as/ld fallback (not bit-reproducible)."
  echo "verify: re-run with RAIL_ARENA_MB>=6000."; exit 2
fi

echo "verify: rebuilding the committed seed from source via the pure-Rail toolchain"
echo "verify:   (arena=${ARENA}MB, no as/ld/codesign) — this takes a couple of minutes…"
RAIL_ARENA_MB="$ARENA" ./rail_native self >/tmp/verify_reproducible.log 2>&1 \
  || { echo "verify: self-compile failed:"; tail -6 /tmp/verify_reproducible.log; exit 2; }

REBUILT=$(sha /tmp/rail_self)
COMMITTED=$(sha rail_native)
echo "verify: rebuilt   $REBUILT"
echo "verify: committed $COMMITTED"
if [ "$REBUILT" = "$COMMITTED" ]; then
  echo "verify: OK — REPRODUCIBLE. The committed rail_native is byte-identical to what its source rebuilds."
  exit 0
else
  echo "verify: FAIL — MISMATCH. The committed binary is NOT reproducible from this source."
  exit 1
fi
