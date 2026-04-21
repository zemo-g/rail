# Session handoff — 2026-04-21 AM (cold-start drop-in)

**Purpose:** read this + the linked plan/memory files and you can resume
without me. Authored at the end of a 6-hour session that landed Phase
1d, 2a, 5.0, and a precise 1d.4 root-cause diagnosis.

## TL;DR — what's done, what's next, what's blocked

**Done in the last session (8 commits on `next`, HEAD=`e1bd472`):**
- ✅ Phase 1d.1 multi-chunk eval + 1d.2 RSS snapshots in `lm_v3_chunked.rail`
- ✅ Phase 1d.3 2000-step memory bisect (linear 3.15 MB/step confirmed)
- ✅ Phase 1d.4 root-cause LOCALIZED at `tools/compile.rail:2855` — `_free` is a literal `ret` no-op stub
- ✅ Phase 2a d=128 ×2-block × 3000 steps: beats d=64 by 0.12 eval mean, 0.16 min loss
- ✅ Phase 4a decision: agent-driven (labrat) route, not hand-port
- ✅ fp16 probe: 1.70× @ N=1024 — Option A gate cleared
- ✅ Phase 5.0 labrat scaffold + first end-to-end win (1.8× fp16 matmul, iter 1) + prompt v4 + no-op detection + float-compare workaround
- ✅ Phase 5.0b Code-JEPA design doc
- ✅ Phase 2d.E snapshot/rollback primitives scaffolded in `self_train.rail`
- ✅ Stability sweep COMPLETE (2026-04-21 00:03): **4/5 KEPT (80% success)**, real KEEP speedups 1.7/1.8/1.9/1.8 → mean **1.80×**, 22-min wall. Labrat is operationally cheap for kernel ports.

**Top-priority next moves (ordered):**
1. Read the stability sweep result. Decide whether labrat is robust enough to delegate kernel ports.
2. **Transplant the labrat-produced fp16 matmul into production**: copy from `/tmp/labrat_test/fp16_kernel_v1.metal` → add as `matmul_f16` next to `matmul` in `tools/metal/tensor_gpu.metal`, add `tgl_matmul_f16` foreign decl in `stdlib/tensor.rail`, wire `@autoreleasepool` host dispatch in `tools/metal/tensor_gpu_lib.m`. Phase 4a Option A's first kernel goes live.
3. **Phase 2b — 4-block depth.** Master plan recommends `adam_lr_mult_gamma=0.3`. The 2-block `lm_v3_chunked.rail` works; `lm_v3_3block.rail` shows the 3-block extension pattern (mk_block + adams_blocks). Extending to 4 means modifying `m_train_step`'s backward path — that's the chunky bit. ~60-90 min careful edit.
4. **Phase 1d.4 actual fix.** Pick Option A from `docs/plans/1D4_MEMORY_LEAK.md` (true small-block free list at `compile.rail` allocator). ~1 day. Until landed, keep training runs ≤3000 steps so RSS stays ≤10 GB.

**Blocked on private repo or external work:**
- Phase 3a/b — `Ledatic-Empire/rail-training` is on Mini at `~/projects/rail-training/` but not cloned to Studio yet. Sync via scp or set up SSH key for the private repo.
- Phase 4b/c — needs Phase 2b checkpoint first.

## State of the world (run these on session start)

```bash
cd ~/projects/rail
git log --oneline -10                           # confirm HEAD = e1bd472 or later
git rev-parse HEAD origin/next                  # both should match
git status --short                              # uncommitted: lm_v3_chunked.rail, self_train.rail (see below)

# What overnight produced
cat /tmp/labrat_stability_summary               # success rate + mean speedup
tail -50 /tmp/labrat_stability.log              # per-run details
ls -t tools/labrat/transcripts/ | head -10      # all labrat run transcripts

# Verify rail_native still works
./rail_native test                              # expect 136/137 (Studio's gpu_map fail)

# MLX health — labrat depends on this
launchctl list | grep mlx_studio
curl -sf http://localhost:8080/v1/models | head -3
```

## Key files added/modified this session

