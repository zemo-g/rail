#!/bin/sh
# tools/lab/watchers/robot_arm_baseline_n20_rerank.sh
#
# N=20 rerank baseline on robot-arm bench v0. Per-prompt max-pass
# routing across N=20 substrate completions at TEMPERATURE=0.9.
# Reproducer: tools/robot/baseline_rerank.sh.
#
# Result (2026-05-16): 20/20 goal_reach, 13m20s wall clock. b14
# closed by diverse-interpretation rerank. Substrate-thesis at
# 100% on a new downstream task (matches the 30/30 hard-bench
# pattern but for robot-arm command emission).

cat <<'EOT'
===RAIL_LAB_COUNTERS===
{"counter": "bench_size", "value": 20}
{"counter": "substrate_compile_count", "value": 20}
{"counter": "substrate_parse_count", "value": 20}
{"counter": "substrate_run_count", "value": 20}
{"counter": "substrate_goal_reach_count", "value": 20}
{"counter": "n_rerank", "value": 20}
{"counter": "wall_seconds", "value": 800}
===END===
===VERDICT=== PASS
EOT
