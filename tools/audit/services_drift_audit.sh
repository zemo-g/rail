#!/usr/bin/env bash
# tools/audit/services_drift_audit.sh
#
# Cross-checks CLAUDE.md's "Currently running" service table against
# launchctl reality. Originally task #7 (sitestats source-of-truth);
# broadened because the table itself has drifted.
#
# See docs/plans/SERVICES_DRIFT_AUDIT.md.
#
# Exit 0 if every claimed-running service is actually loaded, 1 on drift,
# 2 on probe error.

set -u

QUIET=0
LAB_MODE=0
while (( $# )); do
  case "$1" in
    -q)    QUIET=1; shift ;;
    --lab) LAB_MODE=1; QUIET=1; shift ;;   # emit run.rail-compatible sentinels
    *)     echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

CLAUDE_MD="${CLAUDE_MD:-${HOME}/CLAUDE.md}"
AGENTS_DIR="${HOME}/Library/LaunchAgents"

log()    { (( QUIET )) || echo "  $*"; }
header() { (( QUIET )) || echo "--- $* ---"; }

[[ -r "$CLAUDE_MD" ]] || { echo "FATAL: cannot read $CLAUDE_MD"; exit 2; }

# Extract claimed-running com.ledatic.* services from the
# "Currently running" section of CLAUDE.md.  Stop at the next "**header**".
claimed=$(awk '
  /^\*\*Currently running/ { in_block=1; next }
  in_block && /^\*\*/ { in_block=0 }
  in_block { print }
' "$CLAUDE_MD" | grep -oE 'com\.ledatic\.[a-z_-]*[a-z0-9]' | sort -u)

if [[ -z "$claimed" ]]; then
  echo "FATAL: no claimed-running services found in $CLAUDE_MD"
  exit 2
fi

claimed_count=$(echo "$claimed" | wc -l | tr -d ' ')
(( QUIET )) || echo "=== SERVICES DRIFT AUDIT — $(date -u +%FT%TZ) ==="
(( QUIET )) || echo "source: $CLAUDE_MD"
(( QUIET )) || echo "claimed-running services: $claimed_count"
(( QUIET )) || echo

# Cache launchctl list once
LCTL=/tmp/services_audit_launchctl.txt
launchctl list >"$LCTL" 2>/dev/null

header per_service
total=0
ok=0
not_loaded=()
no_plist=()
disabled_plist=()
bad_paths=()

while IFS= read -r svc; do
  [[ -z "$svc" ]] && continue
  total=$((total + 1))

  loaded=0
  plist_present=0
  plist_disabled=0
  paths_ok=1

  if grep -qF "$svc" "$LCTL"; then
    loaded=1
  fi

  if [[ -f "$AGENTS_DIR/$svc.plist" ]]; then
    plist_present=1
  elif [[ -f "$AGENTS_DIR/_disabled.$svc.plist" ]]; then
    plist_disabled=1
  fi

  # Plist path validation (only meaningful if a plist exists).
  # Skip StandardOutPath/StandardErrorPath — they're write targets,
  # created on first run; absence is normal.
  if (( plist_present )); then
    paths=$(plutil -convert xml1 -o - "$AGENTS_DIR/$svc.plist" 2>/dev/null | \
            awk '
              /<key>StandardOutPath<\/key>/ { skip_next=1; next }
              /<key>StandardErrorPath<\/key>/ { skip_next=1; next }
              /<string>\/[^<]+<\/string>/ {
                if (skip_next) { skip_next=0; next }
                s=$0; sub(/.*<string>/,"",s); sub(/<\/string>.*/,"",s);
                if (s ~ /^\/[^:]+$/) print s
              }
            ')
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      if [[ ! -e "$p" ]]; then
        paths_ok=0
        bad_paths+=("$svc: $p")
      fi
    done <<<"$paths"
  fi

  # Verdict per service
  if (( loaded == 1 && plist_present == 1 && paths_ok == 1 )); then
    log "  $svc ✓"
    ok=$((ok + 1))
  else
    reason=""
    (( loaded == 0 )) && reason="${reason}not-loaded "
    (( plist_disabled == 1 )) && reason="${reason}plist-disabled "
    (( plist_present == 0 && plist_disabled == 0 )) && reason="${reason}no-plist "
    (( paths_ok == 0 )) && reason="${reason}bad-paths "
    log "  $svc ✗ ($reason)"
    (( loaded == 0 )) && not_loaded+=("$svc")
    (( plist_disabled == 1 )) && disabled_plist+=("$svc")
    (( plist_present == 0 && plist_disabled == 0 )) && no_plist+=("$svc")
  fi
done <<<"$claimed"

echo
echo "=== SUMMARY ==="
echo "claimed=$total ok=$ok drifted=$((total - ok))"
if (( ${#not_loaded[@]} > 0 )); then
  echo "NOT_LOADED: ${not_loaded[*]}"
fi
if (( ${#disabled_plist[@]} > 0 )); then
  echo "DISABLED_PLIST: ${disabled_plist[*]}"
fi
if (( ${#no_plist[@]} > 0 )); then
  echo "NO_PLIST: ${no_plist[*]}"
fi
if (( ${#bad_paths[@]} > 0 )); then
  echo "BAD_PATHS:"
  for bp in "${bad_paths[@]}"; do echo "  $bp"; done
fi

if (( LAB_MODE == 1 )); then
  echo "===RAIL_LAB_COUNTERS==="
  echo "{\"counter\": \"claimed\", \"value\": $total}"
  echo "{\"counter\": \"ok\", \"value\": $ok}"
  echo "{\"counter\": \"drifted\", \"value\": $((total - ok))}"
  echo "{\"counter\": \"not_loaded_count\", \"value\": ${#not_loaded[@]}}"
  echo "{\"counter\": \"disabled_plist_count\", \"value\": ${#disabled_plist[@]}}"
  echo "===END==="
  if (( ok == total )); then
    echo "===VERDICT=== PASS"
    exit 0
  else
    echo "===VERDICT=== FALSIFIED"
    exit 0  # exit 0 in --lab mode: runner succeeded, verdict is the falsification claim
  fi
fi

if (( ok == total )); then
  echo "VERDICT=PASS"
  exit 0
else
  echo "VERDICT=FALSIFIED — CLAUDE.md service table has drifted"
  exit 1
fi
