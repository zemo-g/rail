#!/bin/sh
# tools/lab/watchers/jit_v2_baseline_corrected.sh
#
# Corrected JIT v2 baseline measurement (replaces jit_v2_baseline.sh for the
# attestable-work-chain re-measurement of entry b999f843).
#
# ============================================================================
# WHAT CHANGED vs jit_v2_baseline.sh
# ============================================================================
# Old harness shelled out to `date +%s%N` per timing point. Shell round-trip
# alone is ~120us/sample on Apple Silicon — masking pthread overhead near the
# noise floor.
#
# This wrapper drives measure_jit_{trampoline,direct}_v2.rail, which use
# `time_us_now_into` (stdlib/time_us.rail, gettimeofday-via-FFI). In-process
# timer floor on 50-iter empty batches: 0us (verified by
# measure_new_harness_floor.rail). Pthread overhead now lives in clean signal.
#
# Sample-file convention preserved: ns-per-call CSV, percentile math
# `$1/1000.0 = us` unchanged.
#
# ============================================================================
# WHAT IS MEASURED + KILL CRITERION
# ============================================================================
# Same as parent watcher: per-call us for the trampoline (v1, pthread) and
# direct (v2, libjit_call.dylib::jit_call) dispatch paths.
#
#   PASS       iff (trampoline_us_p50 - direct_us_p50) >= 40 us
#   FALSIFIED  iff that delta < 40 us
#
# A FALSIFIED verdict honestly retires v2; a PASS would re-open b999f843
# under the chain.
#
# Additional sanity counter: harness_floor_us_p50 (must be <= 10us).
# ============================================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

if [ -x "$REPO_ROOT/rail_native" ]; then
  RAIL="$REPO_ROOT/rail_native"
elif command -v rail_native >/dev/null 2>&1; then
  RAIL="$(command -v rail_native)"
else
  echo "jit_v2_baseline_corrected: rail_native not found" >&2
  exit 1
fi

TRAMP_RAIL="$SCRIPT_DIR/measure_jit_trampoline_v2.rail"
DIRECT_RAIL="$SCRIPT_DIR/measure_jit_direct_v2.rail"
FLOOR_RAIL="$SCRIPT_DIR/measure_harness_floors.rail"
for f in "$TRAMP_RAIL" "$DIRECT_RAIL" "$FLOOR_RAIL"; do
  if [ ! -f "$f" ]; then
    echo "jit_v2_baseline_corrected: missing $f" >&2
    exit 1
  fi
done

cd "$REPO_ROOT"

# --- Phase 0: floor calibration (NEW harness, 50-iter empty batches) -------
# Emits /tmp/rail_floor_old_samples and /tmp/rail_floor_new_samples (us/iter).
"$RAIL" run "$FLOOR_RAIL" >/tmp/rail_floor_calib.log 2>&1 || {
  echo "jit_v2_baseline_corrected: floor calibration failed" >&2
  exit 1
}

# --- Trampoline measurement ---
TRAMP_SAMPLES="/tmp/rail_trampoline_samples_v2"
"$RAIL" run "$TRAMP_RAIL" >/tmp/rail_trampoline_run_v2.log 2>&1 || {
  echo "jit_v2_baseline_corrected: trampoline measurement failed; see /tmp/rail_trampoline_run_v2.log" >&2
  exit 1
}
[ -s "$TRAMP_SAMPLES" ] || { echo "jit_v2_baseline_corrected: no trampoline samples" >&2; exit 1; }

# --- Direct measurement ---
DIRECT_SAMPLES="/tmp/rail_direct_samples_v2"
"$RAIL" run "$DIRECT_RAIL" >/tmp/rail_direct_run_v2.log 2>&1 || {
  echo "jit_v2_baseline_corrected: direct measurement failed; see /tmp/rail_direct_run_v2.log" >&2
  exit 1
}
[ -s "$DIRECT_SAMPLES" ] || { echo "jit_v2_baseline_corrected: no direct samples" >&2; exit 1; }

