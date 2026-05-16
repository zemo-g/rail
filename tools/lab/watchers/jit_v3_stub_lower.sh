#!/bin/zsh
# tools/lab/watchers/jit_v3_stub_lower.sh
#
# Runner for the JIT v3 stub-lower experiment (child of chain entry
# 8d8e809e). Re-runs the JIT v3 headroom probe AFTER jit/lower.rail's
# is_builtin gained `fold` (3-arg) and `join` (2-arg) entries plus
# placeholder `lower_builtin_fold_stub` / `lower_builtin_join_stub`
# emitters. Same N=300 corpus, same probe — apples-to-apples vs the
# parent entry's 72pct baseline.
#
# Counters emitted to stdout in the run.spec §4 wire format:
#   lower_hit_rate_pct_before  72  (the parent measurement; pinned)
#   lower_hit_rate_pct_after   from the live probe
#   delta_pp                    after - before
#   join_fallback_count_after   parsed from top_3_fallback_ops
#   fold_fallback_count_after   parsed from top_3_fallback_ops
#   other_fallback_count_after  parsed from top_3_fallback_ops
#   mean_grade_us_after         from the live probe
#
# Verdict mapping (per the brief):
#   lower_hit_rate_pct_after >= 85  -> PASS       (v3 framing retired)
#   lower_hit_rate_pct_after <  85  -> FALSIFIED  (v3 framing still standing)

set -e
cd /Users/user/projects/rail

# Pinned parent counter — chain entry 8d8e809e6709bcf5...
BEFORE_PCT=72

PROBE_OUT=$(mktemp -t rail_jit_v3_stub_lower.XXXXXX)
trap 'rm -f "$PROBE_OUT"' EXIT

RAIL_ARENA_MB=4096 ./rail_native run tools/lab/probes/jit_v3_headroom.rail >"$PROBE_OUT" 2>&1

# Extract the after counters from the probe's sentinel block.
AFTER_PCT=$(grep '"lower_hit_rate_pct"' "$PROBE_OUT" | sed 's/.*"value": *\([0-9]*\).*/\1/')
MEAN_US=$(grep '"mean_grade_us"'   "$PROBE_OUT" | sed 's/.*"value": *\([0-9]*\).*/\1/')
TOP3=$(grep '"top_3_fallback_ops"' "$PROBE_OUT" | sed 's/.*"value": *"\([^"]*\)".*/\1/')

# Pull the named counters out of the top_3 string.
extract_count() {
  local key="$1"
  local n
  n=$(printf '%s' "$TOP3" | tr ',' '\n' | awk -F: -v k="$key" '$1 == k {print $2}')
  if [ -z "$n" ]; then
    echo 0
  else
    echo "$n"
  fi
}

JOIN_AFTER=$(extract_count "unknown_function:join")
FOLD_AFTER=$(extract_count "unknown_function:fold")
OTHER_AFTER=$(extract_count "other")

DELTA=$(( AFTER_PCT - BEFORE_PCT ))

if [ "$AFTER_PCT" -ge 85 ]; then
  VERDICT=PASS
else
  VERDICT=FALSIFIED
fi

# Also surface the raw probe transcript for human review, but STRIP the
# probe's own sentinel block — run.rail's parser rejects multi-sentinel
# output as exit code 4 ("multiple counter sentinel blocks"). Only this
# watcher's outer sentinel block is the one that gets recorded.
awk '
  /^===RAIL_LAB_COUNTERS===/ { inblock = 1; next }
  /^===END===/                { if (inblock) { inblock = 0; next } }
  /^===VERDICT===/            { next }
  inblock                     { next }
                              { print }
' "$PROBE_OUT"

echo "===RAIL_LAB_COUNTERS==="
echo "{\"counter\": \"lower_hit_rate_pct_before\", \"value\": $BEFORE_PCT}"
echo "{\"counter\": \"lower_hit_rate_pct_after\",  \"value\": $AFTER_PCT}"
echo "{\"counter\": \"delta_pp\",                  \"value\": $DELTA}"
echo "{\"counter\": \"join_fallback_count_after\", \"value\": $JOIN_AFTER}"
echo "{\"counter\": \"fold_fallback_count_after\", \"value\": $FOLD_AFTER}"
echo "{\"counter\": \"other_fallback_count_after\",\"value\": $OTHER_AFTER}"
echo "{\"counter\": \"mean_grade_us_after\",       \"value\": $MEAN_US}"
echo "===END==="
echo "===VERDICT=== $VERDICT"
