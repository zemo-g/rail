# DNRA — Deliberation-Native Reasoning Architecture
## Handoff Document

**Status:** T1 + T2 + T3 closed (v0 of each). T4 (falsification set) in progress. T5 (ledger polish) parked.
**Last updated:** 2026-05-22 16:18 UTC
**Lead:** Reilly (vision) + Claude Code (execution)
**Visibility:** Internal-only, no public surface yet

---

## What this is

A Rail-native cognitive architecture where the unit of cognition is a **deliberating panel**, not a single model. Uncertainty is structural (panel disagreement geometry), not a scalar appended to an answer. Synthesis of every prior cognitive project (Cortex, Oversight, Flywheel, Dream) plus the deliberation primitive Dream Fleet deliberately didn't build.

Thesis: **the structure of how the system reasons IS the uncertainty signal.** Multiple reasoners hold orthogonal perspectives, deliberate against shared context, surface either consensus or legible disagreement. Magic with receipts.

---

## Locked decisions (2026-05-22)

### Architecture
- Three layers: **Panelists** (epistemically distinct reasoners), **Convener** (triage + routing + halting), **Arbiter** (synthesis via debate-as-code on Rail substrate)
- ~~Four panelist modes~~ **Three panelist modes (revised 2026-05-22 16:40 after T4 v0.a finding): Deductive · Empirical · Adversarial.** First Principles dropped — honest curation showed FP converges with Deductive on most code/system problems; the two are epistemic siblings, not orthogonals.
- Hardware: panelists colocated on Mini, Convener/Arbiter deterministic Rail. Studio is in-use for spurarm; do not plan around its availability.
- Public surface: none yet (Dream Fleet halt-state model)

### Models
- **Primary base:** Llama 3.2 (Meta), American open-weight, fine-tunable
- **Prototype size:** 1B for first finetune (Mini-based LoRA, hours per panelist, cheapest mode-separation falsification)
- **Production size:** 3B (Mini-based LoRA, 1–2 days per panelist) — graduate here if 1B proves modes can be instantiated
- **Cross-family fallback:** Llama + Gemma + Phi-3 mixed panel, if shared-base mode-collapses
- **Convener:** deterministic Rail v0, no model (promote to Llama 3.2 1B only if heuristics fail)
- **Arbiter:** Rail + capability sandbox does the structural work; tiny synthesis model only if needed

### Oversight relationship
- **Schema reuse only.** Take the *patterns* (intervention ledger, LCM context engine, override-writer-as-runtime-JSON-authority). Throw away the *content* (oversight.db trading thoughts, 19-param trading override surface, P&L-as-only-outcome, regime detection).
- New ledger. Old `oversight.db` untouched on the RAM disk.