# --- Percentile helpers ---
compute_us_percentiles() {
  local infile="$1"
  local sorted="$2"
  tr ',' '\n' < "$infile" \
    | awk 'NF>0 && $1+0>=0 { printf "%.3f\n", $1/1000.0 }' \
    | sort -n > "$sorted"
}

compute_us_direct() {
  # Floor sample files are already us/iter.
  local infile="$1"
  local sorted="$2"
  tr ',' '\n' < "$infile" \
    | awk 'NF>0 && $1+0>=0 { printf "%.3f\n", $1 }' \
    | sort -n > "$sorted"
}

compute_us_percentiles "$TRAMP_SAMPLES" /tmp/rail_tramp_v2_sorted
compute_us_percentiles "$DIRECT_SAMPLES" /tmp/rail_direct_v2_sorted
compute_us_direct /tmp/rail_floor_new_samples /tmp/rail_floor_new_sorted

N_T=$(wc -l < /tmp/rail_tramp_v2_sorted | tr -d ' ')
N_D=$(wc -l < /tmp/rail_direct_v2_sorted | tr -d ' ')
N_F=$(wc -l < /tmp/rail_floor_new_sorted | tr -d ' ')
if [ "$N_T" -lt 50 ] || [ "$N_D" -lt 50 ] || [ "$N_F" -lt 50 ]; then
  echo "jit_v2_baseline_corrected: insufficient samples (T=$N_T D=$N_D F=$N_F)" >&2
  exit 1
fi

pct() {
  local n="$1"; local p="$2"; local sorted="$3"
  local idx
  idx=$(awk -v n="$n" -v p="$p" 'BEGIN { i=int(n*p); if(i<1) i=1; print i }')
  awk -v idx="$idx" 'NR==idx { print $1; exit }' "$sorted"
}

T_P50=$(pct "$N_T" 0.50 /tmp/rail_tramp_v2_sorted)
T_P90=$(pct "$N_T" 0.90 /tmp/rail_tramp_v2_sorted)
D_P50=$(pct "$N_D" 0.50 /tmp/rail_direct_v2_sorted)
D_P90=$(pct "$N_D" 0.90 /tmp/rail_direct_v2_sorted)
F_P50=$(pct "$N_F" 0.50 /tmp/rail_floor_new_sorted)
F_P90=$(pct "$N_F" 0.90 /tmp/rail_floor_new_sorted)

# Sanity: floor must be <= 10us (else the in-process timer is also broken).
FLOOR_OK=$(awk -v f="$F_P50" 'BEGIN { print (f <= 10) ? 1 : 0 }')
if [ "$FLOOR_OK" != "1" ]; then
  echo "jit_v2_baseline_corrected: harness floor p50=$F_P50 us > 10us threshold" >&2
  echo "===VERDICT=== FALSIFIED-HARNESS"
  exit 1
fi

# Verdict.
DELTA=$(awk -v t="$T_P50" -v d="$D_P50" 'BEGIN { printf "%.3f", t-d }')
VERDICT=$(awk -v delta="$DELTA" -v f="$F_P50" 'BEGIN { print (delta+0 >= 40) ? "PASS" : (f <= 10 ? "FALSIFIED" : "FALSIFIED-HARNESS") }')

cat <<COUNTERS
===RAIL_LAB_COUNTERS===
{"counter": "harness_floor_us_p50", "value": $F_P50}
{"counter": "harness_floor_us_p90", "value": $F_P90}
{"counter": "trampoline_us_p50_corrected", "value": $T_P50}
{"counter": "trampoline_us_p90_corrected", "value": $T_P90}
{"counter": "direct_us_p50_corrected", "value": $D_P50}
{"counter": "direct_us_p90_corrected", "value": $D_P90}
{"counter": "delta_us_corrected", "value": $DELTA}
===END===
COUNTERS

echo "# delta=${DELTA}us (need >=40us for PASS, harness floor=${F_P50}us)"
echo "===VERDICT=== $VERDICT"
exit 0
