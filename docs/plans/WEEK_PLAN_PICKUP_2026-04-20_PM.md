# Week-plan pickup — end of 2026-04-20 PM session

**Purpose:** drop-in context for the next working session. Read this +
`docs/plans/WEEK_PLAN_2026-04-20.md` (the master plan) + your
`~/.claude/projects/-Users-user/memory/` and you can resume without me.

This is a **pickup doc**, not a new plan. The master plan is still the
source of truth for the end-state target (d=128+ Rail-native transformer
on 540 KB corpus, ≥5/30 bench_railnative, one flywheel round closed by
2026-04-27). This doc records what's done, what's blocked, and what to
pick up first.

## State at handoff

- **HEAD = `47e360a`** on `next`. 12 commits shipped today. Studio synced.
- **Test floor: 136/137 on Studio** (only pre-existing `gpu_map` Metal env
  FAIL). Mini 137/137.
- **Self-compile fixed point held** at every commit.
- **Phase 1c T5 run COMPLETE** (killed at step 11183/12000, 5h38m wall).
  Full handoff: `training/rail_native/T5_OVERNIGHT.md`. Headline:
  **min loss 1.37 @ step 1157** — the 2.7–3.3 band was per-chunk eval
  variance, not a loss floor. **d=64 is not capacity-bound.** Separate
  finding: peak RSS 35.84 GB (vs 437 MB at 500 steps) — small-block
  leak active in back half.
- **fp16 probe (Option A decision gate) PASSES:** 1.70× at N=1024,
  1.92× at N=2048 on M1 Ultra. Exceeds the 1.6× threshold from
  `MIXED_PRECISION_SCOPE.md`. Binary at `tools/metal/probes/fp16_probe`.

## Today's commits (bottom-up)

| Commit  | Phase | What                                                   |
|---------|-------|--------------------------------------------------------|
| 2b9279b | 0     | rail: arena slow-path routes through _rail_chained_malloc |
| b8bf477 | 0     | optim: per-param LR constants (adam_lr_mult_gamma=0.3)  |
| 633176a | 0     | oracle: oracle_compile_at / _and_run_at race-proof paths |
| 4399445 | 1a    | rail: `--out-prefix` CLI flag — unlocks parallel oracle  |
| e74ad26 | reorg | (user) CLAUDE.md reflects training/ extraction to private repo |
| e60c768 | 2d.0  | oracle: drop flock in batch → 5.31× speedup on Studio   |
| 46636cc | 2d.B  | llm: `parallel_llm_calls` + `_`-prefix resolution fix   |
| 07be7ac | 2d.C  | self_train: `run_batch_parallel` MVP (`--parallel N`)   |
| 81e81ad | 4a    | docs: mixed-precision scoping decision doc              |
| 251a279 | 2d.D  | self_train: parallel retries with error feedback        |
| 47e360a | 2d.3  | llm: 300s timeout → N=16 10.6× live-validated           |

Plus infra: mlx_studio plist bound 10.42.0.2 → 0.0.0.0 and reloaded
(MLX was down since 2026-04-18 10:36 crash; now live on localhost:8080).

## Phase status vs master plan

