# Orchestrator runbook

How a Claude Code session drives the orchestrator using `ScheduleWakeup`,
`Bash`, and the `tools/orch/*` helpers. The orchestrator is **stateless across
wakeups** — every tick reads run cards from disk and decides actions purely
from on-disk state. This means a session can crash or be replaced and the
next session can pick up cleanly.

## Component map

| Stage             | Tool                                  | Lang | Inputs                          | Outputs                                  |
|-------------------|---------------------------------------|------|---------------------------------|------------------------------------------|
| Parse plan        | `tools/orch/parse_plan.rail`          | Rail | `EXPERIMENT_PLAN.md`            | `runs/<id>/run_card.meta` × N            |
| Substitute seed   | `tools/orch/seed_trainer.sh`          | bash | template `.rail`, seed, prefix  | `runs/<id>/trainer.rail`                 |
| Launch arm        | `tools/orch/launch_arm.sh`            | bash | `runs/<id>/`                    | nohup'd binary, status=running, pid      |
| Poll one arm      | `tools/orch/poll.sh`                  | bash | `runs/<id>/`                    | `val_loss.tsv`, status transitions       |
| Kill decision     | `tools/orch/kill_decision.rail`       | Rail | N × `val_loss.tsv`              | KEY=VALUE decision (kill/keep/hold)      |
| Run bench         | `tools/orch/run_bench.sh`             | bash | `runs/<id>/`                    | `bench_result.meta`, status=benched      |
| Update leaderboard| `tools/orch/update_leaderboard.sh`    | bash | all `runs/<id>/`                | `LEADERBOARD.md`                         |
| Condense ensemble | `tools/orch/condense.sh`              | bash | all `runs/<id>/bench.log`       | `ENSEMBLE.md`                            |
| Write handoff     | `tools/orch/write_handoff.sh`         | bash | all `runs/<id>/`                | `HANDOFF.md`                             |

## Tick lifecycle

Per wake-up (every `poll_interval_min`, default 30 min):

```
1. parse_plan ── only if EXPERIMENT_PLAN.md mtime > runs/_globals.meta mtime
                 (i.e. user edited the plan)
2. for each arm in runs/:
     poll.sh runs/<id>          # updates status, scrapes val_loss
3. running_tsvs = list of runs/<id>/val_loss.tsv where status=running
   if len(running_tsvs) >= 2:
     kill_decision.rail on running_tsvs
     for each kill=<id> in output:
       kill -TERM <pid>; sed status=killed
4. for each arm where status just transitioned running→completed:
     run_bench.sh runs/<id>    # ~13hr CPU; consider kicking off in background
5. update_leaderboard.sh
6. if any new benched arm AND new_pass > prior_SOTA + wake_threshold:
     wake_user "SOTA improvement"
7. queued = list of arms with status=queued
   running = list of arms with status=running
   if len(running) < parallel_budget AND len(queued) > 0:
     for arm in queued[:parallel_budget - len(running)]:
       launch_arm.sh runs/<arm>
8. git add EXPERIMENT_PLAN.md LEADERBOARD.md runs/*/run_card.meta runs/*/bench_result.meta
   git commit -m "orch tick: <summary>"
9. if all arms terminal (no queued, no running):
     condense.sh
     write_handoff.sh --reason "queue done"
     wake_user "queue done"
     STOP scheduling further wakeups
   elif elapsed > wall_clock_cap_min:
     condense.sh
     write_handoff.sh --reason "budget exhausted"
     wake_user "budget exhausted"
     STOP
   else:
     ScheduleWakeup(poll_interval_min, "<<orchestrator-tick>>")
```

## Wake-user mechanics

`wake_user "<reason>"` fires an `osascript` notification + writes a marker file:

```bash
osascript -e "display notification \"$reason\" with title \"Rail orchestrator\" sound name \"Glass\""
date > /tmp/spur_orch_wake.txt
```

Optionally also fire `PushNotification` (in-Claude-Code banner). User-configurable
in `EXPERIMENT_PLAN.md` `wake_mechanism` global.

## State machine per arm

