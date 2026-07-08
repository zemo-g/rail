# tools/orch — autonomous training-arm orchestrator

Pure-Rail tooling driven by Claude Code's `ScheduleWakeup` + `Bash`.
Reads `docs/archive/EXPERIMENT_PLAN.md` (archived 2026-07-08; the May-2026 queue), launches arms in parallel up to
budget, polls every 30 min, kills laggards, benches winners, writes
LEADERBOARD.md + HANDOFF.md. Commits after every arm.

## Architecture (split between Rail and Claude Code)

```
EXPERIMENT_PLAN.md
        │
        ▼
parse_plan.rail ──→ runs/<arm_id>/run_card.json (one per arm)
                                │
                                ▼
        ┌───────────── orchestrate (Claude Code wakeup loop) ──────────┐
        │                                                              │
        │  every 30 min:                                                │
        │    poll.rail   ──→ for each running arm: status + val_loss   │
        │       │                                                       │
        │       ├─→ kill decision (>2σ behind leader @ matched step)   │
        │       ├─→ launch next queued arm if budget free               │
        │       └─→ on arm exit: run_bench.rail + leaderboard.rail     │
        │                                                              │
        │  on SOTA / queue done / cap hit:                              │
        │       write_handoff.rail + git commit + (PushNotification?)  │
        └──────────────────────────────────────────────────────────────┘
```

**Why polyglot under "pure Rail":** every per-arm decision (parsing,
σ-math, bench-grading, leaderboard rendering, handoff text generation)
is a Rail program. Claude Code only owns the wakeup cadence and the
shell handles for `Bash`/`Monitor` — orchestration *control flow*, not
*data flow*.

## File layout

```
tools/orch/
├── README.md                  this doc
├── parse_plan.rail            EXPERIMENT_PLAN.md → list of arm specs
├── run_card.rail              create runs/<id>/run_card.json
├── launch_arm.sh              shell helper: nohup trainer + log redirect
├── poll.rail                  read all run_cards, decide kills
├── kill_decision.rail         σ math (separable from poll for testing)
├── run_bench.rail             post-completion bench runner
├── update_leaderboard.rail    LEADERBOARD.md writer
├── write_handoff.rail         HANDOFF.md writer
└── tests/
    ├── test_parse_plan.rail
    ├── test_kill_decision.rail
    └── test_leaderboard.rail
```

## Run dir layout (per arm)

```
runs/<arm_id>/
├── run_card.json              spec + live state
├── train.log                  trainer stdout/stderr
├── val_loss.tsv               step\tval_loss (parsed from train.log)
├── bench.log                  post-completion bench run
└── bench_result.json          {pass, strip_pass, total, per_band}
```

## Run card states

`queued → running → (killed | completed | failed) → benched → finalized`

- **queued**: in queue, not yet launched
- **running**: nohup'd trainer alive
- **killed**: σ-laggard rule; bench skipped
- **completed**: trainer exited 0
- **failed**: trainer exited nonzero (compile error, OOM, etc.); bench skipped
- **benched**: bench finished, result in `bench_result.json`
- **finalized**: leaderboard updated, run card committed

## Kill rule

At each poll (every 30 min):

1. For each running arm, parse `val_loss.tsv` (live updated by trainer).
2. Identify the **leader** = arm with lowest val_loss at the highest
   *common* step across running arms. (If only one arm is running, no
   kill candidate.)
3. For each non-leader: at matched step, if `val_loss > leader_val_loss
   + kill_sigma * σ(leader, kill_window)` for the most recent
   `kill_window` consecutive readings, **kill**.
4. Skip kill checks until `step >= kill_min_step`.

Implemented in `kill_decision.rail` as a pure function so it can be
unit-tested separately from poll I/O.

## Wake conditions for the human

`PushNotification` (or osascript fallback) fires only on:

1. **SOTA improvement ≥ wake_threshold_prompts** on `bench_strip` vs
   prior leader. (User configured: +1 prompt absolute.)
2. **All arms in queue have failed** (no successes, queue exhausted).
3. **Budget exhausted** (`wall_clock_cap_min` reached) — soft wake;
   includes leader status if any.

NOT a wake event:

- Single arm completion (logged to leaderboard, no wake).
- σ-kill of a laggard (logged, no wake).
- Bench result equal-or-worse than current SOTA (logged, no wake).

## Commit policy

After **every** arm finalizes:

```bash
git add runs/<id>/run_card.json LEADERBOARD.md
git commit -m "orch: <id> <status> bench=<X/30> val=<Y>"
```

Push is **not** automated (per workspace memory: git proxied through
Mini).

## Smoke test

`tools/orch/tests/smoke.sh` runs the orchestrator end-to-end on a
1-arm plan that finishes in ~2 min, verifies all artifacts exist and
the leaderboard contains the right row.

## Status

- [x] `EXPERIMENT_PLAN.md` (4 real arms + globals)
- [x] `seed_trainer.sh` — substitutes `lcg_state_new <N>` + ckpt prefix
- [x] `parse_plan.rail` — markdown → `runs/<id>/run_card.meta`
- [x] `launch_arm.sh` — seed-substitute, mkdir-lock compile, nohup launch
- [x] `kill_decision.rail` + `tests/test_kill_decision.sh` (4/4 pass)
- [x] `poll.sh` — log-scrape val_loss + status transitions
- [x] `run_bench.sh` — strip-N20 bench wrapper + dry-run mode
- [x] `update_leaderboard.sh` — sorted markdown table
- [x] `write_handoff.sh` — leader/falsified/open/next-prompt
- [x] `condense.sh` — per-prompt OR-ensemble across all bench logs
- [x] `orchestrate.md` — runbook for Claude Code's wakeup loop
- [x] `tests/test_e2e.sh` — end-to-end smoke (8 stages green; uncovered + fixed 2 bugs)
