#!/usr/bin/env bash
# test_render_wasm.sh — drive the Tier 3-A WASM gate from the CLI.
#
# Builds render.wasm (so any source edits in render.rail flow through),
# then runs render_harness.js under Apple's bundled JavaScriptCore.
# JSC shares its engine implementation with Safari's WebKit, so a
# passing JSC run is strong evidence the same harness works in-browser.
#
# Exit code: 0 on PASS, non-zero on FAIL (or build error).

set -euo pipefail

cd "$(dirname "$0")/../.."

JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc
[ -x "$JSC" ] || { echo "ERROR: jsc not at $JSC" >&2; exit 1; }

./tools/plasma/build_render_wasm.sh >/dev/null
echo "▶ jsc tools/plasma/render_harness.js"
"$JSC" tools/plasma/render_harness.js
