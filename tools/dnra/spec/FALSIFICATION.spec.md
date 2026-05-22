# DNRA Falsification Set — Contract Spec v0

**Status:** v0 contract — pre-curation lock.
**Purpose:** Prove (or falsify) that the three epistemic modes — **Deductive · Empirical · Adversarial** — are *orthogonal categories*, not stylistic variants of the same reasoning process. (First Principles was dropped 2026-05-22 after v0.a curation showed it converging with Deductive on most code/system problems — see HANDOFF.md changelog for the finding.)

The arbiter scaffold (T3) tests the *structural rule*. This set tests the *modes themselves*. They are different falsifications and must not be conflated.

---

## The single claim under test

> *For each of the four modes, there exist problems where that mode is* **uniquely right** *— where the mode reaches the correct answer AND no other mode reaches the same answer through its own reasoning.*

If every mode has a niche (≥ N problems where only that mode is right), modes are orthogonal. If any mode is dominated (always right ↔ another mode also right), that mode is **redundant** and the architecture should drop it.

This is the cheap falsification of the modes themselves.

---

## Falsification gate

50 problems total: 25 Rail-code (auto-gradable via `rail_native run`) + 25 reasoning (hand-graded against curator's oracle).

**Per-mode unique-right targets** (after all 50 problems are tagged):
- Deductive: ≥ 5 problems where ONLY deductive's prediction matches the oracle
- Empirical: ≥ 5 problems where ONLY empirical's prediction matches
- Adversarial: ≥ 5 problems where ONLY adversarial's prediction matches

**Total uniqueness threshold:** ≥ 15 problems across the set must be "unique-right" (one mode beats the other two). If fewer, modes are too aligned.

**POC vs production-scale interpretation (locked 2026-05-22 17:25 UTC):** the ≥5-per-mode and ≥15-total thresholds are PRODUCTION-SCALE targets. At POC stage (single curator, ~40 problems), a mode missing the floor is *evidence to widen the corpus*, not evidence to drop the mode. Curator bias dilutes as: more curators, more domains, more impl-defined cases. POC current state: D=9, E=2, A=2 unique-right at 40 problems — D passes; E and A are below floor but architecture is held with the scaling thesis. Re-evaluate at 100+ problems and/or after finetune.

**Failure modes the gate must detect:**
- A mode that's always wrong → redundant (drop it from the panel)
- A mode that's always right alongside another mode → redundant (one of the two is dropped)
- A mode that's never uniquely right → either (a) the mode is real but the curator didn't write problems that exercise it, or (b) the mode doesn't exist as a distinct category. The cure differs.

---

## Per-problem JSONL record shape

```json
{
  "id": "F-001",
  "category": "rail_code|reasoning",
  "question": "<the prompt>",
  "oracle": {
    "kind": "compiler|hand_grade",
    "rail_test_code": "<source executed by rail_native; non-empty iff kind==compiler>",
    "expected_output": "<what the oracle considers correct>"
  },
  "mode_predictions": {
    "deductive":        {"prediction": "<what D would output>", "rationale": "<WHY D reaches this>"},
    "empirical":        {"prediction": "<what E would output>", "rationale": "<WHY E reaches this>"},
    "adversarial":      {"prediction": "<what A would output>", "rationale": "<WHY A reaches this>"}
  },
  "design_notes": {
    "expected_unique_winner": "deductive|empirical|adversarial|none",
    "why_others_miss": "<one-sentence explanation per missed mode>"
  }
}
```

The `rationale` field is load-bearing. Anyone can write a prediction; only honest curation produces a rationale that maps back to the mode's epistemic primitive.

---

## Curator discipline (lessons from prior cognitive projects)

1. **Write the question first; predict modes second.** If you start with "I want adversarial to win this one," you'll back-engineer a problem that flatters adversarial. Backward-design is fine in v1+ once we have a coverage map; in v0, design problems first, predict modes second.

2. **Each mode must be embodied honestly.** The deductive predictor reasons from premises forward. The empirical predictor reasons from data outward. Adversarial actively searches for counterexamples. If a rationale doesn't match its mode's primitive, the curation is dishonest.

3. **Avoid "trick" problems.** A problem where all four modes converge on the *wrong* answer (and the oracle is contrarian) tests humility, not orthogonality. Save those for v1.

4. **No leaking the ground truth into the rationale.** "FP gets this right because FP gets it right" is circular. Rationale must reference *which feature of the problem* this mode is suited to.

5. **Half the 50 must have a unique winner; half can have ties.** Ties test where modes are coupled. Unique-winners test where modes are orthogonal. Both signals matter.

---

## Phased curation plan

| Batch | Count | Focus | Cumulative |
|---|---|---|---|
| **v0.a** | 10 | Quick spike — 2-3 per mode unique-winner. Validate format. | 10 |
| **v0.b** | 15 Rail-code | Compiler-oracle scored. Edge cases (head [], overflow, escape semantics, etc.) | 25 |
| **v0.c** | 15 reasoning | Hand-graded. Math, logic, semantic claims about programs. | 40 |
| **v0.d** | 10 fill | Patch coverage holes after measuring v0.a–c. Target whichever mode has <5 unique-right. | 50 |

Curation is intellectually expensive (~15–30 min per problem). Multi-session work. Batch v0.a should ship first as a "does the format hold?" test.

---

## Mode embodiment reference (for the curator)

**Deductive:** "Given premises P1...Pn, what follows?" Best at: formal proof chains, logical entailment, premise-to-conclusion. Misses: when premises are subtly wrong, when the problem has no formal structure, when the right answer requires escaping the given framing.

**Empirical:** "What does running this / measuring this show?" Best at: cases where data exists, observation is reliable, pattern-from-cases. Misses: when data is misleading, when the sample doesn't cover the edge case, when the right answer is unreachable by observation alone.

**Adversarial:** "Where does this break?" Best at: finding flaws, counterexamples, overflow/underflow/edge cases, breaking assumptions. Misses: when there is no flaw, when fault-finding overrules a correct conclusion, when adversarial energy is misdirected.

These are deliberately overlapping at the edges. The point of the falsification set is to find problems where the differences DO matter.

---

## Scoring (auto-runnable)

`tools/dnra/impl/falsification_score.rail` (future ticket) will:
1. Read `sets/falsification_v1.jsonl`
2. For Rail-code problems: execute `oracle.rail_test_code` via `./rail_native run`, capture output
3. For reasoning problems: trust `oracle.expected_output`
4. For each problem, compare each mode's `prediction` to oracle output → right/wrong
5. Compute per-mode total right + per-mode unique-right
6. Print: did each mode hit its 5-unique-right floor?

---

## What v0 deliberately defers

- No re-execution of mode predictions via actual model inference (that's after T4 → finetune gate)
- No correctness-confidence scores (binary right/wrong is enough for orthogonality)
- No problem-difficulty stratification (medium/hard mix is implicit in batch composition)
- No cross-curator validation (single curator in v0; v1+ adds second curator)
- No replay against trained panelists (that's the production validation, comes after finetune)

---

## After v0 passes

- v1: re-execute mode predictions via finetuned panelists; check whether trained panelists actually behave like the curator predicted
- v2: expand to 200 problems with stratified difficulty + dual curators
- v3: use as held-out eval for every model iteration; perpetual benchmark
