#!/usr/bin/env bash
# tools/runtime/build_concurrent.sh — build libconcurrent.dylib
#
# Output: tools/runtime/libconcurrent.dylib
# Run from anywhere; resolves repo root via $0 path.

set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=tools/runtime/libconcurrent.dylib
SRC=tools/runtime/concurrent.c
INSTALL_NAME=$(pwd)/$OUT

clang -shared -Wall -Wextra -O2 -fPIC \
  -install_name "$INSTALL_NAME" \
  "$SRC" -o "$OUT" -lpthread

echo "built $OUT"
file "$OUT"
nm "$OUT" | grep -E ' T _rcon_(chan|spawn|join)' | sort