### Outcome signals (replacing P&L as the single signal)
- Rail-code questions → compiler oracle, binary pass/fail (Flywheel's reusable asset)
- Reasoning questions → held-out falsification set ground truth
- Open-ended → deferred until labeling story is real

### Storage — pivot 2026-05-22
- **SQLite → JSONL hash-chain.** Rail's `stdlib/sqlite.rail` is a bare-bones FFI stub (no prepared statements, no result iteration, zero tools in the codebase use it). `/lab` chain (`~/.rail/lab/chain/log.jsonl`) already proves Ed25519-signed hash-chained JSONL in Rail. Source of truth = chain. Future SQLite/analytics index becomes a derived projection (deferred).
- Source: `~/projects/rail/tools/dnra/`
- Runtime: `~/.ledatic/dnra/{chain,traces,index}/`

### Privacy
- Build internal-only. Hash-chain + beacon-anchor traces for our own audit. No `/deliberate` page until productive disagreement is verified.

---

## Tickets

(See `TaskList`; summary order, dependency-cheapest first.)

1. **T1 — ledger chain schema spec** (IN PROGRESS) — record shape, hash rules, signature scheme, two-chain design (deliberations + outcomes)
2. **T2 — ledger.rail impl** — Rail module for append/verify/iter; mirrors `~/projects/rail/tools/lab/`
3. **T3 — arbiter scaffold** — debate-as-code execution loop + 20 synthetic disagreement examples (10 productive, 10 noise)
4. **T4 — falsification set** — 50 mode-distinguishing problems (25 Rail-code compiler-oracle scored + 25 reasoning hand-graded)

**Gate after T3 + T4:** if both pass, commit to LoRA finetuning 4× Llama 3.2 1B → distinct panelist modes. If either fails, redesign before spending GPU.

---

## Resume protocol (for any future session)

1. **Read this file first.** Then `TaskList` to see current ticket states.
2. **Check fleet state.** Studio is in-use for spurarm; do not assume it's free.
3. **Re-read locked decisions above** before changing architecture. Push back if a change is needed; do not silently revise.
4. **Layout:**
   - Source: `~/projects/rail/tools/dnra/{spec,impl,sets}/`
   - Runtime: `~/.ledatic/dnra/{chain,traces,index}/`
   - Schema spec: `spec/SCHEMA.md`
5. **Update this file** as state changes — every meaningful commit should also touch HANDOFF.md so the resume document never drifts from reality.

---

## Open questions flagged (user to resolve at any time)

- **Q1 [SQLite → JSONL pivot]** — Above. Made the call based on Rail-stdlib reality; flagging for visibility. Override if SQLite-as-source-of-truth is the preference.
- **Q2 [Convener model v1]** — Whether to attempt a learned-model Convener after deterministic v0 hits limits, or stay deterministic indefinitely.
- **Q3 [Cross-family panel composition]** — Shared-base finetuning is the first try; if modes collapse, do we try Llama+Gemma+Phi-3 mixed panel? Or smaller shared base?
- **Q4 [Outcome resolution UX]** — Where do outcome labels come from for non-compiler-oracle problems? Self-labeling? User-labeling? Defer entirely?

---

## Files touched this session

- Created dirs: `~/projects/rail/tools/dnra/{spec,impl,sets}/`
- Created dirs: `~/.ledatic/dnra/{chain,traces,index}/`
- Created: `~/projects/rail/tools/dnra/HANDOFF.md` (this file)
- Created: `~/projects/rail/tools/dnra/spec/SCHEMA.md` (T1 deliverable)

---

## Research artifacts referenced

- Oversight causal cocoon schema: `~/empire/oversight/causal/ledger.py` (three-table: intervention_log → metric_snapshot → edge_draft)
- Oversight DB tables overview: 23 tables across 9 domains
- Rail sqlite stdlib: `~/projects/rail/stdlib/sqlite.rail` (minimal stub, zero adopters)
- `/lab` chain (closest prior art): `~/.rail/lab/chain/log.jsonl` — Ed25519-signed, parent-chain integrity verified on read
- Dream chain (beacon anchoring): `~/.ledatic/dream/*/chain.jsonl`
- Three-layer Oversight pattern (event log → snapshot → computed correlation) — reused as: deliberation entries → outcome entries → analytics projection

---

## Append-only changelog

- **2026-05-22 15:35 UTC** — Initial scaffold. Decisions locked. T1 started. Storage pivoted from SQLite to JSONL hash-chain after research surfaced Rail sqlite stdlib limitations.
- **2026-05-22 15:38 UTC** — T1 (schema spec) completed → `spec/SCHEMA.md`. T2 (ledger.rail impl) started.
- **2026-05-22 15:40 UTC** — Confirmed lab chain prior art exists on Studio at `~/projects/rail/tools/lab/` (chain.rail 960 lines, entry.rail 953 lines). Mini-local mirrors: `tools/attest/` (Rail+Ed25519), `~/.ledatic/dream/` (hash-chain pattern). Wrote `spec/LEDGER.spec.md` — phased v0.1→v0.4 plan (encoder+hash → sign → verify → accessors). Dispatched deep-read agent on Studio lab files (background) to extract canonical-JSON encoder + chain I/O patterns for cribbing.
- **Critical gotcha logged from rail CLAUDE.md**: stdlib/json.rail has a lambda-destructure parse error when imported alongside other deps — lab carries its own scoped encoder. DNRA ledger.rail will too.
- **2026-05-22 15:50 UTC** — Agent returned with full lab pattern map. **Key finding**: lab's `entry.rail` is lab-domain-specific (goal/hypothesis/kill_target/counters/cmd/result fields) and its `chain.rail` index maps are coupled to those fields. Cannot import-as-is. Wrote v0.1 `impl/ledger.rail` (~180 lines, single file) — small, dedicated, copies the patterns (canonical-via-file sha256, parent integrity, envelope-line format) but with DNRA envelope. v0.1 limitations explicit in file header: no signing, no lock, no full verify. Next: compile + smoke-test.
- **2026-05-22 15:55 UTC** — Smoke test PASSED on first compile. Two distinct ids, parent linkage verified on-disk via Python JSON parse. Refactored: ledger.rail → pure library (no main); smoke runner moved to `ledger_demo.rail`; isolated test runner at `test_ledger.rail` (uses /tmp/, doesn't pollute runtime chain).
- **2026-05-22 15:58 UTC** — `test_ledger.rail` running clean: **4/4 PASS** (T1 genesis empty parents · T2 linear chain parents[0] == prior id · T3 hash determinism · T4 tamper detection via sed-mutate). v0.1 unblocks T3 (arbiter scaffold) — arbiter can write hand-crafted disagreement examples to chain immediately.

**v0.1 ledger shipped — file map:**
| File | Role | Lines |
|---|---|---|
| `impl/ledger.rail` | Library: types + canonical hash + JSONL append + head + minimal verify_head | ~170 |
| `impl/ledger_demo.rail` | Smoke runner (appends to runtime chain) | ~25 |
| `impl/test_ledger.rail` | 4 acceptance tests under /tmp/ | ~110 |
| `spec/SCHEMA.md` | Record shape | (T1) |
| `spec/LEDGER.spec.md` | API contract + phased plan | (T2) |

**T2 ticket state**: in_progress. v0.1 = MVP for T3 unblock. Outstanding before strict T2 completion:
- v0.2: add Ed25519 local signing (auto-generate signer keypair, sign id post-hash)
- v0.3: full `verify_chain` (walk every entry, re-hash, verify signatures)
- v0.4: mkdir LOCK.d advisory locking; atomic append with pre-size check
- (Optional) v0.5: cached verified-up-to-N marker for fast open

**Decision point flagged for user:**
- Path A — finish T2 strictly (v0.2 + v0.3 next) before moving to T3
- Path B — call v0.1 enough for T3, move forward, come back to v0.2/0.3 once falsification gate passes

- **2026-05-22 16:02 UTC** — User chose Path B ("trust ya gut"). T2 marked complete (v0.1 ships); polish (v0.2 sign + v0.3 verify + v0.4 lock) split to new ticket T5, lower priority, gated on falsification result. T3 started.
- **2026-05-22 16:02 UTC** — Wrote `spec/ARBITER.spec.md`. Arbiter v0 = deterministic structural rule: panel positions sorted into `productive | noise` based on (a) ≥2 panelists carry rail_claims, AND (b) those claims yield ≥2 distinct outputs. v0 trusts curator-recorded `rail_claim_output` (no eval yet). Acceptance gate: 16/20 (80%) on hand-curated set, ≥8/10 each class. Next: curate the 20 examples + write `impl/arbiter.rail`.
- **2026-05-22 16:10 UTC** — Curated `sets/synthetic_disagreements.jsonl`: 10 productive + 10 noise (5 prose-only + 5 claims-agree), Python sanity check 20/20 against rule logic. P04 simplified (escaped quotes removed from outputs to keep Rail extractor escape-unaware in v0).
- **2026-05-22 16:18 UTC** — Wrote `impl/arbiter.rail` (159 lines). Compiles + runs: **20/20 PASS** on the curated set. Honest caveat in HANDOFF: 100% is expected ceiling when rule matches curation design. v0 proves *Rail impl correctness*, not *classifier generalization*. v1 will re-execute rail_claim via Rail eval (validates curator honesty); v2 adds structural features; v3 replaces deterministic rule with learned classifier; v4 feeds real (post-finetune) panelist output.

**T3 closed — file map:**
| File | Lines | Purpose |
|---|---|---|
| `spec/ARBITER.spec.md` | 90 | Contract: classification rule + acceptance gate |
| `impl/arbiter.rail` | 159 | Rail impl: read JSONL → classify → report |
| `sets/synthetic_disagreements.jsonl` | 20 | Hand-curated examples (P01–P10 productive, N01–N10 noise) |

**Total DNRA Rail shipped to date:** ~500 lines across 3 modules + 2 specs + 1 dataset.

**Next: T4 — falsification set.** 50 mode-distinguishing problems: 25 Rail-code (compiler-oracle scored) + 25 reasoning (hand-graded). For each: which mode SHOULD get it right, which SHOULD get it wrong, and *why* — the why is the load-bearing part. If we can write this set with intellectual honesty, the four modes are real categories. If we can't, they're not orthogonal and the architecture has a deeper problem.

- **2026-05-22 16:25 UTC** — Wrote `spec/FALSIFICATION.spec.md`. Locks the gate: **each mode must be uniquely-right on ≥5 problems** out of 50. If any mode never wins alone, that mode is redundant and the panel composition is wrong. Phased curation plan (v0.a 10 spike → v0.b 15 Rail-code → v0.c 15 reasoning → v0.d 10 fill). Mode-embodiment reference embedded in the spec so curator can check rationale honesty.

---

## Session-end snapshot — 2026-05-22 16:25 UTC

**Closed this session:** T1 (schema), T2 (v0.1 ledger, 4/4 tests), T3 (v0 arbiter, 20/20 on synthetic set).
**In progress:** T4 (falsification set) — spec locked, curation pending. Multi-session intellectual lift.
**Parked:** T5 (ledger polish v0.2/0.3/0.4) — gated on T4 result.

**Repository state:**
- Source: `~/projects/rail/tools/dnra/` — 3 specs + 3 Rail modules + 1 dataset
- Runtime: `~/.ledatic/dnra/{chain,traces,index}/` (chain has 2 smoke-test entries, can be reset)
- Total Rail shipped: ~500 lines across ledger.rail (177) + arbiter.rail (159) + test_ledger.rail (113) + ledger_demo.rail (31) + (forthcoming: falsification_score.rail, T4)

**Resume next session:** read this HANDOFF.md first; then `TaskList`; then begin T4 v0.a curation (10 problems). Curation is ~15–30 min per problem of careful, honest design work — plan for 3–5 hours over multiple sessions.

- **2026-05-22 16:35 UTC** — T4 v0.a curated: 10 problems in `sets/falsification_v0a.jsonl`. Honest per-mode predictions + rationale. Python scorer reports:
    - Mode total-right (out of 10): **D=8, E=7, FP=4, A=6**
    - Mode unique-right: **D=0, E=1, FP=0, A=1**
    - FP scored lowest; on review, my curation made FP "defer to cross-language convention," which is the wrong epistemic primitive (real FP strips back to *this system's* foundations).

**Finding — flag for review before any further curation:**

When FP is honestly curated as "rebuild from this system's foundations" (not "apply cross-language convention"), FP and D appear to converge on the same answer in most code/system problems. They diverge only when the spec itself is questionable — which is rare.

**Hypothesis: First Principles and Deductive may be epistemic siblings, not orthogonal modes.** Both anchor on authoritative source (D = spec as written, FP = spec re-derived from foundations). The four-mode panel composition may be wrong.

**Three possible directions (user choice):**
- **R1: Re-curate FP** as proper foundation-rebuilding and re-score. Maybe the 10 problems just don't exercise FP's strength; v0.b could include "questionable-spec" or "convention-is-wrong" problems where FP wins alone.
- **R2: Replace FP** with a more orthogonal fourth mode — candidates: Analogical (similarity-based), Probabilistic (prior-weighted), Pragmatic (user-needs-driven).
- **R3: Drop to three modes** (D, E, A) — accept that four orthogonal epistemic modes is overspecified, and run a 3-panelist deliberation architecture.

This is the cheap falsification working as designed — finding it at 10 hand-curated problems is much better than finding it after finetuning 4 models.

- **2026-05-22 16:42 UTC** — User chose **R3 (drop to 3 modes: D, E, A)**. Cleanup pass:
    - `sets/synthetic_disagreements.jsonl` — stripped `first_principles` panelist from all 20 records via Python script
    - `sets/falsification_v0a.jsonl` — stripped `first_principles` from `mode_predictions` in all 10 records
    - `spec/SCHEMA.md` — updated example panel + mode_attribution to 3 modes (rebalanced weights: D=0.45 / E=0.35 / A=0.20)
    - `spec/ARBITER.spec.md` — removed FP from panel example
    - `spec/FALSIFICATION.spec.md` — removed FP gate line; updated total-uniqueness threshold ≥20 → ≥15; removed FP mode-embodiment block; cleaned curator-discipline language
    - HANDOFF locked-decisions list updated; FP marked as dropped
- **Verification under 3-mode panel:**
    - Arbiter: **20/20 PASS** (rule is structural — cardinality-independent)
    - Falsification re-score: **D=8/10, E=7/10, A=6/10** (unchanged from 4-mode totals); unique-right: **D=0, E=1, A=1**

**Deeper finding (do NOT pivot yet, but note):** D and E are still heavily coupled. After 10 problems, D has 0 unique-right wins. In well-designed systems, spec matches behavior, so D's spec-reading and E's behavior-observation converge by construction. D-E divergence happens at: spec≠behavior gaps (UB, version skew), unprovable universals (where E can't test), implementation-defined corners.

**Next-step prescription for T4:** v0.b (15 Rail-code) should be designed *specifically* to exercise D-unique-strength: problems where the spec is the ONLY source of truth (E can't test what doesn't have a runtime sample, A doesn't find a flaw because there isn't one — there's just a documented invariant). If after v0.a + v0.b (25 problems) D still has 0 unique-right, that's strong evidence to drop D too and run E + A panel only. Don't decide on 10; do decide on 25.

**Session stopping point — 2026-05-22 16:45 UTC.** Honest summary: substrate works (ledger 4/4 tests; arbiter 20/20). Architecture under active falsification (4 modes → 3 modes done; 3 → 2 questioned but deferred to v0.b evidence). Next session: design + score v0.b targeting D's spec-literacy niche.

- **2026-05-22 16:55 UTC** — T4 v0.b shipped + scored. 15 Rail-code problems written to `sets/falsification_v0b.jsonl` targeting D's spec-literacy niche (filter lambda segfault, auto-memo arity restriction, 63-bit PRNG overflow, length-vs-equals perf trap, 5+ nested match parse error, multi-import json bug, 3-movk version skew, stale-dylib misleading link error, Pi-self-host OOM) plus 6 honest ties (bootstrap cycle, WASM gaps, runtime safety, type-checker warnings, show-on-closure, cross-fn float-return). Python scorer (`impl/score_falsification.py`) sweeps all sets.

**Re-score across v0a+v0b (25 problems):**

| Mode | right | unique-right | lost-alone | Gate ≥5 |
|---|---|---|---|---|
| Deductive | 23 | **9** | 0 | **PASS** |
| Empirical | 13 | 1 | 2 | FAIL |
| Adversarial | 7 | 1 | 8 | FAIL |

D moved from 0 → 9 unique-right after v0.b. 25/25 curator-predicted winners matched the scorer's actual classification (no [MISS] flags) — internal consistency check passed.

**Finding (surface to user before next move):**
- D's spec-literacy niche is REAL and detectable by construction. The architecture's "D" mode is not redundant with E or A on documented-invariant problems.
- E and A are *currently* below the ≥5 unique-right floor (1 each), but v0.b was deliberately D-targeted. E-niche and A-niche batches are not yet curated. Honest reading: E and A under-tested, not falsified.
- D is never wrong alone (lost_alone=0 on D); A loses alone 8× (anti-convention questions); E loses alone 2×. D is the most reliable mode on this 25-problem mix — but the mix is curator-biased toward D's strength.

**Honest caveat on D=9:** the curator wrote both the problem AND the predicted mode behavior. Even with discipline, this is a synthetic ceiling. The harder claim — "finetuned panelist models will *actually* respond like E and A's curator-modeled predictions" — is not tested. That's T4 v1+ (post-finetune replay against the same set).

**Next-step prescription (user decides):**
- **R-A: Continue T4 v0.c (15 reasoning + 10 fill) targeting E and A niches.** Goal: get each mode to ≥5 unique-right with the same curator discipline. Then commit to finetune gate.
- **R-B: Drop E or A now.** If you think E and A's <5 unique-right at 25 problems is already evidence of redundancy with D, drop one and run a 2-mode panel. Aggressive but consistent with the v0.a logic that dropped FP.
- **R-C: Pause T4, switch to T5 (ledger polish v0.2/0.3/0.4)** while sleeping on whether to push for niche-coverage curation or move to finetune.

**File map — T4 v0.b deliverable:**
| File | Purpose | Lines |
|---|---|---|
| `sets/falsification_v0b.jsonl` | 15 Rail-code spec-literacy problems | 15 records |
| `impl/score_falsification.py` | Re-runnable scorer (Python) | 95 |
| `/tmp/dnra_v0b_score.txt` | Last-run scorer output (artifact) | 44 |

- **2026-05-22 17:15 UTC** — T4 v0.c shipped + scored. 15 reasoning problems written to `sets/falsification_v0c.jsonl` targeting E + A niches: Python TCO, hash(-1), time.sleep precision, bool('False'), dict.copy shallow, max with NaN, sqrt fp rounding, TLS 1.3 RSA-KEX removal, BSD sed -i, SQL NULL=NULL, Python 3 list comp scope, naive Fib complexity, HTTP/2 vs TCP HOL, Python bigint, GIL/threading. Scored across full v0a+b+c (40 problems).

**Re-score across v0a+v0b+v0c (40 problems):**

| Mode | right | unique-right | lost-alone | Gate ≥5 |
|---|---|---|---|---|
| Deductive | 36 | **9** | 0 | **PASS** |
| Empirical | 26 | 2 | 3 | FAIL |
| Adversarial | 15 | 2 | 14 | FAIL |

40/40 curator-predicted winners matched scorer (zero [MISS] flags across the entire set). Internal consistency check passes — predictions reflect a coherent model of mode behavior.

**Finding — architecture-relevant:**

After honest curation of 40 problems spanning Rail-specific spec literacy + general reasoning:
- **D is the workhorse.** On both Rail-code and reasoning problems, D's documented-invariant reading is the most reliable predictor of oracle truth. 36/40 right, never wrong alone.
- **A is a noise generator MOST of the time, but catches real counterexamples occasionally.** 2 unique wins (F-004 fib int-overflow, F-032 sqrt fp rounding) vs 14 lost-alone instances. A's "where does this break" prior reliably hits well-documented edge cases (overflow, fp precision) but is wrong on conventions A wants to violate.
- **E is the rarest contributor — wins only when spec is silent.** 2 unique wins (F-002 Python dict order spec-vs-impl, F-026 empty-tuple interning); 3 lost-alone (happy-path observation misses pessimistic edges).

**Hypothesis emerging (do NOT pivot without user input):** the 3-mode peer-panelist architecture may be overspecified. A more honest model might be:
- **D as primary panelist** (handles ~90% of well-documented questions)
- **A as conditional "edge-case finder"** (triggered when the question category suggests overflow/fp/scale matters; not a peer voice on every question)
- **E as conditional "empirical verifier"** (triggered when the question has a cheap runtime test and D's answer is uncertain; not a peer voice on documented questions)

This is "peer panelist → triggered specialist" — closer to Convener-routing-to-specialists than equal-vote panel. Significantly cheaper to operate (D runs always; A/E only when their niche signals fire).

**Honest caveat on the curation bias:** I wrote both the problems AND the predicted mode behaviors. v0.b was deliberately D-targeted; v0.c targeted E+A but the problem inventory still drew from areas where D reads cleanly. A different curator with a different question-bank (e.g., heavy on novel-language behaviors, unobserved-corner cases, adversarial counterexamples) might surface more E/A unique wins. The finding above is preliminary architecture data, not a final ruling.

**Three possible next moves (user decides):**
- **R-A: Accept 3-mode falsified, redesign as triggered-specialist.** Drop equal-panel architecture. Convener routes to D always + A/E conditionally. Update spec/SCHEMA.md, arbiter, falsification gate to match. Cheaper to operate, less symmetric. Most aligned with the data.
- **R-B: Continue T4 v0.d (10 fill).** Spend another 2-3 hours targeting E+A niches more aggressively (impl-defined behavior catalogs, adversarial-input scenarios). Maybe E and A can reach 5 unique-right with better curation. If still <5 after 50 problems, fall back to R-A.
- **R-C: Commit to 3-mode and accept the asymmetry.** Architecture stays 3-peer; understanding D contributes more in 90% of cases is fine — the 10% where A or E catches what D misses is the panel's value. Update arbiter to weight by historical mode-accuracy on the category. Move to T5/finetune.

**Mode lost-alone is itself a signal:** if a mode is wrong while peers agree, that mode contributes *negative information* (it's anti-correlated with truth on that problem). A's 14 lost-alone cases mean A's vote should LOWER confidence in A's claim, not raise it, on convention-aligned problems. This is structural — could be cooked into the arbiter rule as "if mode X has a high lost-alone rate on category C, treat X's dissent as weak evidence."

**File map — T4 v0.c deliverable:**
| File | Purpose | Lines |
|---|---|---|
| `sets/falsification_v0c.jsonl` | 15 reasoning problems for E+A niches | 15 records |
| `/tmp/dnra_v0c_score.txt` | Last-run scorer output (40 problems) | — |

- **2026-05-22 17:25 UTC** — User chose **R-C** with the scaling thesis: "this is just for proof of concept not final, so as we scale the potential for success widens." 3-mode architecture stays for POC. Reasoning behind the call:
    - The ≥5-unique-right gate was designed for production scale. At 40 problems curated by one curator, it is too strict and conflates curator bias with mode redundancy.
    - As the corpus grows (more curators, more impl-defined cases, more adversarial-input scenarios, more domains where the spec is silent), E and A's niche-share is expected to widen. The 2/40 unique-right at POC is a *floor*, not a ceiling.
    - Dropping a mode at POC stage would lock the architecture into D-only assumptions before the empirical case is mature.

**Locked POC architecture (R-C):**
- 3 panelists (Deductive · Empirical · Adversarial) — equal-peer, no triggered-specialist routing yet
- Arbiter v0 stays as the structural rule (productive vs noise on disagreement geometry)
- Mode lost-alone rate is recorded but does NOT yet feed into arbiter weighting (deferred to arbiter v1)
- Falsification gate: ≥5 unique-right per mode REMAINS the production-scale target. At POC scale, treat current numbers as a baseline to widen with more curation/diverse problems, not as a pass/fail.

**Deferred to arbiter v1 (post-finetune):**
- Per-mode lost-alone-rate confidence discount (mode that's wrong-alone often → lower weight on that mode's dissent in same category)
- Per-category mode weighting (D heavier on spec-literacy, A heavier on edge-case-rich, E heavier on impl-defined)
- Possible triggered-specialist mode if R-A becomes warranted by production-scale data

**Next session pickup:**
- T4 closed as "POC-passes-as-baseline." v0.d (10 fill) can be done opportunistically but not gating.
- T5 (ledger polish v0.2/0.3/0.4) becomes the next active ticket.
- Finetune gate (4× → 3× Llama 3.2 1B LoRA, one per mode) is still on the table — needs T5 v0.2 (signing) at minimum so panelist outputs are attested per-mode before being chain-appended.

**Session stopping point — 2026-05-22 17:25 UTC.** v0a+b+c shipped (40 problems, scorer Python). Architecture decision R-C locked with scaling thesis. T4 closed as POC-baseline. Resume on T5 ledger polish.

- **2026-05-22 17:55 UTC** — **T5 shipped in one pass: v0.2 (signing) + v0.3 (verify_chain) + v0.4 (advisory lock).** Tests jumped 4/4 → **7/7**.

**T5 deliverables:**

| Version | What landed | Test |
|---|---|---|
| v0.2 | Ed25519 signing per entry via stdlib/ed25519_sign.rail. Signer fingerprint = first 8 bytes of sha256(pubkey) → 16-hex. Pre-hash material now `{"body":...,"parents":...,"signer":"<fp>"}` (alphabetical key order). Sig over the 64-char id string. Auto-generates 32-byte seed at `~/.ledatic/dnra/signing_key` (chmod 600) via `head -c 32 /dev/urandom`. | T5 sig tamper |
| v0.3 | `ledger_verify_chain log_path key_path` walks every entry: re-hashes body+parents+signer, verifies sig over id, checks parents[0] linkage. Returns 1 if every entry passes, 0 on first failure. | T6 multi-entry chain + mid-chain tamper |
| v0.4 | `acquire_lock`/`release_lock` via POSIX `mkdir <log>.lock.d` (atomic test-and-set). `ledger_append` holds the lock for the entire compute+write critical section, returns "" if lock can't be acquired within 1s (20 × 50ms). | T7 blocked-then-released append |

**Tests (all PASS):**
- T1 genesis · T2 linear chain · T3 hash determinism · T4 body tamper · T5 sig tamper · T6 chain walk + mid-chain tamper · T7 lock blocks then releases

**Gotchas earned this session (worth memory):**
1. **stdlib/sha256.rail transitively imports stdlib/bytes.rail.** Importing both directly produces duplicate-symbol link errors for `_string_to_bytes` etc. Use `hmac.rail` to get `sha256_bytes` (it imports sha256 which imports bytes — clean chain).
2. **`sha256_bytes` lives in `stdlib/hmac.rail`, NOT in `stdlib/sha256.rail`** — convention is "raw byte-array hashing" is hmac-namespaced even when not doing HMAC.
3. **`ed25519.rail` depends on `x25519.rail`** — neither has explicit imports; both must be explicitly imported by the caller.
4. **macOS `wc -l` pads its count with leading spaces.** `parse_int_local` stops at the space and returns 0, making `if n == 0 then 1` (vacuous "empty chain verifies") return 1 on a non-empty chain — silent false negative. Workaround: use `awk 'END{print NR}'` instead of `wc -l`.
5. **Runtime chain in `~/.ledatic/dnra/chain/` had v0.1 entries with empty sig/signer.** v0.2+ verify rejects them. Reset the runtime chain on each schema bump until v0.5+ adds versioned envelope support.

**File map — T5 deliverable:**
| File | Purpose | Lines |
|---|---|---|
| `impl/ledger.rail` | v0.2/0.3/0.4 — library (signing, chain walk, lock) | ~225 |
| `impl/test_ledger.rail` | T1-T7 acceptance | ~165 |
| `impl/ledger_demo.rail` | Smoke runner against runtime chain | ~32 |

**Architecture status post-T5:**
- DNRA substrate (ledger + arbiter + falsification set) is now production-shaped for POC. The chain is cryptographically attested per-entry; chain walks detect any byte-level tamper; concurrent writers can't corrupt.
- Finetune gate is now unblocked. Per-mode panelist outputs will land as signed deliberation entries; arbiter reads them; outcomes get scored and chained.
- Remaining open: arbiter v1 (lost-alone-rate confidence discount, ticket #4) — gated on first real finetune.

**Next session pickup:**
- Read this HANDOFF.md first, then `TaskList`.
- Active open: ticket #4 (arbiter v1, deferred until post-finetune data exists).
- Major next: the finetune gate itself. Read `~/projects/rail-training/CLAUDE.md` (if present) for the training pipeline state. 4× → 3× Llama 3.2 1B LoRA, one per mode (Deductive/Empirical/Adversarial). Mini-based, ~hours per panelist.
- Alternative milestone: add the **Convener** (T6 in the original roadmap — never opened as a ticket). Currently deterministic placeholder; would route question.category to fast vs deliberate paths and choose the panel composition.

**Session stopping point — 2026-05-22 17:55 UTC.** T5 shipped end-to-end (3 versions in one pass). 7/7 acceptance. Substrate production-shaped for POC; finetune gate unblocked. Resume on finetune or Convener.

- **2026-05-22 — multi-front design pass + T6 Convener v0 shipped.** Four sub-agents dispatched in parallel produced scoping specs for the next phase (committed in `ed8b161`):
    - `design/CONVENER.v0.spec.md` — deterministic 5-branch router (R0..R5) keyed on category + complexity_hint + cheap substring matching over question.text. Encodes T4 findings: D mandatory (lost_alone=0), A gated out on convention questions (14/40 lost_alone), E gated in on runtime / impl-defined markers.
    - `design/FINETUNE_DEDUCTIVE.md` (448 lines) — 1.5-3k pairs "cite then derive", LoRA r=16/a=32 attn-only, ~1500 steps, ~2-4h on Mini. **Hard pre-gate**: D-vs-base edit-distance >= 0.25 on a 30-prompt probe BEFORE training E and A. Below threshold, multi-panel plan is dead.
    - `design/FINETUNE_EMPIRICAL.md` (262 lines) — 3-5k pairs observation-leading, 35% spec-silent material to force off D's attractor.
    - `design/FINETUNE_ADVERSARIAL.md` (334 lines) — 2-4k pairs with structured `{where_break, mechanism, applies_to_prompt, prediction}`; 35-40% pairs marked "real break but doesn't apply" to teach LOCATING breaks, not disagreeing.

**User decisions locked this turn:**
- **Q-C1 resolved**: regex-on-text for v0 ships now; explicit `runtime_observable` SCHEMA field promoted to v1.
- Sequencing implication from D's pre-gate: the 3 LoRAs cannot be trained in parallel — D first, edit-distance probe, then E + A.

**T6 Convener v0 — IMPLEMENTED + PASSING.**

| File | Lines | Purpose |
|---|---|---|
| `impl/convener.rail` | 144 | Library: triage_for_line + decide_triage + helpers. No main. Pulls stdlib/file.rail transitively. |
| `impl/test_convener.rail` | 87 | Acceptance harness. Scales gates with set size (85% path, 80% panel). |
| `impl/gen_synthetic_triage.py` | 245 | Curation generator. Emits **compact** JSON (`separators=(",",":")`) so Rail marker-split extractors hit. |
| `sets/synthetic_triage.jsonl` | 10 | v0.a spike (R0 x2, R1 x2, R2 x2, R3 x3, R4 x1). Each record carries `intended` + `wasteful_counter` + rationale. |
| `spec/SCHEMA.md` | (touched) | `triage.reason` now documented as closed terminal-label set. |

**Acceptance: 10/10 path · 10/10 panel · 0 empty panels · 0 unknown reasons · 0 fast+multi cases.**

**Honest caveat (same shape as arbiter's 20/20):** I am both the rule author and the v0.a curator. 10/10 is the synthetic ceiling — it proves the Rail impl matches the spec, not that the rule generalizes. v0.b/v0.c curation (remaining 30 cases) is the real test, and should ideally be done by a different curator or against questions drawn from outside the curator's design awareness.

**Gotcha earned this session (not in Rail CLAUDE.md):**
6. **Python's default `json.dumps` inserts spaces** after `:` and `,`. Rail marker-split extractors looking for `"key":"value"` substrings then fail silently — every record routes to R5_fallback. Fix: `json.dumps(r, separators=(",",":"))`. Confirmed: the falsification + synthetic_disagreements sets either use compact form by accident or have less strict extractors; this is the first case where it mattered.
7. **Local function definitions via `let f x y = ...` inside `main`** are rejected by the Rail parser ("unexpected 'eq' '=' in expression"). Move helpers to top level.
8. **Transitive imports collide if you also import directly.** convener.rail imports stdlib/file.rail; test_convener.rail importing both produces duplicate-symbol link errors. Always rely on transitive imports from the closest library.

**T6 close — what shipped vs what remains:**

| Item | State | Note |
|---|---|---|
| `impl/convener.rail` | DONE | Library + closed-reason set + canonical panel order |
| `impl/test_convener.rail` | DONE | Self-scaling gates (production: 34/40 path, 32/40 panel; spike: 9/10 path, 8/10 panel) |
| `sets/synthetic_triage.jsonl` v0.a | DONE | 10/10 PASS |
| `sets/synthetic_triage.jsonl` v0.b/c | **DEFERRED** | 30 cases. Spec says ~10 min per honest case = ~5 hours. Multi-session curation work; should be done by a different curator or via blind-question harvesting if possible. |
| `spec/SCHEMA.md` triage.reason note | DONE | Closed terminal-label set documented |

**Next session pickup options (user choice):**
- **R-X1: Complete the synthetic_triage curation** (30 more cases per the spec distribution). Multi-session work. Surfacing curator-bias problems before the rule goes live.
- **R-X2: Stand up the D-vs-base probe before any finetune.** Per FINETUNE_DEDUCTIVE's pre-gate, this is the cheapest "is multi-panel plausible?" experiment. ~2 hours including writing the 30 probe prompts.
- **R-X3: Stand up the MLX-LoRA training pipeline scaffold in ~/projects/rail-training/.** Pipeline-first approach; corpus + training runs slot in once it exists.
- **R-X4: Open T7 (the arbiter v1 with lost-alone-rate confidence discount)**, deferred-but-pending per the original handoff.

**Session stopping point — 2026-05-22 (later).** Convener v0 implemented + passing on the spike. Multi-front design phase closed. 4 parallel agent deliverables landed. Next sub-session likely R-X2 (cheapest falsification of the finetune-gate viability).
