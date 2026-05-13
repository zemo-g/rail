# Deadline 2026-04-27 punch-list

**Written:** 2026-04-21 evening, Studio docs session.
**Deadline:** 2026-04-27 (6 calendar days, ~5 working days).
**Deliverables the deadline is scoped against:**
1. `bench_railnative` score ≥ 5/30 on a Rail-corpus-trained checkpoint.
2. One closed flywheel round (retrain on `harvest_clean_v2` → new bench row → delta).
3. `PHASE_4C_MODEL_CARD.md` publishable (architecture / precision / eval / bench populated).

Prior handoff estimate: "8-10 h sequential + ~4 h parallel = comfortable." This doc takes a more honest look at what's actually blocking each item and returns a tighter estimate.

## Legend

- **h (aggressive / realistic / pessimistic):** solo-Claude hour estimates. Aggressive = everything goes right. Realistic = one small snag. Pessimistic = re-run or partial rework.
- **Machine:** Studio / Mini / either / private-repo (requires rail-training sync).
- **Owner:** This session (DOCS) / Main session (the parent Claude holding the GPU) / Mini Claude / next session / flywheel runner.

---

## P0 — Flagship capacity result

### P0.1 — d=256 × 2-block × HalfTensor × 3000-step run

- **Status:** IN FLIGHT. Started Studio 2026-04-21 16:52 PT. PID 37840. Compile finished clean (one typecheck warning on `maybe_eval`, benign). Expected finish window ~18:30-19:00 PT.
- **Artifact missing:** Eval mean @ 3000, peak RSS, wall-time. These land in `/tmp/d256_3000.log` when the run finishes.
- **Blocks:** P0.2 (model card eval row), P0.3 (bench run uses the final checkpoint), P1.1 (flywheel can't close a round without a trained model to retrain from).
- **Hours (a/r/p):** 0.1 / 0.5 / 3.0. (Aggressive: main session reads the log, fills the placeholders, done. Pessimistic: NaN/Inf halfway through → diagnose → restart with LR damp → another 2 h wall.)
- **Machine:** Studio (already pinned).
- **Owner:** Main session (holds the GPU, reviews log, fills eval cells in model card).
- **Risk:** If eval @ 3000 > 2.87 (d=128 f64 baseline), the "width wins" hypothesis is wrong and the model card's flagship claim loses its punch. Mitigation: the S2 writeup has a fallback plan (run d=256 f64 clean baseline, ~1-2 h, to disambiguate capacity vs fp16 bite).

### P0.2 — Fill eval / RSS / wall rows in `PHASE_4C_MODEL_CARD.md`

- **Status:** Doc skeleton written (this session, `docs/plans/PHASE_4C_MODEL_CARD.md`). Three tables have TBD cells: eval results row, hardware RSS/wall, bench_railnative score.
- **What's missing:** ~6 numbers copied from `/tmp/d256_3000.log` + the bench-row cell (P0.3) + a short post-mortem paragraph if the result lands below 2.7 vs above.
- **Hours:** 0.3 / 0.5 / 1.0.
- **Machine:** either.
- **Owner:** Main session (within minutes of P0.1 landing).
- **Risk:** Low. Doc is pre-structured with every field it needs.

### P0.3 — `bench_railnative` score on the final checkpoint

- **Status:** NOT RUN. Blocker: bench harness (`flywheel/bench_railnative.rail`) lives in the private `Ledatic-Empire/rail-training` repo. Not in this repo.
- **What's missing:**
  - scp sync from Mini: `scp -r <user>@<host>:~/projects/rail-training/flywheel ./flywheel-local/` (or the individual `bench_railnative.rail` + its question fixtures).
  - Wire checkpoint path into the bench invocation.
  - Run bench against the d=256 checkpoint when P0.1 lands.
  - Append result row to `flywheel/bench_log.txt` (not `.backup`).
- **Hours:** 0.5 / 1.0 / 2.5. (Pessimistic: checkpoint format has drifted from what the bench harness expects, needs a shim.)
- **Machine:** Studio (has the checkpoint) + private-repo on Mini (has the harness). Either run bench on Studio after scp, or ship the checkpoint to Mini.
- **Owner:** Main session, after P0.1 + the other Studio session's bench plumbing lands (see P1.2).
- **Risk:** **HIGH.** This is the literal deliverable (≥ 5/30). Three historical hits at ≥ 5/30 exist (all from 2026-04-04 model states), so the bar is clearable — but we haven't run bench against a Rail-corpus-trained model yet. Today's model is a different animal than what scored 14/30 on 2026-04-04; no guarantee it transfers.

---

## P1 — Closed flywheel round

### P1.1 — Task #14 Phase 2d.E retrain-bench wiring

- **Status:** NOT STARTED. Primitives exist in `tools/train/self_train.rail` (`harvest_snapshot`, `harvest_rollback`, `harvest_ab_gate`) but aren't wired into the retrain path.
- **What's missing:**
  - Private repo sync (same scp as P0.3).
  - Wire `harvest_snapshot 0` + bench-score parse + `harvest_ab_gate` around the `retrain` call in `run_loop` in `tools/train/self_train.rail`.
  - Force one-round self_train test with `--parallel 4` to validate the gate fires correctly.
- **Hours:** 2.0 / 3.0 / 5.0.
- **Machine:** Studio (can run, needs private-repo sync) or Mini (has the repo, but Mini is currently busy per the session setup).
- **Owner:** Next session (parallel to model-card writeup), or Mini Claude if bandwidth opens.
- **Risk:** MEDIUM. Independent of P0 so doesn't block the flagship claim, but IS the "one closed flywheel round" deliverable. Skippable only if we descope the closed-round deliverable.

### P1.2 — Bench plumbing (save / load / infer / bench)

- **Status:** IN PROGRESS in the other Studio session right now (per this session's brief). That session is building the bench-plumbing pipeline (presumably checkpoint save/load, inference driver, bench harness wiring).
- **What's missing:** whatever the other Studio session delivers. This doc can't be more specific without reading their output.
- **Hours:** already spent / carries over to next session.
- **Machine:** Studio.
- **Owner:** Parallel Studio session.
- **Risk:** MEDIUM. If their pipeline doesn't land in a runnable state, P0.3 and P1.1 both stall. Monitor their branch.

---

## P2 — Housekeeping for the deadline

### P2.1 — Rerun `./rail_native test` on Mini

- **Status:** Session 2 flagged that `./rail_native test` hung at 100% CPU on test #1 (`main=42`) across three attempts on Mini. Root cause unknown. Mini's analysis is that it's unrelated to S2 changes (stdlib/tensor edits are only consumed by explicit imports; `run_tests` strings are standalone). Unverified.
- **What's missing:** One clean `./rail_native test` run on Mini producing 137/137. If it still hangs, root-cause via `lsof /tmp/rail_out`, orphan cleanup, or run tests individually to find which one blocks.
- **Hours:** 0.25 / 0.5 / 2.0.
- **Machine:** Mini.
- **Owner:** Mini Claude (or next session that opens an ssh shell to Mini).
- **Risk:** LOW for the deadline (doesn't block bench/model card), HIGH for confidence (if tests are actually broken, we ship a model on top of a regressed compiler).

### P2.2 — Studio dylib rebuild verification

- **Status:** Session 2 added 4 new dispatchers (`add_half_host`, `scale_half_host`, `transpose_half_host`, `softmax_half_host`) to `tools/metal/tensor_gpu_lib.m`. Studio's local dylib must have them — the 3000-step run is in flight so they clearly loaded. But re-verify post-merge before the flywheel round.
- **What's missing:** `nm tools/metal/libtensor_gpu.dylib | grep -E '(add|scale|transpose|softmax)_half_host'` should return 4 lines. If not, rebuild per the command in `SESSION_HANDOFF_2026-04-22.md`.
- **Hours:** 0.1 / 0.1 / 0.5.
- **Machine:** Studio.
- **Owner:** Next session first-60-minute checklist.
- **Risk:** LOW. Fast to verify, fast to fix.

### P2.3 — Model card finalization / external-facing review

- **Status:** Draft exists (this session). Skeleton + defensible one-liner + architecture + precision design + compiler provenance all written. Eval / bench / hardware cells are explicit placeholders.
- **What's missing:** (a) fill placeholders after P0.1/P0.3. (b) one external-reader pass to remove Rail-insider jargon / tighten claims.
- **Hours:** 0.5 / 1.0 / 1.5.
- **Machine:** either.
- **Owner:** Main session or next session, after P0.3.
- **Risk:** LOW if P0 lands well. MEDIUM if P0 lands weakly and the one-liner needs a rewrite ("trained WITH" rather than "trained COMPETITIVELY WITH").

---

## Aggregate estimate

| priority | items | realistic hours |
|---|---|---:|
| P0 (flagship capacity) | P0.1 + P0.2 + P0.3 | 2.0 |
| P1 (closed round) | P1.1 + P1.2 | 3.0 + ? |
| P2 (housekeeping) | P2.1 + P2.2 + P2.3 | 1.6 |
| **total realistic** | | **~7 h + P1.2 uncertainty** |
| **pessimistic** | | **~13 h + P1.2 uncertainty** |

Over ~5 working days this is comfortable *if* P0 lands cleanly. It becomes tight if P0.1 fails and needs a re-run, and untenable if P1.1/P1.2 both stall (no closed flywheel round means descoping that deliverable).

## Go / no-go

**The handoff doc says "comfortable for 5 working days" and I think that is slightly optimistic.** Specific gaps:

1. **Bench harness is in the private repo.** Every mention of `bench_railnative` assumes it's one scp away. If `Ledatic-Empire/rail-training` has drift (the Python/Rail bench tool, its question fixtures, checkpoint format assumptions) we don't know about, P0.3 time balloons fast.

2. **No bench has been run since 2026-04-04.** Historical peak 14/30 was on an unknown-to-me model state; current Rail-corpus-trained models have never been benched. The ≥ 5/30 claim is a plausible extrapolation, not a tested one.

3. **Task #14 (P1.1) is "2-3 h" in the handoff but depends on private-repo sync being clean AND self_train's existing retrain loop accepting the snapshot/gate primitives without friction.** Neither is verified. 3-5 h realistic, could be more.

4. **Concurrent sessions are doing different things. Coordination cost is real** — the other Studio session is building bench plumbing (P1.2), this session is writing docs, main session is watching the 3000-step run, Mini has 6 Claudes on other work. Shared-file collisions and branch merges will eat some hours.

**Verdict:** on track for a **minimum viable deadline** (model card + flagship capacity result + ≥ 5/30 bench score). Closed flywheel round (P1.1) is the one genuinely at risk; realistic path gets it done, pessimistic path descopes it.

**Recommendation:** if by end of day 2026-04-23 (Thursday, -3 working days from deadline) P1.1 hasn't started, cut it from the deadline scope and document the descope in the model card. Don't try to ship a broken or half-wired flywheel round in the last 24 h.

---

## Historical bench data

Extracted from `flywheel/bench_log.txt.backup` (25 rows, 2026-03-18 → 2026-04-04; `.backup.prev` is identical).

### 25-question era (2026-03-18 only, 7 rows)

5 axes × 5 questions (fund / io / tools / comp / adv), total out of 25. Scores:

| date | fund | io | tools | comp | adv | total |
|---|---:|---:|---:|---:|---:|---:|
| 03-18 12:00 | 0 | 0 | 0 | 0 | 0 | 0/25 |
| 03-18 12:02 | 1 | 1 | 0 | 0 | 0 | 2/25 |
| 03-18 12:25 | 0 | 0 | 0 | 0 | 1 | 1/25 |
| 03-18 13:27 | 0 | 0 | 0 | 1 | 2 | 3/25 |
| 03-18 13:58 | 0 | 1 | 0 | 2 | 0 | 3/25 |
| **03-18 15:14** | **3** | **5** | **5** | **5** | **5** | **23/25 (92%)** ← outlier |
| 03-18 16:20 | 0 | 1 | 0 | 0 | 1 | 2/25 |

The 23/25 row is an outlier: every other 03-18 row is ≤ 3/25. That looks like either a harness bug (e.g., scoring function stuck on "pass") or a model state that memorized the question set verbatim. Don't take 23/25 at face value; the cluster is 1-3/25 with one anomaly.

### 30-question era (2026-03-21 onward, 18 rows)

6 axes × 5 questions (fund / io / tools / comp / adv / comprehend), total out of 30. `port=` column indicates which inference server port the harness hit. `quality` / `w` columns added 2026-04-04 20:49.

| date | total | notes |
|---|---:|---|
| 03-21 00:35 | 10/30 (33%) | first 30-q row |
| 03-21 00:46 | 0/30 | |
| 04-03 23:12 | 0/30 | |
| 04-03 23:15 | 0/30 | |
| 04-03 23:20 | 0/30 | port=0 (no inference server up) |
| 04-03 23:36 | 6/30 (20%) | first useful post-restart row |
| 04-04 00:55 | 12/30 (40%) | |
| 04-04 01:00 | 12/30 (40%) | |
| 04-04 01:05 | 11/30 (36%) | |
| **04-04 01:32** | **14/30 (46%)** | **era peak** |
| 04-04 12:37 | 14/30 (46%) | rerun — same result |
| 04-04 12:43 | 14/30 (46%) | rerun — same result |
| 04-04 20:49 | 14/30 (46%) | quality=0/100 (quality metric not yet wired) |
| 04-04 20:52 | 10/30 (33%) | quality=28/100 |
| 04-04 21:29 | 2/30 (6%) | quality=5/100 |
| 04-04 21:33 | 2/30 (6%) | quality=5/100 |
| **04-04 21:42** | **11/30 (36%)** | quality=33/100, **last row in the log** |

### Observations

- **The bar has been cleared repeatedly in the 30-q era.** 5 of the 18 rows scored ≥ 10/30 (well over the ≥ 5/30 deadline target). 7 of 18 scored ≥ 5/30.
- **Peak 14/30 held across three reruns** on 2026-04-04. That's a real, reproducible score on whatever model state was live.
- **No benches since 2026-04-04** — 17 days of silence in the log. The current training pipeline (Rail-corpus + d=128/256 + HalfTensor) has never appeared in this log. So "≥ 5/30" is historically plausible but untested against current models.
- **Quality-metric wiring is partial.** The last 5 rows have `quality=X/100 w=Y/90` columns; the first 13 of the 30-q era don't. Bench schema has been evolving — expect one more small schema change before the deadline bench row lands.
- **Model state corresponding to 14/30 is not documented here.** The log doesn't record which checkpoint it benched. P0.3 should log the checkpoint path in the result row; prior rows don't.

**What this means for P0.3:** the ≥ 5/30 target is not a moonshot — half the 30-q era rows cleared it — but the current model is a new training regime that has never been benched. Plan for at least one "it scores 0/30 because X" debug iteration before the real number.
