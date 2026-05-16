#!/bin/sh
# tools/lab/watchers/jit_v2_baseline.sh
#
# Baseline-measurement watcher for the JIT v2 direct-call leverage call.
#
# ===========================================================================
# WHAT THIS MEASURES
# ===========================================================================
# Per-call wall-clock overhead of TWO JIT dispatch paths against the SAME
# IR fixture (op_const 42 + op_ret):
#
#   trampoline (v1): jit/loader.rail::call_jit         -- pthread_create + join
#   direct     (v2): jit/loader.rail::call_jit_direct  -- libjit_call.dylib::jit_call
#
# Both timed with 200 batches x 50 calls = 10,000 calls each, identical
# harness. The per-call delta IS the dispatch-overhead delta (everything
# else cancels).
#
# Unit: MICROSECONDS per call (us/call).
#
# ===========================================================================
# KILL CRITERION (chain entry 8f60d09d)
# ===========================================================================
#   PASS       iff (trampoline_us_p50 - direct_us_p50) >= 40 us
#   FALSIFIED  iff that delta < 40 us
#
# A FALSIFIED verdict is a SUCCESS for the chain: it retires JIT v2 effort
# (the direct-call win is smaller than the leverage call required) and
# redirects to v3 full lowering.
#
# ===========================================================================
# MEASUREMENT-FLOOR CAVEAT
# ===========================================================================
# The Rail harness samples wall clock via `shell "date +%s%N"`, which has
# ~100us round-trip cost. Batching (50 calls per `date` invocation) cuts
# this to ~2us/call of harness noise per sample, but the harness floor
# is NOT zero. See tools/lab/watchers/measure_jit_floor.rail: an empty
# inner loop (no JIT call at all) measures p50 ~= 120 us/call on Apple
# Silicon. The per-call dispatch overhead (pthread, foreign call) is
# strictly the DELTA above this floor — which is what the kill criterion
# compares.
#
# Concretely (typical measurement, 2026-05-16, Studio M-class):
#   floor       p50 ~= 120 us  (harness-only, no JIT call)
#   direct      p50 ~= 121 us  (foreign-call cost dwarfed by harness)
#   trampoline  p50 ~= 142 us  (~21 us real pthread_create + join cost)
#   delta = 21 us   --> FALSIFIED relative to >=40us threshold
#
# ===========================================================================
# SANITY RANGE
# ===========================================================================
# Both p50 values must fall in [5, 5000] us. Anything outside indicates
# measurement bug (stale samples file, thermal throttle, exotic load).
#
# ===========================================================================
# IDEMPOTENCY
# ===========================================================================
# /tmp/rail_trampoline_samples + /tmp/rail_direct_samples rewritten each run.
# No chain mutation, no training-state read. Pure stdout.
# ===========================================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

if [ -x "$REPO_ROOT/rail_native" ]; then
  RAIL="$REPO_ROOT/rail_native"
elif command -v rail_native >/dev/null 2>&1; then
  RAIL="$(command -v rail_native)"
else
  echo "jit_v2_baseline: rail_native not found in $REPO_ROOT or on PATH" >&2
  exit 1
fi

TRAMP_RAIL="$SCRIPT_DIR/measure_jit_trampoline.rail"
DIRECT_RAIL="$SCRIPT_DIR/measure_jit_direct.rail"
for f in "$TRAMP_RAIL" "$DIRECT_RAIL"; do
  if [ ! -f "$f" ]; then
    echo "jit_v2_baseline: missing $f" >&2
    exit 1
  fi
done

cd "$REPO_ROOT"

# --- Run trampoline measurement ---
TRAMP_SAMPLES="/tmp/rail_trampoline_samples"
rm -f "$TRAMP_SAMPLES"
"$RAIL" run "$TRAMP_RAIL" >/tmp/rail_trampoline_run.log 2>&1 || {
  echo "jit_v2_baseline: trampoline measurement failed; see /tmp/rail_trampoline_run.log" >&2
  exit 1
}
[ -s "$TRAMP_SAMPLES" ] || { echo "jit_v2_baseline: no trampoline samples" >&2; exit 1; }

# --- Run direct measurement ---
DIRECT_SAMPLES="/tmp/rail_direct_samples"
rm -f "$DIRECT_SAMPLES"
"$RAIL" run "$DIRECT_RAIL" >/tmp/rail_direct_run.log 2>&1 || {
  echo "jit_v2_baseline: direct measurement failed; see /tmp/rail_direct_run.log" >&2
  exit 1
}
[ -s "$DIRECT_SAMPLES" ] || { echo "jit_v2_baseline: no direct samples" >&2; exit 1; }

# --- Compute percentiles for both ---
compute_percentiles() {
  local infile="$1"
  local sorted="$2"
  tr ',' '\n' < "$infile" \
    | awk 'NF>0 && $1+0>0 { printf "%.3f\n", $1/1000.0 }' \
    | sort -n > "$sorted"
}

compute_percentiles "$TRAMP_SAMPLES" /tmp/rail_trampoline_sorted
compute_percentiles "$DIRECT_SAMPLES" /tmp/rail_direct_sorted

N_T=$(wc -l < /tmp/rail_trampoline_sorted | tr -d ' ')
N_D=$(wc -l < /tmp/rail_direct_sorted | tr -d ' ')
if [ "$N_T" -lt 50 ] || [ "$N_D" -lt 50 ]; then
  echo "jit_v2_baseline: insufficient samples (trampoline=$N_T direct=$N_D)" >&2
  exit 1
fi

pct() {
  local n="$1"; local p="$2"; local sorted="$3"
  local idx
  idx=$(awk -v n="$n" -v p="$p" 'BEGIN { i=int(n*p); if(i<1) i=1; print i }')
  awk -v idx="$idx" 'NR==idx { print $1; exit }' "$sorted"
}

T_P50=$(pct "$N_T" 0.50 /tmp/rail_trampoline_sorted)
T_P90=$(pct "$N_T" 0.90 /tmp/rail_trampoline_sorted)
D_P50=$(pct "$N_D" 0.50 /tmp/rail_direct_sorted)
D_P90=$(pct "$N_D" 0.90 /tmp/rail_direct_sorted)

TOTAL_CALLS=$(awk -v n="$N_T" 'BEGIN { print n * 50 }')

# Sanity gates.
for p in "$T_P50" "$D_P50"; do
  SANE=$(awk -v p="$p" 'BEGIN { print (p >= 5 && p <= 5000) ? 1 : 0 }')
  if [ "$SANE" != "1" ]; then
    echo "jit_v2_baseline: p50=$p us outside sane range [5, 5000] us" >&2
    exit 1
  fi
done

# Verdict.
DELTA=$(awk -v t="$T_P50" -v d="$D_P50" 'BEGIN { printf "%.3f", t-d }')
VERDICT=$(awk -v delta="$DELTA" 'BEGIN { print (delta+0 >= 40) ? "PASS" : "FALSIFIED" }')

cat <<COUNTERS
===RAIL_LAB_COUNTERS===
{"counter": "trampoline_us_p50", "value": $T_P50}
{"counter": "trampoline_us_p90", "value": $T_P90}
{"counter": "trampoline_calls_measured", "value": $TOTAL_CALLS}
{"counter": "direct_us_p50", "value": $D_P50}
{"counter": "direct_us_p90", "value": $D_P90}
===END===
COUNTERS

echo "# delta=${DELTA}us (need >=40us for PASS)"
echo "===VERDICT=== $VERDICT"
exit 0
