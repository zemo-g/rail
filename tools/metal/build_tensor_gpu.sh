#!/usr/bin/env bash
# tools/metal/build_tensor_gpu.sh — build libtensor_gpu.dylib (Metal kernels)
#
# Output: tools/metal/libtensor_gpu.dylib
# Run from anywhere; resolves repo root via $0 path.
#
# Auto-invoked by tools/compile.rail when the .m source is newer than the
# dylib (or the dylib is absent). Manual invocation is still useful after
# editing tools/metal/tensor_gpu_lib.m if you want to verify symbols
# before triggering a Rail compile.

set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=tools/metal/libtensor_gpu.dylib
SRC=tools/metal/tensor_gpu_lib.m
INSTALL_NAME=$(pwd)/$OUT

clang -shared -fobjc-arc \
  -framework Metal \
  -framework Foundation \
  -install_name "$INSTALL_NAME" \
  "$SRC" -o "$OUT"

echo "built $OUT"
file "$OUT"
nm "$OUT" | grep -cE ' T _tgl_' | xargs printf "tgl_* symbols: %s\n"