**Committed:**
- `docs/plans/WEEK_PLAN_2026-04-20.md` — master plan (now includes Phase 1d, revised Phase 2a, Phase 2d.E, Phase 5.0/5.0b stretch)
- `docs/plans/WEEK_PLAN_PICKUP_2026-04-20_PM.md` — yesterday's pickup, now updated with T5-complete state + fp16 probe result
- `docs/plans/CODE_JEPA_5_0b.md` — LeWM-inspired learned-oracle design
- `docs/plans/1D4_MEMORY_LEAK.md` — leak diagnosis with root cause + 4 fix paths (option A recommended)
- `docs/plans/LABRAT_FIRST_WIN.md` — proof of agent-driven kernel port
- `tools/metal/probes/fp16_probe.m` + `README.md` — Option A decision-gate experiment
- `tools/test/match_nest_exhaustive_bug.rail` — preserved parse-bug reproducer
- `tools/labrat/{labrat.rail, researcher.rail, README.md, test_researcher.rail, tasks/fp16_matmul.spec}` — agent scaffold
- `tools/labrat/stability_run.sh` — N-run sweep characterizing labrat success rate

**Uncommitted (Studio-local, user discretion):**
- `tools/train/lm_v3_chunked.rail` — has 1d.1/1d.2 instrumentation (multi-chunk eval at every 100 steps, RSS snapshot every 500). Knobs are currently `d=128`, `max_steps=3000` (Phase 2a config). Reset to `d=64`, `max_steps=2000` if you want to re-run the bisect baseline. The instrumentation itself is GOOD — keep it. If committing, separate the instrumentation from the experimental knobs.
- `tools/train/self_train.rail` — has Phase 2d.E snapshot/rollback primitives added (`harvest_snapshot`, `harvest_rollback`, `harvest_ab_gate`). Not yet wired into the retrain path — that needs `bench_railnative` from the private flywheel/ dir.

**Ephemeral test fixtures (in `/tmp/labrat_test/`, regenerable from doc):**
- `seed.metal` (matmul_f32 only) + `seed.metal.orig` (snapshot)
- `seed_blocked.metal` + `.orig` (matmul_blocked_f32 — for next labrat task)
- `validate_metal.m` + binary — Obj-C harness using `newLibraryWithSource` (Studio has no `xcrun metal`)
- `bench_dyn.m` + binary — runtime-compile bench for matmul
- `bench_dyn_blocked.m` + binary — same for matmul_blocked
- `run_bench.sh`, `run_bench_blocked.sh` — wrappers (labrat passes no args)
- `fp16_spec.json`, `spec_blocked.json` — labrat task specs
- `fp16_kernel_v1.metal` — **the working fp16 matmul kernel labrat produced** (KEEP — this is the Option A artifact for transplant)
- `iter1_response.txt` — the MLX raw response that produced `fp16_kernel_v1`

## Known gotchas (session-fresh additions)

These are also in the `~/.claude/projects/-Users-user/memory/rail_quirks.md`
memory file but worth surfacing:

1. **`_free` is a no-op stub at `compile.rail:2855`** — `let nfree = "_free:\n    ret\n\n"`. All sub-64KB chained_malloc blocks leak forever (the chain drain at line 2657 only munmaps blocks >64KB; the rest call `_free` → no-op). **This is the entire 3 MB/step training leak.** Fix needs a real small-block free list in compile.rail.

2. **Float `>=` codegen segfaults** on `let pass = speedup >= min_speed` even when both are provably float. Type-checker emits a benign `mismatched types 'int' and 'float'` warning. Workaround: route via int by `(x * 1000.0)` and `float_to_int`, then int `>=`. See `tools/labrat/labrat.rail:labrat_step` for the pattern.

3. **Studio has no `xcrun metal`** (CLI tools only, not full Xcode). Don't attempt to install — installing is hours and not needed. The `validate_metal` harness uses `newLibraryWithSource` which is the SAME compile path `tensor_gpu_lib.m` uses in production. Equivalent fidelity.

4. **Negative-form prompt instructions backfire on Qwen3.5-27B-distilled.** "Do not explain" makes the model explain. Use positive-only ("You produce ONE patch per turn") + a worked example. See `lb_prompt` v4 in `labrat.rail` for the working shape.