| Phase | Status | Notes |
|---|---|---|
| 0     | ✅ DONE | Three commits shipped |
| 1a    | ✅ DONE | `--out-prefix` flag |
| 1b    | ⏸ Stream 1 | BPE hash table — coordination required; not mine to touch |
| 1c    | ✅ DONE | Min loss 1.37; d=64 not capacity-bound. See `training/rail_native/T5_OVERNIGHT.md` |
| 1d    | 🟢 Next | Multi-chunk eval + memory bisect. Precondition for Phase 2. |
| 2a    | ⏳ Blocked on 1d | Revised: ≤3000 steps with multi-chunk eval |
| 2b    | ⏳ Blocked | Waits on 2a |
| 2c    | ⏳ Blocked | Waits on 2a/b |
| 2d    | ✅ DONE | Structurally + 5.31× batch + 10.6× N=16 round — validated live |
| 2d.E  | 🟢 Can start | Snapshot/rollback (nnzap-inspired). Small, post-1c OK |
| 3a    | ⏳ Blocked | `harvest_clean_v2.jsonl` lives in private `rail-training` repo |
| 3b    | ⏳ Blocked | Needs 3a + `flywheel/` code (private repo) |
| 3c    | ✅ DONE | Cleanup done; match parse bug non-reproducible in current HEAD |
| 4a    | 🟢 Gate open | Scoping doc shipped; probe measured 1.70× at N=1024 — Option A worth pursuing |
| 4b    | ⏳ Blocked | Needs 2a/b trained checkpoint + harvest_clean_v2 |
| 4c    | ⏳ Blocked | Needs 4b soak output |
| 5.1   | ⏸ Private repo territory | flywheel process-level parallelism |
| 5.2   | 🟢 Can start | Typed effects annotation — compiler work, self-contained |
| 5.3   | 🟢 Can start | Stage0 bootstrap — weekend-scale |
| 5.4   | 🟢 Can start | Distributed all-reduce — infra work |

## First-to-act list for next session (priority order)

1. **Phase 1d.1 — multi-chunk eval in `lm_v3_chunked.rail`.** Held-out
   fixed-seed 10-chunk average every N=100 steps. This is the ranking
   signal. Without it, Phase 2a tells you nothing (single-chunk loss
   spans 1.4–4+). See master plan Phase 1d.
2. **Phase 1d.2 + 1d.3 — RSS snapshots every 500 steps, 2000-step
   memory-bisect run.** 437 MB → 35 GB growth needs localization.
   Likely small-block arena or an allocation in `m_train_step`
   accumulating across `arena_reset`.
3. **Phase 1d.4 — fix the leak** once bisect identifies the growth
   regime. Likely mirrors `d24340c` (munmap path for bump region) or
   pulls an `arr_new` out of the hot path.
4. **Phase 2a launch** (d=64 → d=128, 2-block, **≤3000 steps**, multi-chunk
   eval). Only meaningful after 1d. Compare 10-chunk mean @ step ≤1500
   vs d=64 baseline captured in 1d validation.
5. **Phase 4a fp16 Option A** — the decision gate passed (1.70× @ N=1024).
   Decide: hand-port kernels (~2-3d) vs drive via Phase 5.0 labrat-style
   agent (~1d + durable infra). User call.
6. **Phase 2d.E snapshot/rollback** — small, independent, can interleave.
7. **Phase 3a/b** if `Ledatic-Empire/rail-training` is clonable on Studio
   — `harvest_clean_v2.jsonl` + `flywheel/harvest_filter.rail` live there.

## What the parallel self_train path can do now

End-to-end live validated on Studio (Qwen3.5-27B-6bit on :8080):

```
./rail_native run tools/train/self_train.rail --parallel 16 --no-retrain
```

- 16 tasks fan out concurrently to MLX
- Batch compile via `--out-prefix` (no /tmp/rail_out race)
- Batch run with 5s per-binary timeout
- Classify per task against expected output
- Up to 3 attempts with error-classified retry prompts (SYNTAX/TYPE/LINKER)
- Harvest successes (still writes to `training/self_train/harvest.jsonl`
  which no longer exists locally post-reorg — harvest fails silently,
  fix that path when needed)

Round wall: ~2 min at N=16 vs ~19 min serial (10.6× on Studio).

## Live-infra knowledge needed for pickup

- **Studio MLX** on localhost:8080 + 10.42.0.2:8080 (same server, bound
  to 0.0.0.0). Running Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-6bit.
  User noted "better models on disc" — Qwen3.6-35B-A3B-8bit already
  runs on :8081 for DDA; other options in `/Users/user/models/`:
  `Qwen3.5-122B-A10B-heretic-v2-2.34bit-msq`, `gemma-4-31b-it-UD-MLX-4bit`,
  `QwQ-32B-4bit`. Model swap = edit plist's `--model` line + launchctl
  reload. Not done this session.
