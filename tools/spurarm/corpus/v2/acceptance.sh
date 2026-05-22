#!/bin/sh
# tools/spurarm/corpus/v2/acceptance.sh
#
# Five kill_target acceptance checks per SPEC §8. Exit 0 PASS, 1 FAIL,
# 2 INCONCLUSIVE.
#
# Targets:
#   1. total pairs >= 80,000
#   2. random 50-sample grader pass rate >= 90%
#   3. eval_bench_overlap_count == 0
#   4. by_source_max_share_pct <= 50%
#   5. coord_uniformity_max_share_pct <= 5%   (NEW)
#
# Usage:
#   sh tools/spurarm/corpus/v2/acceptance.sh <corpora_dir>

set -u
DIR="${1:?usage: acceptance.sh <corpora_dir>}"
MAIN="$DIR/spurarm_v2.jsonl"
STATS="$DIR/spurarm_v2_stats.json"

if [ ! -f "$MAIN" ]; then
  echo "ERROR: $MAIN missing" >&2
  exit 2
fi
if [ ! -f "$STATS" ]; then
  echo "ERROR: $STATS missing (run stats.sh first)" >&2
  exit 2
fi

fail=0

# 1. total pairs >= 80,000
total=$(wc -l < "$MAIN" | tr -d ' ')
echo "[1] total_pairs=$total (target >= 80000)"
if [ "$total" -lt 80000 ]; then
  echo "    FAIL"
  fail=1
fi

# 2. random 50-sample grader pass rate >= 90%
echo "[2] grader sample (N=50)..."
sample_out=$(sh tools/spurarm/corpus/v2/sample_grader_check.sh "$MAIN" 50 2>/dev/null | tail -1)
pct=$(printf '%s' "$sample_out" | sed -n 's/.*pct=\([0-9]*\).*/\1/p')
echo "    $sample_out"
if [ "${pct:-0}" -lt 90 ]; then
  echo "    FAIL"
  fail=1
fi

# 3. eval / bench overlap count == 0
overlap=$(jq '.eval_bench_overlap_count' "$STATS")
echo "[3] eval_bench_overlap=$overlap (target == 0)"
if [ "$overlap" != "0" ]; then
  echo "    FAIL"
  fail=1
fi

# 4. by-source max share <= 50%
max_share=$(jq '.by_source_max_share_pct' "$STATS")
echo "[4] by_source_max_share=$max_share (target <= 50)"
if [ "$(printf '%s\n' "${max_share:-0}" | awk '{print ($1 > 50) ? 1 : 0}')" = "1" ]; then
  echo "    FAIL"
  fail=1
fi

# 5. coord_uniformity_max_share <= 5%  (NEW)
coord_max=$(jq '.coord_uniformity_max_share_pct' "$STATS")
echo "[5] coord_uniformity_max_share=$coord_max (target <= 5)"
if [ "$(printf '%s\n' "${coord_max:-0}" | awk '{print ($1 > 5) ? 1 : 0}')" = "1" ]; then
  echo "    FAIL"
  fail=1
fi

if [ "$fail" = "0" ]; then
  echo ""
  echo "VERDICT: PASS"
  exit 0
fi
echo ""
echo "VERDICT: FAIL"
exit 1
