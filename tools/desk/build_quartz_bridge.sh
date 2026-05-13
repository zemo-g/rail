#!/usr/bin/env bash
# build_quartz_bridge.sh — compile the CoreGraphics bridge dylib used by
# stdlib/quartz.rail.
#
# Output:  tools/desk/libquartz_bridge.dylib
#
# Run from the repo root. First-time use also requires granting Accessibility
# permission to whichever rail_native binary will install the event tap; macOS
# will pop the dialog on first qb_init() call.

set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=tools/desk/libquartz_bridge.dylib
SRC=tools/desk/quartz_bridge.m
INSTALL_NAME=$(pwd)/$OUT

clang -shared -fobjc-arc -Wall -O2 \
  -framework CoreGraphics \
  -framework Foundation \
  -framework AppKit \
  -framework ApplicationServices \
  -install_name "$INSTALL_NAME" \
  "$SRC" -o "$OUT"

echo "built $OUT"
file "$OUT"
otool -L "$OUT" | head -10
