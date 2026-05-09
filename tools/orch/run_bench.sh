#!/bin/bash
# run_bench.sh — post-completion bench runner for one orchestrator arm.
#
# Runs flywheel-local/bench_strip.rail on the arm's _best checkpoint with
# N=<n> rerank, parses the per-band + pass-rate lines, writes
# runs/<arm_id>/bench_result.meta. Updates run_card.meta status to `benched`.
#
# Wall-clock at N=20 is ~13 hr per arm (CPU substrate). For dry validation
# pass `--dry-run` (no bench, fake result written).
#
# Usage:
#   tools/orch/run_bench.sh runs/<arm_id> [--n N] [--dry-run]
#
# Exits 0 on success, 2 on bad args, 3 on bench failure.

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$REPO_ROOT"

if [ $# -lt 1 ]; then
  echo "usage: $0 runs/<arm_id> [--n N] [--dry-run]" >&2
  exit 2
fi

RUN_DIR=$1
shift
N=20
DRY=no
while [ $# -gt 0 ]; do
  case $1 in
    --n)      N=$2; shift 2;;
    --dry-run) DRY=yes; shift;;
    *) shift;;
  esac
done

RUN_CARD=$RUN_DIR/run_card.meta
[ -f "$RUN_CARD" ] || { echo "error: $RUN_CARD not found" >&2; exit 2; }

get_key() { grep "^$1=" "$RUN_CARD" | head -1 | cut -d'=' -f2-; }

ARM_ID=$(get_key arm_id)
CKPT_PREFIX=$(get_key ckpt_prefix)
[ -n "$CKPT_PREFIX" ] || { echo "error: ckpt_prefix missing in $RUN_CARD" >&2; exit 2; }

BENCH_LOG=$RUN_DIR/bench.log
BENCH_RESULT=$RUN_DIR/bench_result.meta

if [ "$DRY" = "yes" ]; then
  # Fake plausible result for orchestrator-pipeline smoke testing.
  cat > "$BENCH_RESULT" <<EOF
arm_id=$ARM_ID
bench_pass=0
bench_total=30
fundamentals=0/5
practical_io=0/5
real_tools=0/5
compiler=0/5
advanced=0/5
comprehend=0/5
dry_run=yes
EOF
  echo "[$ARM_ID] dry-run bench result written"
else
  echo "[$ARM_ID] running bench (N=$N)..." >&2
  ./rail_native run flywheel-local/bench_strip.rail \
    --prefix "${CKPT_PREFIX}_best" \
    --max 128 --k 10 --n "$N" \
    --gen-source tools/train/lm_infer_cpu.rail \
    --tag "$ARM_ID" \
    > "$BENCH_LOG" 2>&1
  RC=$?
  if [ $RC -ne 0 ]; then
    echo "error: bench failed rc=$RC; see $BENCH_LOG" >&2
    exit 3
  fi

  # Parse per-band + pass rate
  parse_band() {
    grep -E "^  $1:" "$BENCH_LOG" | head -1 | grep -oE "[0-9]+/5" | head -1
  }

  PASS_RATE_LINE=$(grep -E "^  pass rate:" "$BENCH_LOG" | head -1)
  PASS=$(echo "$PASS_RATE_LINE" | grep -oE "[0-9]+/30" | head -1)
  PASS_COUNT=${PASS%/30}

  cat > "$BENCH_RESULT" <<EOF
arm_id=$ARM_ID
bench_pass=${PASS_COUNT:-0}
bench_total=30
fundamentals=$(parse_band "Fundamentals")
practical_io=$(parse_band "Practical IO")
real_tools=$(parse_band "Real Tools")
compiler=$(parse_band "Compiler")
advanced=$(parse_band "Advanced")
comprehend=$(parse_band "Comprehend")
dry_run=no
EOF
fi

# Update run card
sed -i.bak "s|^status=completed\$|status=benched|" "$RUN_CARD"
rm -f "$RUN_CARD.bak"
if ! grep -q "^bench_pass=" "$RUN_CARD"; then
  PASS_COUNT_OUT=$(get_key bench_pass)
  # Read from result file
  BR_PASS=$(grep "^bench_pass=" "$BENCH_RESULT" | cut -d'=' -f2)
  echo "bench_pass=$BR_PASS" >> "$RUN_CARD"
  echo "benched_at=$(date +%Y-%m-%dT%H:%M:%S%z)" >> "$RUN_CARD"
fi

echo "[$ARM_ID] benched: pass=$(grep ^bench_pass "$BENCH_RESULT" | cut -d= -f2)/30"
exit 0
