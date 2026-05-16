# Agent A — corpus pipeline (worktree-isolated brief)

You are Agent A in a 4-agent parallel build of Spur-arm: a pure-Rail
~15M-param model that emits a robot-arm DSL from natural language. The
overall plan is in `notes/railarm4agent/README.md`; the research
synthesis is in `notes/railarm4agent/RESEARCH.md`. Read both before
starting. Then read THIS file end-to-end before writing any code.

You own the corpus. Your output unblocks Agent B (training). Agents C
and D are running in parallel — coordinate via the chain, not by
touching their files.

---

## Mission

Produce `training/corpora/spurarm_v0.jsonl` containing ≥30,000
(natural-language-prompt, Rail-DSL-script) pairs, three-way split
(pretrain / sft / eval), with every pair verified to compile and run
in our sim or marked with a source-and-stage flag.

The corpus is the SINGLE bottleneck for everything downstream. Quality
matters more than raw count. A 20k clean corpus beats a 50k noisy one.

---

## Required reading before starting

1. `notes/railarm4agent/README.md` — overall plan
2. `notes/railarm4agent/RESEARCH.md` — especially the **Datasets** section
3. `stdlib/robot_arm.rail` — the DSL you must produce examples in
4. `tools/robot/arm_sim.rail` — the sim every generated script must run in
5. `tools/robot/grader.rail` — the verifier you'll filter with
6. `tools/robot/bench_v0.txt` — the 20-prompt eval set (do NOT include
   any of these prompts in the train corpus; they're held out)
7. `tools/robot/reference_scripts/*` — 20 verified scripts as schema examples
8. Memory: `feedback_blob_slice_fan_condense` — the "synthesize aggressively
   then filter" pattern
9. Memory: `feedback_diagnostics_first` — ship counters with every
   transformation
10. Memory: `chain_caught_five_wrong_leverage_swings` — propose chain
    entry BEFORE major work

---

## Architecture

```
                              ┌──────────────────┐
                              │   spurarm_v0     │
                              │     .jsonl       │
                              │  (≥ 30k pairs)   │
                              └────────▲─────────┘
                                       │
                ┌──────────────────────┼──────────────────────┐
                │                      │                      │
        ┌───────┴────────┐    ┌───────┴────────┐    ┌────────┴───────┐
        │  pretrain      │    │      sft       │    │     eval       │
        │  (paraphrase   │    │  (DSL-exact    │    │  (held-out 200,│
        │   prior, ≥25k) │    │   syntax, ≥5k) │    │   no leakage)  │
        └───────▲────────┘    └───────▲────────┘    └────────▲───────┘
                │                     │                      │
        ┌───────┴────────────┐  ┌─────┴──────────┐    ┌──────┴──────┐
        │ extract_           │  │ substrate      │    │  curated    │
        │  virtualhome.rail  │  │  synthesizer   │    │  bench-     │
        │ extract_alfred.rail│  │  + seed pairs  │    │  adjacent   │
        │ extract_saycan.rail│  │  (Robo-Instruct│    │  hand-       │
        └────────────────────┘  │     pattern)   │    │  written    │
                                └────────────────┘    └─────────────┘
                                         │                  │
                ┌────────────────────────┴──────────────────┘
                │                    │
        ┌───────▼────────┐  ┌────────▼────────┐
        │  dedup_filter  │  │  grader.rail    │
        │  .rail         │  │  (every pair    │
        │                │  │  must pass at   │
        │                │  │  stage ≥ 3)     │
        └────────────────┘  └─────────────────┘
```

---

## Deliverables (every one of these is required)

### Files

```
tools/spurarm/corpus/
├── README.md                  # how to reproduce the corpus
├── extract_virtualhome.rail   # VH ActivityPrograms → DSL pairs
├── extract_alfred.rail        # ALFRED high-level PDDL → DSL pairs
├── extract_saycan.rail        # SayCan v0 → DSL pairs
├── synthesize_substrate.rail  # paraphrase + new-prompt synthesizer
├── filter_grader.rail         # runs each pair through grader, drops fails
├── dedup.rail                 # script-canonicalization + NL near-dup
├── split.rail                 # pretrain/sft/eval split with leakage check
├── stats.rail                 # corpus summary (counts, length distribution, source mix)
└── pipeline.sh                # one-shot reproducer: stage → extract → synth → filter → dedup → split

training/corpora/
├── spurarm_v0_raw.jsonl       # all sources before filter/dedup
├── spurarm_v0.jsonl           # final, filtered, deduped, all splits in one file
├── spurarm_v0_pretrain.jsonl  # split: pretrain (~25k)
├── spurarm_v0_sft.jsonl       # split: sft (~5k)
├── spurarm_v0_eval.jsonl      # split: eval (200, held-out, no overlap with bench v0)
├── spurarm_v0_stats.json      # counters from stats.rail
└── README.md                  # corpus card (license, sources, sizes, how to load)
```

### JSONL schema (exact)

Every line of every `.jsonl` file:

```json
{
  "id": "vh:00042",
  "nl": "Pick up the apple and place it on the table.",
  "script": "script = [\n  MoveTo 10 5 5,\n  SetGrip GripClose,\n  MoveTo 15 15 8,\n  SetGrip GripOpen\n]",
  "world": {"obx": 10, "oby": 5, "obz": 5, "present": 1},
  "expected": {"gex": 15, "gey": 15, "gez": 8, "ggrip": 0, "gheld": 0},
  "source": "vh",
  "stages_passed": 4,
  "rationale": "(optional) Goes to apple, closes grip to pick up, moves to table, opens grip to place."
}
```

Fields:
- `id`: globally unique, `<source>:<5-digit zero-padded>`
- `nl`: the natural-language prompt (UTF-8, but ASCII-only is safer; em-dashes and curly quotes have bitten chain entries before, see `lab_chain` memory)
- `script`: a string containing valid Rail that defines `script = [...]`. Must be parseable + compileable when wrapped per `tools/robot/grader.rail::build_program`
- `world`: starting world state (obx<0 means no object)
- `expected`: target final state
- `source`: one of `vh|alfred|saycan|substrate|seed`
- `stages_passed`: 1–4 as graded by `grader.rail` (4 is goal-reach, 3 is runs-without-fault, etc.)
- `rationale` (optional): teacher-emitted reasoning trace — included on `substrate` source when available, used during Agent B's SFT for rationale-then-DSL training (Phi-3 / Distilling-Step-by-Step pattern, see RESEARCH.md)

### Three-way split rules

- **Pretrain**: ~25k. All sources, including verb-remapped VH/ALFRED
  scripts that may not exactly match Rail's DSL syntax. Goal:
  paraphrase robustness + verb-composition prior.
- **SFT**: ~5k. ONLY substrate-synthesized + seed pairs. Every script
  must be syntactically valid Rail DSL AND pass `grader.rail` at
  stages_passed ≥ 3. Goal: DSL-exact syntax + rail-compileability.
- **Eval**: 200 pairs, held out. Sampled to cover the 5 bench-v0
  categories (basic moves, pick-and-place, multi-step, edge phrasing,
  ambiguous). **Must not overlap with `tools/robot/bench_v0.txt`** —
  enforce by checking nl strings against bench prompts pairwise.

---

## Source-by-source recipe

### Source 1: VirtualHome ActivityPrograms (~3–4k pairs after filter)

Repo: https://github.com/xavierpuigf/virtualhome
License: MIT
Format: scripts of `<charN> [Verb] <obj> (idx)`

Verb remap table:
| VH verb | Rail Cmd | Notes |
|---|---|---|
| `[Walk]`, `[Find]`, `[Go]` | `MoveTo <x> <y> <z>` | use object's named-point if known, else assign synthetic coords in [0,30] |
| `[Grab]`, `[PickUp]` | `SetGrip GripClose` | preceded by `MoveTo` to the object position |
| `[PutBack]`, `[Put]`, `[PutOn]` | `SetGrip GripOpen` | preceded by `MoveTo` to target position |
| `[Open]`, `[Close]` of furniture | DROP — out of scope (no door semantics in DSL) | |
| `[Switch]`, `[Read]`, `[Drink]` | DROP — out of scope | |
| `[Sit]`, `[Stand]`, `[Lie]` | DROP — humanoid actions | |

**Object→coordinate mapping:** maintain a stable assignment file
(`tools/spurarm/corpus/vh_object_coords.json`) so the same `<apple>`
always gets the same coords across the corpus. Use a hash-based
assignment seeded by object name; clamp to [3, 27] (workspace edges
left for free positions).

**For pretrain split**: drop the object name and replace with `<obj_0>`,
`<obj_1>`, etc. so the model learns verb composition without
memorizing VH's specific vocab. This is the slot-substitute mitigation
from the risk register.

Filter: every emitted script must pass `script_well_formed` from
`stdlib/robot_arm.rail`. Drop pairs that don't.

### Source 2: ALFRED high-level PDDL (~25k pairs)

Repo: https://github.com/askforalfred/alfred
License: MIT
Data: `traj_data.json::plan.high_pddl` — high-level actions ONLY, do NOT load THOR pixels

ALFRED action remap:
| ALFRED action | Rail Cmd |
|---|---|
| `GotoLocation` | `MoveTo <x> <y> <z>` |
| `PickupObject`, `PickupObjectInReceptacle` | `SetGrip GripClose` |
| `PutObject`, `PutObjectInReceptacle` | `SetGrip GripOpen` |
| `OpenObject`, `CloseObject` | DROP |
| `ToggleObject`, `CleanObject`, `HeatObject`, `CoolObject`, `SliceObject` | DROP |

ALFRED has 3 NL paraphrases per trajectory — emit 3 pairs per
trajectory using the same script. This is paraphrase signal Agent B
needs.

**Critical**: ALFRED uses object IDs that are environment-specific.
Reuse the object-coords mapping from VH (extend with ALFRED's object
vocab). The point of pretrain is verb composition, not object grounding —
keep that crisp.

### Source 3: SayCan v0 (99 pairs)

Repo: https://huggingface.co/datasets/chiayewken/saycan
License: CC-BY 4.0
Format: NL → numbered free-text steps

Manual remap (99 pairs is small enough for hand-curation):
- Each numbered step → one or two Cmds
- Drop kitchen-specific verbs that don't map

Use SayCan as eval-bench-adjacent data; partly held out for eval split.

### Source 4: Substrate synthesizer (~10–50k pairs)

Pattern: Robo-Instruct's RoboSim + InstAlign (RESEARCH.md → Prior Art).

Loop:
1. Start from seed (300 pairs in `/tmp/robot_completions_rerank/` from
   prior session — harvest these into the seed pool with their grader
   verdicts).
2. For each seed pair, prompt substrate (122B Qwen on Studio :8082) for
   N=5–20 alternative NL phrasings of the same intent. (Use
   `tools/robot/call_substrate.sh` — it works.)
3. For each rephrase, ask substrate to emit a Rail DSL script.
4. **Filter every emitted script through `grader.rail`** with the seed
   pair's world state. Keep only stages_passed ≥ 3.
5. Optionally request substrate to emit a *rationale* alongside the
   script (Phi-3 style). Include in `rationale` field.

Plus: synthesize NEW intents not in the seed pool. Prompt substrate with
"emit 100 new natural-language commands for a robot arm that does
pick-and-place in a 30×30×30 workspace with named points A=(10,0,5),
B=(10,10,5), C=(20,10,5), D=(20,20,5), and one ball." For each, ask
substrate to write the corresponding script. Filter through grader.

**Hard requirement**: every substrate-synthesized pair must have
stages_passed = 4 (full goal-reach), OR be marked `stages_passed: 3`
and counted as "negatives" (used by Agent C's RL phase for contrast).
No stage-1 or stage-2 noise in the SFT split.

### Source 5: seed (300+ pairs from prior session)

Location: `/tmp/robot_completions_rerank/b<id>_<n>.rail` — 20 prompts
× 20 reranks = 400 raw completions from the N=20 baseline. Re-grade
each (the rerank session graded them, but re-grade for safety):

```bash
for f in /tmp/robot_completions_rerank/b*_*.rail; do
  id=$(basename "$f" .rail | cut -d_ -f1)
  ./rail_native run tools/robot/grader.rail "$id" "$f" 2>/dev/null | grep '^GRADE '
done
```

Filter to stages_passed ≥ 3. Tag as `source: seed`. These are the
gold-standard pairs because they came from the highest-quality
substrate run on the canonical bench prompts.

---

## Filtering and dedup discipline

After all sources merge to `spurarm_v0_raw.jsonl`:

### `filter_grader.rail`

Per the existing `tools/robot/grader.rail` pattern (see prior session's
work). For each pair:
1. Write `<script>` to /tmp file
2. Build candidate.rail via grader's `build_program`
3. Compile, run, parse SIM_RESULT
4. Compare to `expected`; assign stages_passed

Discard any pair where stages_passed < 3.

### `dedup.rail`

Two-level dedup:

**Script canonicalization**: normalize the script text:
- Strip leading/trailing whitespace
- Collapse internal whitespace
- Lowercase Cmd constructor names? NO — keep canonical case
- Compute SHA-256 of canonical form
- Dedupe by hash

**NL near-duplicate detection**: cheap shingle-based:
- Lowercase, strip punctuation
- 3-gram word shingles
- Jaccard similarity > 0.7 → duplicate
- Keep the one with stages_passed = 4 over stages_passed = 3; otherwise
  keep the one with longer NL (more informative)

### `split.rail`

- Hash `id` → bucket
- Stratify by source so pretrain/sft/eval each contain proportional mix
- **Leakage check**: for every eval pair, verify nl does not match any
  bench_v0.txt prompt (Jaccard > 0.5 → reject)

### `stats.rail`

Output `spurarm_v0_stats.json` with:
```json
{
  "total_pairs": 31472,
  "pretrain_pairs": 25083,
  "sft_pairs": 4912,
  "eval_pairs": 200,
  "by_source": {"vh": 3812, "alfred": 22904, "saycan": 87, "substrate": 4569, "seed": 100},
  "by_stages_passed": {"3": 4012, "4": 27460},
  "script_length_distribution": {"1": ..., "2": ..., ...},
  "nl_length_distribution": {...},
  "unique_canonical_scripts": 19834,
  "eval_bench_overlap_count": 0
}
```

The `eval_bench_overlap_count` MUST be 0 — if non-zero, Agent A's
acceptance test fails.

---

## Acceptance test

Run from a clean clone:

```bash
sh tools/spurarm/corpus/pipeline.sh

# Expected counts (within tolerance)
wc -l training/corpora/spurarm_v0.jsonl              # >= 30000
wc -l training/corpora/spurarm_v0_pretrain.jsonl     # >= 23000
wc -l training/corpora/spurarm_v0_sft.jsonl          # >= 4500
wc -l training/corpora/spurarm_v0_eval.jsonl         # == 200

# Schema valid (every line parses as JSON with all required fields)
python3 -c '
import json
required = {"id","nl","script","world","expected","source","stages_passed"}
ok = err = 0
with open("training/corpora/spurarm_v0.jsonl") as f:
    for line in f:
        try:
            d = json.loads(line)
            assert required.issubset(d.keys())
            ok += 1
        except Exception as e:
            err += 1
print(f"ok={ok} err={err}")
'
# err must be 0

# Random sample passes grader at stage >= 3
shuf -n 50 training/corpora/spurarm_v0.jsonl | while read -r line; do
  # parse JSON, write script to /tmp, run grader, check stage
  ...
done

# Stats sane
cat training/corpora/spurarm_v0_stats.json | jq '.eval_bench_overlap_count'  # must be 0
```

**PASS** if all of:
- spurarm_v0.jsonl has ≥ 30,000 lines
- schema-valid JSON every line
- 50/50 random sample passes grader at stage ≥ 3
- `eval_bench_overlap_count == 0`
- by-source distribution roughly matches the design (no source >70% of total, no source <0.1%)

**FAIL** if any of those fail. Do not merge a failing corpus.

**INCONCLUSIVE** if VH/ALFRED downloads blocked (license server down,
etc.) — emit a chain entry naming the blocker and ship a partial
corpus (substrate + seed only, ~10k pairs) for downstream agents to use
as a starting point.

---

## Chain entry

On completion, append a chain entry with parent `66bb63f9`. cmd points
to a sentinel watcher at `tools/lab/watchers/spurarm_corpus_a.sh` that
emits:

```
===RAIL_LAB_COUNTERS===
{"counter": "pretrain_pairs", "value": <N>}
{"counter": "sft_pairs", "value": <N>}
{"counter": "eval_pairs", "value": <N>}
{"counter": "eval_bench_overlap_count", "value": 0}
{"counter": "random_sample_grader_pass_rate_pct", "value": <0..100>}
===END===
===VERDICT=== PASS
```

Goal text: `"Spur-arm corpus v0 built: <total> pairs across <sources>, pretrain/sft/eval split, leakage-checked"`.

Pre-normalize Unicode in goal/hypothesis text (no em-dashes).

---

## Out of scope for Agent A

- Tokenizer (Agent B owns)
- Model architecture (Agent B owns)
- Training (Agent B owns)
- RL data generation (Agent C may augment the corpus later; you provide v0)
- Hardware (Agent D owns)
- Bench v1+ prompts (separate arc)

If you find a bug in `grader.rail` or `arm_sim.rail` during filtering,
DO NOT fix it inline. File a note in `notes/spurarm_corpus_a_notes.md`
and ship around it (e.g., skip pairs that trip the bug). Coordinate
the fix with the integration session.

---

## Discipline reminders

- **Counter-discipline**: emit `spurarm_v0_stats.json` early in development,
  watch its numbers move as you iterate. Don't ship without it.
- **No em-dashes in chain entry text**: R-ASCII gate rejects them.
- **No commits to main**: stage on `spurarm/A-corpus` worktree branch.
- **No mutations to existing files** except adding entries to
  `tools/lab/watchers/`. The DSL (`stdlib/robot_arm.rail`), sim
  (`tools/robot/arm_sim.rail`), and grader (`tools/robot/grader.rail`)
  are FROZEN for the duration of this arc.
- **Honest reporting**: if you can only build a 15k corpus because
  ALFRED is down, ship 15k with an INCONCLUSIVE chain entry naming
  the blocker. Don't pad with junk.

---

## Estimated effort

6–8 hours. Bottlenecks:
- VH and ALFRED download + first verb-remap pass (2–3h)
- Substrate paraphrase loop (1–2h, parallelizable with BATCH=4 per
  prior session's MaxOOM finding)
- Filter + dedup runs (1h, run sequentially)
- Stats + split + acceptance test (1h)

If you exceed 12 hours and acceptance is still failing, escalate.
