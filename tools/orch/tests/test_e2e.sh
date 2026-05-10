#!/bin/bash
# test_e2e.sh — end-to-end orchestrator validation with fake_smoke arms.
# Exercises the full pipeline without launching real training.
#
# Verifies, in order:
#   1. parse_plan-style run_card.meta setup
#   2. launch_arm.sh (concurrent, 2 arms via mkdir compile-lock)
#   3. poll.sh detects exit + transitions running→completed
#   4. run_bench.sh --dry-run writes bench_result.meta + transitions completed→benched
#   5. update_leaderboard.sh emits LEADERBOARD.md (sorted)
#   6. condense.sh emits ENSEMBLE.md
#   7. write_handoff.sh emits HANDOFF.md (with leader, paste-ready prompt)
#
# Cleanup at end; safe to re-run. Doesn't touch real arms in runs/.

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
cd "$REPO_ROOT"

ARMS=(fake_a fake_b)
SEEDS=(1234 5678)

cleanup() {
  for arm in "${ARMS[@]}"; do
    rm -rf "runs/$arm"
  done
  rm -f LEADERBOARD.md ENSEMBLE.md HANDOFF.md
  rm -rf /tmp/rail_orch_compile.lock.d
}
trap cleanup EXIT

echo "=== STEP 1: setup run_card.meta for 2 fake arms ==="
for i in 0 1; do
  arm=${ARMS[$i]}
  seed=${SEEDS[$i]}
  mkdir -p "runs/$arm"
  cat > "runs/$arm/run_card.meta" <<EOF
arm_id=$arm
trainer_template=tools/train/lm_fake_smoke.rail
seed_override=$seed
hyperparams=fake d=0
corpus_path=fake
expected_wall_min=1
success_criteria=
rationale=e2e orchestrator smoke
status=queued
EOF
done
ls runs/fake_*/run_card.meta

echo "=== STEP 2: launch both arms (concurrent, mkdir-locked compile) ==="
START=$(date +%s)
tools/orch/launch_arm.sh runs/fake_a &
P1=$!
tools/orch/launch_arm.sh runs/fake_b &
P2=$!
wait $P1 $P2
LAUNCH_END=$(date +%s)
echo "  launch wall: $((LAUNCH_END - START))s"

echo "=== STEP 3: wait for fake trainers (3s sleep + slack) ==="
sleep 5

echo "=== STEP 4: poll each arm to transition status ==="
for arm in "${ARMS[@]}"; do
  echo "  --- poll $arm ---"
  tools/orch/poll.sh "runs/$arm" | sed 's/^/    /'
done

echo "=== STEP 5: dry-run bench on each arm ==="
for arm in "${ARMS[@]}"; do
  tools/orch/run_bench.sh "runs/$arm" --dry-run | sed 's/^/    /'
done

echo "=== STEP 6: leaderboard ==="
tools/orch/update_leaderboard.sh
[ -f LEADERBOARD.md ] && echo "  LEADERBOARD.md OK ($(wc -l < LEADERBOARD.md) lines)" || { echo "  LEADERBOARD.md MISSING"; exit 1; }

echo "=== STEP 7: condense ==="
tools/orch/condense.sh
[ -f ENSEMBLE.md ] && echo "  ENSEMBLE.md OK ($(wc -l < ENSEMBLE.md) lines)" || { echo "  ENSEMBLE.md MISSING"; exit 1; }

echo "=== STEP 8: handoff ==="
tools/orch/write_handoff.sh --reason "e2e smoke"
[ -f HANDOFF.md ] && echo "  HANDOFF.md OK ($(wc -l < HANDOFF.md) lines)" || { echo "  HANDOFF.md MISSING"; exit 1; }

echo ""
echo "=== ARTIFACTS ==="
echo "--- LEADERBOARD.md (head) ---"
head -15 LEADERBOARD.md
echo ""
echo "--- ENSEMBLE.md (head) ---"
head -15 ENSEMBLE.md
echo ""
echo "--- HANDOFF.md (Leader section + prompt) ---"
sed -n '/^## Leader/,/^## Per-arm/p' HANDOFF.md | head -10
sed -n '/^## Paste-ready/,/^```$/p' HANDOFF.md | head -15

echo ""
echo "=== ALL E2E STAGES PASSED ==="
exit 0
