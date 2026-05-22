# spurarm corpus v2 — pipeline

Ports v1 (`~/projects/rail-spurarm-A/tools/spurarm/corpus/`) to the
v2 SPEC at `SPEC.md`. Built to address the Cap I diagnostic
(coordinate-semantic grounding genuinely absent at 2M params on v1
corpus) by uniform front-hemisphere coord sampling + 10× prompt
diversity + stricter source-share + a new coord uniformity gate.

See `SPEC.md` for the canonical contract. This README is operational.

## Sources

| Source       | Tool                                | Target (~) | Tag                |
|--------------|-------------------------------------|------------|--------------------|
| procedural   | `synthesize_procedural.rail`        | 40,000     | `proc_v2`, stages=4 |
| ALFRED       | `extract_alfred.sh` (capped 20k)    | 20,000     | `alfred`, stages=3 |
| VirtualHome  | `extract_virtualhome.sh`            | 5,000      | `vh`, stages=3     |
| seed         | `extract_seed.sh`                   | ~3,000     | `seed`, stages>=3  |
| substrate    | `synthesize_substrate.sh`           | 12,000     | `substrate`, stages>=3 |

Pre-dedup raw ~= 80,000. After joint-key dedup, the spec target stays
at ~= 80,000 (the procedural source is constructively dedup-resistant
because both NL and coord are sampled).

## What changed vs v1

