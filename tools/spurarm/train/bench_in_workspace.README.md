# bench_in_workspace — Phase 1 Cap H PASS gate

100 plain-English prompts that measure whether a trained checkpoint emits
**in-workspace, prompt-faithful DSL**. PASS = >= 90% (>= 90/100). Companion
to the existing 20-prompt `bench_v0`; in spirit a superset, not a duplicate.

Files in this directory:

| File | Role |
|---|---|
| `bench_in_workspace.txt` | 100 prompts, pipe-separated `id|prompt` |
| `bench_in_workspace.expected.txt` | JSONL sidecar; one expected row per prompt_id |
| `check_in_workspace.rail` | Rail checker scaffold (design only — not compiled yet) |
| `README.md` | this file |

## Categories

| Category | Count | Pass shape |
|---|---|---|
| direct_coord | 15 | last MoveTo within +/-1 cm of `expected.target`; all moves in workspace |
| named_point | 10 | last MoveTo OR Home matches named point within +/-2 cm |
| relative_motion | 25 | final pose - start pose matches `expected.delta` within +/-2 cm |
| goal_oriented | 25 | final pose satisfies `expected.region` predicate |
| multi_step | 25 | script length + required ops + pattern-specific signature pass |

## Workspace gate

Front-hemisphere only, per [[spurarm-bringup-2026-05-18]] and
[[maxarm-coord-frame-2026-05-18]]:

- `z in [3, 18]` (firmware-observed up clip is +208 mm = +20.8 cm; spec said +187 mm but empirical is higher; we conservatively cap DSL z at 18)
- horizontal radius `sqrt(x^2 + y^2) >= 5 cm` (closer is firmware-singular)
- horizontal radius `<= 30 cm` (envelope outer)
- all axes in `[0, 30]` (DSL cube)
- DSL `y >= 0` (front-hemisphere; firmware `y <= 0` is the front of the arm, but the DSL flips y at the boundary so DSL `+y forward` == firmware `-y forward`)
- `(0, 0, 0)` exempted (Home / ORIGIN)

The S1 check runs against every `MoveTo` in the candidate. One out-of-workspace
move fails the prompt regardless of final pose.

## Run loop

```bash
# from ~/projects/rail-spurarm-cap-h on Studio:
./rail_native run tools/spurarm/train/bench_in_workspace_eval.rail \
    --prefix training/checkpoints/spurarm-cap-h_seed42_sft_best \
    --bench tools/spurarm/train/bench_in_workspace.txt \
    --expected tools/spurarm/train/bench_in_workspace.expected.txt \
    --max-gen 100 \
    --grammar 1 \
    --out /tmp/bench_in_workspace_cap_h.json
```

`bench_in_workspace_eval.rail` (not yet written; mirrors `bench_eval.rail`)
loops over the 100 rows, shells out to `generate.rail --grammar 1` per prompt,
hands each candidate to `check_in_workspace.rail`, and emits an aggregate JSON:

```json
{
  "prefix": "...",
  "total": 100,
  "passes": 92,
  "by_category": {
    "direct_coord": "14/15",
    "named_point": "10/10",
    "relative_motion": "22/25",
    "goal_oriented": "23/25",
    "multi_step": "23/25"
  }
}
```

PASS gate = `passes >= 90`.

## Convention decisions (resolved 2026-05-22)

These were the 6 open questions from the bench design; resolved by Reilly's
"resolve it" mandate.

### 1. Start pose for relative-motion prompts: **ORIGIN, cold per prompt**

Each prompt is evaluated in a fresh session; the implicit start pose is
`(0, 0, 0)`. There is no carry-over between prompts. This matches how
`bench_v0` runs and keeps the bench reproducible across re-runs.

`expected.start_pose` is `[0,0,0]` for every relative-motion prompt.

If a prompt says "from your current position move 5 cm right", the start
pose is still `(0, 0, 0)` and the checker expects a final pose of `(5, 0, 0)`
within tolerance. The phrase "from your current position" is semantically
descriptive, not a state-carrying directive at bench time.

