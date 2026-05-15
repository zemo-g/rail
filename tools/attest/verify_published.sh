#!/usr/bin/env bash
# verify_published.sh — antibodies
#
# For every release tag with a checked-in rail_native + tools/compile.rail,
# fetch the published artifact at /releases/<tag>/<file> on ledatic.org
# and compare its sha256 to the git blob at that tag. Mismatch = tamper.
#
# This is the active integrity check the witness chain doesn't do —
# the witness signs WHEN a binary was attested, not WHAT the binary
# at the public URL is RIGHT NOW. Worker rewrites, accidental
# overwrite, CDN poisoning, KV-bin corruption — all become loud.
#
# Output:
#   - Per-tag: "ok" | "MISMATCH" | "404" | "skipped"
#   - Final: count of each outcome
#   - Exit 0 if no MISMATCH, exit 1 otherwise
#
# Usage:
#   ./tools/attest/verify_published.sh                # check all tags
#   ./tools/attest/verify_published.sh v3.11.0        # one tag
#   ./tools/attest/verify_published.sh --json         # machine output

set -uo pipefail

REPO="${REPO:-$HOME/projects/rail-https}"
SITE_BASE="${SITE_BASE:-https://ledatic.org}"
JSON=0
TARGET_TAG=""

# Tags from before binaries were checked into the repo. There is no
# rail_native or compile.rail blob at these tags, so they were never
# published and have no manifest to verify against. drift_audit.sh
# uses the same list — keep them in sync.
PRE_HISTORIC_TAGS=(v0.6.0)

for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
    -*)     echo "verify_published: unknown flag: $arg" >&2; exit 2 ;;
    *)      TARGET_TAG="$arg" ;;
  esac
done

cd "$REPO"

# ── candidate tags ─────────────────────────────────────────────────
CANDIDATES=()
if [ -n "$TARGET_TAG" ]; then
  CANDIDATES=("$TARGET_TAG")
else
  # bash 3.2-safe: while read instead of mapfile
  while IFS= read -r line; do
    CANDIDATES+=("$line")
  done < <(git tag | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V)
fi

# Drop pre-historic tags before walking — they have no manifest and
# never will. Without this filter, the script reports them as `miss`
# with a fix command (`./tools/attest/publish.sh releases/<tag>`)
# that would fail because the local releases/<tag>/ directory
# doesn't exist either.
declare -a PREHISTORIC_SKIPPED=()
filtered=()
for tag in "${CANDIDATES[@]}"; do
  is_prehistoric=0
  for pre in "${PRE_HISTORIC_TAGS[@]}"; do
    [ "$tag" = "$pre" ] && is_prehistoric=1 && break
  done
  if [ "$is_prehistoric" = "1" ]; then
    PREHISTORIC_SKIPPED+=("$tag")
  else
    filtered+=("$tag")
  fi
done
CANDIDATES=("${filtered[@]+"${filtered[@]}"}")

declare -a OK=() MISMATCH=() MISSING=() SKIPPED=()

# Verify one tag's published artifacts are honest. The attestation
# index.json names a specific commit + per-artifact sha256s — those
# are the witness-signed claims. We then check:
#   (a) published artifact sha256 == manifest's claimed sha256
#       — catches CDN/KV tampering since publish
#   (b) git blob at manifest.git.commit sha256 == manifest's claim
#       — catches a manifest that lies about its source commit
#
# Returns: 0=honest, 1=tampered, 3=manifest-not-published, 4=git-commit-missing
verify_one_tag() {
  local tag="$1"
  local manifest_url="$SITE_BASE/releases/$tag/index.json"
  local manifest
  manifest=$(curl -s --max-time 8 "$manifest_url" 2>/dev/null)
  if [ -z "$manifest" ] || ! echo "$manifest" | grep -q '"sha256"'; then
    return 3
  fi

  # Pull the commit + per-artifact (path, sha256) pairs from the manifest.
  local manifest_commit
  manifest_commit=$(echo "$manifest" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("git",{}).get("commit",""))' 2>/dev/null)
  [ -z "$manifest_commit" ] && return 3

  # Quickly: does the local repo even know about that commit? If not,
  # we can't verify provenance — caller decides whether to skip or alert.
  if ! git cat-file -e "$manifest_commit" 2>/dev/null; then
    return 4
  fi

  # Walk each artifact. Manifest is the source of truth.
  local rc=0
  echo "$manifest" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for a in d.get("artifacts", []):
    print(a["path"] + "\t" + a["sha256"])
' | while IFS=$'\t' read -r path expected_sha; do
    [ -z "$path" ] && continue

    # (a) public artifact sha256 must match manifest claim.
    local public_url="$SITE_BASE/releases/$tag/$(basename "$path")"
    local code public_sha
    code=$(curl -s --max-time 30 -o /tmp/_verify_buf.$$ -w '%{http_code}' "$public_url" 2>/dev/null || echo 000)
    if [ "$code" != "200" ]; then
      rm -f /tmp/_verify_buf.$$
      echo "    MISSING $tag/$(basename "$path") (public 404 — partial publish)"
      continue
    fi
    public_sha=$(shasum -a 256 /tmp/_verify_buf.$$ | awk '{print $1}')
    rm -f /tmp/_verify_buf.$$
    if [ "$public_sha" != "$expected_sha" ]; then
      echo "    TAMPER $tag/$(basename "$path"): manifest=${expected_sha:0:16} public=${public_sha:0:16}"
      continue
    fi

    # (b) git blob at manifest.git.commit must match manifest claim.
    local git_sha
    git_sha=$(git show "${manifest_commit}:${path}" 2>/dev/null | shasum -a 256 | awk '{print $1}')
    if [ -z "$git_sha" ]; then
      echo "    MISMATCH $tag/$(basename "$path"): manifest names commit ${manifest_commit:0:7} but blob '$path' missing there"
      continue
    fi
    if [ "$git_sha" != "$expected_sha" ]; then
      echo "    TAMPER $tag/$(basename "$path"): git@${manifest_commit:0:7}=${git_sha:0:16} manifest=${expected_sha:0:16}"
      continue
    fi
  done

  return 0
}

