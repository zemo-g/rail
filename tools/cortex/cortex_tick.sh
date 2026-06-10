#!/bin/bash
# cortex_tick.sh — single launchd tick for cortex with two safety nets.
#
# Without these, a hung Anthropic call (or any other stall inside
# cortex.rail) leaves /tmp/rail_out spinning forever, and launchd
# stacks a fresh tick every 5 min on top of it.  We had a 14-min
# orphan eating a full core on 2026-05-05.
#
# Net 1 — skip-if-running: if any /tmp/rail_out is alive, abort this
#         tick.  Prevents stacking.
# Net 2 — hard timeout: a watchdog SIGTERMs the run after 240 s
#         (cortex normally finishes in ~10–30 s; 240 is generous).

set -u

if pgrep -f '^/tmp/rail_out$' >/dev/null; then
  echo "cortex_tick: previous /tmp/rail_out still running — skipping this tick"
  exit 0
fi

# Run from the repo root (this script lives at tools/cortex/).
cd "$(dirname "$0")/../.." || exit 1

./rail_native run tools/cortex/cortex.rail &
RAIL_PID=$!

# Watchdog: kill the rail process group if it exceeds the budget.
( sleep 240 && kill -TERM "$RAIL_PID" 2>/dev/null && \
  sleep 5 && kill -KILL "$RAIL_PID" 2>/dev/null ; \
  pkill -f '^/tmp/rail_out$' 2>/dev/null ; true ) &
WATCHDOG=$!

wait "$RAIL_PID"
RC=$?

# Cancel watchdog cleanly if rail finished on its own.
kill "$WATCHDOG" 2>/dev/null
wait "$WATCHDOG" 2>/dev/null

exit "$RC"
