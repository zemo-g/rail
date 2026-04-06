# Empire → Rail Transplant Plan

> **Generated at the end of 2026-04-06 neural plasma session.**
> **Execute in a fresh session.** Tonight's session is loaded with plasma/compiler state — this is different work and needs clean context.

---

## Why this exists

Empire isn't a project to revive — it's a donor body. Rail has been growing without operational discipline (recovery, causality, modularity, tunability). Empire learned these the hard way. The goal: transplant the patterns Empire proved in production into Rail before the flywheel gets too big to debug by hand.

The crown jewels below are all **operational discipline** — not features. Rail currently has none of them and doesn't realize it needs them yet, because the flywheel is still small enough to hold in one head. That won't last.

---

## Crown Jewels (top 4 — do these)

### 1. Intervention Ledger ✅ SHIPPED 2026-04-06

**Empire pattern:** `oversight/causal/ledger.py` — every override, every tuner write, every restart logged as a causal intervention with before/after state. Phase 1 was just the passive ledger; Phases 2-4 (DAG, predictions) were the dream but never shipped.

**Why Rail needs it desperately:** The flywheel makes thousands of unrecorded interventions — every training round, every adapter swap, every curriculum advance, every bench retry. There is no causal record. When a regression happens (level 25 → 6, hyperagent stalled at cycle 26, gemma 2/30 → 14/30), there's no bisect. Flying blind through the most important loop in the project.

**What was built (Rail-native, zero Python):**
- **Inline helpers in `tools/train/self_train.rail`** (added after the existing `write_line` at line 33):
  - `kvi key val` — builds a `,"key":int` JSON fragment
  - `kvs key val` — builds a `,"key":"string"` JSON fragment
  - `log_intervention kind fields` — gets ISO timestamp via `shell "date -u ..."`, builds the full record, appends one JSON line via `write_line "flywheel/interventions.jsonl"`. Reuses the same `q = "\""` and `json_esc` machinery already in the file.
- **5 hooks in `tools/train/self_train.rail`** — each is a single `let _ = log_intervention "kind" (cat [kvi ..., kvs ...])` call, no shell-out per hook:
  - `server_skip` — MLX server unhealthy after 3 min retries, round abandoned
  - `round_end` — post-round snapshot at the level the round ran at (canonical event)
  - `goal_grind` — all 25 levels mastered, entering ultimate goal-grind mode
  - `level_advance` — consecutive_pass ≥ 2, level + 1
  - `level_fallback` — 4 consecutive 0% rounds, level - 1