- **`com.ledatic.mlx_studio.plist`** — edit `~/Library/LaunchAgents/com.ledatic.mlx_studio.plist` and `launchctl unload && launchctl load`.
  Latent mlx_lm bug (ValueError in Qwen3.5 linear_attn conv concat) can
  crash the server under concurrent load; auto-restart via KeepAlive
  should cover.
- **No adapter path** on the plist currently — the previous
  `adapter-path /Users/ledaticempire/projects/rail-https/training/adapters_4b_v5_mlx`
  (in `tools/train/mlx_watchdog.sh`) was killed by the 2026-04-20 reorg.
  Adapter for this model is baked into the distilled checkpoint.
- **Parallel session coordination:** parallel Mini session owns
  `tools/train/lm_v3_chunked.rail` (has uncommitted seq=1024 +
  corpus_path edits for the overnight). Don't touch that file until
  overnight is done.

## Critical gotchas from this session (saved to memory)

- **`_`-prefix identifiers don't resolve across import boundaries** (ARM64
  `_` symbol-prefix collision). stdlib/llm.rail's helpers were renamed
  `_llm_*` → `llm_*` this session. See `rail_quirks.md`.
- **ARM64 codegen can emit invalid `as` output for `large_constant * var`
  patterns.** Triggered by `72000 * n` in a smoke. Workaround: let-bind
  the constant first. Not bisected.
- **parallel_shell's max_conc throttle doesn't work on Mac bash 3.2**
  (`wait -n` requires bash 4.3+). Not blocking for N ≤ cores. Documented
  in `ORACLE_PARALLEL_BENCH.md` (private repo now).
- **Match parse "expected decl" bug is likely fixed.** Four targeted
  reproducers all compiled cleanly. CLAUDE.md still warns about it;
  preserve any future failing source.

## Starter commands

```bash
# State check
cd ~/projects/rail-https && git log --oneline -15
git rev-parse HEAD origin/next     # must match

# Parallel session's overnight status
ls -la /tmp/t5_overnight.log
tail -20 /tmp/t5_overnight.log
ps aux | grep t5_overnight_bin

# MLX health
launchctl list | grep mlx_studio
curl -sf http://localhost:8080/v1/models | head -3

# Parallel self_train — first sanity with a tiny fan-out
./rail_native run tools/train/self_train.rail --parallel 4 --no-retrain

# If you need to update rail_native to HEAD (self-compile + codesign)
./rail_native self && cp /tmp/rail_self rail_native && codesign -s - --force rail_native
./rail_native test   # expect 136/137 on Studio
```

## Open decisions (carried from today)

1. **`&&` / `||` short-circuit** — user: "notsure" today. Three options
   (change semantics, add `&?`/`|?` alternates, lint-only). Master plan
   Phase 3c work item.
2. **fp16 Option A** — scoping doc `MIXED_PRECISION_SCOPE.md` recommends
   fp16 Metal kernels (2–3 days, contained risk) this week. User flagged
   "everything this week" for fp16. **2026-04-20 PM: probe measured
   1.70× at N=1024, 1.92× at N=2048 — passes the 1.6× decision gate.**
   Open sub-decision: hand-port vs agent-driven (Phase 5.0 labrat).
3. **Phase 5 stretch priority** — not chosen. Master plan ranks 5.1 →
   5.2 → 5.3 → 5.4 by leverage; 5.1 lives in private repo.
4. **Model swap on mlx_studio** — "better models on disc" noted today.
   Current Qwen3.5-27B-6bit works; swap is one edit + reload.

## What NOT to touch without coordination

- `tools/train/lm_v3_chunked.rail` — parallel session's training target.
- `stdlib/bpe.rail` + `stdlib/tokenizer.rail` — Stream 1 territory.
- `rail_native` binary — toolchain-local to Studio; never commit from
  Studio. If you refresh it via self-compile, re-codesign after `cp`.
- `~/Library/LaunchAgents/com.ledatic.mlx_studio.plist` — modified this
  session (bind changed to 0.0.0.0). Further edits: warn user before
  reloading if DDA on :8081 might be affected.
