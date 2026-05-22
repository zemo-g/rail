# spurarm corpus v2 -- design spec

Author: Phase 1.1 of [[spurarm-embodiment-roadmap]]
Status: SPEC ONLY -- corpus not yet generated
Predecessor: v1 corpus (34,576 pairs, falsified Cap I at kill_target)
Companion: `~/projects/rail-spurarm-A/tools/spurarm/corpus/README.md` (v1 pipeline)

## 1. Why v2

v1 corpus + 2M-param trainer FALSIFIED Cap I at commit `299c51e`
([[spurarm-bringup-2026-05-18]] Stage 7 diagnostic):

| decode mode | bench | compile-clean |
|---|---|---|
| `--grammar 0` | 0/20 | 0/20 |
| `--grammar 1` | 0/20 | **14/20** |

The 0 -> 14 compile lift under the grammar walker proves the model has
*syntactic* knowledge of the DSL. What it lacks is *coordinate-semantic
grounding*: it emits attractors like `MoveTo 100 100 100` (out of the
0-30 workspace) or `MoveTo 10 10 5` (literal point B) regardless of the
prompt. No decoder fix can supply coordinate semantics that aren't in
the training distribution.

Root cause in v1: 19,239 procedural pairs use a 4-named-point + 60-free-
coord pool. Even with 5,536 unique canonical scripts, the named points
A/B/C/D and a handful of "convenient" free coords dominate the empirical
coordinate distribution. By Cap I diagnostic, this is "genuinely absent"
knowledge at 2M params -- the model collapses to the modal coord per
verb class.

v2 fixes this by sampling coords uniformly from the front-hemisphere
workspace, expanding prompt diversity 10x, and gating every pair through
`arm_sim::run_sim_with_world` before inclusion.

## 2. Prompt diversity

Target: **>= 300 prompt-family templates** (10x v1's ~30 surface forms
across 5 procedural families).

Templates are the cross-product of:

| dimension | size | examples |
|---|---|---|
| verb | 60 | move, reach, go, navigate, place, position, send, push, shift, slide, ease, glide, dart, advance, retreat, lift, drop, pluck, grab, snatch, set, lay, plant, drop off, retrieve, fetch, return, park, sit, idle, sweep, draw, trace, scan, brush, scribble, hop, jump, dab, tap, poke, tip, touch, kiss, point, gesture, wave, salute, wiggle, nudge, edge, drift, hover, settle, perch, rest, halt, freeze, pause |
| adverb / qualifier | 24 | slowly, quickly, smoothly, carefully, precisely, gently, briskly, rapidly, deliberately, casually, firmly, lightly, in a hurry, without rushing, with care, exactly, approximately, roughly, just barely, a little, way over, slightly, partially, fully |
| target-form | 8 | exact coords `(x, y, z)`, "coordinates x y z", "the position (x, y, z)", named point A/B/C/D, ORIGIN, relative offset ("2 cm to the right of B"), descriptive ("upper-left corner"), "current position" + delta |
| landmark / context | 12 | absent, "from where you are", "above the table", "before you do anything else", "after a brief pause", "then return", "while gripping", "once you reach it", "if you can", "even if it's awkward", "as best you can", "starting from home" |

Each prompt is the result of one row of (verb, adverb, target, landmark,
script-length-bucket). Template inflater lives in
`tools/spurarm/corpus/v2/templates.rail` (or `.sh`). The full Cartesian
is 60*24*8*12 = 138,240 -- we sample at random rather than enumerate.

In addition, **>= 30% of NL prompts** are paraphrased by the substrate
(Qwen3.5-122B at Studio :8082) for surface-form variety the templates
can't reach -- contractions, multi-sentence structure, polite framing,
typos, etc. Substrate paraphrase preserves the target coord/script
identity; only the NL field changes.

## 3. Coordinate sampling spec

**Uniform front-hemisphere workspace sampling.** For each MoveTo coord
needed by a pair:

