#!/usr/bin/env bash
# tools/audit/dda_closeout_audit.sh
#
# Walks the public DDA attestation surface (index → manifests → sidecars).
# Checks structural integrity + coverage. Crypto verification is Phase 2.
#
# See docs/plans/DDA_CLOSEOUT_AUDIT.md.
#
# Exit 0 if all classes PASS, 1 if any FAIL, 2 on probe error.

set -u

QUIET=0
[[ "${1:-}" == "-q" ]] && QUIET=1

BASE="${LEDATIC_BASE:-https://ledatic.org}"
VAULT="${HOME}/ledatic-clients/dda/reports"

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

(( QUIET )) || echo "=== DDA CLOSEOUT AUDIT — $(date -u +%FT%TZ) ==="
(( QUIET )) || echo "base: $BASE  vault: $VAULT"
(( QUIET )) || echo

# ---- Fetch index ---------------------------------------------------------
IDX=/tmp/dda_index.json
curl -sf "$BASE/dda/index.json" -o "$IDX" \
  || { echo "FATAL: cannot fetch /dda/index.json"; exit 2; }

total_briefs=$(python3 -c "import json,sys; print(json.load(open('$IDX')).get('total_briefs',0))")
row_count=$(python3 -c "import json,sys; print(len(json.load(open('$IDX')).get('rows',[])))")
latest_delivered=$(python3 -c "import json,sys; print(json.load(open('$IDX')).get('latest_delivered_at',''))")
(( QUIET )) || echo "index: $row_count rows, $total_briefs briefs total, latest=$latest_delivered"
(( QUIET )) || echo

# ============================================================================
# CLASS: total_briefs_consistency
# ============================================================================
header total_briefs_consistency
sum_briefs=$(python3 -c "import json; d=json.load(open('$IDX')); print(sum(r['brief_count'] for r in d.get('rows',[])))")
log "index.total_briefs=$total_briefs  sum(rows.brief_count)=$sum_briefs"
if [[ "$total_briefs" == "$sum_briefs" ]]; then
  verdict total_briefs_consistency PASS
else
  log "FAIL: top-level total_briefs disagrees with sum of rows"
  verdict total_briefs_consistency FAIL
fi

# ============================================================================
# CLASS: manifest_reachable + sidecar_coverage + sidecar_wellformed
#  (per-row walk; aggregate verdicts)
# ============================================================================
header per_row_walk
rows=$(python3 -c "
import json
for r in json.load(open('$IDX')).get('rows',[]):
    print(f\"{r['model']}|{r['week']}|{r['vertical']}\")")

manifest_fail=0
sidecar_missing=0
sidecar_malformed=0
sidecars_checked=0

while IFS='|' read -r model week vertical; do
  [[ -z "$model" ]] && continue
  manifest_url="$BASE/dda/$model/$week/$vertical/manifest.json"
  log "row: $model/$week/$vertical"
  if ! curl -sf "$manifest_url" -o /tmp/dda_manifest.json; then
    log "  FAIL: manifest unreachable"
    manifest_fail=$((manifest_fail + 1))
    continue
  fi
  # Manifest schema: briefs is a dict keyed by name; each brief has
  # digests[ext]. One sidecar per (name, ext) pair.
  pairs=$(python3 -c "
import json
m=json.load(open('/tmp/dda_manifest.json'))
briefs=m.get('briefs', {})
if isinstance(briefs, dict):
    for name, b in briefs.items():
        for ext in b.get('digests', {}).keys():
            print(f'{name}.{ext}')")
  if [[ -z "$pairs" ]]; then
    log "  WARN: no (name, ext) pairs extracted from manifest"
    continue
  fi
  while IFS= read -r pair; do
    [[ -z "$pair" ]] && continue
    sidecar="$BASE/dda/$model/$week/$vertical/$pair.attestation.json"
    sidecars_checked=$((sidecars_checked + 1))
    if ! curl -sf "$sidecar" -o /tmp/dda_sidecar.json; then
      log "  MISS: $pair.attestation.json"
      sidecar_missing=$((sidecar_missing + 1))
      continue
    fi
    # Check required fields. Sidecar wraps the attestation under various keys
    # depending on schema vintage; check top-level + common nestings.
    missing_fields=$(python3 -c "
import json
d=json.load(open('/tmp/dda_sidecar.json'))
req=['pulse_id','sig','pk_fp']
# Try top-level then attestation/witness nesting
for src in (d, d.get('attestation', {}), d.get('witness', {})):
    if all(f in src for f in req):
        print(''); break
else:
    miss=[f for f in req if f not in d and f not in d.get('attestation',{}) and f not in d.get('witness',{})]
    print(','.join(miss))")
    if [[ -n "$missing_fields" ]]; then
      log "  MALFORMED: $pair.attestation.json missing $missing_fields"
      sidecar_malformed=$((sidecar_malformed + 1))
    fi
  done <<<"$pairs"
done <<<"$rows"

log "manifests unreachable: $manifest_fail"
log "sidecars checked: $sidecars_checked"
log "sidecars missing: $sidecar_missing"
log "sidecars malformed: $sidecar_malformed"

if (( manifest_fail == 0 )); then
  verdict manifest_reachable PASS
else
  verdict manifest_reachable FAIL
fi

if (( sidecar_missing == 0 && sidecars_checked > 0 )); then
  verdict sidecar_coverage PASS
elif (( sidecars_checked == 0 )); then
  verdict sidecar_coverage FAIL  # no sidecars checked = manifest schema unknown
else
  verdict sidecar_coverage FAIL
fi

if (( sidecar_malformed == 0 )); then
  verdict sidecar_wellformed PASS
else
  verdict sidecar_wellformed FAIL
fi

# ============================================================================
# CLASS: vault_coverage — local weeks vs index weeks
# ============================================================================
header vault_coverage
if [[ -d "$VAULT" ]]; then
  index_weeks=$(python3 -c "
import json
weeks = set()
for r in json.load(open('$IDX')).get('rows', []):
    weeks.add(r['week'])
print('\n'.join(sorted(weeks)))")
  vault_weeks=$(find "$VAULT" -maxdepth 3 -type d -name 'POC-*' 2>/dev/null | xargs -I{} basename {} 2>/dev/null | sort -u)
  log "index weeks: $(echo $index_weeks | tr '\n' ' ')"
  log "vault weeks: $(echo $vault_weeks | tr '\n' ' ')"
  missing_in_index=$(comm -23 <(echo "$vault_weeks") <(echo "$index_weeks") 2>/dev/null)
  if [[ -z "$missing_in_index" ]]; then
    verdict vault_coverage PASS
  else
    log "FAIL: weeks present in vault but not in index: $(echo $missing_in_index | tr '\n' ' ')"
    verdict vault_coverage FAIL
  fi
else
  log "no local vault at $VAULT — skipping"
  verdict vault_coverage PASS
fi

# ---- Summary -------------------------------------------------------------
echo
echo "=== SUMMARY ==="
echo "PASS=$total_pass FAIL=$total_fail"
echo "rows=$row_count total_briefs=$total_briefs sidecars_checked=$sidecars_checked"
if (( total_fail > 0 )); then
  printf 'FAILING_CLASSES='
  IFS=,; echo "${failing[*]}"
fi

[[ $total_fail -eq 0 ]] && exit 0 || exit 1