- **`flywheel/interventions_tail.rail`** — Rail-native viewer. Self-contained `parse_int` (Rail's `to_int` is float→int, not string→int), shells `tail -n N` for the actual read. Supports default (20), explicit `N`, and `all`.
- self_train.rail compiles cleanly (77140 chars). Probe-tested end-to-end: a standalone Rail program calling the identical `kvi`/`kvs`/`log_intervention` helpers wrote 3 well-formed JSON records to the ledger, and `python3 -c "json.loads(line)"` confirmed parseability.

**Schema** (open — any caller can add new keys without migration):

```jsonc
{
  "ts":               "2026-04-06T15:53:00+00:00",   // ISO 8601 UTC, seconds
  "kind":             "round_end",                    // event class
  "round":            117,                             // self-train round counter
  "level":            6,                               // curriculum level
  "pass":             3,                               // tasks passed this round
  "total":            10,                              // tasks attempted
  "pass_rate":        30,                              // integer percent
  "new_harvested":    2,                               // examples added this round
  "harvested":        503,                             // running total
  "since_retrain":    12,                              // examples since last retrain
  "consecutive_pass": 1,                               // pass-streak counter
  "consecutive_zero": 0,                               // zero-streak counter
  "attributed_to":    "self_train",                    // writer identity
  // event-specific extras:
  "old_level":        6,                               // level_advance, level_fallback
  "new_level":        7,                               // level_advance, level_fallback, goal_grind
  "reason":           "consecutive_pass_2"             // free-text reason
}
```

**Reading the ledger:**
```bash
./rail_native run flywheel/interventions_tail.rail        # last 20 records
./rail_native run flywheel/interventions_tail.rail 100    # last 100
./rail_native run flywheel/interventions_tail.rail all    # full file
```
For event-class filtering or substring grep, pipe through standard tools:
```bash
./rail_native run flywheel/interventions_tail.rail all | grep '"kind":"level_advance"'
./rail_native run flywheel/interventions_tail.rail all | grep '"level":6'
```

**Auto-activation:** No manual install needed. `run_training.sh` md5-checks `self_train.rail`, detects the source change, recompiles, installs `/tmp/rail_st_bin`. The next training round writes its first intervention record automatically.

**The level 25 → 6 regression mystery:** progress.txt currently shows round=117 level=6 but memory claims level=25 / 934 rounds. There is no record of how the curriculum collapsed because the pre-ledger flywheel didn't save state transitions. This regression is the proof the ledger was needed; the next one we'll be able to bisect.

**Why this first (not recovery):** Recovery lets you roll back. Ledger tells you *what caused the problem* so you don't need to. Understanding compounds. Defense doesn't.

### 2. Recovery Chain ✅ SHIPPED 2026-04-06 (Session 2)

**Empire pattern:**
```
/Volumes/OversightRAM/oversight.db (RAM disk)
  ↓ 5min flush via tools/oversight_db_flush.sh (VACUUM INTO + size guard + conclusions guard)
oversight/data/oversight.db.nvm_backup (primary backup)
  ↓ before overwrite
oversight/data/oversight.db.nvm_backup.prev (previous backup)
```

`_open_db_with_recovery()` in `oversight_v3.py` validates both **integrity AND data presence** before accepting a file. It refuses to overwrite a good backup with an empty one.

**Why Rail needs it:** `training/self_train/harvest.jsonl` (10,868 lines), `harvest_clean.jsonl` (5,811), `progress.txt`, the dataset splits — all irreplaceable training data with zero recovery. One bad shell redirect kills the corpus. You wouldn't notice for days.

**What was built (pure Rail, zero Python):**
- **`flywheel/flush.rail`** (~145 lines, 8258 chars) — recovery-chain rotator. Per protected file: cp src→tmp, mv backup→prev, mv tmp→backup. Exit code is always 0; failures are visible via `[REFUSE]` / `[skip]` markers in stdout.
- **Two-deep backup chain**: `<file>.backup` + `<file>.backup.prev` per protected file. Empire's exact pattern, with `prev` rotated before each new write.
- **Three guards** (mirror Empire's safeguards):
  1. **Source-empty guard**: source must exist + size > 0, otherwise skipped
  2. **Size guard**: when old backup > 1024 bytes, new must be ≥ 50% of old. Refuses an attempt to back up a truncated file.
  3. **Line guard**: never overwrite a non-empty backup with a zero-line file (defends against partial writes that have bytes but no complete records)
- **Protected files** (extend the list in `main`):
  - `training/self_train/harvest.jsonl` — training corpus (5.4MB, 10,868 lines)
  - `training/self_train/progress.txt` — curriculum state (88 bytes, 6 lines)
  - `flywheel/interventions.jsonl` — Session 1 ledger
  - `flywheel/bench_log.txt` — bench history
- **Wired into `tools/train/run_training.sh`** — every successful round triggers `/tmp/rail_flush_bin` after the self-train invocation. Same md5-cached compile pattern as `self_train.rail`. Empire flushes every 5 min via launchd; Rail flushes every round (similar cadence in practice).
- **Initial backups already created**: `harvest.jsonl.backup`, `progress.txt.backup`, `bench_log.txt.backup` plus `.prev` snapshots all live on disk now.

**Guard test suite** (run via temp fixture, exercised all 5 cases):
1. ✅ First flush — succeeds (no backup yet)
2. ✅ Second flush — rotates current → prev
3. ✅ Shrink guard — 19-byte replacement of 20890-byte file → REFUSED
4. ✅ Empty source — skipped cleanly
5. ✅ Missing source — skipped cleanly
6. ✅ Backup integrity verified after all refusals — 20890 bytes / 2000 lines preserved

**Reading the recovery state:**
```bash
ls -la training/self_train/*.backup* flywheel/*.backup*
./rail_native run flywheel/flush.rail   # one-shot manual flush
```

**Why this works without launchd:** Empire used a 5-min cron because `oversight.db` was on a RAM disk and could vanish on power loss. Rail's flywheel data is on NVMe, but the training loop runs constantly during active sessions — flushing per round gives fresher backups than a 5-min cron without any new infrastructure.

### 3. Domain Plugin Spine ✅ SHIPPED 2026-04-06 (Session 3)

**Empire pattern:** `domains/trading/domain.py`, `domains/ad_intel/domain.py`, with `pipeline.py` as the engine. Each domain is a plugin that hooks into oversight. New domain = one file.

**Why Rail needs it:** `tools/` is a flat zoo — `deploy/`, `train/`, `fleet/`, `apps/`, `plasma/`, `railml/`, `uav/`. They share nothing. Each re-implements its own logging, its own bench, its own state file, its own deploy script. There's no spine.

**What was built (zero abstraction layers, filesystem is the registry):**
- **`tools/domains/README.rail`** — executable convention spec. Run it to print the rules. Each domain lives at `tools/domains/<name>/` and may contain any subset of: `state.rail`, `bench.rail`, `init.rail`, `tick.rail`, `harvest.rail`. All optional. No dispatcher, no manifest format, no registry file. The filesystem IS the registry. Discovery is `ls`.
- **`tools/domains/list.rail`** — discovers domains via `find tools/domains -mindepth 1 -maxdepth 1 -type d`. For each, prints which conventional verbs are present. Pure read; no execution.
- **`tools/domains/neural_plasma/state.rail`** — file inventory + key-source metadata for `tools/plasma/`. Shows total files, .rail/.metal/.m breakdown, sizes + mtimes of `neural_mhd_gpu.rail`, `neural_renderer.rail`, `plasma_3d.rail`, `plasma_lab.html`, plus the d8 + float regression test mtimes.
- **`tools/domains/neural_plasma/bench.rail`** — re-compiles `tools/plasma/d8_test.rail` and `tools/plasma/float_bug_test.rail`. Reports a real `score: N/2`. Currently 2/2 (the d8 fix is alive). This is a *real* bench, not a stub — if the d8 codegen ever regresses, this is the canary.

**Why no dispatcher:** Any Rail-level dispatcher would introduce a registry (which file lives where, what verbs are valid, etc.) — that's the abstraction layer the warning was about. Each verb is just a normal Rail program runnable via `./rail_native run tools/domains/<name>/<verb>.rail`. When the second domain proves the shape, generalize. Until then, don't.

**The shape was proved within hours.** A parallel session built `tools/domains/s0_pcfg/` — a 13-integer PCFG trained via REINFORCE on compiler feedback — without any spine modification. Six ticks: 43% → 81% lifetime pass rate, every round writing `s0_round_end` events to `flywheel/interventions.jsonl` using the exact `kvi`/`kvs`/`log_intervention` pattern from Session 1. The new domain reads the 4 tunables from `flywheel/overrides.txt` (Session 4) and persists state to `flywheel/s0_state.txt` (now in flush.rail's protected list, Session 2). All four crown jewels lit up at once.

**Output of `./rail_native run tools/domains/neural_plasma/bench.rail`:**
```
═══ neural_plasma — bench ═══

[1/2] d8_test.rail (d8 callee-saved float TCO)...
      ✓ compiled
[2/2] float_bug_test.rail (recursive float ops)...
      ✓ compiled

score: 2/2
```

### 4. Runtime Overrides + Audit Trail ✅ SHIPPED 2026-04-06 (Session 4)

**Empire pattern:** `TUNABLE_BOUNDS` in oversight defines what can be tuned. `runtime_overrides.json` carries the live values with a `last_writer` audit field. The trader reads overrides on the fly without restart.

**Why Rail needs it:** `compile.rail` and `self_train.rail` are full of magic constants. Tuning means editing source and recompiling. Worse, the flywheel can't tune itself because there's no surface to tune through.

**What was built (closes the loop with Session 1):**
- **`flywheel/overrides.txt`** — simple `key=value` format (matches `progress.txt` convention, parseable by the existing `parse_kv` helper). Header carries `last_writer`, `last_writer_ts`, `last_writer_reason`. 4 tunables to start (the user's "5-10 not 50" guidance).
- **`flywheel/override_set.rail`** — CLI setter. Args: `KEY VALUE REASON`. Validates the key against the known set, the value against per-key bounds, then atomically rewrites `overrides.txt` (temp + `mv -f`) and **appends one `override_write` record to `flywheel/interventions.jsonl`** with old→new diff and reason. Closes the Session 1 loop: every tune is recorded.
- **`load_override` helper added to `tools/train/self_train.rail`** — reads `flywheel/overrides.txt` once per round at the top of `run_loop`. Falls back to default if the file is missing or the key is absent. The 4 hardcoded literals in `run_loop` were replaced with the loaded values:
  - `pass_rate >= 20` → `pass_rate >= pass_threshold`
  - `consecutive_pass >= 2` → `consecutive_pass >= advance_threshold`
  - `consecutive_zero >= 4` → `consecutive_zero >= fallback_threshold`
  - `since_retrain >= 200` → `since_retrain >= retrain_threshold`

**The 4 tunables:**
| key | bounds | default | what it controls |
|---|---|---|---|
| `pass_threshold` | 5..80 (pct) | 20 | min pass_rate to count this round toward `consecutive_pass` |
| `advance_threshold` | 1..20 | 2 | consecutive passes required to advance one curriculum level |
| `fallback_threshold` | 2..50 | 4 | consecutive 0% rounds before falling back one level |
| `retrain_threshold` | 50..2000 | 200 | examples since retrain marker (logging only today) |

**End-to-end verified:**
1. ✅ `override_set.rail pass_threshold 30 "tighten harvest gate"` → file updated, intervention logged
2. ✅ Multi-word reasons (Rail's `args` splits on whitespace, `drop_n` + `join " "` recombines)
3. ✅ Reject paths: unknown key, value below min, value above max — all surface clear `[reject]` messages and exit non-zero without touching disk
4. ✅ Loader probe: `load_override` reads each new value live the very next round
5. ✅ Restored to defaults (pass=20, advance=2) at end of session

**Reading the audit trail:**
```bash
./rail_native run flywheel/interventions_tail.rail all | grep override_write
cat flywheel/overrides.txt
```

**Sample ledger entry:**
```json
{"ts":"2026-04-06T16:25:14+00:00","kind":"override_write","key":"advance_threshold","old_value":2,"new_value":3,"reason":"slower curriculum advancement","attributed_to":"human"}
```

**Why this closes the loop:** Session 1 gave the flywheel eyes (the intervention ledger). Session 4 gives it knobs (the overrides). Both are recorded in the same JSONL stream. A future automation layer can read `interventions.jsonl`, decide a tuning is warranted, call `override_set.rail`, and the next round's `load_override` picks it up — with the cause preserved in the same ledger that justified the change.

---

## Tier 2 — Smaller wins (port when you need them)

- **`autonomy/cloud_tools.py` multi-turn tool loop** — Rail's agent does single-shot. Multi-turn with tool-use is already wired in Python. Steal the loop structure.
- **Prompt caching `cache_control: ephemeral`** — 90% cost savings on cloud fallback. Pure free lunch.
- **Anthropic SDK direct calls bypassing GPU queue** (`autonomy/server.py`) — Rail's agent currently competes with itself for GPU. The bypass-cloud pattern is exactly what `self_train.rail` needs when it hits a stuck level.
- **`conviction_corpus.py` → `conviction_train.py` → `conviction_benchmark.py` pipeline** — Empire built (but never shipped) corpus → label → train → bench for arbitrary scorers. Rail's flywheel only does this for code generation. **Generalizing it means Rail can train scorers for anything** — bench tasks, plasma surrogates, drone reward models. The pipeline shape is the gold; the LoRA target was incidental.
- **`launchd ThrottleInterval=30s`** — prevents crash-loop corruption. Rail's training loop should adopt this.
- **Kill switches (`~/.ledatic/data/.kill_switch`)** — file-presence halt is dumb and bulletproof. The flywheel should have one.

---

## Tier 3 — Leave it in the ground

- Telegram bot plumbing — no audience, anti-pattern for a compiler project
- Launchd service zoo — Rail should not become 14 services
- Plaintext plist secrets (Empire's Architectural Debt #22) — actively bad pattern, don't import the disease with the organ
- MLX router — Rail will route its own way
- Retired `legacy/cortex/`, `legacy/portfolio/` — already dead, leave them dead
- Trader-specific feature set (top1%, fatigue, GoPlus integration) — domain-specific, not transferable
- Half-built `oversight/expansion/` components 1, 3, 4, 6 — beautiful plans but no working code; reinvent in Rail when the flywheel needs them, don't port

---

## The big insight

Empire and Rail were building the same machine from opposite ends.

- Empire started from "we need to make money and learn from it" and was reaching toward self-improvement.
- Rail started from "we need a self-improving compiler" and is now reaching toward usefulness.

The gold isn't the code itself — it's the patterns Empire learned the hard way that Rail hasn't hit yet. The crown jewels above are all operational discipline. Rail has none of them and will need every one of them within the next few months of flywheel scale-up.

---

## Recommended execution order (revised)

1. ✅ **Intervention ledger** — SHIPPED 2026-04-06. Writer + viewer + 5 hooks in self_train.rail. Auto-activates on next training round.
2. ✅ **Recovery chain** — SHIPPED 2026-04-06. flush.rail + 3 guards + run_training.sh integration. Three protected files now have .backup + .backup.prev chains.
3. ✅ **Domain plugin spine** — SHIPPED 2026-04-06. README + list discoverer + neural_plasma (state + bench wrapping the d8 regression test). Filesystem-as-registry, no dispatcher.
4. ✅ **Overrides + audit** — SHIPPED 2026-04-06. overrides.txt + override_set.rail CLI with bounds + intervention logging. self_train.rail's 4 hardcoded thresholds now live-tunable. Closes the Session 1 loop — every override write is recorded.

**All four crown jewels shipped in one session. 92/92 compiler tests still green throughout.**

---

## State snapshot at end of 2026-04-06 session

Entering this plan, Rail is in the following state:

**Compiler:**
- Self-hosting, byte-identical fixed point
- 91/92 tests
- d8 callee-saved float register support (new tonight)
- ARM64, x86_64, Linux ARM64, WASM backends
- GC in ARM64 assembly
- Zero C dependencies

**Neural plasma engine:**
- 3D Metal MHD simulator (128³, volume raymarcher)
- CPU Rail neural surrogate (loss 4.45 → 0.03)
- Metal GPU MLP training (10 kernels, analytical backprop)
- Stable 200-step autoregressive simulation (mass within 3% through t=100)
- Spectral norm + conservation drift loss + positivity penalty
- Neural renderer (MLP as physics engine, real-time)
- Documented in `docs/neural-plasma-engine.md`

**GitHub:**
- `zemo-g/rail` — public, BSL 1.1, 17 commits in the last 24 hours
- `zemo-g/rail.tmbundle` — MIT TextMate grammar (new tonight)
- `github-linguist/linguist#7905` — PR open, awaiting review
- CI green

**Flywheel (legacy state, untouched tonight):**
- `training/self_train/progress.txt` — round 117, level 6, 501 harvested
- `training/self_train/harvest.jsonl` — 10,868 entries
- MLX server not running
- Gemma 4 E4B bench peak: 14/30 (46%)

**Immediate friction points the transplants will fix:**
- No way to bisect regressions in the flywheel
- No recovery if harvest data gets corrupted
- No way to tune compiler/flywheel constants without rebuild
- `tools/` is a flat zoo with no shared infrastructure
