#!/bin/sh
# tools/lab/watchers/robot_arm_flywheel_genesis.sh
#
# Genesis-entry sentinel for the robot-arm flywheel arc.
#
# This arc names a new downstream target for the open-verifier RLVR loop:
# natural-language commands -> Rail DSL scripts -> compile + sim-verify.
# Goal: substrate (or a Spur arm distilled from it) can drive a real arm
# from spoken/typed commands ("pick up the ball", "move to point A").
#
# This is a SUFFICIENCY arc parallel to fccdb405's training freeze:
#   - fccdb405 froze training on the saturated hard-bench-v3.
#   - This entry asks: does substrate hit a useful threshold on a NEW
#     bench (robot-arm DSL)? If yes, the substrate-thesis carries to a
#     real downstream task with no Spur training required.
#   - If substrate falls short, the headroom is named and a Spur arm
#     can be designed against the gap.
#
# Either outcome closes the question; neither requires un-freezing.
#
# Counter unit conventions:
#
#   bench_size                   integer count of robot-arm bench prompts
#                                (target: 20 in v0)
#   substrate_compile_count      out of (bench_size * N_rerank).
#                                Stage 1 of the 4-stage ladder.
#   substrate_parse_count        scripts that compile AND parse as
#                                well-formed arm-cmd sequences.
#   substrate_run_count          scripts that execute in sim without
#                                fault (no out-of-workspace, no grip
#                                while empty, etc).
#   substrate_goal_reach_count   scripts that compile + parse + run +
#                                terminate in the expected goal state.
#                                This is the headline metric.
#
# Kill criterion: substrate_goal_reach_count >= 10 out of 20 (single-best,
# N=20 reranks) => substrate is a useful baseline driver; arc PASSES.
# < 10 => substrate-headroom named; arc names the gap and a Spur arm
# becomes justifiable as a distillation target.
#
# This genesis emitter is intentionally tiny: it records zeros for the
# counters at session-start. Result entries from later in the session
# (e.g. after substrate baseline) supersede with measured values.

cat <<'EOT'
===RAIL_LAB_COUNTERS===
{"counter": "bench_size", "value": 0}
{"counter": "substrate_compile_count", "value": 0}
{"counter": "substrate_parse_count", "value": 0}
{"counter": "substrate_run_count", "value": 0}
{"counter": "substrate_goal_reach_count", "value": 0}
===END===
===VERDICT=== INCONCLUSIVE
EOT
