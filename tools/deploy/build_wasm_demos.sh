#!/bin/bash
# Compile every Rail playground demo to /tmp/demo_*.wasm, the layout
# gen_site.rail base64-embeds into ledatic.org's playground section.
#
# Sources live under examples/wasm/.  We invoke `rail_native wasm` for
# each one and route the produced /tmp/rail_out.wasm to the named
# /tmp/demo_<name>.wasm slot.

set -e

cd "$(dirname "$0")/../.."

if [[ ! -x ./rail_native ]]; then
  echo "rail_native not found in $(pwd)" >&2
  exit 1
fi

SOURCES_DIR=examples/wasm
DEMOS=(hello fib math list adt closure fizz loop)

for name in "${DEMOS[@]}"; do
  src="$SOURCES_DIR/$name.rail"
  if [[ ! -f "$src" ]]; then
    echo "MISSING: $src" >&2
    exit 1
  fi
  ./rail_native wasm "$src" >/dev/null
  cp /tmp/rail_out.wasm "/tmp/demo_${name}.wasm"
  size=$(stat -f%z "/tmp/demo_${name}.wasm" 2>/dev/null \
       || stat -c%s "/tmp/demo_${name}.wasm")
  printf "  %-10s %5d bytes\n" "$name" "$size"
done

echo "Built ${#DEMOS[@]} demos."
