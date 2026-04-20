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
- **Parallel Mini session running Phase 1c T5 overnight** — d=64 × 2-block
  × seq=1024 × 540 KB corpus, ~12,000 steps / ~3.5 h wall. 500-step
  staging showed clean warmup (8.40 → 3.15 in 100 steps) then plateau
  at 3.1–3.3. Overnight establishes baseline loss + resolves plateau-
  vs-floor. Not in my lane; check `/tmp/t5_overnight.log` + the parallel
  session's own handoff if present.

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
| 1c    | 🏃 Running | Parallel session overnight on lm_v3_chunked.rail |
| 2a    | ⏳ Blocked | Waits on 1c baseline loss curve |
| 2b    | ⏳ Blocked | Waits on 2a |
| 2c    | ⏳ Blocked | Waits on 2a/b |
| 2d    | ✅ DONE | Structurally + 5.31× batch + 10.6× N=16 round — validated live |
| 3a    | ⏳ Blocked | `harvest_clean_v2.jsonl` lives in private `rail-training` repo |
| 3b    | ⏳ Blocked | Needs 3a + `flywheel/` code (private repo) |
| 3c    | ✅ DONE | Cleanup done; match parse bug non-reproducible in current HEAD |
| 4a    | ✅ DONE | Scoping doc shipped — decision pending from user |
| 4b    | ⏳ Blocked | Needs 2a/b trained checkpoint + harvest_clean_v2 |
| 4c    | ⏳ Blocked | Needs 4b soak output |
| 5.1   | ⏸ Private repo territory | flywheel process-level parallelism |
| 5.2   | 🟢 Can start | Typed effects annotation — compiler work, self-contained |
| 5.3   | 🟢 Can start | Stage0 bootstrap — weekend-scale |
| 5.4   | 🟢 Can start | Distributed all-reduce — infra work |

## First-to-act list for next session (priority order)

1. **Read parallel session's 1c result.** `/tmp/t5_overnight.log` +
   `training/rail_native/T5_OVERNIGHT.md` if committed. Loss curve
   resolution — plateau at 3.1–3.3 or descent below? This is the single
   biggest decision input for Phase 2a.
2. **Confirm MLX :8080 is still up** on Studio. `launchctl list | grep
   mlx_studio` and `curl -sf localhost:8080/v1/models`. MLX crashes have
   been observed under concurrent load; if down, `launchctl load ~/Library/LaunchAgents/com.ledatic.mlx_studio.plist`.
3. **Decide Phase 2a launch** (width d=64 → d=128, 2-block). Single-line
   edit to `tools/train/lm_v3_chunked.rail`. Only proceed if the 1c loss
   curve shows capacity bottleneck (plateau ~3.0+). If 1c dropped well
   below 3.0, consider depth up first (2b).
4. **If Phase 3a/b wanted:** confirm with user where
   `Ledatic-Empire/rail-training` is cloned locally (or clone it) and
   wire up paths. `harvest_clean_v2.jsonl` + `flywheel/harvest_filter.rail`
   are both in that repo.
5. **If waiting on training runs + no 2a/3 decision yet:** pick a
   Phase 5 stretch item that's self-contained. 5.2 (typed effects) is
   best-scoped; 5.3 (Stage0) and 5.4 (all-reduce) are weekend-scale.

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
  `adapter-path /Users/ledaticempire/projects/rail/training/adapters_4b_v5_mlx`
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
cd ~/projects/rail && git log --oneline -15
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
   "everything this week" for fp16 — awaiting go on Option A.
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
