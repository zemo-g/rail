#!/usr/bin/env bash
# build_render_wasm.sh — Rail-WASM render module build pipeline.
#
# Compiles tools/plasma/render.rail to WASM with explicit exports for
# the kernel functions that JS needs to invoke directly.  The Rail WASM
# emitter (compile.rail line ~4280) only declares `memory` and `_start`
# in the module header; per-function exports require a post-process
# pass that inserts `(export "name" (func $name))` lines before
# wat2wasm runs.
#
# Output: tools/plasma/render.wasm (plus render.wat for inspection).

set -euo pipefail

cd "$(dirname "$0")/../.."
[ -x ./rail_native ] || { echo "ERROR: ./rail_native missing" >&2; exit 1; }
command -v wat2wasm >/dev/null || { echo "ERROR: wat2wasm not in PATH (brew install wabt)" >&2; exit 1; }

EXPORTS=(
  vorticity                         # ∂vy/∂x − ∂vx/∂y
  current_density                   # |∂By/∂x − ∂Bx/∂y|
  schlieren                         # |∇ρ|
  total_kinetic_energy
  total_magnetic_energy
  max_divb
  mean_vorticity
  seed_ot                           # seed the OT initial condition
  float_arr_new                     # JS-side state alloc (Tier 3-B glue)
  float_arr_get                     # read a cell as raw f64 bits
  float_arr_set                     # write a cell from raw f64 bits
  float_arr_len                     # tagged length
  arena_mark                        # snapshot $str_ptr — used to free per-frame scratch
  arena_reset                       # rewind $str_ptr to a saved mark
  lic                               # Tier 3-C: streamline noise convolution
  particle_step                     # Tier 3-D: RK2 advection of K tracers
  chamber_render                    # Tier 4: volumetric chamber raymarch
)

echo "▶ ./rail_native wasm tools/plasma/render.rail"
./rail_native wasm tools/plasma/render.rail >/dev/null

cp /tmp/rail_out.wat tools/plasma/render.wat

# Insert (export ...) lines just after the memory export, AND bump the
# memory ceiling from the emitter's default 1 MB to 2 MB (32 pages).
# Default is too tight once kernels need a permanent noise buffer plus
# scratch above the per-frame arena mark.
WAT=tools/plasma/render.wat
TMP=$(mktemp)
awk -v EXPORTS="${EXPORTS[*]}" '
BEGIN { n = split(EXPORTS, e, " "); printed = 0 }
{
  if ($0 ~ /\(memory \(export "memory"\) 16 16\)/) {
    sub(/16 16/, "32 32")
  }
  print
  if (!printed && $0 ~ /\(memory \(export "memory"\) /) {
    for (i = 1; i <= n; i++) {
      printf "  (export \"%s\" (func $%s))\n", e[i], e[i]
    }
    printed = 1
  }
}
' "$WAT" > "$TMP"
mv "$TMP" "$WAT"

echo "▶ wat2wasm --enable-tail-call $WAT → tools/plasma/render.wasm"
wat2wasm --enable-tail-call "$WAT" -o tools/plasma/render.wasm

echo "▶ exports listed:"
wasm-objdump -x tools/plasma/render.wasm 2>/dev/null | sed -n '/^Export/,/^[A-Z]/p' | grep -E '^ - func' | head -20 || \
  echo "  (install wasm-objdump for verification)"

echo ""
echo "render.wasm built ($(stat -f %z tools/plasma/render.wasm) bytes)."