# ── walk ───────────────────────────────────────────────────────────
if [ "$JSON" = "0" ]; then
  msg="verifying ${#CANDIDATES[@]} tag(s) against $SITE_BASE"
  [ ${#PREHISTORIC_SKIPPED[@]} -gt 0 ] && msg="$msg ($((${#PREHISTORIC_SKIPPED[@]})) pre-historic skipped: ${PREHISTORIC_SKIPPED[*]})"
  echo "$msg"
fi

# Edge: target was the only thing requested AND it's pre-historic.
if [ ${#CANDIDATES[@]} -eq 0 ]; then
  [ "$JSON" = "0" ] && echo "summary: 0 verifiable tags (all candidates were pre-historic)"
  exit 0
fi

for tag in "${CANDIDATES[@]}"; do
  # Capture verify_one_tag's stdout into a buffer so we can decide
  # the verdict from any TAMPER/MISSING lines it emitted.
  local_buf=$(verify_one_tag "$tag" 2>&1)
  rc=$?
  case "$rc" in
    3)
      MISSING+=("$tag")
      [ "$JSON" = "0" ] && echo "  miss   $tag (manifest 404 — run: ./tools/attest/publish.sh releases/$tag)"
      continue
      ;;
    4)
      SKIPPED+=("$tag")
      [ "$JSON" = "0" ] && echo "  skip   $tag (manifest's commit not in local git — shallow clone?)"
      continue
      ;;
  esac

  if echo "$local_buf" | grep -q TAMPER; then
    MISMATCH+=("$tag")
    [ "$JSON" = "0" ] && {
      echo "  TAMPER $tag"
      echo "$local_buf" | sed 's/^/    /'
    }
  elif echo "$local_buf" | grep -q MISSING; then
    MISSING+=("$tag")
    [ "$JSON" = "0" ] && {
      echo "  miss   $tag (partial publish)"
      echo "$local_buf" | sed 's/^/    /'
    }
  else
    OK+=("$tag")
    [ "$JSON" = "0" ] && echo "  ok     $tag"
  fi
done

# ── summary ────────────────────────────────────────────────────────
if [ "$JSON" = "1" ]; then
  python3 <<PY
import json, sys
print(json.dumps({
    'site': '$SITE_BASE',
    'ok': """$(printf '%s\n' "${OK[@]+"${OK[@]}"}")""".strip().split('\n') if ${#OK[@]} > 0 else [],
    'mismatch': """$(printf '%s\n' "${MISMATCH[@]+"${MISMATCH[@]}"}")""".strip().split('\n') if ${#MISMATCH[@]} > 0 else [],
    'missing': """$(printf '%s\n' "${MISSING[@]+"${MISSING[@]}"}")""".strip().split('\n') if ${#MISSING[@]} > 0 else [],
    'skipped': """$(printf '%s\n' "${SKIPPED[@]+"${SKIPPED[@]}"}")""".strip().split('\n') if ${#SKIPPED[@]} > 0 else [],
    'summary': {
        'ok': ${#OK[@]}, 'mismatch': ${#MISMATCH[@]},
        'missing': ${#MISSING[@]}, 'skipped': ${#SKIPPED[@]},
    },
}, indent=2))
PY
else
  echo ""
  echo "summary: ${#OK[@]} ok · ${#MISMATCH[@]} MISMATCH · ${#MISSING[@]} missing · ${#SKIPPED[@]} skipped"
  if [ "${#MISMATCH[@]}" -gt 0 ]; then
    echo ""
    echo "TAMPER ALERT — published artifacts do not match git source for:"
    for t in "${MISMATCH[@]}"; do echo "  - $t"; done
  fi
fi

[ "${#MISMATCH[@]}" -gt 0 ] && exit 1
exit 0