1. Sample `z ~ Uniform([3, 18])` (inclusive integers).
2. Sample horizontal radius `r ~ Uniform([5, 30])` (inclusive integers).
3. Sample angle `theta ~ Uniform([0, pi])` (front half-plane only;
   firmware `+y` is behind the base, so DSL `y >= 0` is the user-facing
   front).
4. Convert to DSL cartesian: `x = round(r * cos(theta))`,
   `y = round(r * sin(theta))`.
5. Clip `x, y` to `[0, 30]`.
6. Validate via `coord_map.rail::reachable_mm_calib` -- if it returns 0
   (out of envelope, behind base, or above/below clip), reject and
   resample.

**No coord bias to named points.** A and B and C and D appear in roughly
their proportion in the random sample, no special boost. Named-point
prompts use the templates that mention "point A" etc.; they don't
preferentially produce A-coord scripts.

**Coordinate uniformity audit (NEW kill_target):** quantize each emitted
coord to a 1x1x1 cm cell (the cube the DSL already lives in). No single
cell may exceed **5% of all coords** in the final corpus. This is a hard
gate -- the `stats.sh` script computes `coord_uniformity_max_share` and
fails acceptance if > 5.

## 4. Verb compositionality

Script-length distribution targets:

| length (# Cmds) | share | notes |
|---|---|---|
| 1-2 | 60% | basic moves, single-grip ops |
| 3-5 | 30% | pick-and-place, multi-step navigation |
| 6-8 | 8% | extended chains, multiple waits, return-home tails |
| 9-12 | 2% | stress-test compositional limit (DSL cap is 12) |

Total **multi-step (>= 2 Cmds): 90%**, of which **~33% are multi-step
chains (>= 3 Cmds) -- the 30% spec target**. This is up from v1, where
`multi_step` was 1 of 5 families and the corpus skewed toward
length-1-or-2 basic moves.

Verb compositionality is enforced at the template layer: each length
bucket has its own set of templates that compose `MoveTo`, `SetGrip`,
`Wait`, and `Home` according to grammar legality. `Wait` (in ms in
[100, 5000)) appears in ~25% of length-3+ scripts.

## 5. Workspace adherence

**Every pair runs through `arm_sim.rail::run_sim_with_world` BEFORE
inclusion.** If any single `MoveTo` in the script triggers a workspace-
out-of-bounds fault (`coord_map.rail::ik` returns fault != 0), the pair
is rejected. The procedural generator already does this constructively
for v1 stages_passed=4 records; v2 makes it mandatory for **all**
sources, including substrate paraphrase output.

Substrate-paraphrased pairs: if the substrate emits a new script (not
just a new NL), re-run the sim. If the script changed and the new one
faults, reject. The seed script and its substrate-paraphrased NL
twins share the same script; only the script needs simming once.

Result: stages_passed >= 3 for 100% of v2 records. Pairs with
stages_passed=4 (sim end-state matches `expected`) are flagged for SFT
eligibility; stages_passed=3 (ran without fault, but `expected` not
matched, e.g. for paraphrase-only sources where `expected` is taken
from the seed) are pretrain-eligible.

## 6. Target counts

| split | target | vs v1 | notes |
|---|---|---|---|
| total pairs | **80,000** | 34,576 | 2.3x |
| pretrain | ~59,800 | 29,376 | the bulk |
| SFT | **>= 20,000** | 5,000 | 4x |
| eval | 200 | 200 | unchanged |

**Per-source max share <= 50%** (v1 was 56%, target <= 70%). This is
tighter than v1 because no single source -- not even the procedural
generator -- should dominate the distribution. Suggested source mix
(soft targets; actual mix subject to the cap):

| source | target | notes |
|---|---|---|
| `proc_v2` | 40,000 | uniform-coord procedural generator |
| `alfred` | 20,000 | full uncapped (was 11,394) |
| `vh` | 5,000 | expand to broader VH directories |
| `substrate` | 12,000 | de-novo prompts + NL paraphrase |
| `seed` | 3,000 | regrade of historical reranks + cap_H stable runs |

## 7. Dedup policy

**Joint key**: FNV-1a over `(normalized_nl, canonical_script)` per
Agent A's lesson ([[spurarm-bringup-2026-05-18]] memory note).
`normalized_nl` lowercases, collapses whitespace, strips punctuation.
`canonical_script` strips all whitespace and comments; preserves
constructor order; converts the sugar surface (`move_to x y z`) to its
ADT form (`MoveTo x y z`) before hashing so the two forms count as
equivalent.

**Per-source dedup rules**:

- All sources: drop exact (nl, script) duplicates via the joint key.
- **NO Jaccard near-dup cut on paraphrase sources** (substrate, ALFRED
  trajectories with 3 turk paraphrases each). Agent A's data shows a
  0.7 cutoff drops ~40% of the corpus and gutters the paraphrase
  signal. The joint key is sufficient: identical (nl, script) pairs
  drop, distinct surface forms of the same script stay.
- Cross-split leakage: eval split must have 0 (nl, script) overlap with
  the bench probe AND 0 with the SFT/pretrain splits at Jaccard >= 0.5
  on the NL field. Tighter than v1 (which used Jaccard 0.5 on NL).

## 8. Acceptance script structure

`tools/spurarm/corpus/v2/acceptance.sh <corpora_dir>` runs these 5
kill_target checks. Exit 0 PASS, 1 FAIL, 2 INCONCLUSIVE.

```sh
#!/bin/sh
# 5 kill_targets per the v2 spec.

set -u
DIR="${1:?usage: acceptance.sh <corpora_dir>}"
MAIN="$DIR/spurarm_v2.jsonl"
STATS="$DIR/spurarm_v2_stats.json"

fail=0

# 1. total pairs >= 80,000
total=$(wc -l < "$MAIN" | tr -d ' ')
echo "[1] total_pairs=$total (target >= 80000)"
[ "$total" -lt 80000 ] && fail=1

# 2. random 50-sample grader pass rate >= 90%
sample_out=$(sh tools/spurarm/corpus/v2/sample_grader_check.sh "$MAIN" 50 | tail -1)
pct=$(printf '%s' "$sample_out" | sed -n 's/.*pct=\([0-9]*\).*/\1/p')
echo "[2] grader_pass_pct=$pct (target >= 90)"
[ "${pct:-0}" -lt 90 ] && fail=1

# 3. eval / bench overlap count == 0
overlap=$(jq '.eval_bench_overlap_count' "$STATS")
echo "[3] eval_bench_overlap=$overlap (target == 0)"
[ "$overlap" != "0" ] && fail=1

# 4. by-source max share <= 50%
max_share=$(jq '.by_source_max_share_pct' "$STATS")
echo "[4] by_source_max_share=$max_share (target <= 50)"
[ "${max_share:-0}" -gt 50 ] && fail=1

# 5. coord uniformity max share <= 5%  (NEW)
coord_max=$(jq '.coord_uniformity_max_share_pct' "$STATS")
echo "[5] coord_uniformity_max_share=$coord_max (target <= 5)"
[ "${coord_max:-0}" -gt 5 ] && fail=1

[ "$fail" = "0" ] && { echo "VERDICT: PASS"; exit 0; }
echo "VERDICT: FAIL"
exit 1
```

`stats.sh` is extended over v1 to compute `coord_uniformity_max_share_pct`:
quantize every `MoveTo x y z` coord to a 1x1x1 cm cell, count occurrences
per cell, divide max-cell count by total-coord count.

## 9. Risks + mitigations

**(a) Coord-attractor recurrence.** Even with uniform sampling, the
trainer may learn a coord prior from the prompt distribution that biases
output. Mitigation: the coord_uniformity audit (check 5) gates the
corpus itself, but the proof point is the model's bench output. If
Phase 1.7 `bench_in_workspace` shows < 90% in-workspace despite v2,
re-audit at the **per-prompt-class** level (e.g., do "ball pickup"
prompts disproportionately collapse to point A?).

**(b) Substrate collapse on certain prompts.** Qwen3.5-122B at temp=0.9
will sometimes emit invalid DSL (out of workspace, missing `script =`,
wrong constructor names). Pipeline accepts only `arm_sim`-validated
output; rejected pairs are logged to `/tmp/spurarm_v2_pipeline/substrate_rejects.jsonl`
for offline analysis. Target reject rate < 30%; > 50% means substrate
context window is too tight or temp too high.

**(c) bpe.rail O(n^2) RAM blowup.** Agent B's report flagged 1MB input
-> 15GB peak ([[feedback_rail_perf_traps]]). Tokenizer v2 training in
Phase 1.3 must chunk the pretrain split. v2 corpus generation itself
does NOT touch bpe.rail, so the cap is downstream; flagged here for
roadmap awareness.

**(d) Substrate co-resident swap with DDA.** Studio's 64GB cannot host
35B (DDA POC reasoning) and 122B (substrate) simultaneously per
[[dda-122b-portal-infrastructure]]. v2 generation must be scheduled
during a 122B window; pipeline.sh starts with a `curl :8082/v1/models`
probe and aborts if the substrate isn't loaded. Generation timing must
be coordinated with whatever DDA work is active; closing memo says POC
closed 2026-05-12 so the 122B should be parkable for arm work.

## 10. Reproducer

```sh
# from Studio at ~/projects/rail-spurarm-A
# (or whichever worktree gets the v2 work; spec is filesystem-agnostic)

PROC_N=60000 \
  ALFRED_CAP=20000 \
  VH_DIR=/tmp/vh_extract/programs_processed_precond_nograb_morepreconds \
  ALFRED_DIR=/tmp/alfred_data/json_2.1.0 \
  SEED_DIR=/tmp/robot_completions_rerank \
  SUBSTRATE_TARGET=12000 \
  SFT_TARGET=20000 \
  EVAL_TARGET=200 \
  sh tools/spurarm/corpus/v2/pipeline.sh

# Acceptance + chain entry.
sh tools/spurarm/corpus/v2/acceptance.sh training/corpora_v2
sh tools/lab/watchers/spurarm_corpus_v2.sh
```

Outputs under `training/corpora_v2/`:

```
spurarm_v2_raw.jsonl       all sources concatenated, pre-dedup
spurarm_v2.jsonl           final, deduped, all 3 splits in order
spurarm_v2_pretrain.jsonl  pretrain split (~59.8k)
spurarm_v2_sft.jsonl       sft split (>= 20k)
spurarm_v2_eval.jsonl      eval split (200; bench-overlap-clean)
spurarm_v2_stats.json      counters + coord_uniformity_max_share_pct
README_v2.md               corpus card with per-source license + counts
```

Pipeline is parallel where possible: procedural generator is single-
process (xorshift PRNG is seed-deterministic), but substrate paraphrase
+ ALFRED + VH walks each run as their own background job. Total wall-
clock estimate at Studio capacity: 4-6 hours (substrate is the long
tail at ~30s/call at BATCH=4).

## Cross-references

- [[spurarm-embodiment-roadmap]] -- Phase 1.1 deliverable target.
- [[spurarm-bringup-2026-05-18]] -- Cap I diagnostic + JSONL schema.
- [[feedback_rail_perf_traps]] -- bpe.rail O(n^2) cap, length-zero
  perf trap.
- [[dda-122b-portal-infrastructure]] -- substrate co-resident swap.
- v1 pipeline: `~/projects/rail-spurarm-A/tools/spurarm/corpus/`
  (README + acceptance.sh + synthesize_procedural.rail).