```
                ┌──────── parse_plan ─────────┐
                │                             ▼
              queued ──launch_arm──▶ running
                                       │
                       poll.sh detects pid dead
                                       │
                                       ├─→ completed (log has "saved best")
                                       │      └─→ run_bench ─→ benched ─→ finalized
                                       │
                                       └─→ failed (no save evidence)
                  killed ◀──── kill_decision says laggard ──── running
```

Terminal states: `benched`, `failed`, `killed`. The orchestrator never re-launches
a terminal arm; the user can manually reset to `queued` if they want a retry.

## Manual operation (no wakeup loop)

You can drive the orchestrator step-by-step from a Terminal or a Claude Code
session:

```bash
# 1. populate runs/ from plan
./rail_native run tools/orch/parse_plan.rail

# 2. launch first 2 arms (matching parallel_budget=2)
tools/orch/launch_arm.sh runs/smoke_v54_repro
tools/orch/launch_arm.sh runs/bq_s200_repro

# 3. wait ~45min, then check progress
for d in runs/*/; do tools/orch/poll.sh "$d"; done

# 4. when all running tsvs have step >= 500, exercise kill rule
./rail_native run tools/orch/kill_decision.rail \
    --kill_min_step 500 --kill_sigma 2.0 --kill_window 10 \
    runs/smoke_v54_repro/val_loss.tsv runs/bq_s200_repro/val_loss.tsv

# 5. for any completed arm, run bench
tools/orch/run_bench.sh runs/smoke_v54_repro --n 20    # real bench (~13hr CPU)
tools/orch/run_bench.sh runs/smoke_v54_repro --dry-run # just write fake result

# 6. update leaderboard + handoff anytime
tools/orch/update_leaderboard.sh
tools/orch/condense.sh
tools/orch/write_handoff.sh --reason "manual checkpoint"
```

## Failure modes + recovery

| Failure                                         | Symptom                            | Recovery                                                |
|-------------------------------------------------|------------------------------------|---------------------------------------------------------|
| Trainer compile error                           | launch_arm.sh exits 6              | Inspect `runs/<id>/compile.log`; fix template; re-launch |
| Trainer crash mid-run                           | poll detects pid dead, log empty   | Status → failed; bench skipped; visible on LEADERBOARD   |
| Two arms try to compile concurrently            | flock-on-mkdir handles it          | (no manual action — built in)                            |
| Host kernel panic mid-tick                      | wakeup never fires                 | Next session re-reads run cards from disk; resumes      |
| Compile lock dir orphaned (process killed)      | future launches hang ≤120s         | `rmdir /tmp/rail_orch_compile.lock.d` to clear          |
| `lm_v54` template gets renamed/refactored       | seed_trainer.sh exits 3 (no match) | Update `trainer_template:` in plan to new path          |

## Globals reference

All in `EXPERIMENT_PLAN.md`'s `## Globals` table:

- `parallel_budget` (int, default 2): max concurrent running arms.
- `wall_clock_cap_min` (int, default 480): orchestrator hard stop.
- `wake_threshold_prompts` (int, default 1): SOTA delta required to wake user.
- `kill_min_step` (int, default 500): no kills before this step.
- `kill_sigma` (float, default 2.0): laggard threshold = leader_vl + σ·this.
- `kill_window` (int, default 10): leader's last-K val_losses for σ.
- `poll_interval_min` (int, default 30): wakeup cadence.
- `bench_after_complete` (bool, default true): auto-bench on completion.
- `commit_after_each_arm` (bool, default true): git commit cadence.

## Constraints baked into the design

1. **Stateless wakeups.** No in-memory state survives between ticks — read disk
   every tick. Lets a Claude Code session crash without losing orchestrator
   progress.
2. **No re-launch of terminal arms.** Avoids amplifying transient failures
   into permanent loops.
3. **Push, not poll, for SOTA wake.** Wake fires only on bench completion, not
   on every val_loss tick — avoids noise.
4. **Single compile lock.** `mkdir /tmp/rail_orch_compile.lock.d` serialises
   trainer compiles so concurrent arms don't race `/tmp/rail_out`.
5. **Pure-Rail decision math, bash for I/O glue.** Float-heavy stat math goes
   into `kill_decision.rail`; status updates and text munging stay in bash for
   robustness against Rail's cross-function float-return inference quirk.
