# EXPERIMENT_PLAN.md

Pure-Rail training-arm orchestrator queue. Filled by user; consumed by
`tools/orch/parse_plan.rail`. Each `## arm:` block defines one training
variant. Orchestrator launches up to `parallel_budget` in parallel,
kills laggards >`kill_sigma`σ behind leader at matched step, runs bench
on completion, appends to LEADERBOARD.md, writes HANDOFF.md on terminal
events.

## Globals

| Key                     | Value                                                |
|-------------------------|------------------------------------------------------|
| `parallel_budget`       | 2                                                    |
| `wall_clock_cap_min`    | 480                                                  |
| `wake_threshold_prompts`| 1                                                    |
| `kill_min_step`         | 500                                                  |
| `kill_sigma`            | 2.0                                                  |
| `kill_window`           | 10                                                   |
| `poll_interval_min`     | 30                                                   |
| `bench_after_complete`  | true                                                 |
| `bench_harness`         | `flywheel-local/bench_strip.rail` (strip-N20 CPU)    |
| `commit_after_each_arm` | true                                                 |
| `wake_mechanism`        | osascript                                            |

## Arm schema

Each `## arm: <id>` block must contain every key:

```
## arm: <unique_id>
trainer_template:    <path/to/lm_*.rail>     (cloned + seed-substituted per arm)
seed_override:       <int>                   (replaces template's lcg_state_new N)
hyperparams:         d=<int> max_steps=<int> lr=<float>
                     (informational; must match what trainer_template hardcodes)
corpus_path:         <path>                  (informational; declared by trainer)
expected_wall_min:   <int>
success_criteria:    <comma-separated predicates>
rationale:           <1-3 lines>
```

`success_criteria` predicates:

- `val_loss < <X> @ step <N>` — true at the recorded step ≥ N closest to it
- `bench_strip >= <K>/30`     — single-best strip-graded pass count
- `bench_raw   >= <K>/30`     — single-best raw pass count

An arm is **success** if ALL listed predicates pass. **Falsified** otherwise.
Arms are not killed for failing success criteria — only for the σ-laggard
rule. Failed arms still get bench-graded and appear on LEADERBOARD.

## Per-arm artifacts

```
runs/<arm_id>/
├── run_card.json           spec + live state
├── trainer.rail            cloned + seed-substituted from trainer_template
├── checkpoints/<id>_best.* trainer's own checkpoint output
├── train.log               trainer stdout/stderr
├── val_loss.tsv            step\tval_loss (parsed live from train.log)
├── bench.log               post-completion bench run
└── bench_result.json       {pass, strip_pass, total, per_band}
```

---

## arm: smoke_v54_repro

```
trainer_template:    tools/train/lm_v54_BQ2_s77.rail
seed_override:       77
hyperparams:         d=256 max_steps=3000 lr=0.01
corpus_path:         training/corpora/spur_compile_back_quarter.txt
expected_wall_min:   45
success_criteria:    val_loss < 3.30 @ step 2500, bench_strip >= 8/30
rationale:           Smoke test — exact v54 reproduction (seed=77 unchanged).
                     Validates orchestrator end-to-end before queueing variant
                     arms. Also serves as a fresh post-V-fix data point on the
                     v54 recipe (per audit, all pre-2026-05-05 numbers are
                     floors not ceilings).
```

## arm: bq_s200_repro

```
trainer_template:    tools/train/lm_v54_BQ2_s77.rail
seed_override:       200
hyperparams:         d=256 max_steps=3000 lr=0.01
corpus_path:         training/corpora/spur_compile_back_quarter.txt
expected_wall_min:   45
success_criteria:    val_loss < 3.30 @ step 2500, bench_strip >= 6/30
rationale:           Back-quarter recipe at fresh seed (s200, untested). Per
                     spur_compile_rail_lever_reproducible.md, BQ-class is
                     bimodal: ~67% of seeds hit ≥6/30, ~33% collapse to 0/30.
                     Tests whether the lever still reproduces post-V-fix and
                     whether s200 lands in the productive mode.
```

## arm: halfB_s5555_repro

```
trainer_template:    tools/train/lm_v43_halfB_s5555.rail
seed_override:       5555
hyperparams:         d=256 max_steps=3000 lr=0.01
corpus_path:         training/corpora/spur_compile_half_b.txt
expected_wall_min:   45
success_criteria:    val_loss < 3.30 @ step 2500, bench_strip >= 6/30
rationale:           Exact v43 reproduction (seed=5555). Per
                     spur_halfB_better_than_full.md, half-B is the robust
                     shipping recipe (mean 3.9, zero 0/30 collapses across
                     10 seeds; peak v43 = 7/30). Confirms or falsifies the
                     robustness claim post-V-fix.
```

## arm: halfB_s7777_fresh

```
trainer_template:    tools/train/lm_v43_halfB_s5555.rail
seed_override:       7777
hyperparams:         d=256 max_steps=3000 lr=0.01
corpus_path:         training/corpora/spur_compile_half_b.txt
expected_wall_min:   45
success_criteria:    val_loss < 3.30 @ step 2500, bench_strip >= 5/30
rationale:           Half-B at untested seed (s7777). Together with s5555
                     repro, gives a 2-point post-V-fix half-B sample. If
                     both ≥6/30 with low variance, half-B robustness claim
                     survives the V-fix; if either collapses to 0-1/30,
                     prior 10-seed robustness was an artifact of the bug.
```
