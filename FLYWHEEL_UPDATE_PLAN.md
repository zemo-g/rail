# FLYWHEEL UPDATE PLAN — 2026-04-04

Current: 14/30 bench (46%). Target: 20/30 (66%).

---

## 1. Golden Examples (HIGHEST LEVERAGE)

The model learns Rail from examples, not rules. Every golden example is a verified program the model sees during training. Quality >> quantity.

**Current state:** 30 bench solutions + 60 variations = 90 golden. Not enough, and they don't cover the failing patterns.

**Action:** Write 30 new golden examples targeting the 14 bench failures:

| Failure | Golden to write |
|---|---|
| List drop-last (reverse+tail+reverse) | `drop_last xs = reverse (tail (reverse xs))` program |
| Insertion sort | Full isort with named `insert` helper |
| Word reversal (chars+reverse+join) | `rev_word w = join "" (reverse (chars w))` + map |
| Line counting (off-by-one on trailing \n) | Filter empty strings after split |
| Stack machine (Op ADT + list processing) | Full stack interpreter with recursive `exec` |
| Expr Mul eval | eval with Mul (mirrors the Add example) |
| JSONL filter (str_contains on lines) | count_matches + split + str_contains |
| Score read-modify-write | parse_int + append for string building |
| KV lookup (find line by prefix) | find_line + split on = |
| ERROR log counting | count_matches on split lines |
| Flatten nested lists | `flatten xss = if length xss == 0 then [] else append (head xss) (flatten (tail xss))` |
| Fold refactor | Side-by-side: recursive sum → fold add 0 |
| Print list sum (map + fold) | `double x = x * 2` + `add a b = a + b` + fold add 0 (map double xs) |
| find_key function | Recursive search with str_contains + split |

**Format:** Each golden is a complete program with system prompt, user task, and correct Rail code. Goes in `training/golden/bench_targeted.jsonl`.

**Why first:** These directly teach the model the 14 patterns it fails on. One example per failure mode. Training on these before running the flywheel gives the model a foundation instead of learning from scratch.

---

## 2. Prompt Updates

**bench.rail system prompt (mk_sys):**
- Current: clean prompt with 5 examples + grammar + rules. Gets 14/30.
- Keep it lean. The prelude handles helper functions.
- No changes needed right now — prompt is optimized.

**self_train.rail system prompt (mk_sys):**
- Updated with targeted examples (matches bench). Gets 40% at level 3, 80% spikes at level 4.
- Level 4 seeds now scaffolded (named helpers instead of lambda patterns).
- No changes needed — wait for golden examples + retrain to see if level 4 breaks through.

**Prelude (bench.rail):**
- Defines: starts_with, flatten, find_line, count_matches, parse_int, rev_word, insert, isort
- Currently disabled (not prepended) — was causing OOM when combined with server.
- **Action:** Re-enable prelude BUT only for non-comprehension tasks (comprehension tasks define their own functions).

---

## 3. Curriculum

**Current:** 25 levels, 10 seeds each (250 total). Advance at 2x20%+, fallback at 4x0%.

**Problem:** Level 4 is the wall. Model cycles between 0% and 80% on the same 10 tasks.

**Actions:**
1. **Level 4 seeds already scaffolded** — task descriptions now spell out named helper functions instead of forcing lambdas. Ready to test.
2. **Add 10 more level 4 seeds** — diverse tasks that test the same skills (filter/map/fold with named functions) but different programs. Prevents memorization cycling.
3. **Level 5+ seed audit** — check if levels 5-10 have the same lambda-forcing problem. Scaffold any that do.

**Not changing:** Level count (25), advance/fallback thresholds (2x20%/4x0%), temperature sweep (5 temps per task).

---

## 4. Dataset Pipeline

**Current:** 17 sources → SHA-256 dedup → 90/5/5 split. 7,663 train after cleaning.

**Sources inventory:**
```
  244  train.jsonl (base)
  150  git_harvest.jsonl
5,793  harvest_clean.jsonl (self-train deduped)
1,155  real_programs.jsonl
   50  handcrafted_l2_l5.jsonl
2,971  repairs.jsonl
  204  synthetic_repairs.jsonl
   20  session_harvest.jsonl
   40  builtin_examples.jsonl
1,359  targeted.jsonl
   30  golden/bench_solutions.jsonl
   60  golden/bench_variations.jsonl
  199  dna/rail_dna.jsonl
   20  traces.jsonl
   32  negatives.jsonl
  ---  cloud_harvest.jsonl (missing)
  ---  cloud_repairs.jsonl (missing)
```

**Actions:**
1. **Add golden/bench_targeted.jsonl** to merge list in dataset.rail (new file from section 1)
2. **Clean harvest again** — 10,863 raw harvest lines → dedup should yield more than current 5,793
3. **Rebuild split** after golden examples are added: `./rail_native run flywheel/dataset.rail prepare`
4. **JSON validation** — 230 bad lines last time. Run cleaner after every rebuild.

---

## 5. Bench Expansion

The 30-task bench is fixed and comparable. Don't change existing tasks. But we can add a diagnostic bench.

**Action:** Create `flywheel/bench_diag.rail` — 30 NEW tasks specifically for the patterns the model fails on. Not for scoring (scores come from the fixed bench), but for rapid iteration on prompts and training.

**Diagnostic tasks to add:**
- 5 tasks requiring named helper functions with filter/map/fold
- 5 tasks requiring str_contains/find_line/count_matches
- 5 tasks requiring parse_int/append for read-modify-write
- 5 tasks requiring recursive list processing (flatten, zip, take/drop)
- 5 tasks requiring multi-step file I/O pipelines
- 5 tasks requiring ADT interpreters (stack machine, expression eval)

**Why separate:** The fixed bench measures progress. The diagnostic bench identifies gaps. Running both tells you where you are AND what to fix next.

---

## 6. Execution Order

Prioritized by leverage. Each step builds on the previous.

```
PHASE 1 — DATA QUALITY (1-2 hours)
  1. Write 30 golden examples → training/golden/bench_targeted.jsonl
  2. Add to dataset.rail merge list
  3. Re-dedup harvest (10,863 raw → should be ~6K+ unique)
  4. Rebuild dataset: ./rail_native run flywheel/dataset.rail prepare
  5. Clean JSON: remove bad lines from all splits

PHASE 2 — SERVE + BENCH (30 min)
  6. Start Gemma 4 server on :8081 (no adapter — test base + golden)
  7. Run bench baseline (no adapter, fresh golden in dataset)
  8. If base improved: the golden examples are working

PHASE 3 — TRAIN (1-2 hours)
  9. Run 10x 10-iter training bursts (8 layers, LR 3e-6, --val-batches 0)
  10. Restart server with adapter
  11. Re-bench — should exceed 14/30

PHASE 4 — FLYWHEEL (continuous)
  12. Start self-training loop: --port 8081 --no-retrain yes
  13. Monitor: should climb levels 1→4 quickly with scaffolded seeds
  14. Level 4 breakthrough = new examples at harder difficulty
  15. Every 100+ new examples: rebuild dataset + retrain burst

PHASE 5 — ITERATE
  16. Run failure diagnosis on remaining bench failures
  17. Write targeted golden examples for new failure patterns
  18. Repeat from Phase 1
```

Each cycle should push the bench 2-4 points. Target 20/30 by end of day.
