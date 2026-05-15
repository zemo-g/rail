#!/usr/bin/env bash
# publish.sh — push attestations to ledatic.org
#
# PUTs every JSON in releases/<tag>/, builds/<sha>/, selfhost/<sha>/
# to https://ledatic.org/<kind>/<ident>/<file>.  Mirrors the witness_push
# pattern: BEACON_TOKEN auth, idempotent (PUT replaces), 200 = ok.
#
# Tampering at the CDN layer is detectable — the Ed25519 signature is
# inside the body and verify.sh will reject any modification — so this
# is purely a delivery channel.
#
# Usage: publish.sh                     (publishes all under releases/, builds/, selfhost/)
#        publish.sh releases/v3.6.0     (publishes a specific dir)

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

TOKEN_FILE=${TOKEN_FILE:-$HOME/.ledatic/entropy/beacon_token}
[ -s "$TOKEN_FILE" ] || { echo "missing beacon token: $TOKEN_FILE" >&2; exit 2; }
TOKEN=$(cat "$TOKEN_FILE")

SITE=${SITE:-https://ledatic.org}

# Validate path component shape — the worker enforces the same regex,
# but failing locally is a cleaner error than a 404 from the edge.
valid_ident() {
  case "$1" in
    *[!A-Za-z0-9._-]*|"") return 1 ;;
    *) return 0 ;;
  esac
}

publish_dir() {
  local dir=$1
  case "$dir" in
    releases/*|builds/*|selfhost/*) ;;
    *) echo "skip $dir (not under releases/, builds/, selfhost/)" >&2; return 0 ;;
  esac
  [ -d "$dir" ] || { echo "no dir: $dir" >&2; return 1; }
  local kind=${dir%%/*}
  local rest=${dir#*/}
  local ident=${rest%%/*}
  valid_ident "$ident" || { echo "bad ident: $ident" >&2; return 1; }
  local count=0 fails=0
  # Push JSON attestations + the allowlisted release binaries.  Anything
  # else in the directory (rail_self_1, rail_self_2, run.log, pass*.log)
  # stays local — those are evidence-on-demand, not the published surface.
  shopt -s nullglob
  local files=("$dir"/*.json)
  if [ "$kind" = "releases" ]; then
    [ -f "$dir/rail_native"  ] && files+=("$dir/rail_native")
    [ -f "$dir/compile.rail" ] && files+=("$dir/compile.rail")
  fi
  for f in "${files[@]}"; do
    local file content_type
    file=$(basename "$f")
    valid_ident "$file" || { echo "  skip bad name: $file" >&2; ((fails++)); continue; }
    case "$file" in
      *.json) content_type="application/json" ;;
      *)      content_type="application/octet-stream" ;;
    esac
    local url="$SITE/$kind/$ident/$file"
    local code
    code=$(curl -sS -X PUT \
      -H "x-beacon-token: $TOKEN" \
      -H "content-type: $content_type" \
      --data-binary "@$f" \
      -o /dev/null -w '%{http_code}' \
      --max-time 60 "$url" || echo "000")
    if [ "$code" = "200" ]; then
      echo "  ok  $url"
      count=$((count + 1))
    else
      echo "  FAIL $url ($code)" >&2
      fails=$((fails + 1))
    fi
  done
  echo "$dir: $count ok, $fails fail"
  return $fails
}

if [ "$#" -ge 1 ]; then
  rc=0
  for d in "$@"; do
    publish_dir "$d" || rc=$?
  done
  exit "$rc"
fi

rc=0
for kind in releases builds selfhost; do
  [ -d "$kind" ] || continue
  for d in "$kind"/*/; do
    publish_dir "${d%/}" || rc=$?
  done
done
exit "$rc"
