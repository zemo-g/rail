#!/usr/bin/env bash
# tools/audit/compound_halt_audit.sh
#
# Verifies the compound halt (commit b916f67, 2026-04-22) was a
# properly falsified decision: kill_target declared in commit, data
# showed it wasn't met, halt followed the data.
#
# See docs/plans/COMPOUND_HALT_AUDIT.md.
#
# Exit 0 if all four classes PASS, 1 if any FAIL, 2 on probe error.

set -u

QUIET=0
LAB_MODE=0
HALT_COMMIT="${HALT_COMMIT:-b916f67}"
COMPOUND_DIR="${COMPOUND_DIR:-${HOME}/projects/compound}"

while (( $# )); do
  case "$1" in
    -q)    QUIET=1; shift ;;
    --lab) LAB_MODE=1; QUIET=1; shift ;;
    *)     echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

log()    { (( QUIET )) || echo "  $*"; }
header() { (( QUIET )) || echo "--- $* ---"; }

total_pass=0
total_fail=0
failing=()
verdict() {
  local class=$1 result=$2
  if [[ "$result" == "PASS" ]]; then
    total_pass=$((total_pass + 1))
    (( QUIET )) || echo "CLASS=$class VERDICT=PASS"
  else
    total_fail=$((total_fail + 1))
    failing+=("$class")
    echo "CLASS=$class VERDICT=FAIL"
  fi
}

cd "$COMPOUND_DIR" 2>/dev/null || { echo "FATAL: cannot cd $COMPOUND_DIR"; exit 2; }

(( QUIET )) || echo "=== COMPOUND HALT AUDIT — $(date -u +%FT%TZ) ==="
(( QUIET )) || echo "halt commit: $HALT_COMMIT"
(( QUIET )) || echo "repo: $COMPOUND_DIR"
(( QUIET )) || echo

# ---- Extract halt-message claims ----------------------------------------
halt_msg=$(git show --no-patch --format=%B "$HALT_COMMIT" 2>/dev/null) \
  || { echo "FATAL: halt commit not found"; exit 2; }

claimed_records=$(echo "$halt_msg" | grep -oE 'Final state — [0-9]+ records' | grep -oE '[0-9]+')
cal2_commit=$(echo "$halt_msg" | grep -oE 'Calibration #2 \(commit [0-9a-f]+\)' | grep -oE '[0-9a-f]{6,}')
threshold_str=$(echo "$halt_msg" | grep -oE 'ACCEPT_SPEEDUP [0-9.]+→[0-9.]+' | grep -oE '→[0-9.]+' | tr -d '→')

log "halt-msg claims: $claimed_records records, calibration commit $cal2_commit, threshold $threshold_str"
echo

# ============================================================================
# CLASS: threshold_committed_before_halt
# ============================================================================
header threshold_committed_before_halt
if [[ -z "$cal2_commit" ]]; then
  log "FAIL: cannot extract calibration commit from halt message"
  verdict threshold_committed_before_halt FAIL
else
  cal_time=$(git show --no-patch --format=%ct "$cal2_commit" 2>/dev/null)
  halt_time=$(git show --no-patch --format=%ct "$HALT_COMMIT" 2>/dev/null)
  log "calibration ts: $cal_time  halt ts: $halt_time"
  if [[ -n "$cal_time" && -n "$halt_time" && "$cal_time" -lt "$halt_time" ]]; then
    verdict threshold_committed_before_halt PASS
  else
    log "FAIL: calibration commit does not predate halt"
    verdict threshold_committed_before_halt FAIL
  fi
fi

