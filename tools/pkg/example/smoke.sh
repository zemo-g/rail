#!/usr/bin/env bash
# tools/pkg/example/smoke.sh — End-to-end smoke for pkg v0.
# Run from repo root: bash tools/pkg/example/smoke.sh
set -e
RAIL=${RAIL_BIN:-$PWD/rail_native}
PKG_B=tools/pkg/example/package_b

# Clean slate so the smoke is reproducible.
rm -rf "$PKG_B/vendor"

echo "==> pkg_resolve"
"$RAIL" run tools/pkg/pkg_resolve.rail "$PKG_B"

echo "==> pkg_link"
"$RAIL" run tools/pkg/pkg_link.rail "$PKG_B"

echo "==> compile + run main"
cd "$PKG_B"
"$RAIL" run main.rail
