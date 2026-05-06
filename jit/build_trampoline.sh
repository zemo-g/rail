#!/bin/bash
# jit/build_trampoline.sh — builds libjit_call.dylib (option-c trampoline).
# Not used in the shipping pthread_create path; kept for future variants.
set -e
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cc -O2 -dynamiclib "$REPO_ROOT/tools/jit_call.c" -o "$SCRIPT_DIR/libjit_call.dylib"
echo "built: $SCRIPT_DIR/libjit_call.dylib"
