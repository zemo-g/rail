#!/bin/sh
# tools/spurarm/corpus/acceptance.sh
#
# Acceptance test for the corpus build (per AGENT_A_corpus.md).
#
# Checks:
#   1. spurarm_v0.jsonl has >= 30,000 lines
#   2. schema-valid JSON every line (required fields)
#   3. 50/50 random sample passes grader at stage >= 3
#      (target >= 45/50 == 90%)
#   4. eval_bench_overlap_count == 0
#   5. by-source max share <= 70% (no single source dominates)
#
# Exit 0 on PASS, 1 on FAIL (kill_target tripped), 2 on INCONCLUSIVE.
#
# Usage:
#   sh tools/spurarm/corpus/acceptance.sh <corpora_dir>

set -u
DIR="${1:?usage: acceptance.sh <corpora_dir>}"
MAIN="$DIR/spurarm_v0.jsonl"
EVAL="$DIR/spurarm_v0_eval.jsonl"
SFT="$DIR/spurarm_v0_sft.jsonl"
PRE="$DIR/spurarm_v0_pretrain.jsonl"
STATS="$DIR/spurarm_v0_stats.json"

fail=0
inconclusive=0

# Check 1: total line count.
total=$(wc -l < "$MAIN" | tr -d ' ')
echo "[1] total_pairs=$total (target >= 30000)"
if [ "$total" -lt 30000 ]; then
  echo "    FAIL"
  fail=1
fi

# Check 2: schema-valid JSON every line.
echo "[2] schema validation..."
schema_ok=$(python3 -c '
import json, sys
required = {"id","nl","script","world","expected","source","stages_passed"}
ok = err = 0
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
            assert required.issubset(d.keys())
            ok += 1
        except Exception as e:
            err += 1
print(f"{ok} {err}")
' "$MAIN")
ok=$(printf '%s' "$schema_ok" | awk '{print $1}')
err=$(printf '%s' "$schema_ok" | awk '{print $2}')
echo "    ok=$ok err=$err"
if [ "$err" != "0" ]; then
  echo "    FAIL"
  fail=1
fi

# Check 3: grader sample pass rate.
echo "[3] grader sample (N=50)..."
sample_out=$(sh tools/spurarm/corpus/sample_grader_check.sh "$MAIN" 50 2>/dev/null | tail -1)
pct=$(printf '%s' "$sample_out" | sed -n 's/.*pct=\([0-9]*\).*/\1/p')
echo "    $sample_out"
if [ "${pct:-0}" -lt 90 ]; then
  echo "    FAIL"
  fail=1
fi

# Check 4: eval bench overlap.
echo "[4] eval/bench overlap..."
overlap=$(jq '.eval_bench_overlap_count' "$STATS")
echo "    overlap=$overlap (target == 0)"
if [ "$overlap" != "0" ]; then
  echo "    FAIL"
  fail=1
fi

# Check 5: max source share.
echo "[5] max source share..."
max_share=$(jq '.by_source_max_share_pct' "$STATS")
echo "    max_share=${max_share}% (target <= 70)"
if [ "${max_share:-0}" -gt 70 ]; then
  echo "    FAIL"
  fail=1
fi

# Also surface split counts for chain counters.
n_pre=$(wc -l < "$PRE" | tr -d ' ')
n_sft=$(wc -l < "$SFT" | tr -d ' ')
n_eval=$(wc -l < "$EVAL" | tr -d ' ')
echo ""
echo "split: pretrain=$n_pre sft=$n_sft eval=$n_eval"

if [ "$fail" = "1" ]; then
  echo ""
  echo "VERDICT: FAIL"
  exit 1
fi
if [ "$inconclusive" = "1" ]; then
  echo "VERDICT: INCONCLUSIVE"
  exit 2
fi
echo "VERDICT: PASS"
exit 0
