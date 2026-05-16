#!/bin/zsh
# tools/lab/watchers/jit_v3_other48_breakdown.sh
#
# Runner for the JIT v3 other:48 fallback-bucket breakdown probe (child of
# chain entry 0d48105b). The probe itself does all the measurement; this
# watcher just shells it out, surfaces the transcript, and emits the
# probe's sentinel block exactly once (the wire format the chain reads).
#
# Counters emitted (per run.spec.md §4 wire format):
#   total_fallback_count        (should be 48 — sanity with parent)
#   unique_fallback_categories  count of distinct bucket labels
#   largest_single_bucket_count N of the top bucket
#   top_5_fallback_categories   "cat1:N,cat2:N,..."
#   lower_hit_rate_pct          sanity check (should be 84)
#   mean_grade_us               via stdlib/time_us.rail
#
# Verdict mapping (per the brief):
#   largest_single_bucket_count >= 15  -> PASS       (named target)
#   unique >= 10 AND largest <= 5      -> FALSIFIED  (long tail; v3 retires)
#   otherwise                          -> INCONCLUSIVE

set -e
cd /Users/user/projects/rail

PROBE_OUT=$(mktemp -t rail_jit_v3_other48.XXXXXX)
trap 'rm -f "$PROBE_OUT"' EXIT

RAIL_ARENA_MB=4096 ./rail_native run tools/lab/probes/jit_v3_other48_breakdown.rail >"$PROBE_OUT" 2>&1

# Replay the probe's transcript verbatim (it's already wire-format-valid:
# one sentinel block + one ===VERDICT=== line). run.rail's parser accepts
# a single sentinel block; no awk-stripping needed here.
cat "$PROBE_OUT"
