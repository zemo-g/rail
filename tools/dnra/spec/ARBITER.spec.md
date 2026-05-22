# DNRA arbiter.rail v0 — Contract Spec

**Status:** v0 contract — pre-implementation lock.
**Purpose:** Test whether a structural rule can sort *productive disagreement* from *noise* on hand-crafted panel positions, BEFORE we spend GPU on panelist finetuning.

If a v0 arbiter cannot distinguish 10 productive vs 10 noise synthetic disagreements at meaningfully-above-chance accuracy, the architecture has a deeper problem — no amount of training fixes it. This is the cheap falsification of the arbiter layer.

---

## The single question the arbiter answers

Given a panel of position tuples — one per mode — for a single question:

> *Is this a* **productive disagreement** *(the modes are reaching distinct, testable conclusions that downstream resolution can decide between) — or* **noise** *(the modes appear to disagree but are restating the same thing, or talking past each other, or none of their positions are testable)?*

Output: `productive` | `noise` | `ambiguous` (last only if rule is genuinely undecidable).

---

## Input shape (one example per JSONL line)

```json
{
  "id": "synth-001",
  "category": "rail_code|reasoning|open_ended",
  "question": "<the prompt>",
  "panel": [
    {
      "mode": "deductive",
      "prose": "<the prose position>",
      "rail_claim": "<source string OR empty>",
      "rail_claim_output": "<pre-recorded output of executing rail_claim, or empty>"
    },
    {"mode": "empirical", "prose": "...", "rail_claim": "...", "rail_claim_output": "..."},
    {"mode": "adversarial", "prose": "...", "rail_claim": "...", "rail_claim_output": "..."}
  ],
  "ground_truth": "productive|noise"
}
```

v0 trusts the curator's pre-recorded `rail_claim_output`. v1 will re-execute via Rail-eval and verify outputs match. The curator-trust assumption is honest scaffolding — we're testing the arbiter rule's *structural validity*, not its execution-integrity.

---

## Arbiter classification rule v0 (deterministic)

```
inputs := panel positions
claims := [p for p in panel if p.rail_claim is non-empty]
outputs := [p.rail_claim_output for p in claims]
distinct_outputs := unique(outputs)

if len(claims) < 2:
    return "noise"                  -- can't disagree if <2 panelists made testable claims
elif len(distinct_outputs) >= 2:
    return "productive"             -- ≥2 panelists made distinct testable claims
else:
    return "noise"                  -- panelists made claims but they all agree (no real disagreement)
```

That's the entire rule. It encodes one principle: **disagreement is only productive if it's testable AND actually disagreeing.**

What it deliberately ignores in v0:
- Prose content (no NLP)
- Mode identity (no weighting by mode)
- Question category (no per-category specialization)
- Confidence scores (no calibration)

These all become inputs in later versions. v0 establishes the floor.

---

## Acceptance gate

Run arbiter against `sets/synthetic_disagreements.jsonl` (20 hand-curated examples: 10 productive, 10 noise).

| Metric | v0 target | Why |
|---|---|---|
| Accuracy on productive examples | ≥ 8/10 | Rule should catch most testable disagreements |
| Accuracy on noise examples | ≥ 8/10 | Rule should reject most untestable disagreements |
| Overall accuracy | ≥ 16/20 (80%) | Meaningfully above the 50% random-chance baseline |
| No `ambiguous` outputs | 0 | Rule is deterministic; ambiguity would mean curation is wrong |

**Pass** → arbiter scaffold ships, T3 advances to writing examples to the chain via ledger.
**Fail** → either the rule is too crude (acceptable: add structural features) OR the curator-side `rail_claim_output` recording is dishonest (means examples are actually inconsistent — re-curate).

---

## What the curator must avoid (lessons from prior cognitive projects)

- **No prompt-engineering the prose** to telegraph the answer. The arbiter doesn't read prose in v0. If the rule passes only because curated noise has no rail_claims and productive does, that's a real signal — the curator was honest. If the curator made noise examples ALSO have rail_claims that happen to agree, that's a harder test, which is what we want.
- **No leaking the ground_truth into the rail_claim_output field** (e.g., setting empirical's output to "noise: this is a noise example"). The output must be plausibly the result of executing the rail_claim.
- **Half the noise examples must have rail_claims that agree** (not just be empty). Otherwise the rule degenerates to "does anyone have a claim" which doesn't test what we care about.

---

## Files this ticket produces

| File | Lines (est) | Purpose |
|---|---|---|
| `impl/arbiter.rail` | ~120 | Library + CLI runner: parse JSONL → classify → report accuracy |
| `sets/synthetic_disagreements.jsonl` | 20 lines | Hand-curated examples |
| `impl/test_arbiter.rail` | ~50 | Acceptance check against the 16/20 gate |

---

## After v0 passes

- v1: re-execute `rail_claim` via Rail eval, verify `rail_claim_output` is honest curation
- v2: add structural features (mode-consistency, claim-similarity-distance) to the rule
- v3: replace deterministic rule with a small classifier trained on hand-labeled examples
- v4: feed real panelist output (post-finetune) into the same rule; measure productive-disagreement rate

The deterministic rule never goes away — it stays as the structural floor that learned components must beat.
