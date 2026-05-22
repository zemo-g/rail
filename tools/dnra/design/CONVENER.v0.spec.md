# DNRA convener.rail v0 - Contract Spec

**Status:** v0 contract - pre-implementation lock.
**Purpose:** Decide, before any panelist runs, (a) whether to spend a full 3-mode deliberation on the question or take a cheaper path, and (b) which subset of `Deductive | Empirical | Adversarial` to invoke. Halting (when to stop deliberation) is post-MVP and out of scope for v0.

If a deterministic Convener cannot route the question set with meaningfully-above-naive triage, the cost of running deliberation everywhere will swamp the architecture. v0 establishes the floor; promotion to a learned-classifier Convener is gated on this floor being insufficient.

---

## The single question the Convener answers

Given a fresh question and the (small) recent ledger context:

> *(1) Fast-path or deliberate-path? (2) If deliberate, which subset of {D, E, A}?*

Output is written into the `triage` envelope of the deliberation entry BEFORE panelists run. Panelists read `triage.selected_panel` to know whether they were invited.

---

## Decision inputs

The Convener reads ONLY the following. No prose-content inspection, no NLP, no model call.

| Input | Source | Shape |
|---|---|---|
| `question.text` | caller | string - used for length-bucket + cheap regex on Rail-syntax markers |
| `question.features.category` | caller or pre-classifier stub | `"rail_code"` / `"reasoning"` / `"open_ended"` |
| `question.features.complexity_hint` | caller or pre-classifier stub | `"trivial"` / `"medium"` / `"hard"` |
| `question.features.has_oracle` | caller | bool |
| `question.features.oracle_kind` | caller | `"compiler"` / `"falsification_set"` / `"user"` / `"none"` |
| recent ledger tail (last K=32 entries, by `ledger_iter_tail`) | local chain | array of prior deliberation envelopes |

The `complexity_hint` is *Convener's pre-deliberation estimate*; if absent the Convener computes it from `question.text` length and the count of Rail-syntax tokens. Ground truth comes from outcomes (deferred).

What the Convener does NOT read in v0: panelist self-confidence, weights_hash, prior arbiter decisions on similar questions (deferred to v1+ - this is the learned-Convener input set).

---

## Decision outputs - the `triage` envelope

The Convener writes exactly these fields onto the deliberation entry, all set BEFORE panelists run (panelists read them):

```json
"triage": {
  "path": "fast" | "deliberate",
  "reason": "<one of the rule's terminal labels - see below>",
  "selected_panel": ["deductive"] | ["deductive","empirical","adversarial"] | <subset>
}
```

`reason` values are a closed set (terminal labels of the rule below), not free-form. This makes the Convener's behavior auditable by `grep` on the chain.

`selected_panel` ordering is canonical: `["deductive","empirical","adversarial"]`, filtered. Never reorder; downstream weights and the SCHEMA example assume this ordering.

---

## Convener routing rule v0 (deterministic)

```
inputs := question.features (category, complexity_hint, has_oracle, oracle_kind)
text   := question.text
ledger_tail := last K=32 deliberation entries from chain (may be empty on cold start)

-- Rule R0: trivial questions skip deliberation entirely
if complexity_hint == "trivial":
    return {path: "fast", reason: "R0_trivial", selected_panel: ["deductive"]}

-- Rule R1: compiler-oracle Rail-code questions get D + A
-- D reads the spec/docs; A's empirical edge-case prior (overflow, fp, scale) has
-- documented unique-right hits on this category (F-004 fib overflow, F-032 sqrt fp).
-- E is conditionally added if the question text mentions a runtime symptom
-- (segfault, crash, hang, leak, slow, error) - signals an observable to test.
if category == "rail_code" and oracle_kind == "compiler":
    panel := ["deductive", "adversarial"]
    if regex(text, "(?i)\\b(segfault|crash|hang|leak|slow|error|panic|loop)\\b"):
        panel := panel + ["empirical"]
    return {path: "deliberate", reason: "R1_rail_compiler_oracle", selected_panel: panel}

-- Rule R2: rail_code without compiler oracle (hand-graded edge-case questions)
-- D is the workhorse (lost_alone=0 across v0a+b+c); A is included unless the
-- question reads as a documented-invariant statement (no edge to find).
-- The "documented-invariant" tell is a question that asks 'does X always Y'
-- with no scale / overflow / numeric / unsafe markers - in which case A's
-- 14/40 lost-alone rate predicts it will drag the panel down.
if category == "rail_code":
    panel := ["deductive"]
    needs_e := regex(text, "(?i)\\b(observe|measure|run|test|trace|benchmark|profile)\\b")
    needs_a := regex(text, "(?i)\\b(overflow|underflow|fp|float|precision|scale|edge|race|concurrent|large|huge|max|min|nan|inf|wrap|truncate)\\b")
    if needs_e: panel := panel + ["empirical"]
    if needs_a: panel := panel + ["adversarial"]
    if length(panel) == 1 and complexity_hint == "hard":
        panel := panel + ["adversarial"]      -- hard + no signal -> hedge with A
    return {path: "deliberate", reason: "R2_rail_invariant_or_specialist", selected_panel: panel}

-- Rule R3: reasoning questions - full 3-mode default, with A gated out on
-- "documented-fact" reasoning where A's lost-alone rate is highest
if category == "reasoning":
    panel := ["deductive", "empirical", "adversarial"]
    if regex(text, "(?i)\\b(definition|standard|spec|documented|by definition|formally)\\b"):
        panel := ["deductive", "empirical"]   -- drop A on documented-fact framing
    return {path: "deliberate", reason: "R3_reasoning", selected_panel: panel}

-- Rule R4: open_ended - no oracle, no auto-scoring viable
-- Run all 3, mark as low-resolution; outcome layer cannot score it cleanly.
if category == "open_ended":
    return {path: "deliberate", reason: "R4_open_ended", selected_panel: ["deductive","empirical","adversarial"]}

-- Rule R5: fallback - missing/unknown category
return {path: "deliberate", reason: "R5_fallback", selected_panel: ["deductive","empirical","adversarial"]}
```

