#!/usr/bin/env bash
# tools/audit/spurarm_chain_schema_audit.sh
#
# README-vs-substrate audit for the ledatic-arm attestation claim.
# See docs/plans/SPURARM_ATTEST_AUDIT.md.
#
# The README at Ledatic-Empire/ledatic-arm asserts every commanded pose
# carries an attestation tuple (state, action, model_hash, kernel_hash,
# beacon_pulse). This walker verifies that promise against the latest
# entry in ~/.ledatic-arm/chain/armsim_chain.jsonl.
#
# Aliases: README "action" → record "params" (same semantic).
#
# Exit 0 if every tuple field is present (or aliased), 1 if any missing,
# 2 on probe error.

set -u

QUIET=0
[[ "${1:-}" == "-q" ]] && QUIET=1

ARM_DIR="${LEDATIC_ARM_DIR:-${HOME}/projects/ledatic-arm}"
CHAIN="${LEDATIC_ARM_CHAIN:-${HOME}/.ledatic-arm/chain/armsim_chain.jsonl}"
README="$ARM_DIR/README.md"

# Allowed aliases: tuple field -> record field with same semantic.
# Inline because macOS default bash 3.2 has no associative arrays.
alias_for() {
  case "$1" in
    action) echo "params" ;;
    *)      echo "" ;;
  esac
}

log()    { (( QUIET )) || echo "  $*"; }
header() { (( QUIET )) || echo "--- $* ---"; }

[[ -r "$README" ]] || { echo "FATAL: cannot read $README"; exit 2; }
[[ -r "$CHAIN"  ]] || { echo "FATAL: cannot read $CHAIN"; exit 2; }

(( QUIET )) || echo "=== SPURARM CHAIN SCHEMA AUDIT — $(date -u +%FT%TZ) ==="
(( QUIET )) || echo "readme: $README"
(( QUIET )) || echo "chain:  $CHAIN"
(( QUIET )) || echo

# ---- 1. Extract tuple fields from README ---------------------------------
# Find the per-pose record tuple. README format evolved:
#   v1 (aspirational): (state, action, model_hash, kernel_hash, beacon_pulse)
#   v2 (substrate):    (t, kind, params, state, prev_sha, sha)
# Match either by looking for a parenthesized list containing 'state'.
header "tuple extraction"
tuple_line=$(grep -E '`\([^)]*\bstate\b[^)]*\)`' "$README" | head -1)
if [[ -z "$tuple_line" ]]; then
  echo "FATAL: per-pose tuple line not found in README"; exit 2
fi
log "claim line: $(echo "$tuple_line" | sed 's/^[[:space:]]*//')"
tuple_raw=$(echo "$tuple_line" | grep -oE '\([^)]*\bstate\b[^)]*\)' | head -1)
# Strip parens, split on comma, trim whitespace
TUPLE_FIELDS=()
IFS=',' read -ra parts <<<"${tuple_raw#(}"
for f in "${parts[@]}"; do
  field=$(echo "$f" | tr -d '() `' | xargs)
  [[ -n "$field" ]] && TUPLE_FIELDS+=("$field")
done
log "fields: ${TUPLE_FIELDS[*]}"
echo

# ---- 2. Read latest chain record -----------------------------------------
header "chain inspection"
last_rec=$(tail -1 "$CHAIN")
total=$(wc -l <"$CHAIN" | tr -d ' ')
last_mtime=$(stat -f "%Sm" "$CHAIN" 2>/dev/null || stat -c "%y" "$CHAIN" 2>/dev/null)
log "records: $total"
log "last write: $last_mtime"
log "latest: $last_rec"
echo

# ---- 3. Verify each tuple field is present (or aliased) -------------------
header "per-field verdicts"
missing=()
present=()
for field in "${TUPLE_FIELDS[@]}"; do
  alias=$(alias_for "$field")
  if grep -qE "\"$field\"[[:space:]]*:" <<<"$last_rec"; then
    log "  $field ✓ present"
    present+=("$field")
  elif [[ -n "$alias" ]] && grep -qE "\"$alias\"[[:space:]]*:" <<<"$last_rec"; then
    log "  $field ✓ present (aliased as $alias)"
    present+=("$field(alias:$alias)")
  else
    log "  $field ✗ MISSING"
    missing+=("$field")
  fi
done
echo

# ---- 4. Verdict + summary -------------------------------------------------
echo "=== SUMMARY ==="
echo "tuple_size=${#TUPLE_FIELDS[@]} present=${#present[@]} missing=${#missing[@]}"
if (( ${#missing[@]} == 0 )); then
  echo "VERDICT=PASS — README tuple matches substrate"
  exit 0
else
  printf 'MISSING_FIELDS='
  IFS=,; echo "${missing[*]}"
  echo "VERDICT=FALSIFIED — README claims more than the substrate delivers"
  exit 1
fi
