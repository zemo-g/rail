#!/bin/sh
# tools/lab/watchers/spurarm_corpus_a.sh
#
# Agent A (corpus) chain-entry watcher. Reads counters from
# training/corpora/spurarm_v0_stats.json and re-runs the corpus
# acceptance test for a fresh PASS verdict.
#
# Emits the canonical RAIL_LAB_COUNTERS sentinel block + VERDICT line
# (PASS / INCONCLUSIVE / FALSIFIED) per CHAIN_SKELETON_AGENT_A.md.
#
# Parent: 66bb63f9 (substrate-thesis baseline at 20/20 N=20 rerank).

set -u

STATS="training/corpora/spurarm_v0_stats.json"

if [ ! -f "$STATS" ]; then
  echo "===RAIL_LAB_COUNTERS==="
  echo "{\"counter\": \"stats_present\", \"value\": 0}"
  echo "===END==="
  echo "===VERDICT=== INCONCLUSIVE"
  exit 2
fi

PRE=$(jq '.pretrain_pairs' "$STATS")
SFT=$(jq '.sft_pairs' "$STATS")
EVAL=$(jq '.eval_pairs' "$STATS")
OVERLAP=$(jq '.eval_bench_overlap_count' "$STATS")
MAX_SHARE=$(jq '.by_source_max_share_pct' "$STATS")
TOTAL=$(jq '.total_pairs' "$STATS")
UNIQ=$(jq '.unique_canonical_scripts' "$STATS")

# Re-run grader sample for a fresh pass-rate signal.
PASS_LINE=$(sh tools/spurarm/corpus/sample_grader_check.sh training/corpora/spurarm_v0.jsonl 50 2>/dev/null | tail -1)
PASS_PCT=$(printf '%s' "$PASS_LINE" | sed -n 's/.*pct=\([0-9]*\).*/\1/p')
PASS_PCT="${PASS_PCT:-0}"

echo "===RAIL_LAB_COUNTERS==="
echo "{\"counter\": \"total_pairs\", \"value\": $TOTAL}"
echo "{\"counter\": \"pretrain_pairs\", \"value\": $PRE}"
echo "{\"counter\": \"sft_pairs\", \"value\": $SFT}"
echo "{\"counter\": \"eval_pairs\", \"value\": $EVAL}"
echo "{\"counter\": \"eval_bench_overlap_count\", \"value\": $OVERLAP}"
echo "{\"counter\": \"random_sample_grader_pass_rate_pct\", \"value\": $PASS_PCT}"
echo "{\"counter\": \"by_source_max_share_pct\", \"value\": $MAX_SHARE}"
echo "{\"counter\": \"unique_canonical_scripts\", \"value\": $UNIQ}"
echo "===END==="

VERDICT="FALSIFIED"
if [ "$TOTAL" -ge 30000 ] && [ "$OVERLAP" -eq 0 ] && [ "$PASS_PCT" -ge 90 ] && [ "$MAX_SHARE" -le 70 ]; then
  VERDICT="PASS"
elif [ "$TOTAL" -ge 10000 ]; then
  VERDICT="INCONCLUSIVE"
fi
echo "===VERDICT=== $VERDICT"
