#!/usr/bin/env bash
# tools/audit/system_page_audit.sh
#
# /system page substrate audit — Phase 1 of docs/plans/SYSTEM_PAGE_AUDIT.md.
#
# Covers static substrate-dependent strings in ledatic.org/system. The
# live JS-fetched values are covered by tools/audit/attest_endpoint_walk.sh.
#
# Phase 1 classes: rail_version, test_count.
# Phase 2 classes (TODO): stdlib_count, compiler_loc, function_count,
#                        pk_fingerprint, verifier_paths.
#
# Exit 0 if all PASS, 1 if any FAIL, 2 on probe error.

set -u

QUIET=0
LAB_MODE=0
while (( $# )); do
  case "$1" in
    -q)    QUIET=1; shift ;;
    --lab) LAB_MODE=1; QUIET=1; shift ;;
    *)     echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

BASE="${LEDATIC_BASE:-https://ledatic.org}"
# The /system page advertises PUBLIC rail (origin/master), so verify against a
# master-TRACKING reference, NOT a working clone -- those sit on feature branches
# with divergent test counts, which caused the 2026-07-07 171-vs-178 false FAIL
# (the working clone was on security/gitleaks-config@171; origin/master actually
# tests 178, matching the page). Self-refresh to latest origin/master each run.
RAIL_DIR="${RAIL_MASTER_REF:-${HOME}/.fleet/rail-master-ref}"
if [[ -e "$RAIL_DIR/.git" ]]; then
  git -C "$RAIL_DIR" fetch --quiet origin master 2>/dev/null \
    && git -C "$RAIL_DIR" reset --hard --quiet origin/master 2>/dev/null || true
fi
PAGE=/tmp/system_audit.html

total_pass=0
total_fail=0
failing=()

log()    { (( QUIET )) || echo "  $*"; }
header() { (( QUIET )) || echo "--- $* ---"; }
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

curl -sf "$BASE/system" -o "$PAGE" || { echo "FATAL: could not fetch /system"; exit 2; }

# ============================================================================
# CLASS: rail_version — header version matches latest git tag
# ============================================================================
class_rail_version() {
  local page_ver tag_ver
  # Page carries the version as an attested <data> element, e.g.
  # <data pulse="...">v5.2.0</data> (format moved off the old "RAIL v5.1.0"
  # header string 2026-07 — match the bare vX.Y.Z anywhere).
  page_ver=$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' "$PAGE" | head -1)
  tag_ver=$(cd "$RAIL_DIR" && git tag --list 'v*' | sort -V | tail -1)
  log "page: $page_ver  substrate: $tag_ver"
  if [[ "$page_ver" == "$tag_ver" ]]; then
    verdict rail_version PASS
  else
    log "FAIL: header version $page_ver != latest tag $tag_ver"
    verdict rail_version FAIL
  fi
}

# ============================================================================
# CLASS: test_count — header X/Y matches actual test run
# ============================================================================
class_test_count() {
  local page_count truth_count
  # Header reads "RAIL v5.1.0 · 141/141"
  page_count=$(grep -oE '[0-9]+/[0-9]+' "$PAGE" | head -1)
  truth_count=$(cd "$RAIL_DIR" && ./rail_native test 2>&1 | tail -1 | grep -oE '[0-9]+/[0-9]+' | head -1)
  log "page: $page_count  substrate: $truth_count"
  if [[ "$page_count" == "$truth_count" ]]; then
    verdict test_count PASS
  else
    log "FAIL: page $page_count != substrate $truth_count"
    verdict test_count FAIL
  fi
}

# ============================================================================
# RUN
# ============================================================================
(( QUIET )) || echo "=== SYSTEM PAGE AUDIT — $(date -u +%FT%TZ) ==="
(( QUIET )) || echo "base: $BASE"
(( QUIET )) || echo

header rail_version;  class_rail_version
header test_count;    class_test_count

echo
echo "=== SUMMARY ==="
echo "PASS=$total_pass FAIL=$total_fail"
if (( total_fail > 0 )); then
  printf 'FAILING_CLASSES='
  IFS=,; echo "${failing[*]}"
fi

if (( LAB_MODE == 1 )); then
  echo "===RAIL_LAB_COUNTERS==="
  echo "{\"counter\": \"classes_total\", \"value\": $((total_pass + total_fail))}"
  echo "{\"counter\": \"classes_pass\", \"value\": $total_pass}"
  echo "{\"counter\": \"classes_fail\", \"value\": $total_fail}"
  echo "===END==="
  if (( total_fail == 0 )); then
    echo "===VERDICT=== PASS"
    exit 0
  else
    echo "===VERDICT=== FALSIFIED"
    exit 0  # exit 0 in --lab mode: runner succeeded, verdict is the falsification claim
  fi
fi

[[ $total_fail -eq 0 ]] && exit 0 || exit 1
