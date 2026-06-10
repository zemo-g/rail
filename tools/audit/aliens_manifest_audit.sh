#!/usr/bin/env bash
# tools/audit/aliens_manifest_audit.sh
#
# /pursue manifest re-hash audit. Picks the smallest record, verifies
# size + sha256 against what the manifest claims.
#
# Exit 0 if all checks PASS, 1 if drift, 2 on probe error.

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
MANIFEST_PATH="${MANIFEST_PATH:-/pursue/manifest.jsonl}"
MANIFEST=/tmp/aliens_manifest.jsonl

log()    { (( QUIET )) || echo "  $*"; }
header() { (( QUIET )) || echo "--- $* ---"; }

# ---- 1. Fetch manifest ---------------------------------------------------
curl -sf "$BASE$MANIFEST_PATH" -o "$MANIFEST" \
  || { echo "FATAL: cannot fetch $MANIFEST_PATH"; exit 2; }

records=$(wc -l <"$MANIFEST" | tr -d ' ')
(( QUIET )) || echo "=== ALIENS MANIFEST AUDIT — $(date -u +%FT%TZ) ==="
(( QUIET )) || echo "manifest: $BASE$MANIFEST_PATH ($records records)"
(( QUIET )) || echo

# ---- 2. Pick smallest record --------------------------------------------
header "sample selection"
# Extract size_bytes + local_path + sha256 per line; tolerate whitespace.
# Find smallest by size. One line per JSON record.
sample=$(while IFS= read -r line; do
  s=$(echo "$line" | grep -oE '"size_bytes"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | head -1)
  p=$(echo "$line" | grep -oE '"local_path"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"local_path"[[:space:]]*:[[:space:]]*"//;s/"$//' | head -1)
  # First sha256 in record is the main file's (thumbnail_sha256 comes later)
  h=$(echo "$line" | grep -oE '"sha256"[[:space:]]*:[[:space:]]*"[0-9a-f]+"' | head -1 | grep -oE '[0-9a-f]{64}')
  [[ -n "$s" && -n "$p" && -n "$h" ]] && printf '%s\t%s\t%s\n' "$s" "$p" "$h"
done <"$MANIFEST" | sort -n | head -1)
size_claimed=$(echo "$sample" | cut -f1)
local_path=$(echo "$sample" | cut -f2)
sha_claimed=$(echo "$sample" | cut -f3)
log "smallest record: $local_path"
log "claimed size: $size_claimed bytes"
log "claimed sha256: ${sha_claimed:0:16}..."

if [[ -z "$size_claimed" || -z "$local_path" || -z "$sha_claimed" ]]; then
  echo "FATAL: could not parse manifest fields"
  exit 2
fi

# ---- 3. HEAD: size check ------------------------------------------------
header "size check"
# URL-encode path segments (R2 keys with spaces, etc.)
encoded_path=$(python3 -c "import sys, urllib.parse; print('/'.join(urllib.parse.quote(p) for p in sys.argv[1].split('/')))" "$local_path")
url="$BASE/pursue/$encoded_path"
size_actual=$(curl -sfI "$url" | grep -i '^content-length:' | awk '{print $2}' | tr -d '\r')
log "url: $url"
log "actual size: $size_actual bytes"

fail=0
if [[ "$size_actual" != "$size_claimed" ]]; then
  log "FAIL: size drift ($size_claimed claimed vs $size_actual actual)"
  fail=1
fi

# ---- 4. GET: sha256 check -----------------------------------------------
header "sha256 check"
tmp=/tmp/aliens_audit_sample.bin
rm -f "$tmp"
curl -sf "$url" -o "$tmp" || { echo "FATAL: GET failed for $url"; exit 2; }
sha_actual=$(shasum -a 256 "$tmp" | awk '{print $1}')
log "actual sha256: ${sha_actual:0:16}..."

if [[ "$sha_actual" != "$sha_claimed" ]]; then
  log "FAIL: sha256 drift"
  log "  claimed: $sha_claimed"
  log "  actual:  $sha_actual"
  fail=1
fi
rm -f "$tmp"

# ---- 5. Verdict ----------------------------------------------------------
echo
echo "=== SUMMARY ==="
echo "sampled: $local_path"

if (( LAB_MODE == 1 )); then
  size_match=$([[ "$size_actual" == "$size_claimed" ]] && echo 1 || echo 0)
  sha_match=$([[ "$sha_actual" == "$sha_claimed" ]] && echo 1 || echo 0)
  echo "===RAIL_LAB_COUNTERS==="
  echo "{\"counter\": \"size_match\", \"value\": $size_match}"
  echo "{\"counter\": \"sha_match\", \"value\": $sha_match}"
  echo "{\"counter\": \"sampled_size_bytes\", \"value\": ${size_claimed:-0}}"
  echo "{\"counter\": \"manifest_records\", \"value\": ${records:-0}}"
  echo "===END==="
  if (( fail == 0 )); then
    echo "===VERDICT=== PASS"
    exit 0
  else
    echo "===VERDICT=== FALSIFIED"
    exit 0  # exit 0 in --lab mode: runner succeeded, verdict is the falsification claim
  fi
fi

if (( fail == 0 )); then
  echo "VERDICT=PASS — sampled record matches manifest (size + sha256)"
  exit 0
else
  echo "VERDICT=FALSIFIED — drift detected on $local_path"
  exit 1
fi
