# spurarm_v0 corpus card

Author: Spur-arm Agent A (corpus pipeline)
Date: 2026-05-16
License: MIT (this corpus is a derived dataset; per-source licenses below)
Total: 34,576 (NL prompt, Rail-DSL script) pairs

## Splits

| Split    | Lines |
|----------|-------|
| pretrain | 29,376 |
| sft      | 5,000 |
| eval     | 200 |
| total    | 34,576 |

`spurarm_v0.jsonl` is the concatenation in order
`pretrain + sft + eval`. The three split files are also written
separately for downstream loaders.

## Sources

| Source     | Count | Tag        | Stages | License        |
|------------|-------|------------|--------|----------------|
| proc       | 19,239 | `proc`      | 4       | n/a (synthetic) |
| alfred     | 11,394 | `alfred`    | 3       | MIT (askforalfred/alfred) |
| vh         | 2,420 | `vh`        | 3       | MIT (VirtualHome ActivityPrograms) |
| substrate  | 1,450 | `substrate` | 3-4     | n/a (paraphrase of seed) |
| seed       | 73    | `seed`      | 4       | n/a (this project) |

- `proc`: procedurally generated; every record's script is run
  through `tools/robot/arm_sim.rail::run_sim_with_world` to derive
  `expected` constructively (stages_passed=4).
- `alfred`: ALFRED traj_data.json high_pddl plans, navigation-only
  remap (Goto / Pickup / Put -> MoveTo coord-of-object). Tagged
  stages_passed=3 (sim runs without fault; we don't claim goal-reach
  because the original ALFRED goal has no DSL coordinate analog).
- `vh`: VirtualHome ActivityPrograms `withoutconds/`, same
  navigation-only remap. Same stages_passed=3 rationale.
- `substrate`: 200 seed pairs x 8 substrate-generated NL paraphrases.
  The script is the seed's; only the NL varies. Inherits seed's
  stages_passed.
- `seed`: prior-session 400 substrate-from-bench reranks regraded
  through `tools/robot/grader.rail`; kept only stages_passed >= 3.

## Schema

Each JSONL line:

```json
{
  "id": "<source>:<sequence>",
  "nl": "<natural-language prompt, ASCII printable>",
  "script": "<Rail source defining `script = [...]`>",
  "world": {"obx": -1, "oby": 0, "obz": 0, "present": 0},
  "expected": {"gex": 0, "gey": 0, "gez": 0, "ggrip": 0, "gheld": 0},
  "source": "proc|alfred|vh|substrate|seed",
  "stages_passed": 3
}
```

- `script` is the literal Rail source. Embedded newlines are encoded
  as the two-char sequence `\n` so each record stays on one line.
- `world` is the starting state: `obx < 0` means no ball in world;
  otherwise (obx, oby, obz) is the ball's starting position with
  `present == 1`.
- `expected` is the goal-reach target for stage-4 grading.

## Reproduce

```bash
sh tools/spurarm/corpus/pipeline.sh
sh tools/spurarm/corpus/acceptance.sh training/corpora
```

Acceptance returns 0 on PASS. Chain-entry watcher at
`tools/lab/watchers/spurarm_corpus_a.sh` re-runs the grader sample
and emits the canonical sentinel block.

## Acceptance results (this build)

```
[1] total_pairs=34576 (target >= 30000)  PASS
[2] schema validation:  ok=34576 err=0   PASS
[3] grader sample 50/50:  100%           PASS
[4] eval_bench_overlap=0                  PASS
[5] max_source_share=56% (<= 70)         PASS
VERDICT: PASS
```

See `notes/railarm4agent/CHAIN_SKELETON_AGENT_A.md` for the full
falsification contract.
