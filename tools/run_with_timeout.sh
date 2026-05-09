#!/usr/bin/env bash
# run_with_timeout.sh <secs> <cmd...> — exec a command with a hard kill after secs.
# macOS lacks coreutils' `timeout`; this is a portable substitute used by
# marathon-era corpus generators (preimage, fixed-point, diff-to-nearest).
#
# Behavior:
#   exit 124 — timed out and killed (matches GNU timeout convention)
#   exit N   — process exited normally with code N
#
# Usage:
#   tools/run_with_timeout.sh 5 ./rail_native run /tmp/probe.rail

set -u

if [ $# -lt 2 ]; then
  echo "usage: run_with_timeout.sh <secs> <cmd...>" >&2
  exit 2
fi

SECS=$1
shift

"$@" &
CMD_PID=$!

( sleep "$SECS" && kill -9 "$CMD_PID" 2>/dev/null && echo TIMEOUT >&2 ) &
WATCHER_PID=$!
disown "$WATCHER_PID" 2>/dev/null || true

wait "$CMD_PID" 2>/dev/null
RC=$?

kill -9 "$WATCHER_PID" 2>/dev/null

# If the command was killed by SIGKILL (signal 9), GNU timeout reports 124.
if [ "$RC" = "137" ]; then
  exit 124
fi
exit "$RC"
