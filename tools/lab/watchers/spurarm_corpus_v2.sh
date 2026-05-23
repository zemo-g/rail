#!/bin/sh
# tools/lab/watchers/spurarm_corpus_v2.sh
#
# Attests the spurarm corpus v2 acceptance: all 5 kill_targets pass on
# training/corpora_v2/. Counters emitted are the v2 SPEC §8 numbers.
#
# PASS iff: total_pairs >= 80000 AND grader_pass_pct >= 90 AND
#           eval_bench_overlap == 0 AND by_source_max_share <= 50 AND
#           coord_uniformity_max_share <= 5
set -u
REPO="$HOME/projects/rail-spurarm-cap-h"
STATS="$REPO/training/corpora_v2/spurarm_v2_stats.json"

if [ ! -s "$STATS" ]; then
  cat <<COUNTERS
===RAIL_LAB_COUNTERS===
{"counter": "total_pairs", "value": 0}
{"counter": "grader_pass_pct", "value": 0}
{"counter": "eval_bench_overlap_count", "value": -1}
{"counter": "by_source_max_share_pct", "value": 100}
{"counter": "coord_uniformity_max_share_pct", "value": 100}
{"counter": "unique_canonical_scripts", "value": 0}
===END===
COUNTERS
  echo "===VERDICT=== FALSIFIED"
  exit 0
fi

TOTAL=$(jq '.total_pairs' "$STATS")
OVERLAP=$(jq '.eval_bench_overlap_count' "$STATS")
BSM=$(jq '.by_source_max_share_pct' "$STATS")
COORDU=$(jq '.coord_uniformity_max_share_pct' "$STATS")
UCS=$(jq '.unique_canonical_scripts' "$STATS")

# Grader sample on freshest data
GRADER=$(cd "$REPO" && sh tools/spurarm/corpus/v2/sample_grader_check.sh training/corpora_v2/spurarm_v2.jsonl 50 2>/dev/null | tail -1 | sed -n 's/.*pct=\([0-9]*\).*/\1/p')
GRADER=${GRADER:-0}

# Verdict gate
VERDICT="FALSIFIED"
COORDU_INT=$(printf '%d' "${COORDU%.*}" 2>/dev/null || echo 100)
if [ "$TOTAL" -ge 80000 ] && [ "$GRADER" -ge 90 ] \
  && [ "$OVERLAP" = "0" ] \
  && [ "$BSM" -le 50 ] \
  && [ "$COORDU_INT" -le 4 ]; then
  VERDICT="PASS"
fi

cat <<COUNTERS
===RAIL_LAB_COUNTERS===
{"counter": "total_pairs", "value": $TOTAL}
{"counter": "grader_pass_pct", "value": $GRADER}
{"counter": "eval_bench_overlap_count", "value": $OVERLAP}
{"counter": "by_source_max_share_pct", "value": $BSM}
{"counter": "coord_uniformity_max_share_pct", "value": $COORDU}
{"counter": "unique_canonical_scripts", "value": $UCS}
===END===
COUNTERS
echo "===VERDICT=== $VERDICT"
exit 0
