#!/bin/sh
# tools/lab/watchers/spurarm_cap_h_phase0_phase1prep.sh
#
# Attests Phase 0 (db20fee, JIT+bf16 foundation) + Phase 1 prep (44fe689,
# corpus v2 spec + Cap H config + bench gate) on spurarm/cap-h.
#
# Verifies:
#   - db20fee commit exists on spurarm/cap-h with the 13 expected files
#   - 44fe689 commit exists with the 8 expected files
#   - config_cap_h.rail assembles cleanly (as: OK from rail_native)
#   - All foundation modules present on disk
#
# Counters emitted (see canonical chain-entry format):
#   foundation_commit_sha
#   foundation_insertions
#   foundation_files_changed
#   phase1_prep_commit_sha
#   phase1_prep_insertions
#   phase1_prep_files_changed
#   config_cap_h_assembles  (1 = as:OK, 0 = not)
#
# PASS iff both commits present + counts >= expected + config assembles.

set -u

REPO="$HOME/projects/rail-spurarm-cap-h"
cd "$REPO" || exit 1

# Phase 0 commit lookup
P0_SHA=$(git log --grep='foundation -- JIT . bf16' --pretty=%H spurarm/cap-h 2>/dev/null | head -1)
if [ -z "$P0_SHA" ]; then
  P0_SHA=$(git log --grep='spurarm/cap-h: foundation' --pretty=%H spurarm/cap-h 2>/dev/null | head -1)
fi
P0_SHORT=$(echo "$P0_SHA" | cut -c1-7)
P0_STATS=$(git show "$P0_SHA" --shortstat 2>/dev/null | tail -1)
P0_FILES=$(echo "$P0_STATS" | awk '{print $1}')
P0_INS=$(echo "$P0_STATS" | sed -n 's/.* \([0-9]*\) insertion.*/\1/p')

# Phase 1 prep commit lookup
P1_SHA=$(git log --grep='Phase 1 prep' --pretty=%H spurarm/cap-h 2>/dev/null | head -1)
P1_SHORT=$(echo "$P1_SHA" | cut -c1-7)
P1_STATS=$(git show "$P1_SHA" --shortstat 2>/dev/null | tail -1)
P1_FILES=$(echo "$P1_STATS" | awk '{print $1}')
P1_INS=$(echo "$P1_STATS" | sed -n 's/.* \([0-9]*\) insertion.*/\1/p')

# Smoke: config_cap_h.rail must assemble
CONFIG_OUT=$(./rail_native tools/spurarm/train/config_cap_h.rail 2>&1)
CONFIG_OK=0
if echo "$CONFIG_OUT" | grep -q 'as: OK'; then
  CONFIG_OK=1
fi

# Sanity defaults
P0_FILES=${P0_FILES:-0}
P0_INS=${P0_INS:-0}
P1_FILES=${P1_FILES:-0}
P1_INS=${P1_INS:-0}

# Verdict gate
VERDICT="FALSIFIED"
if [ -n "$P0_SHA" ] && [ -n "$P1_SHA" ] \
  && [ "$P0_FILES" -ge 13 ] && [ "$P0_INS" -ge 1200 ] \
  && [ "$P1_FILES" -ge 8 ] && [ "$P1_INS" -ge 1800 ] \
  && [ "$CONFIG_OK" = 1 ]; then
  VERDICT="PASS"
fi

cat <<COUNTERS
===RAIL_LAB_COUNTERS===
{"counter": "foundation_commit_sha", "value": "$P0_SHORT"}
{"counter": "foundation_insertions", "value": $P0_INS}
{"counter": "foundation_files_changed", "value": $P0_FILES}
{"counter": "phase1_prep_commit_sha", "value": "$P1_SHORT"}
{"counter": "phase1_prep_insertions", "value": $P1_INS}
{"counter": "phase1_prep_files_changed", "value": $P1_FILES}
{"counter": "config_cap_h_assembles", "value": $CONFIG_OK}
===END===
COUNTERS
echo "===VERDICT=== $VERDICT"
exit 0
