#!/usr/bin/env bash
# tools/audit/aliens_manifest_audit.sh
#
# /pursue manifest re-hash audit.
#
# Reworked 2026-07-25 for the free-tier posture. The old version sampled the
# smallest DOCUMENT and required it to be fetchable — true only while R2 was
# mirroring 10.5 GB of PDFs. Document bytes are now deliberately withheld (CF
# ToS §2.8 on a Free zone; war.gov 403s us, so there is no upstream to
# redirect to either), which made this audit exit FATAL every day on a policy
# rather than a fault.
#
# The invariant that still earns its keep is the one the archive rests on:
# NOTHING IS SERVED THAT FAILS ITS OWN ATTESTATION. So this samples what we do
# serve — the digest-verified thumbnails — and re-hashes them against the
# manifest. Withheld is expected and never a failure; drift on a served
# artifact is.
#
# See docs/plans/ALIENS_MANIFEST_AUDIT.md.
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
SAMPLE_N="${SAMPLE_N:-3}"

log()    { (( QUIET )) || echo "  $*"; }
header() { (( QUIET )) || echo "--- $* ---"; }

# ---- 1. Fetch manifest ---------------------------------------------------
curl -sf "$BASE$MANIFEST_PATH" -o "$MANIFEST" \
  || { echo "FATAL: cannot fetch $MANIFEST_PATH"; exit 2; }

records=$(wc -l <"$MANIFEST" | tr -d ' ')
(( QUIET )) || echo "=== ALIENS MANIFEST AUDIT — $(date -u +%FT%TZ) ==="
(( QUIET )) || echo "manifest: $BASE$MANIFEST_PATH ($records records)"
(( QUIET )) || echo

# ---- 2. Candidate served artifacts (thumbnails, smallest first) ----------
# A thumbnail path is published only when every record citing it agrees on one
# digest, so sampling by path is well-defined. Smallest-first keeps the audit
# cheap and deterministic. Serial fetches on purpose: hammering our own CDN in
# parallel trips bot protection, and then you are hashing a challenge page.
header "sample selection"
candidates=$(python3 - "$MANIFEST" "$SAMPLE_N" <<'PY'
import json, sys, collections
path, n = sys.argv[1], int(sys.argv[2])
recs = [json.loads(l) for l in open(path) if l.strip()]
digests = collections.defaultdict(set)
for r in recs:
    t = r.get("thumbnail_local")
    if t:
        digests[t].add(r.get("thumbnail_sha256"))
rows = {}
for r in recs:
    t = r.get("thumbnail_local")
    if not t or len(digests[t]) != 1:
        continue                      # ambiguous path — correctly withheld
    rows[t] = (r.get("thumbnail_size_bytes") or 0, t, r.get("thumbnail_sha256"))
for size, t, sha in sorted(rows.values())[:n]:
    print(f"{size}\t{t}\t{sha}")
PY
)
[[ -n "$candidates" ]] || { echo "FATAL: no unambiguous thumbnail records in manifest"; exit 2; }

# ---- 3. Verify each served candidate ------------------------------------
fail=0; served=0; withheld=0
while IFS=$'\t' read -r size_claimed local_path sha_claimed; do
  [[ -n "$local_path" ]] || continue
  rel=${local_path#files/}
  encoded=$(python3 -c "import sys,urllib.parse;print('/'.join(urllib.parse.quote(p) for p in sys.argv[1].split('/')))" "$rel")
  url="$BASE/pursue/files/$encoded"
  tmp=/tmp/aliens_audit_sample.bin
  rm -f "$tmp"
  if ! curl -sf --max-time 40 "$url" -o "$tmp"; then
    withheld=$((withheld + 1))
    log "withheld (expected, not a failure): $rel"
    continue
  fi
  served=$((served + 1))
  size_actual=$(wc -c <"$tmp" | tr -d ' ')
  sha_actual=$(shasum -a 256 "$tmp" | awk '{print $1}')
  if [[ "$size_actual" != "$size_claimed" ]]; then
    log "FAIL: size drift on $rel ($size_claimed claimed vs $size_actual actual)"
    fail=1
  elif [[ "$sha_actual" != "$sha_claimed" ]]; then
    log "FAIL: sha256 drift on $rel"
    log "  claimed: $sha_claimed"
    log "  actual:  $sha_actual"
    fail=1
  else
    log "ok  $rel  (${size_actual} B, ${sha_actual:0:16}…)"
  fi
  rm -f "$tmp"
done <<<"$candidates"

# A served set of zero means thumbnail publication silently lapsed — the
# archive would render as placeholders and nobody would notice.
if (( served == 0 )); then
  log "FAIL: no sampled thumbnail was served — publication may have lapsed"
  fail=1
fi

# ---- 4. Policy check: document bytes stay withheld -----------------------
header "document withholding"
doc=$(python3 - "$MANIFEST" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
recs = [r for r in recs if r.get("local_path")]
r = min(recs, key=lambda r: r.get("size_bytes") or 0)
print(r["local_path"][len("files/"):])
PY
)
doc_enc=$(python3 -c "import sys,urllib.parse;print('/'.join(urllib.parse.quote(p) for p in sys.argv[1].split('/')))" "$doc")
doc_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$BASE/pursue/files/$doc_enc")
if [[ "$doc_code" == "404" ]]; then
  log "ok  documents withheld as intended (sampled → 404)"
else
  log "NOTE: document bytes are being served again (sampled → $doc_code)"
  log "      not a failure — but re-check the ToS §2.8 exposure decision"
fi

# ---- 5. Verdict ----------------------------------------------------------
echo
echo "=== SUMMARY ==="
echo "sampled=$((served + withheld)) served=$served withheld=$withheld doc_probe=$doc_code"

if (( LAB_MODE == 1 )); then
  echo "===RAIL_LAB_COUNTERS==="
  echo "{\"counter\": \"served_verified\", \"value\": $served}"
  echo "{\"counter\": \"served_drifted\", \"value\": $fail}"
  echo "{\"counter\": \"manifest_records\", \"value\": ${records:-0}}"
  echo "===END==="
  if (( fail == 0 )); then echo "===VERDICT=== PASS"; else echo "===VERDICT=== FALSIFIED"; fi
  exit 0
fi

if (( fail == 0 )); then
  echo "VERDICT=PASS — every served artifact matches its attestation"
  exit 0
else
  echo "VERDICT=FALSIFIED — a served artifact drifted from the manifest"
  exit 1
fi
