#!/usr/bin/env bash
# ard_off_after_session.sh — Deactivate Apple Remote Desktop / Remote Management.
#
# Generated for security_deferred_runbook_2026-05-12.md §2.
# Run AFTER you have moved off Screen Sharing onto SSH-only (`ssh studio`)
# and have closed the Screen Sharing client window from Air/laptop.
#
# Effect: ARDAgent stops listening on *:3283 (and the kickstart -off path also
# disables ARD-managed Screen Sharing access). SSH via Tailscale is unaffected.

set -u

KICKSTART="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"

# --- Pre-flight: cached-sudo check ---------------------------------------------
# Kickstart needs root. If sudo's credential cache is empty AND no tty is
# attached for password entry, we'd hang silently. Fail fast instead.
if ! sudo -n true 2>/dev/null; then
  if [ ! -t 0 ]; then
    echo "ERROR: sudo password not cached and no tty for prompt. Run from an" >&2
    echo "       interactive shell after \`sudo -v\` to cache credentials." >&2
    exit 2
  fi
  echo "Note: sudo will prompt for your password (cached creds not present)."
fi

# --- Pre-flight: warn if Screen Sharing still has an active VNC peer -----------
ESTAB=$(lsof -nP -iTCP:5900 -sTCP:ESTABLISHED 2>/dev/null | tail -n +2)
if [ -n "$ESTAB" ]; then
  echo "WARNING: ESTABLISHED VNC connection on port 5900 detected:" >&2
  echo "$ESTAB" >&2
  echo "Aborting. Disconnect Screen Sharing first, then re-run." >&2
  exit 3
fi

# --- Deactivate ----------------------------------------------------------------
echo "Deactivating ARD / Remote Management ..."
sudo "$KICKSTART" -deactivate -configure -access -off
RC=$?
if [ $RC -ne 0 ]; then
  echo "ERROR: kickstart returned $RC" >&2
  exit $RC
fi

# Give launchd a beat to reap the listener.
sleep 1

# --- Verify --------------------------------------------------------------------
LISTEN=$(lsof -nP -iTCP:3283 -sTCP:LISTEN 2>/dev/null | tail -n +2)
TS=$(date '+%Y-%m-%d %H:%M:%S %z')
if [ -z "$LISTEN" ]; then
  echo "OK [$TS]: port 3283 no longer in LISTEN. ARD is off."
  exit 0
else
  echo "WARNING [$TS]: port 3283 still LISTEN after deactivate:" >&2
  echo "$LISTEN" >&2
  echo "Try System Settings -> General -> Sharing -> Remote Management toggle off." >&2
  exit 4
fi
