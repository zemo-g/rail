#!/usr/bin/env bash
# Stage 5 - signed GCD round-trip via USB Mass Storage.
#
# Pushes a Garmin-signed GUPDATE.GCD onto the watch's FAT volume. The watch
# picks it up on physical-cable disconnect (or `diskutil eject`) and runs
# the bootloader's sig-verify + flash flow. We supply ONLY firmwares that
# came from Garmin's CDN, never anything we built or modified.
#
# Usage:
#   tools/garmin/stage5_push.sh same        # push 19.10 (re-installs current ver)
#   tools/garmin/stage5_push.sh backdate    # push 19.01 (downgrade, reversible)
#   tools/garmin/stage5_push.sh inspect     # diff watch state vs baseline (no push)
#
# Hard rule: NEVER pushes anything not pulled from download.garmin.com.

set -euo pipefail
mode="${1:-inspect}"

watch_root=/Volumes/GARMIN
gcd_dir=/Users/user/garmin_recon/firmware/Instinct_1910/Instinct_1910Beta
gcd_19_10="${gcd_dir}/System_1910/GUPDATE.GCD"
gcd_19_01="${gcd_dir}/System_Backdate_1901/GUPDATE.GCD"
baseline=/Users/user/garmin_recon/snapshot_2026-04-28.sha256

if [[ ! -d "$watch_root/GARMIN" ]]; then
  echo "ERROR: watch not mounted at $watch_root" >&2
  exit 1
fi

case "$mode" in
  inspect)
    echo "=== watch state vs baseline ==="
    echo "(comparing live device against snapshot taken at session start)"
    cd /
    drift=0
    while IFS= read -r line; do
      hash="${line%%  *}"
      path="${line#*  }"
      if [[ -f "$path" ]]; then
        live=$(shasum -a 256 "$path" | awk '{print $1}')
        if [[ "$live" != "$hash" ]]; then
          echo "  CHANGED: $path"
          drift=$((drift+1))
        fi
      else
        echo "  GONE:    $path"
        drift=$((drift+1))
      fi
    done < "$baseline"
    if [[ "$drift" == "0" ]]; then
      echo "  no drift - watch matches baseline."
    else
      echo "  $drift files differ from baseline."
    fi
    ;;
  same)
    echo "=== pushing 19.10 (idempotent re-install) ==="
    [[ -f "$gcd_19_10" ]] || { echo "missing $gcd_19_10"; exit 1; }
    sz=$(stat -f '%z' "$gcd_19_10")
    h=$(shasum -a 256 "$gcd_19_10" | awk '{print $1}')
    echo "  source: $gcd_19_10"
    echo "  size:   $sz bytes  sha256: $h"
    cp "$gcd_19_10" "$watch_root/GARMIN/GUPDATE.GCD"
    sync
    echo "  staged to $watch_root/GARMIN/GUPDATE.GCD"
    echo
    echo "  NEXT STEP (user action): eject the watch."
    echo "    diskutil eject $watch_root"
    echo "  The watch will run the update flow on disconnect, blank screen for"
    echo "  ~30s, then re-mount. Re-run \`stage5_push.sh inspect\` after."
    ;;
  backdate)
    echo "=== pushing 19.01 (downgrade - undoable by re-pushing 19.10) ==="
    [[ -f "$gcd_19_01" ]] || { echo "missing $gcd_19_01"; exit 1; }
    sz=$(stat -f '%z' "$gcd_19_01")
    h=$(shasum -a 256 "$gcd_19_01" | awk '{print $1}')
    echo "  source: $gcd_19_01"
    echo "  size:   $sz bytes  sha256: $h"
    cp "$gcd_19_01" "$watch_root/GARMIN/GUPDATE.GCD"
    sync
    echo "  staged to $watch_root/GARMIN/GUPDATE.GCD"
    echo
    echo "  NEXT STEP (user action): eject the watch."
    echo "    diskutil eject $watch_root"
    ;;
  *)
    echo "usage: $0 {inspect|same|backdate}" >&2
    exit 2
    ;;
esac
