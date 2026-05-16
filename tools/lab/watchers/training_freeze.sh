#!/bin/sh
# tools/lab/watchers/training_freeze.sh
#
# Genesis-entry sentinel watcher for the "freeze further Spur training
# until any checkpoint beats substrate=30/30 on any hard-bench-v3 band"
# meta-policy decision.
#
# This script is intentionally tiny. Its only contract is to emit the
# four declared counters and a verdict sentinel in the wire format
# required by tools/lab/run.rail (see specs/run.spec.md §4-§5):
#
#   ===RAIL_LAB_COUNTERS===
#   {"counter": "<name>", "value": <num>}
#   ...
#   ===END===
#   ===VERDICT=== INCONCLUSIVE
#
# === Counter unit conventions (read before editing) ====================
#
#   spur_best_compile_rate   integer count out of 30 (hard-bench-v3 has
#                            6 bands x 5 prompts = 30). 13 = v54 single-
#                            best (13/30 = 43.3%) from the lineage
#                            archive in memory/spur_lineage_archive.md.
#
#   substrate_compile_rate   integer count out of 30. 30 = bench-cracker
#                            ceiling on hard-bench-v3 N=20, established
#                            2026-05-09 (memory/substrate_30_of_30_*.md).
#
#   max_band_delta           SIGNED integer: spur_band - substrate_band,
#                            maximum across the 6 bands. Positive = Spur
#                            ahead of substrate on at least one band
#                            (which would FALSIFY the freeze). Negative
#                            = substrate still ahead on every band.
#                            -17 today is the worst-case ceiling-floor
#                            gap (13/30 - 30/30 = -17/30).
#
#   days_elapsed_in_window   integer days since the freeze was recorded.
#                            0 at genesis. Watch window is 30 days
#                            (see kill_target in entry).
#
# === Future-iteration TODO =============================================
#
# This sentinel-emitter does NOT re-read any logs. Future iterations of
# this freeze-arc should evolve the watcher to:
#
#   1. Scan ~/git/rail-training/flywheel/bench_logs/ (or the equivalent
#      path on the host running this) for the most-recent N=20 bench
#      report per Spur checkpoint, parse per-band compile counts, and
#      update spur_best_compile_rate + max_band_delta accordingly.
#
#   2. Read the entry's created_at from the chain (via
#      `./rail_native run tools/lab/run.rail read <id>`) and compute
#      days_elapsed_in_window from that.
#
#   3. Emit VERDICT=PASS if max_band_delta > 0 (training beat substrate
#      on a band — freeze falsified, training resumes). Emit
#      VERDICT=FALSIFIED only if 30 days pass with max_band_delta <= 0
#      (freeze becomes permanent — but that's actually the freeze
#      HOLDING, so we should re-read this and probably swap PASS/
#      FALSIFIED semantics for this arc once we settle the convention).
#      For now: emit INCONCLUSIVE always. The user can grep the verdict
#      column in subsequent child entries to see the state evolve.
#
# === Idempotency =======================================================
#
# This script is pure stdout. No filesystem writes. No environment
# mutation. Re-running yields the same output. Safe under run.rail's
# exec-once-per-put-goal model.

set -eu

cat <<'COUNTERS'
===RAIL_LAB_COUNTERS===
{"counter": "spur_best_compile_rate", "value": 13}
{"counter": "substrate_compile_rate", "value": 30}
{"counter": "max_band_delta", "value": -17}
{"counter": "days_elapsed_in_window", "value": 0}
===END===
COUNTERS

echo "===VERDICT=== INCONCLUSIVE"
exit 0