5. **MLX response parsing — file delimiters leak.** When prompting an LLM with file contents, use markdown code fences (```` ``` ```` ) NOT custom markers like `<<<FILE_END>>>`. The model echoes custom markers into its FIND text. Fences are recognized as meta-syntax.

6. **No-op patches must be detected explicitly.** If FIND text isn't in the source, `str_replace` no-ops, file is unchanged, compile passes (file is still valid), bench fails (kernel missing) — labrat would think "compile-fail" rather than "patch didn't apply". Now detected via `str_find find_t file_text < 0` before `apply_patch`. See `labrat.rail:labrat_step`.

7. **Nested match on multi-ctor ADTs broken at depth ≥2** — parser attaches all `|`-arms to innermost. Reproducer: `tools/test/match_nest_exhaustive_bug.rail`. Workaround: helper fn or single-ctor ADTs.

## Memory pointers (auto-loaded)

- `~/.claude/projects/-Users-user/memory/MEMORY.md` — index
- `~/.claude/projects/-Users-user/memory/session_handoff.md` — operational state, **updated through this session** with full timeline
- `~/.claude/projects/-Users-user/memory/rail_quirks.md` — landmines (added: float `>=`, nested-match)
- `~/.claude/projects/-Users-user/memory/mission.md` — Rail-on-Rail
- `~/.claude/projects/-Users-user/memory/incremental_testing.md` — staging discipline (10 → 50 → 500)
- `~/.claude/projects/-Users-user/memory/init_matters.md` — Kaiming sqrt(2/fan_in) for multi-block

## Concrete first hour, in order

```bash
# 0. Wake-up state
cd ~/projects/rail && git log --oneline -10 && git rev-parse HEAD origin/next

# 1. Did labrat survive the night?
cat /tmp/labrat_stability_summary
# Interpret: if success_rate >= 60%, labrat is reliable enough to delegate.
# If < 40%, prompt v5 needed (look at /tmp/labrat_resp_iterN.txt for failure modes).

# 2. Transplant the fp16 win into production (Phase 4a's first kernel)
diff /tmp/labrat_test/seed.metal.orig /tmp/labrat_test/fp16_kernel_v1.metal
# Confirm the diff is just the matmul_f16 addition — no surprise edits.
# Then add matmul_f16 to tools/metal/tensor_gpu.metal next to existing matmul.
# Re-build libtensor_gpu.dylib (existing build process — check tools/metal/ for the recipe).
# Add tgl_matmul_f16 foreign decl in stdlib/tensor.rail.
# Wire host dispatch in tools/metal/tensor_gpu_lib.m (mirror tgl_matmul_f64's @autoreleasepool block).

# 3. If you have appetite for Phase 2b (4-block):
#    Read tools/train/lm_v3_3block.rail — uses block2 + block2_adams.
#    Clone tools/train/lm_v3_chunked.rail → lm_v3_chunked_4block.rail.
#    Add block2 + block3 + their adams.
#    Extend m_train_step's backward path (the hard part — gradients flow
#    in reverse through 4 blocks; existing 2-block code uses cache0/cache1,
#    extend to cache2/cache3).
#    Adopt adam_lr_mult_gamma=0.3 from stdlib/optim.rail call-site pattern.
#    Stage 10 → 50 → 500 → full (per incremental_testing memory).
#    Multi-chunk eval is already wired — you'll get clean d=128×4block vs d=128×2block comparison.

# 4. Or pick 1d.4 fix (Option A from docs/plans/1D4_MEMORY_LEAK.md)
#    Add a small-block free list at compile.rail. Power-of-two size classes.
#    Test path: re-run /tmp/t5_bisect_bin equivalent at 2000 steps — target flat RSS.
```

## Open user decisions (carried forward)

1. `&&` / `||` short-circuit semantics — still "notsure" since 2026-04-20.
2. Model swap on `mlx_studio` — Qwen3.6-35B-A3B-8bit is on disk; current is Qwen3.5-27B-distill. Bigger model might fix labrat's prompt-v4 success rate if low.
3. Whether to commit `lm_v3_chunked.rail` (instrumentation is good; experimental knobs are noise — split the commit).
4. Whether to commit `self_train.rail` (2d.E scaffold is additive, harmless).

## Live infra state (don't break)

- **MLX :8080** — Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-6bit. Healthy at session end.
- **MLX :8081** — Qwen3.6-35B-A3B-8bit (DDA). Healthy.
- **Studio `rail_native`** — locally bootstrapped, NOT to be committed (toolchain-local). Backup at `rail_native.pre_1a.bak`.

## What you ABSOLUTELY MUST NOT do

- Commit `rail_native` from Studio. It's a different toolchain build and breaks Mini.
- Modify `tools/metal/tensor_gpu.metal` while a training run is using `libtensor_gpu.dylib`. Check `ps aux | grep -E "rail_out|t5_"` first.
- Re-attempt `xcrun metal` install — not necessary (validator path works) and is hours of bandwidth.
- Trust single-chunk loss as a ranking signal. Multi-chunk eval (every 100 steps) is the only reliable ranking signal — it's already wired in `lm_v3_chunked.rail`.

## Late-night addendum (00:00–00:40 EDT)

After the formal handoff was written, ran labrat on two more kernel
ports back-to-back:

- **matmul_blocked**: KEPT @ iter 5, speedup 1.6× (right at gate). Saved
  to `tools/metal/fp16_drafts/matmul_blocked_f16.metal`.
- **matmul_bias_relu**: 0/5 KEPT in v4 (closing-fence echo dominated).
  After **prompt v5** fix (drop all file delimiters, natural text flow),
  v5 retry got real iters (no more no-ops) but plateaued at 1.2–1.3×
  speedup. Conclusion: bias_relu is a harder fp16 target — model
  produces literal half-bias which costs conversion in the inner loop.
  A v5+ task spec should hint "keep bias as fp32 buffer to avoid
  per-cell conversion overhead." Documented in `tools/metal/fp16_drafts/RESULTS.md`.

So tonight delivers **2 production-ready fp16 kernel drafts** (matmul,
matmul_blocked) — the first concrete artifacts of Phase 4a Option A
via the labrat agent. The transplant checklist is in
`tools/metal/fp16_drafts/RESULTS.md`.

**Overnight continuation (00:00–08:30 EDT):** session continued
autonomously. Two prompt iterations (v5, v6) and two new guards
(ambiguity detection, fence-strip in parser) landed. All three
remaining matmul-family kernels delivered:

| Kernel | Task-spec lesson | Speedup | Commit |
|---|---|---|---|
| matmul_blocked   | same as matmul | 1.6× | `b79452b` |
| matmul_bias_relu | **fp32-bias hint** — keeps bias as fp32 to avoid per-cell conversion | 1.8× | `ab1f106` |
| matmul_bias_gelu | fp32-bias + uniqueness hint | 1.7× | `d324f95` |

tensor_relu attempted but plateaued at 1.1–1.2× — unary ops need
vectorized (half4/half8) task specs before labrat hits the gate.
Documented as a limit of the current scaffold. Commit `85ef7d2`.

**End-of-session state: 4 production-ready fp16 kernel drafts** at
`tools/metal/fp16_drafts/`. Phase 4a Option A's matmul sub-family is
done pending transplant + dylib wiring.

Tomorrow's Phase 4a work:

1. Review + merge the 4 drafts into `tools/metal/tensor_gpu.metal`
   (rename existing `matmul`, `matmul_blocked`, `matmul_bias_relu`,
   `matmul_bias_gelu` → `_f32` first).
2. Add `tgl_*_f16` foreign decls in `stdlib/tensor.rail` and host
   dispatch in `tools/metal/tensor_gpu_lib.m` for each.
3. Rebuild `libtensor_gpu.dylib`; `./rail_native test` must still pass.
4. Once those are live, extend `port_kernels.sh` to cover softmax
   family + layernorm + reductions (compute-bound, good labrat fit).
   For unary ops, first revise the task-spec template to require
   half4/half8 vectorization.

## Final commit log this session

```
85ef7d2 labrat: fence-strip in patch parser + tensor_relu findings
d324f95 labrat: prompt v6 (uniqueness hint) + ambiguity guard + bias_gelu port
ab1f106 fp16_drafts: matmul_bias_relu ported — 1.8x with fp32-bias hint
a7b8bcd docs: session handoff — late-night addendum + full commit log
88b2953 labrat: prompt v5 — drop file delimiters entirely
b79452b fp16_drafts: 2 labrat-produced kernels (matmul, matmul_blocked)
4209d8a labrat: chain runner for sequential kernel ports
6b5afae labrat: stability sweep result — 4/5 KEPT (80%), mean speedup 1.80x
ac40c10 docs: session handoff for 2026-04-21 AM — full cold-start context
e1bd472 docs: 1d.4 leak root cause LOCALIZED — _free is no-op stub at compile.rail:2855
4e8b8e2 labrat: prompt v4 (markdown fences) + no-op patch detection
f74ec2a labrat: first end-to-end win (1.8x fp16) + stability sweep runner
d6f37ea labrat: end-to-end working — prompt v3, float-compare workaround, validator path
9c87d2b labrat: autonomous kernel-optimizer agent scaffold (Phase 5.0)
888cafe test: nested-match parse bug reproducer (depth=2, multi-ctor ADTs)
9cc5838 metal: fp16 vs fp32 matmul probe — Option A decision gate
7403d57 docs: Phase 1d (eval discipline + memory bisect), Phase 2a revision, Phase 2d.E + 5.0/5.0b stretch
```

Take care of the model. It's your model now.
