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

# Text of the page's Figure for a data-src key. The page's numbers are
# <data class="fig" data-src="KEY">…</data> elements, injected from the
# substrate at deploy (one element per line by the site's contract), so this
# is the page's claim; anything else matching the same shape is prose or a
# recipe. Empty when the page carries no such Figure, which then fails the
# class loudly rather than matching something that merely looks like one.
fig_text() {
  grep -oE "<data[^>]*data-src=\"$1\"[^>]*>[^<]*</data>" "$PAGE" | head -1 \
    | sed -E 's/.*>([^<]*)<\/data>$/\1/'
}

# ============================================================================
# CLASS: rail_version — header version matches latest git tag
# ============================================================================
class_rail_version() {
  local page_ver tag_ver
  # The page's version is its Figure: <data class="fig" data-src="repo:version">.
  # Until 2026-09-15 this took the FIRST vX.Y.Z anywhere in the HTML, which
  # was the verify recipe's release URL, so a correct footer failed on a
  # recipe example for two weeks (and the reason never reached the log,
  # because -q silenced it). FAIL lines print regardless of -q now.
  page_ver=$(fig_text repo:version)
  tag_ver=$(cd "$RAIL_DIR" && git tag --list 'v*' | sort -V | tail -1)
  log "page: $page_ver  substrate: $tag_ver"
  if [[ -n "$page_ver" && "$page_ver" == "$tag_ver" ]]; then
    verdict rail_version PASS
  else
    echo "  FAIL: page repo:version Figure '${page_ver:-<none>}' != latest tag '$tag_ver'"
    verdict rail_version FAIL
  fi
}

# ============================================================================
# CLASS: test_count — header X/Y matches actual test run
# ============================================================================
class_test_count() {
  local page_count truth_count
  # The page's count is its Figure: <data class="fig" data-src="tests:total"
  # data-fmt="ratio">N/N</data>. The substrate is the suite itself, run here
  # on the master-tracking clone.
  page_count=$(fig_text tests:total)
  truth_count=$(cd "$RAIL_DIR" && ./rail_native test 2>&1 | tail -1 | grep -oE '[0-9]+/[0-9]+' | head -1)
  log "page: $page_count  substrate: $truth_count"
  if [[ -n "$page_count" && "$page_count" == "$truth_count" ]]; then
    verdict test_count PASS
  else
    echo "  FAIL: page tests:total Figure '${page_count:-<none>}' != suite '$truth_count'"
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