| Aspect | v1 | v2 |
|---|---|---|
| Coord sampling | named A/B/C/D + 60-coord pool | uniform front-hemisphere (z∈[3,18], r∈[5,30], θ∈[0,π]) |
| Coord validation | constructive (sim faults dropped) | constructive **+** pre-checked via `coord_map.rail::reachable_mm_calib` |
| Prompt templates | ~30 surface forms | 60×24×8×12 = 138,240 Cartesian (sampled) |
| Script-length distribution | basic-move dominant | 60% (1-2), 30% (3-5), 8% (6-8), 2% (9-12) |
| ALFRED cap | 12,000 | 20,000 |
| Substrate target | ~1,500 (NL paraphrase only) | 12,000 |
| Total target | 30,000 floor | 80,000 floor |
| SFT target | 5,000 | 20,000 |
| Per-source max share | <= 70% | <= 50% |
| Dedup | joint FNV-1a (no Jaccard) | **same** (Agent A's lesson preserved) |
| Eval leakage threshold | Jaccard 0.5 | Jaccard 0.3 (tighter) |
| Coord uniformity audit | n/a | <= 5% per 1×1×1 cm cell (NEW kill_target) |

## Pipeline

```
+--------------+    +----------+    +--------+    +--------+
| extractors:  |    |  raw     |    | dedup  |    | split: |
|  proc_v2.rail|--->|  jsonl   |--->| joint  |--->| eval   |
|  vh.sh       |    | (concat) |    | FNV-1a |    | sft    |
|  alfred.sh   |    +----------+    +--------+    | pretrain|
|  seed.sh     |                                   +--------+
|  substrate.sh|                                          |
+--------------+                                          v
                                                  +--------------+
                                                  |  stats.json  |
                                                  |  acceptance  |
                                                  +--------------+
```

## Files

| File | Role | Lines |
|---|---|---|
| `synthesize_procedural.rail` | uniform-coord procedural generator | 674 |
| `templates.rail` | data module: 60/24/8/12 template tables (reference; inlined for now) | 77 |
| `extract_alfred.sh` | ALFRED traj_data.json → JSONL | 159 |
| `extract_virtualhome.sh` | VH ActivityPrograms → JSONL | 134 |
| `extract_seed.sh` | regrade prior rerank pools | 99 |
| `synthesize_substrate.sh` | 122B paraphrase loop (rejected → log) | 167 |
| `dedup.sh` | joint FNV-1a dedup; NO Jaccard | 88 |
| `split.sh` | 4-bucket priority split, Jaccard 0.3 leakage | 219 |
| `stats.sh` | counters + coord_uniformity_max_share_pct (NEW) | 251 |
| `pipeline.sh` | orchestrator (parallel vh+alfred) | 188 |
| `acceptance.sh` | 5 kill_target checks | 82 |
| `sample_grader_check.sh` | random 50-sample grader | 95 |

## Reproducer

Prereqs:

- `./rail_native` in repo root (clean tree); compile.rail at the
  spurarm/cap-h tip.
- `jq` on PATH.
- **Substrate available at `http://localhost:8082`** — Qwen3.5-122B-
  A10B-heretic-2.34bit on Studio (per `dda-122b-portal-infrastructure`
  memo). Pipeline aborts cleanly if absent unless `SKIP_SUBSTRATE=1`.
- Optional: VH `programs_processed_precond_nograb_morepreconds.zip`
  extracted at `/tmp/vh_extract/...`.
- Optional: ALFRED `json_2.1.0.7z` extracted at
  `/tmp/alfred_data/json_2.1.0/`.
- Optional: prior reranks at `/tmp/robot_completions_rerank/` and/or
  `/tmp/robot_completions_stage7_rerank/`.

One-shot:

```sh
PROC_N=60000 \
  ALFRED_CAP=20000 \
  SUBSTRATE_TARGET=12000 \
  SFT_TARGET=20000 \
  EVAL_TARGET=200 \
  sh tools/spurarm/corpus/v2/pipeline.sh

sh tools/spurarm/corpus/v2/acceptance.sh training/corpora_v2
```

Wall-clock estimate (Studio at substrate-capacity):

| Stage | Time |
|---|---|
| proc_v2 (60k) | ~30-60 min |
| VH + ALFRED parallel | ~5 min |
| seed | <1 min |
| substrate (12k @ ~30s/call BATCH=4) | 2-4 h (long tail) |
| dedup + split + stats + acceptance | <2 min |
| **Total** | **4-6 h** |

## Outputs

Under `training/corpora_v2/`:

```
spurarm_v2_raw.jsonl       all sources concatenated, pre-dedup
spurarm_v2.jsonl           final, deduped, splits in order
spurarm_v2_pretrain.jsonl  pretrain split (~59.8k)
spurarm_v2_sft.jsonl       sft split (>= 20k)
spurarm_v2_eval.jsonl      eval split (200; bench-overlap-clean)
spurarm_v2_stats.json      counters + coord_uniformity_max_share_pct
eval_leakage_report.txt    any candidate rejected during leakage check
```

## JSONL schema

Unchanged from v1.

```json
{
  "id": "proc_v2:000042",
  "nl": "Ease smoothly to coordinates 12 4 7, from where you are.",
  "script": "script = [\n  MoveTo 12 4 7\n]",
  "world": {"obx": -1, "oby": 0, "obz": 0, "present": 0},
  "expected": {"gex": 12, "gey": 4, "gez": 7, "ggrip": 0, "gheld": 0},
  "source": "proc_v2",
  "stages_passed": 4
}
```

Source tag changed: `proc` (v1) → `proc_v2` (v2). All other tags
unchanged so downstream loaders that special-case `seed`, `vh`,
`alfred`, `substrate` need no changes.

## Acceptance (SPEC §8)

```sh
sh tools/spurarm/corpus/v2/acceptance.sh training/corpora_v2
```

PASS criteria (5 kill_targets):

1. `total_pairs >= 80000`
2. random 50-sample grader pass rate >= 90% (stages_passed >= 3)
3. `eval_bench_overlap_count == 0`
4. `by_source_max_share_pct <= 50`
5. `coord_uniformity_max_share_pct <= 5` (NEW)

## Risks / known issues (operational)

1. **Substrate co-resident swap.** SPEC §9d — Studio's 64GB can't host
   35B (DDA reasoning) + 122B simultaneously. Pipeline aborts on
   missing substrate. Coordinate with DDA portal window.
2. **bpe.rail O(n²) RAM blowup.** Downstream of this pipeline (Phase
   1.3); v2 corpus generation does NOT touch bpe.rail. Flagged for
   awareness.
3. **Substrate reject rate.** Logged to
   `/tmp/spurarm_v2_pipeline/substrate_rejects.jsonl`. Target < 30%;
   > 50% suggests temperature is too high (default 0.9) or context
   window is too tight.
4. **Procedural generator drop rate.** Some sampled coord chains will
   sim-fault (e.g., if a coord sneaks past `reachable_mm_calib` and
   then hits an in-flight occlusion). The pipeline tolerates this by
   skipping the record and continuing; `PROC_N` is the request count
   not the emit count. Allow ~10-20% over for the requested final
   target (default `PROC_N=60000` → expect ~40k emitted procedural).

## Cross-references

- Spec: `SPEC.md` in this directory
- v1 pipeline: `~/projects/rail-spurarm-A/tools/spurarm/corpus/`
- Memory: `spurarm-embodiment-roadmap`, `spurarm-bringup-2026-05-18`,
  `maxarm-coord-frame-2026-05-18`,
  `feedback_rail_compile_traps`, `feedback_rail_perf_traps`
- Roadmap: Phase 1.2 of `spurarm-embodiment-roadmap`
