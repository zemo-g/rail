#!/usr/bin/env bash
# tools/audit/beacon_chain_audit.sh
#
# Walks the Pi fleet0 witness log and verifies the entropy beacon chain.
# Checks: monotonic pulse_id, prev_hex linkage on consecutive gap=1 pairs,
# gap-shape statistics over the sampled window.
#
# See docs/plans/BEACON_CHAIN_AUDIT.md.
#
# Args: -n N  number of records to sample from tail of Pi log (default 200)
#       -q    quiet (only summary + failures)
# Exit: 0 if all kill_targets PASS, 1 if FALSIFIED, 2 on probe error.

set -u

N=200
QUIET=0
LAB_MODE=0
PI=zemog@100.87.231.45
LOG='$HOME/.ledatic/witness/log.jsonl'  # quoted: $HOME expands on Pi, not locally
MAX_GAP=1000

while (( $# )); do
  case "$1" in
    -n)    N="$2"; shift 2 ;;
    -q)    QUIET=1; shift ;;
    --lab) LAB_MODE=1; QUIET=1; shift ;;
    *)     echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

log()    { (( QUIET )) || echo "  $*"; }
header() { (( QUIET )) || echo "--- $* ---"; }

SAMPLE=/tmp/beacon_audit_sample.jsonl
ssh -o ConnectTimeout=5 "$PI" "tail -n $N $LOG" > "$SAMPLE" 2>/dev/null \
  || { echo "FATAL: cannot tail $LOG on $PI"; exit 2; }

records=$(wc -l <"$SAMPLE" | tr -d ' ')
if (( records < 2 )); then
  echo "FATAL: only $records records returned; need >=2"
  exit 2
fi

(( QUIET )) || echo "=== BEACON CHAIN AUDIT — $(date -u +%FT%TZ) ==="
(( QUIET )) || echo "source: $PI:$LOG (last $records records)"
(( QUIET )) || echo

# Walk pairs (A=prev, B=curr)
header "chain walk"
monotone_fail=0
linkage_checked=0
linkage_fail=0
max_gap=0
min_gap=999999999
sum_gap=0
gap_count=0
first_fail=""
prev_pid=""
prev_vhex=""

while IFS= read -r rec; do
  pid=$(echo "$rec" | grep -oE '"pulse_id":[0-9]+' | grep -oE '[0-9]+$')
  vhex=$(echo "$rec" | grep -oE '"value_hex":"[0-9a-f]+"' | head -1 | grep -oE '[0-9a-f]{64}')
  prev=$(echo "$rec" | grep -oE '"prev_hex":"[0-9a-f]+"' | head -1 | grep -oE '[0-9a-f]{64}')
  gap=$(echo "$rec" | grep -oE '"gap":[0-9]+' | grep -oE '[0-9]+$')
  [[ -z "$pid" || -z "$vhex" || -z "$gap" ]] && continue

  if [[ -n "$prev_pid" ]]; then
    # Monotone
    if (( pid <= prev_pid )); then
      monotone_fail=$((monotone_fail + 1))
      [[ -z "$first_fail" ]] && first_fail="monotone @ pulse $pid (prev $prev_pid)"
    fi
    # Linkage: only checkable when gap == 1 (B's predecessor IS A)
    if [[ "$gap" == "1" ]]; then
      linkage_checked=$((linkage_checked + 1))
      if [[ "$prev" != "$prev_vhex" ]]; then
        linkage_fail=$((linkage_fail + 1))
        [[ -z "$first_fail" ]] && first_fail="linkage @ pulse $pid (prev_hex mismatch)"
      fi
    fi
  fi

  # Gap stats
  if (( gap > 0 )); then
    (( gap > max_gap )) && max_gap=$gap
    (( gap < min_gap )) && min_gap=$gap
    sum_gap=$((sum_gap + gap))
    gap_count=$((gap_count + 1))
  fi

  prev_pid=$pid
  prev_vhex=$vhex
done <"$SAMPLE"

mean_gap=0
(( gap_count > 0 )) && mean_gap=$(( sum_gap / gap_count ))

log "records walked: $records"
log "gap stats: min=$min_gap max=$max_gap mean=$mean_gap (samples=$gap_count)"
log "monotone failures: $monotone_fail"
log "linkage pairs checked (gap==1): $linkage_checked"
log "linkage failures: $linkage_fail"
echo

# Verdict
echo "=== SUMMARY ==="
echo "RECORDS=$records GAP_MIN=$min_gap GAP_MAX=$max_gap GAP_MEAN=$mean_gap"
echo "MONOTONE_FAIL=$monotone_fail LINKAGE_CHECKED=$linkage_checked LINKAGE_FAIL=$linkage_fail"

fail=0
(( monotone_fail > 0 )) && fail=1
(( linkage_fail > 0 )) && fail=1
(( max_gap > MAX_GAP )) && { echo "GAP_OVER_THRESHOLD max_gap=$max_gap > $MAX_GAP"; fail=1; }

if (( LAB_MODE == 1 )); then
  echo "===RAIL_LAB_COUNTERS==="
  echo "{\"counter\": \"records_walked\", \"value\": $records}"
  echo "{\"counter\": \"gap_min\", \"value\": $min_gap}"
  echo "{\"counter\": \"gap_max\", \"value\": $max_gap}"
  echo "{\"counter\": \"gap_mean\", \"value\": $mean_gap}"
  echo "{\"counter\": \"monotone_fail\", \"value\": $monotone_fail}"
  echo "{\"counter\": \"linkage_checked\", \"value\": $linkage_checked}"
  echo "{\"counter\": \"linkage_fail\", \"value\": $linkage_fail}"
  echo "===END==="
  if (( fail == 0 )); then
    echo "===VERDICT=== PASS"
    exit 0
  else
    echo "===VERDICT=== FALSIFIED"
    exit 1
  fi
fi

if (( fail == 0 )); then
  echo "VERDICT=PASS"
  exit 0
else
  echo "VERDICT=FALSIFIED — first_fail=${first_fail:-(gap threshold)}"
  exit 1
fi
