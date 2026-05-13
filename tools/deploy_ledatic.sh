#!/usr/bin/env bash
# deploy_ledatic.sh — one-command Studio→Mini→ledatic.org deploy.
#
# From any Studio shell, in any directory:
#   ~/projects/rail/tools/deploy_ledatic.sh <files...>
#
# Files are paths RELATIVE to ~/projects/ledatic-site/.  Examples:
#   deploy_ledatic.sh holo.html
#   deploy_ledatic.sh holo.html mobile.html _shared/site.css
#   deploy_ledatic.sh _shared/wasm_render.js render.wasm
#
# What it does:
#   1. scp each named file from Studio's ~/projects/ledatic-site/<path>
#      to Mini's ~/projects/ledatic-site/<path>.
#   2. ssh into Mini, run ./deploy.sh with Mini's CF_TOKEN sourced from
#      ~/Desktop/rings.  Push goes to Cloudflare KV.
#   3. curl-verify each deployed URL from Studio with a cache-buster.
#      Prints HTTP code + size + content-type for each.
#
# No back-and-forth.  No CF_TOKEN paste.  No remembering scp aliases.

set -euo pipefail

REMOTE_USER=ledaticempire
REMOTE_HOST=mini.tb
REMOTE_DIR='~/projects/ledatic-site'   # tilde-expanded on Mini
LOCAL_DIR="$HOME/projects/ledatic-site"
TOKEN_PATH='~/Desktop/rings'           # tilde-expanded on Mini

if [ "$#" -eq 0 ]; then
  cat >&2 <<EOF
usage: $(basename "$0") <file>...
files are paths relative to $LOCAL_DIR (e.g. holo.html, _shared/site.css)
EOF
  exit 2
fi

# Validate every file exists locally before touching the remote.
for f in "$@"; do
  if [ ! -f "$LOCAL_DIR/$f" ]; then
    echo "ERROR: $LOCAL_DIR/$f not found" >&2
    exit 3
  fi
done

cyan() { printf '\033[36m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
red() { printf '\033[31m%s\033[0m' "$*"; }

echo "$(cyan '▶ stage') $# file(s) → $REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"
for f in "$@"; do
  # Use scp -p to preserve mtimes; ensure remote subdir exists.
  remote_dir=$(dirname "$f")
  if [ "$remote_dir" != "." ]; then
    ssh "$REMOTE_USER@$REMOTE_HOST" "mkdir -p $REMOTE_DIR/$remote_dir"
  fi
  scp -p "$LOCAL_DIR/$f" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/$f" >/dev/null
  printf '  %s\n' "$f"
done

echo "$(cyan '▶ deploy') ./deploy.sh $* (CF_TOKEN sourced from Mini:$TOKEN_PATH)"
ssh "$REMOTE_USER@$REMOTE_HOST" \
  "cd $REMOTE_DIR && CF_TOKEN=\$(cat $TOKEN_PATH) ./deploy.sh $*"

echo "$(cyan '▶ verify') from Studio (?cb=\$RANDOM forces edge cache miss)"
all_ok=1
for f in "$@"; do
  # The KV key is the relative path, except index.html mounts at /.
  case "$f" in
    index.html) key="" ;;
    *)          key="$f" ;;
  esac
  url="https://ledatic.org/$key?cb=$RANDOM"
  read -r code size ct < <(
    curl -s -o /dev/null -w '%{http_code} %{size_download} %{content_type}\n' "$url"
  )
  if [ "$code" = "200" ]; then
    printf '  %s  %s  %sB  %s\n' "$(green ✓)" "$f" "$size" "$ct"
  else
    printf '  %s  %s  HTTP %s  %s\n' "$(red ✗)" "$f" "$code" "$ct"
    all_ok=0
  fi
done

if [ "$all_ok" = 1 ]; then
  echo "$(green '▶ done') all $# file(s) live"
else
  echo "$(red '▶ FAIL') one or more files did not return 200"
  exit 4
fi
