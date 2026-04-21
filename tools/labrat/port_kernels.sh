#!/usr/bin/env bash
# port_kernels.sh — sequentially run labrat on each kernel-port spec,
# capturing the produced kernel into tools/metal/fp16_drafts/ on success.
#
# Adds one entry per success to a results table. Designed to be left
# running overnight; safe across labrat per-run failures (which just
# get logged and skipped, not aborted).
#
# Usage: ./tools/labrat/port_kernels.sh
#   (set LABRAT_BIN if /tmp/labrat_bin isn't current)

set -u

LABRAT_BIN="${LABRAT_BIN:-/tmp/labrat_bin}"
DRAFTS_DIR="${DRAFTS_DIR:-tools/metal/fp16_drafts}"
RESULTS="${RESULTS:-tools/metal/fp16_drafts/RESULTS.md}"

[ -x "$LABRAT_BIN" ] || { echo "missing $LABRAT_BIN"; exit 1; }
mkdir -p "$DRAFTS_DIR"

# Spec list: name, spec path, seed path, seed orig path
TASKS=(
  "matmul|/tmp/labrat_test/fp16_spec.json|/tmp/labrat_test/seed.metal|/tmp/labrat_test/seed.metal.orig"
  "matmul_blocked|/tmp/labrat_test/spec_blocked.json|/tmp/labrat_test/seed_blocked.metal|/tmp/labrat_test/seed_blocked.metal.orig"
  "matmul_bias_relu|/tmp/labrat_test/spec_bias_relu.json|/tmp/labrat_test/seed_bias_relu.metal|/tmp/labrat_test/seed_bias_relu.metal.orig"
)

if [ ! -f "$RESULTS" ]; then
  cat > "$RESULTS" <<EOF
# fp16 kernel port results (labrat overnight)

| Kernel | Outcome | Speedup | Iter | Wall (s) | Saved file |
|---|---|---|---|---|---|
EOF
fi

for entry in "${TASKS[@]}"; do
  IFS='|' read -r name spec seed seed_orig <<< "$entry"
  [ -f "$spec" ] || { echo "skip $name: no spec"; continue; }
  [ -f "$seed_orig" ] || { echo "skip $name: no seed orig"; continue; }

  echo
  echo "=== $name ($(date '+%H:%M:%S')) ==="
  cp "$seed_orig" "$seed"

  T0=$(date +%s)
  OUT=$(LABRAT_SPEC="$spec" "$LABRAT_BIN" 2>&1)
  T1=$(date +%s)
  WALL=$((T1 - T0))

  echo "$OUT"

  KEEP_LINE=$(echo "$OUT" | grep -E "iter [0-9]+: KEEP" | tail -1)
  if [ -n "$KEEP_LINE" ]; then
    SPEEDUP=$(echo "$KEEP_LINE" | grep -oE "speedup=[0-9.]+" | cut -d= -f2)
    ITER=$(echo "$KEEP_LINE" | grep -oE "iter [0-9]+" | cut -d' ' -f2)
    DRAFT="$DRAFTS_DIR/${name}_f16.metal"
    cp "$seed" "$DRAFT"
    echo "| $name | KEPT | ${SPEEDUP}x | $ITER | $WALL | $(basename $DRAFT) |" >> "$RESULTS"
    echo "  -> SAVED $DRAFT"
  else
    echo "| $name | rolled-back | — | — | $WALL | — |" >> "$RESULTS"
    echo "  -> no KEEP after 5 iters"
  fi
done

echo
echo "=== port_kernels DONE $(date) ==="
echo "Results: $RESULTS"
echo
cat "$RESULTS"