The rule encodes three observations from T4 v0a+b+c (40 problems, single-curator baseline; treat as production-floor not ceiling per the scaling thesis):

1. **D is never wrong alone** (lost_alone=0). D is mandatory on every deliberate-path question.
2. **A's lost-alone rate is 14/40**, concentrated on convention-aligned/documented-fact questions where there is no edge to find. The Convener gates A out when the text shape predicts "no edge."
3. **E's value is rare but irreplaceable on impl-defined / runtime-observable questions** (F-002 dict order, F-026 empty-tuple identity). The Convener gates E in on runtime-symptom or measurement-verb markers.

What it deliberately ignores in v0:
- Prose semantics (no model call, no embedding similarity)
- Per-mode historical accuracy from the ledger (deferred to v1; needs outcomes layer)
- Halting decisions (Convener v0 routes; arbiter halts via its own rule)
- Dynamic panel composition mid-deliberation (one-shot at entry)

---

## Acceptance gate

Run Convener against `sets/synthetic_triage.jsonl` (40 hand-curated examples, see shape below). Curator labels each question with the *intended productive routing* AND a *wasteful counter-routing*; Convener output is scored against the intended productive routing.

| Metric | v0 target | Why |
|---|---|---|
| Correct path (fast/deliberate) | >= 34/40 (85%) | Path is the cheaper decision; should be easy |
| Correct selected_panel (set equality) | >= 32/40 (80%) | Match arbiter's 16/20; same structural-rule discipline |
| No empty selected_panel | 0 | An empty panel is a deliberation with no panelists - bug |
| All `reason` values in the closed terminal-label set | 40/40 | Auditability invariant |
| No `path: fast` with `selected_panel != ["deductive"]` | 0 | Schema invariant: fast = single mode |

**Pass** -> Convener v0 ships; replaces the deterministic placeholder.
**Fail (path metric < 34/40)** -> rule's path logic is too crude; add features (e.g., split `complexity_hint == "medium"` into sub-rules) and re-run before considering a model promotion.
**Fail (panel metric < 32/40)** -> the panel-subset logic is the weak link. First check: is the curator's intended routing reproducible by *any* deterministic rule? If yes, refine. If no, the question set is the problem, not the rule.

The set itself is intellectually expensive: ~10 min per problem to design "productive routing vs wasteful counter-routing," multi-session work analogous to the falsification set.

---

## Synthetic triage set - record shape

```json
{
  "id": "T-001",
  "question": {
    "text": "...",
    "features": {
      "category": "rail_code|reasoning|open_ended",
      "complexity_hint": "trivial|medium|hard",
      "has_oracle": true,
      "oracle_kind": "compiler|falsification_set|user|none"
    }
  },
  "intended": {
    "path": "fast|deliberate",
    "selected_panel": ["deductive", ...],
    "rationale": "<why this routing is productive>"
  },
  "wasteful_counter": {
    "path": "deliberate|fast",
    "selected_panel": ["deductive","empirical","adversarial"],
    "rationale": "<why this routing would burn compute or produce noise>"
  }
}
```

Suggested distribution across the 40:

| Bucket | Count | What it tests |
|---|---|---|
| Trivial (R0) | 6 | Fast-path correctness on cheap questions |
| Rail-code + compiler oracle, edge-case signal (R1+E) | 6 | E gated in on runtime-symptom regex |
| Rail-code + compiler oracle, no edge signal (R1) | 6 | D+A baseline |
| Rail-code invariant, no edge (R2 D-only) | 6 | A gated OUT on convention questions |
| Rail-code w/ overflow/scale markers (R2 D+A) | 4 | A gated IN on numeric markers |
| Reasoning, documented-fact (R3 drop A) | 6 | A gated out on spec-literacy framing |
| Reasoning, exploratory (R3 full) | 4 | Full panel default |
| Open-ended / fallback (R4/R5) | 2 | Routing on missing oracle |