# ============================================================================
# CLASS: threshold_value_was_5pct
# ============================================================================
header threshold_value_was_5pct
threshold_in_file=$(git show "$cal2_commit:verifier/verifier.sh" 2>/dev/null | grep 'ACCEPT_SPEEDUP=' | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
log "verifier.sh @ $cal2_commit: ACCEPT_SPEEDUP=$threshold_in_file"
if [[ "$threshold_in_file" == "1.05" ]]; then
  verdict threshold_value_was_5pct PASS
else
  log "FAIL: expected ACCEPT_SPEEDUP=1.05; got $threshold_in_file"
  verdict threshold_value_was_5pct FAIL
fi

# ============================================================================
# CLASS: record_count_matches
# ============================================================================
header record_count_matches
store=$(ls "$COMPOUND_DIR"/store/*.jsonl 2>/dev/null | head -1)
actual_records=0
if [[ -n "$store" ]]; then
  actual_records=$(wc -l <"$store" | tr -d ' ')
  log "store: $store ($actual_records records)"
fi
log "claimed: $claimed_records  actual: $actual_records"
if [[ "$claimed_records" == "$actual_records" ]]; then
  verdict record_count_matches PASS
else
  log "FAIL: halt claimed $claimed_records records; store has $actual_records"
  verdict record_count_matches FAIL
fi

# ============================================================================
# CLASS: zero_accepts_under_tight
# ============================================================================
header zero_accepts_under_tight
# Records under tight calibration are those whose 'created' timestamp is
# after cal2_commit's commit time.  Count accepts among those.
tight=$(python3 -c "
import json, sys
recs = [json.loads(l) for l in open('$store')]
cal_time = int('$cal_time' or 0)
under_tight = [r for r in recs if r.get('created', 0) >= cal_time or 'created' not in r and False]
# 'created' may be in epoch seconds or ISO; try both
def to_epoch(v):
    if isinstance(v, (int, float)): return int(v)
    if isinstance(v, str):
        import datetime
        try:
            return int(datetime.datetime.fromisoformat(v.replace('Z','+00:00')).timestamp())
        except: return 0
    return 0
under_tight = [r for r in recs if to_epoch(r.get('created') or r.get('ts') or r.get('completed')) >= cal_time]
accepts = sum(1 for r in under_tight if r.get('verdict') == 'accept')
print(f'{len(under_tight)} {accepts}')
")
tight_count=$(echo "$tight" | awk '{print $1}')
tight_accepts=$(echo "$tight" | awk '{print $2}')
log "records under tight calibration: $tight_count, accepts: $tight_accepts"
if [[ "$tight_accepts" == "0" && "$tight_count" -gt 0 ]]; then
  verdict zero_accepts_under_tight PASS
else
  if [[ "$tight_count" -eq 0 ]]; then
    log "FAIL: zero records under tight calibration (timestamp-mapping failed?)"
  else
    log "FAIL: $tight_accepts accepts under tight calibration (halt claims 0)"
  fi
  verdict zero_accepts_under_tight FAIL
fi

# ---- Summary -------------------------------------------------------------
echo
echo "=== SUMMARY ==="
echo "PASS=$total_pass FAIL=$total_fail"
if (( total_fail > 0 )); then
  printf 'FAILING_CLASSES='
  IFS=,; echo "${failing[*]}"
fi

if (( LAB_MODE == 1 )); then
  echo "===RAIL_LAB_COUNTERS==="
  echo "{\"counter\": \"classes_pass\", \"value\": $total_pass}"
  echo "{\"counter\": \"classes_fail\", \"value\": $total_fail}"
  echo "{\"counter\": \"records_under_tight\", \"value\": ${tight_count:-0}}"
  echo "{\"counter\": \"tight_accepts\", \"value\": ${tight_accepts:-0}}"
  echo "{\"counter\": \"total_records\", \"value\": ${actual_records:-0}}"
  echo "===END==="
  if (( total_fail == 0 )); then
    echo "===VERDICT=== PASS"
    exit 0
  else
    echo "===VERDICT=== FALSIFIED"
    exit 0  # exit 0 in --lab mode: runner succeeded, verdict is the falsification claim
  fi
fi

if (( total_fail > 0 )); then
  echo "VERDICT=FALSIFIED — compound halt provenance is not fully verifiable"
  exit 1
else
  echo "VERDICT=PASS — compound halt was a properly falsified decision"
  exit 0
fi
