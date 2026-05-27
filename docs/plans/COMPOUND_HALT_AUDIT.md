# COMPOUND HALT AUDIT — Plan

**Status:** proposal.
**Date:** 2026-05-27
**Owner:** Ledatic (compound lane, halted)
**Tracked task:** #8

## 1. Why

`compound` (the self-optimizing-compiler swarm) was halted 2026-04-22
at commit `b916f67`. The stated reason: "no 5%+ wins after tight
calibration." Task #8 asks whether that conclusion was a properly
falsified lab-style claim (kill_target declared BEFORE the data),
or post-hoc rationalization.

A 60-second probe says: **properly falsified.** But the audit walker
verifies this rigorously so the finding is itself attested.

Evidence already in the git history:

- Commit `833e043` (calibration #2) tightened
  `ACCEPT_SPEEDUP=1.00 → 1.05` (5% kill_target).
- Halt commit `b916f67` is the *next* commit after `833e043` — so
  every run between those two commits is under the tight
  calibration.
- Halt commit's prose: "5 records produced 5 defers and 0 accepts —
  confirming the prior 9 'accepts' were noise-flips."
- Total records in `store/2026-W17.jsonl`: 34, matching the halt
  commit's accounting.

So: the threshold (kill_target) was committed BEFORE the data
accumulated; the data showed zero accepts at the threshold; the halt
followed the data. That's the lab pattern, retro-fitted.

The audit's job is to make this provenance explicit and re-runnable
by any third party.

## 2. What the audit asserts

| Class | PASS iff |
|---|---|
| **threshold_committed_before_halt** | the commit that set ACCEPT_SPEEDUP=1.05 predates b916f67 |
| **threshold_value_was_5pct** | `git show <cal2>:verifier.sh` contains `ACCEPT_SPEEDUP=1.05` |
| **record_count_matches** | the halt commit's claimed 34 records match `wc -l store/2026-W17.jsonl` |
| **zero_accepts_under_tight** | among records whose verifier ran with ACCEPT_SPEEDUP=1.05, accept count == 0 |

The fourth class is the load-bearing one. The first three are
provenance; the fourth is the actual data check.

## 3. Limitation

The walker can verify the *halt was data-driven against a
pre-declared threshold*. It cannot verify that the 5% threshold
itself was the right threshold — that's a meta-question (was 5%
chosen because it was the genuine noise floor, or chosen because
it was high enough to halt?). Memory says the threshold was set
empirically after seeing noise band of 1.0008–1.0136x on the prior
9 "accepts" — i.e., calibration #2 was a response to bad data, not
arbitrary. But the walker won't relitigate that judgment.

## 4. Walker design

`tools/audit/compound_halt_audit.sh`:

```
1. Find halt commit in ~/projects/compound (default: b916f67)
2. Parse halt commit message for: claimed record count, threshold,
   calibration #2 commit reference
3. Verify ACCEPT_SPEEDUP value in the calibration commit's verifier.sh
4. Verify calibration commit predates halt commit
5. Read store/<week>.jsonl, count verdicts
6. Cross-check against halt commit's accounting
7. Emit per-class verdict
```

## 5. Expected first-run result

All four classes PASS. The compound halt is rigorous.

If somehow a class FAILS, that's a discovery (e.g., the record
count doesn't match — would indicate a record drop or post-halt
edit).

## 6. Phased rollout

**Phase 1 — Walker v0** (this session). One-shot audit; if compound
resumes, re-run after each calibration change to keep the provenance
chain intact.

**Phase 2 — Per-record verdict provenance** (deferred until
compound resumes): for each record, the verdict should reference
which calibration commit it ran under. Currently inferred from
record timestamp vs commit time; explicit is better.

## 7. Open decisions

1. **Hardcode the halt commit or accept as arg?** Recommend arg
   with default. Lets the audit re-run with a different halt point
   if compound resumes + halts again.

2. **Store-file path discovery — single week or any week?** Halt
   message specifies `store/2026-W17.jsonl`. Walker should accept
   any matching pattern; if multiple, walk them all.

3. **Output to chain?** Defer to Studio HTTP endpoint (Lakes plan
   §4). For now: stdout only.

## 8. Out of scope

- The threshold-choice meta-question (was 5% the right number?)
- Re-running the proposer with a new threshold to see if it would
  accept this time (that's a resume operation, not an audit)
- Auditing the bench scripts themselves (each bench script is its
  own claim; defer until compound resumes)
- The Phase 1 / Phase 2 split in CLAUDE.md's `compound Phase 0
  PINNED` memory entry — that's a separate roadmap question
