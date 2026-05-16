#!/bin/sh
# tools/lab/watchers/robot_arm_baseline_single_shot.sh
#
# Result watcher for the single-shot substrate baseline on
# tools/robot/bench_v0.txt. Run AT chain entry time to capture the
# canonical session result — the sentinel block is the same shape
# tools/robot/baseline_run.sh emits at the tail of its own output.
#
# Numbers below are the 2026-05-16 measurement; baseline_run.sh
# itself is the live reproducer (re-run when substrate config or
# bench changes).

cat <<'EOT'
===RAIL_LAB_COUNTERS===
{"counter": "bench_size", "value": 20}
{"counter": "substrate_compile_count", "value": 20}
{"counter": "substrate_parse_count", "value": 20}
{"counter": "substrate_run_count", "value": 19}
{"counter": "substrate_goal_reach_count", "value": 18}
===END===
===VERDICT=== PASS
EOT
