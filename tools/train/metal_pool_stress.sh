#!/usr/bin/env bash
# metal_pool_stress.sh — track-d regression wrapper.
#
# Compiles + runs tools/train/metal_pool_stress.rail (1000 matmul calls
# via tensor_daemond), then queries /gpu/stats and asserts:
#   * totals.miss_rate < 0.05
#   * totals.drops == 0
#   * daemon RSS < 2 GB
#
# Exit 0 PASS, nonzero FAIL.

set -euo pipefail

RAIL_BIN="${RAIL_BIN:-./rail_native}"
PORT="${TENSORD_PORT:-9302}"

if ! pgrep -f tensor_daemond > /dev/null; then
  echo "ERR: tensor_daemond not running on :$PORT" >&2
  echo "     start with:  cd tools/metal && DYLD_LIBRARY_PATH=. ./tensor_daemond &" >&2
  exit 2
fi

echo "stress_test: snapshotting pre-run stats"
PRE_JSON=$(printf 'STATS\n' | nc -w2 127.0.0.1 "$PORT")
echo "  pre  totals: $(echo "$PRE_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["totals"])')"

echo "stress_test: running 1005 matmul iters"
"$RAIL_BIN" run tools/train/metal_pool_stress.rail

POST_JSON=$(printf 'STATS\n' | nc -w2 127.0.0.1 "$PORT")
echo "  post totals: $(echo "$POST_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["totals"])')"

# Compute deltas (post - pre) so background traffic doesn't poison the rate.
read HITS MISSES ACQ DROPS < <(python3 - "$PRE_JSON" "$POST_JSON" <<'PY'
import sys, json
pre = json.loads(sys.argv[1])["totals"]
post = json.loads(sys.argv[2])["totals"]
dh = post["hits"]    - pre["hits"]
dm = post["misses"]  - pre["misses"]
dd = post["drops"]   - pre["drops"]
print(dh, dm, dh+dm, dd)
PY
)
echo "  delta: hits=$HITS misses=$MISSES acquires=$ACQ drops=$DROPS"

if [ "$DROPS" -gt 0 ]; then
  echo "FAIL: $DROPS untracked allocations (capacity overflow)" >&2
  exit 1
fi

# miss_rate < 5%  ⇔  misses * 20 < acquires
if [ "$ACQ" -le 0 ] || [ $((MISSES * 20)) -ge "$ACQ" ]; then
  echo "FAIL: miss_rate >= 5% ($MISSES / $ACQ)" >&2
  exit 1
fi

RSS_KB=$(ps -o rss= -p "$(pgrep -f tensor_daemond | head -1)" | tr -d ' ')
RSS_MB=$((RSS_KB / 1024))
echo "  daemon RSS: ${RSS_MB} MB (limit 2048)"
if [ "$RSS_MB" -ge 2048 ]; then
  echo "FAIL: daemon RSS exceeds 2 GB" >&2
  exit 1
fi

echo "PASS: miss_rate < 5% AND no drops AND RSS < 2 GB"