### 2. Spatial frame: **arm base-frame is canonical**

"Left" and "right" in prompts are interpreted in the arm base-frame:
`+x` = arm's right = user's right (DSL convention per
[[maxarm-coord-frame-2026-05-18]]). This matches `coord_map.rail`'s DSL
header ("x right, y forward, z up"), and it matches how Reilly seats
himself in front of the arm in the live REPL.

(Note: the firmware's internal `+x` is the USER's LEFT — but the DSL
already flips this at the boundary. The DSL convention is what the model
emits, so the bench uses DSL frame.)

### 3. Wave / nod / shake strictness: **permissive, Phase 1**

Prompts w079, w080, w088, w089, w090 pass for ANY alternating motion
along the appropriate axis with amplitude `>= 3 cm` and at least 2 cycles.
The checker does not require:

- Specific waveform (triangle / plateau / sinusoid)
- Return-to-start at the end
- Minimum period count beyond 2
- Specific axis strictness for "nod" (z) vs "shake" (x) — either passes if
  alternation is present along one of the two axes

Phase 2 may tighten if the trained model exploits this looseness.

### 4. Grammar walker: **REQUIRED (`--grammar 1`)**

Per the Cap I diagnostic, decoding without the grammar walker yields
0/20 compile-clean. The bench REQUIRES `--grammar 1` at evaluation. The
acceptance script enforces this by failing if the candidate parses with
the walker off but not on, OR if `--grammar 1` is missing from the eval
command-line trace.

Wiring: `generate.rail --grammar 1` is the canonical call. The bench
eval loop sets this flag unconditionally.

### 5. Named point A = (10, 0, 5): **canonical, y=0 exception kept**

Point A sits on y=0, with horizontal radius = 10 (= x). It passes the
`radius >= 5` workspace gate by virtue of x=10 alone (no y contribution).
This is intentional — A is a documented canonical landmark and changing
its coord would invalidate every existing reference (corpus, bench_v0,
reference_scripts). The y=0 exception is documented in
[[maxarm-coord-frame-2026-05-18]] and an inline note will land in
`coord_map.rail`.

### 6. Multi-step shape patterns: **5 canonical for Phase 1**

Current patterns:

| Pattern | Used by | Pass condition |
|---|---|---|
| `alternating_lateral` | w079 (wave), w080 (sweep) | >= 2 sign-flips in x deltas, amp >= 3 |
| `tap` | w060, w067 | one MoveTo to low-z (~3-5), then one back up |
| `x_sweep` | w086 (line), w075 | >= 2 MoveTos with monotone x progression, near-constant y/z (≤3 cm drift) |
| `square` | w093, w096 | 4 MoveTos forming closed loop in xy plane |
| `forward_up_home` | w072, w078 | MoveTo forward, MoveTo up, then Home (or MoveTo back to ORIGIN) |

If Phase 1 results show the trained model emits novel multi-step
shapes (e.g., circles, arcs, oscillating-then-progressing), add
patterns in a Phase 1.7.5 update. Don't preemptively over-broaden;
this risks accepting degenerate scripts.

## Why this bench exists

Cap I FALSIFIED at 0/20 on `bench_v0` without the grammar walker; 14/20
compile-clean WITH it. That confirms surface degeneracy hid syntactic
competence but did NOT supply coordinate-semantic grounding.
`bench_in_workspace` probes the grounding directly: does the model know
where the workspace is, and does it map English ("forward", "left",
"the upper-right corner") to coords that actually fall inside it?

The 90-of-100 PASS gate is the embodiment roadmap's anchor for Phase 1
("Linguistic embodiment"). Phase 2 ("Embodied SFT") will add
`bench_target_hit` at the 80% gate.

## Memory cross-refs

- [[spurarm-embodiment-roadmap]] — the parent roadmap; Phase 1.7
- [[spurarm-bringup-2026-05-18]] — workspace + frame conventions
- [[maxarm-coord-frame-2026-05-18]] — the double-flip detail
- [[feedback_drone_private]] — not applicable (arm is public work; bench can be too)