---

## What v0 deliberately omits (deferred to v1+)

- **Halting decisions.** v0 is one-shot routing at deliberation entry; the arbiter ends deliberation via its own structural rule. Multi-round halting (when to call another round vs stop) is v2+.
- **Per-mode historical accuracy lookup.** The ledger tail input is currently unused by the rule. v1 will read prior outcomes scored against modes-per-category to dynamically discount panels that have been wrong-alone on this category.
- **Mid-deliberation re-routing.** v0 picks the panel and commits. v2+ may add a "panel disagrees structurally - escalate to fuller panel" step.
- **Learned-classifier Convener.** Locked as the deterministic-first path. Promotion to a Llama 3.2 1B Convener is gated on: (a) v0 acceptance below 75% on either metric, OR (b) operations data showing the deterministic rule misroutes >15% of production questions across 200+ deliberations.
- **Per-question budget / latency targets.** The fast/deliberate split is a categorical decision in v0, not a latency-budget decision. Latency-aware routing is v1+ once we have observed panelist latencies.
- **Cross-deliberation deduplication.** If the chain already answers this question, the Convener doesn't notice. Lookup index is deferred to the SQLite projection (post-1000 entries).
- **Witnesses / cross-node panels.** Single-signer assumption holds; Convener doesn't model remote panelists.

---

## Files this ticket produces

| File | Lines (est) | Purpose |
|---|---|---|
| `impl/convener.rail` | ~180 | Library + CLI: read question record -> write triage envelope. Pure Rail, no model. |
| `sets/synthetic_triage.jsonl` | 40 lines | Hand-curated triage cases (intended + wasteful counter) |
| `impl/test_convener.rail` | ~80 | Acceptance harness: runs rule against the set, scores against the 4 gate metrics |
| (touched) `spec/SCHEMA.md` | - | Add note that `triage.reason` values are drawn from the closed terminal-label set defined here |
| (touched) `HANDOFF.md` | - | Append T6 deliverable entry on close |

Conventions follow ARBITER.spec.md: pure Rail, library-plus-runner split, exit 0 + last-line `PASS` for `tools/test/rail_test.rail` compatibility.

Crib structure from `impl/arbiter.rail` (the closest prior art): JSONL read loop, per-record classification function, accumulator-style report at end.

---

## Open questions flagged for user resolution

- **Q-C1 [E-trigger regex vs explicit feature]** - v0 uses a regex on `question.text` to gate E in. This works but is fragile. Alternative: add `features.runtime_observable: bool` to the SCHEMA and require the caller to set it. The regex is faster to ship; the explicit feature is more honest. **Recommend regex for v0, explicit feature for v1.** Surface for confirmation before implementation.
- **Q-C2 [A drop on documented-fact framing]** - The "drop A on `(definition|standard|spec|documented|by definition|formally)`" rule reduces A's lost-alone drag but also removes A's ability to catch counterexamples to documented invariants (F-004 fib was a documented-math problem A uniquely caught). The current text doesn't match F-004's wording, but the curator should sanity-check the synthetic_triage set covers this corner before locking.
- **Q-C3 [ledger_tail input declared but unused in v0]** - Should we still read it (to lock the I/O shape) and just ignore it? Or omit the read entirely until v1 needs it? **Recommend: omit until needed**, but flag as a SCHEMA contract that the Convener interface MAY read recent context in future versions.
- **Q-C4 [Scaling-thesis interaction]** - The rule was derived from a 40-problem set known to be curator-biased toward D's strength. If production data widens E and A's niches as predicted, the gating regexes will start under-selecting them. Decision: how often do we re-derive the rule against fresh production data? Suggest quarterly until the learned-Convener decision (Q2 in HANDOFF).

---

## After v0 passes

- **v1:** ledger-tail-aware Convener. Read last K outcomes by category; discount panels that lost-alone on that category in recent history.
- **v2:** halting added. Convener becomes responsible for both entry-routing and per-round continue/stop calls; the arbiter only handles synthesis.
- **v3:** evaluate learned-classifier promotion vs continued deterministic. Promotion requires the deterministic rule to be misrouting >15% of production deliberations, AND a labeled dataset of >=500 questions with productive/wasteful routing pairs.
- **v4:** triggered-specialist mode (R-A from the HANDOFF roadmap). D runs always; E and A become triggered specialists rather than peer panelists.

The deterministic rule never goes away. Even after a learned Convener ships, v0 stays as the structural floor that any model-based router must beat on the same `sets/synthetic_triage.jsonl` gate.
