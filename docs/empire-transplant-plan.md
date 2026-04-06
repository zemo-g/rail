# Empire → Rail Transplant Plan

> **Generated at the end of 2026-04-06 neural plasma session.**
> **Execute in a fresh session.** Tonight's session is loaded with plasma/compiler state — this is different work and needs clean context.

---

## Why this exists

Empire isn't a project to revive — it's a donor body. Rail has been growing without operational discipline (recovery, causality, modularity, tunability). Empire learned these the hard way. The goal: transplant the patterns Empire proved in production into Rail before the flywheel gets too big to debug by hand.

The crown jewels below are all **operational discipline** — not features. Rail currently has none of them and doesn't realize it needs them yet, because the flywheel is still small enough to hold in one head. That won't last.

---

## Crown Jewels (top 4 — do these)

### 1. Intervention Ledger (start here — revised order)

**Empire pattern:** `oversight/causal/ledger.py` — every override, every tuner write, every restart logged as a causal intervention with before/after state. Phase 1 was just the passive ledger; Phases 2-4 (DAG, predictions) were the dream but never shipped.

**Why Rail needs it desperately:** The flywheel makes thousands of unrecorded interventions — every training round, every adapter swap, every curriculum advance, every bench retry. There is no causal record. When a regression happens (level 25 → 6, hyperagent stalled at cycle 26, gemma 2/30 → 14/30), there's no bisect. Flying blind through the most important loop in the project.

**Transplant:** Steal Phase 1 only. Passive ledger. `flywheel/interventions.jsonl` — round, level, adapter hash, bench score, what changed, why. Append-only. Indispensable.

**Cost:** Half a day.

**Why this first (not recovery):** Recovery lets you roll back. Ledger tells you *what caused the problem* so you don't need to. Understanding compounds. Defense doesn't.

### 2. Recovery Chain — oversight.db style

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

**Transplant:**
- Port `oversight_db_flush.sh` → `tools/flywheel_flush.sh`
- Add size + line-count guards
- Set up a flush cron
- Apply to: `training/self_train/harvest.jsonl`, `flywheel/interventions.jsonl` (from step 1), `flywheel/bench_log.txt`

**Cost:** Half a day.

### 3. Domain Plugin Spine — the Ledatic OS thesis

**Empire pattern:** `domains/trading/domain.py`, `domains/ad_intel/domain.py`, with `pipeline.py` as the engine. Each domain is a plugin that hooks into oversight. New domain = one file.

**Why Rail needs it:** `tools/` is a flat zoo — `deploy/`, `train/`, `fleet/`, `apps/`, `plasma/`, `railml/`, `uav/`. They share nothing. Each re-implements its own logging, its own bench, its own state file, its own deploy script. There's no spine.

**This is the Ledatic OS thesis in one transplant.** A `tools/domains/` directory with a tiny Rail interface (`init`, `tick`, `bench`, `harvest`, `state`), and suddenly RailML, neural plasma, the flywheel, the UAV, DDA — all share infrastructure.

**Transplant approach:**
- Start with **one** test domain. The neural plasma engine is the obvious candidate (`tools/domains/neural_plasma/`).
- Define the interface as the smallest thing that works. Resist over-engineering.
- Prove the shape before generalizing.
- Migrate a second domain (probably `railml`) to validate the interface
- Then propose migrating others

**Cost:** 2 days.

**Warning:** Domain plugin architectures are easy to over-engineer. The interface should be obvious and boring. If you're designing abstraction layers, stop.

### 4. Runtime Overrides + Audit Trail

**Empire pattern:** `TUNABLE_BOUNDS` in oversight defines what can be tuned. `runtime_overrides.json` carries the live values with a `last_writer` audit field. The trader reads overrides on the fly without restart.

**Why Rail needs it:** `compile.rail` is full of magic constants (arena size, GC threshold, register pressure cutoffs, harvest score thresholds, curriculum advance percentages). They're all hardcoded. Tuning means editing source and recompiling. Worse, the flywheel can't tune itself because there's no surface to tune through.

**Transplant:**
- `flywheel/overrides.json` — typed, bounded, audited
- Tiny Rail reader (50 lines)
- Every override write logs to `flywheel/interventions.jsonl` (from step 1)
- `last_writer` field on every override
- Start with 5-10 tunable constants, not 50

**Cost:** 1 day.

**Why last:** Before you have overrides, you don't know what to tune. The interventions ledger from step 1 will *tell* you what to tune by showing which constants correlate with regressions. Don't ship tuning knobs without the telemetry to use them.

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

1. **Intervention ledger** — half day, unblocks all future debugging → DO FIRST
2. **Recovery chain** — half day, blocks the next data disaster
3. **Domain plugin spine** (one domain: neural_plasma) — 2 days, unblocks the OS thesis
4. **Overrides + audit** — 1 day, unblocks self-tuning

**Total: 4 days of focused work, spread across 2-3 sessions.**

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
