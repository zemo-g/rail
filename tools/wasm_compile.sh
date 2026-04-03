#!/bin/bash
# wasm_compile.sh — Build and run WASM backend for Rail
# Called by: ./rail_native wasm <file.rail>
set -e
FILE="$1"
if [ -z "$FILE" ]; then echo "Usage: wasm_compile.sh <file.rail>"; exit 1; fi

# Run WASM codegen via Rail interpreter
./rail_native run tools/wasm_backend.rail "$FILE" 2>&1

# Assemble WAT → WASM
if command -v wat2wasm &>/dev/null; then
    wat2wasm /tmp/rail_out.wat -o /tmp/rail_out.wasm 2>&1
    echo "  wat2wasm: OK"
else
    echo "  wat2wasm not found (brew install wabt)"
    exit 1
fi

# Run if wasmtime available
if command -v wasmtime &>/dev/null; then
    wasmtime /tmp/rail_out.wasm 2>&1
else
    echo "  Binary: /tmp/rail_out.wasm (install wasmtime to run)"
fi
