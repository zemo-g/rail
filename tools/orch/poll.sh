#!/bin/bash
# poll.sh — single-arm state updater. Idempotent; safe to call repeatedly.
#
# Per arm:
#   - scrape `eval@step=<S> mean=<V> std=...` lines from train.log → val_loss.tsv
#   - check pid alive via `kill -0`; if dead, transition status:
#       running → completed (if "saved final checkpoint" or "saved best" present)
#       running → failed     (otherwise)
#   - emit a summary KV block to stdout
#
# Usage: tools/orch/poll.sh runs/<arm_id>
#
# Exits 0 on any successful poll (regardless of status outcome).
# Exits 2 on bad args / missing run_card.

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$REPO_ROOT"

if [ $# -ne 1 ]; then
  echo "usage: $0 runs/<arm_id>" >&2
  exit 2
fi

RUN_DIR=$1
RUN_CARD=$RUN_DIR/run_card.meta
LOG=$RUN_DIR/train.log
TSV=$RUN_DIR/val_loss.tsv

if [ ! -f "$RUN_CARD" ]; then
  echo "error: $RUN_CARD not found" >&2
  exit 2
fi

get_key() {
  grep "^$1=" "$RUN_CARD" | head -1 | cut -d'=' -f2-
}

ARM_ID=$(get_key arm_id)
STATUS=$(get_key status)
PID=$(get_key pid)

# ── Scrape val_loss.tsv from train.log ─────────────────────────────
# Matches: eval@step=N mean=V std=...   →   N<TAB>V
if [ -f "$LOG" ]; then
  grep -E '^eval@step=[0-9]+ mean=' "$LOG" 2>/dev/null \
    | sed -E 's/^eval@step=([0-9]+) mean=([0-9.]+).*/\1	\2/' \
    > "$TSV"
fi

LAST_STEP=""
LAST_VL=""
if [ -s "$TSV" ]; then
  LAST=$(tail -1 "$TSV")
  LAST_STEP=${LAST%%$'\t'*}
  LAST_VL=${LAST##*$'\t'}
fi

# ── Liveness check + status transition ────────────────────────────
ALIVE=no
NEW_STATUS=$STATUS

if [ "$STATUS" = "running" ]; then
  if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then
    ALIVE=yes
  else
    # Process is dead. Decide completed vs failed based on log evidence.
    if [ -f "$LOG" ] && grep -qE "(saved final checkpoint|saved best|saved at step=)" "$LOG"; then
      NEW_STATUS=completed
    else
      NEW_STATUS=failed
    fi
    # Persist transition + completed_at timestamp (idempotent — only adds once)
    sed -i.bak "s|^status=running\$|status=$NEW_STATUS|" "$RUN_CARD"
    rm -f "$RUN_CARD.bak"
    if ! grep -q "^completed_at=" "$RUN_CARD"; then
      echo "completed_at=$(date +%Y-%m-%dT%H:%M:%S%z)" >> "$RUN_CARD"
    fi
  fi
fi

# ── Summary ───────────────────────────────────────────────────────
echo "arm_id=$ARM_ID"
echo "status=$NEW_STATUS"
echo "alive=$ALIVE"
echo "last_step=${LAST_STEP:-none}"
echo "last_val_loss=${LAST_VL:-none}"
echo "val_loss_tsv=$TSV"
exit 0
