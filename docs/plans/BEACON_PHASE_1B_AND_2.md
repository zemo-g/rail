# Beacon Phase 1-B + Phase 2 — Plan with Risk Analysis

**Status:** PLAN, not yet executed. Phase 1-A (live `renice +10` + plist `Nice=10`) already shipped 2026-05-14, PID 11325 running NI=10.

**Goal restatement (user words):** "ensure the beacon is smooth and steady on the mini." Constraint: keep CPU + f64 — the 10⁻¹⁵ conservation claim is load-bearing for the "physics, not theater" voice on ledatic.org.

---

## What we actually know about the current beacon

- `tools/plasma/mhd_beacon.rail:114` — `beacon_loop` recurses with no throttle. `target_fps = 4` at line 28 is dead documentation, never read.
- `stdlib/mhd_kernel.rail:212` — `mk_lxf_loop` walks 16384 cells (128×128) in one tail-recursive pass. Each cell calls `mk_lxf_update_cell` → 4 flux calls (x±1, y±1) → 6 field updates → ~24 `float_arr_get` + 6 `float_arr_set`. Scalar `fadd/fmul` per op.
- One frame = `steps_per_frame = 4` substeps. Each substep = 1 full LF pass.
- The `fxr/fxl/fyu/fyd` scratch buffers (6 floats each) are caller-owned and reused per cell — this matters for parallelization.
- Live observation post-renice: PID 11325 is at 99.8% CPU on one perf core, 10-min uptime, niced but still pegging.

---

## PHASE 1-B — Real fps throttle

### Mechanism
Use the existing `stdlib/time.rail` `wait n` primitive (FFI nanosleep via libSystem on macOS / syscall #101 on Linux ARM64). No fork, no shell, no leak.

### Code change (4 lines)
```rail
-- mhd_beacon.rail
import "stdlib/mhd_kernel.rail"
import "stdlib/time.rail"             -- NEW

target_fps = 1                          -- was 4 (dead var); now live

-- In beacon_loop, line ~147, BEFORE the recursive call:
let _ = wait (1.0 / to_float target_fps)
beacon_loop buffers p2 ctx buf coeffs fxr fxl fyu fyd (frame_id + 1) max_frames
```

### Deploy
1. `cd ~/projects/rail-https && ./rail_native tools/plasma/mhd_beacon.rail` — confirms compile.
2. `launchctl bootout gui/$(id -u)/com.ledatic.mhd && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ledatic.mhd.plist`
3. Tail `~/.ledatic/logs/mhd.log` — frame N+1 should appear ~1 s after frame N.
4. Watch `/tmp/plasma_live.bin` mtime — should advance every ~1 s, not every ~0.1 s.

### What could go wrong — Phase 1-B
1. **`to_int`/`to_float` conversion ambiguity.** `1.0 / to_float target_fps` should resolve cleanly because `target_fps` is an int literal and `to_float` is float-typed. But CLAUDE.md flags "Cross-function *parameter* inference still requires explicit annotations" — if Rail mistypes the result of `wait`, we get a runtime crash or no-op. **Mitigation:** test compile produces no `WARNING [typecheck]` lines for this construct; verify with a 5-second hand-run before deploying.
2. **`foreign sleep` precision on macOS.** macOS's nanosleep is generally honored to ~1 ms but not strictly real-time. At 1 fps the jitter is invisible; if we ever push to >30 fps it would matter. Not a blocker here.
3. **Throttle interacts with FIFO backpressure.** Currently `run_packer` is `write_file "/tmp/mhd_beacon/ready" "1\n"` which blocks until the daemon reads. If the daemon is slow, beacon is already throttled. Adding `wait 1.0` on top is fine — they don't conflict, they compose. The 1 s sleep dwarfs any FIFO delay.
4. **Chain attestation cadence.** Public ledatic.org/plasma consumes the beacon. If anything downstream was assuming ≥1 fps, dropping to exactly 1 fps could starve it. **Mitigation:** check the Pi witness chain after deploy — it should keep verifying without lag. Roll back is one-line revert + recompile.
5. **Conservation regression — none expected.** This change adds wall-clock delay; the math is untouched. divB and Δm should remain at 10⁻¹⁵.
6. **Compile time hits an arena limit.** Beacon source is small (~200 lines); adding one import is negligible.
7. **`wait` on negative/zero input.** If `target_fps` is somehow ≤ 0 by typo, `1.0 / 0` → inf → `nanosleep` traps or sleeps forever. **Mitigation:** keep `target_fps = 1` literal, no user config exposure.

**Verdict:** Phase 1-B is low-risk, well-bounded. Estimate 30 min including validation.

---

## PHASE 2 — Honest assessment

The original sketch ("parallelize across 4 cores + NEON for 6–8×") had **two false assumptions:**

1. **Rail's GC is cooperative single-threaded.** `spawn_thread`/`join_thread` exist as compiler builtins (compile.rail:2861) but `stdlib/parallel.rail:3` explicitly warns the runtime is one OS thread + one GC arena. Naive in-language threading corrupts state. Process-level parallelism is the only safe path.
2. **No NEON autovectorization.** `tools/compile.rail` emits scalar `fadd d0,d1,d0` per float op. The compiler does not emit `fadd.2d` (paired d-register). Hand-coding NEON would require extending the compiler with inline-asm support.

So the realistic Phase 2 options are:

### Option A — Single-thread hand-optimization (recommended)

**What:** Reduce per-cell overhead in `mk_lxf_loop`. Concrete moves:
1. Replace `(i % mk_nn, i / mk_nn)` decomposition with explicit `(x, y)` counters incremented in tail call. Saves 2 divisions/cell × 16384 cells × 4 substeps × N fps.
2. Inline `mk_lxf_update_fields` into `mk_lxf_update_cell` to remove the f-loop recursion (6 iterations becomes 6 straight-line statements).
3. Pre-compute `mk_get state f (x-1) y` etc. once per (x,y) and reuse across the 6 field updates (currently `mk_get` is called inside the f-loop, so we'd compute the neighbor lookups 4 times redundantly).
4. Inline `mk_x_flux`/`mk_y_flux` to avoid 4 function-call entries per cell.

**Realistic gain:** 1.5–2.5× same-core speedup. Combined with Phase 1-B's 1 fps throttle, this means CPU drops from current ~100% on one core to ~10-15% on one core. That IS the "smooth and steady" outcome.

**Time:** ~3-4 h focused, with byte-exact conservation validation against baseline.

### Option B — Subprocess fan-out (defer)

**What:** Spawn 4 long-running Rail workers, each owning a 32-row band. Halo exchange via mmap'd shared file. Coordinator does barrier-per-substep (4 barriers/frame × 4 substeps = 16 sync points).

**Why defer:** ~6 distinct sub-features to build (shm_open binding doesn't exist yet; halo protocol; barrier/semaphore IPC; per-worker arena management; worker health-check; failure recovery). 12-20 h realistic. The complexity-vs-gain ratio is worse than Option A.

### Option C — Phase 1-B only

If Phase 1-B alone drops CPU to a comfortable floor (and it should — 1 fps × current per-frame compute is plausibly 10-15% CPU duty cycle), Phase 2 may not be needed at all. **Defer Option A until we have measured post-1-B baseline.**

---

## What could go wrong — Phase 2 Option A (hand-optimize)

If we do go ahead with Option A, here's the failure surface:

1. **Float self-loop TCO regression.** CLAUDE.md: "Float self-loop TCO: Deferred — body_has_float guard prevents int-TCO corruption but float-specific d8-d15 TCO not yet implemented." If we restructure `mk_lxf_loop` to carry float state in addition to int counters, we may lose TCO entirely → stack overflow on 16384-cell loop. **Mitigation:** keep float state in heap-allocated `float_arr` (already done); only int counters change. Verify with `objdump -d /tmp/rail_out | grep -A 5 mk_lxf_loop` that the tail call compiles to `b mk_lxf_loop` not `bl`.
2. **Conservation drift from reorder.** Floating-point `(a + b) + c ≠ a + (b + c)` in the last ULP. Reordering the 6-field updates or the 4-neighbor average changes which bits round. divB might shift from 10⁻¹⁵ to 10⁻¹³. **Mitigation:** the pre-change baseline log captures Δm/divB across 1000 frames; post-change must stay within the same band. If it drifts, partial-revert until we find the offending statement.
3. **Register pressure from aggressive inlining.** ARM64 has 32 d-registers but Rail uses d0–d7 for args, d8–d15 callee-saved, scratch in d16+. Inlining 6 field updates × 4 neighbor reads = up to 24 simultaneous f64 values. The compiler will spill. **Mitigation:** measure cycles/cell BEFORE committing. If inlining makes it slower (more spills than the function-call overhead it removes), revert that step.
4. **`mk_get` inlining might break the type checker.** `mk_get state f x y` does `float_arr_get state (mk_idx f x y)`. If we inline that and the type-inference can't tell `mk_idx` returns int, we get a warning. **Mitigation:** the existing `mk_idx` callsites already work; inlining doesn't change the type signature.
5. **Arena fragmentation under long runs.** Even with `arena_mark`/`arena_reset` per frame, if our inlined hot loop creates new transient float arrays per cell (e.g. a temporary `[avg, dfx, dfy]`), we'd see 16384 small allocs/cell × 4 substeps/frame. Per memory: "rail-https/CLAUDE.md ... 512MB bump arena." 16384 × 24 bytes = 384 KB/substep — fine, but if we double or triple it the GC starts grinding. **Mitigation:** all `let avg = …` style bindings should be scalar floats in registers, not heap tuples. Check the codegen.
6. **Compile-time pathology.** Memory feedback: "Rail compile-time pathologies — importing both anthropic_client.rail AND slack_client.rail hangs the compiler." `mhd_beacon.rail` only imports mhd_kernel + (new) time. Should be safe but watch for new hangs after edit.
7. **Phase 2 makes Phase 1-B redundant.** If Option A gets per-frame compute down to 50 ms, the 1 fps throttle would mean 50 ms compute + 950 ms sleep — 5% duty cycle. We'd be paying a sleep that we no longer need for relief. **Mitigation:** Phase 1-B is still useful as a cadence cap (predictable 1 frame/sec for the public viewer), but the user might want to revisit target_fps after Option A lands.
8. **Self-compile fixed-point check.** Per CLAUDE.md project root: "After modifying Rail compiler codegen or adding new language features, always run the full test suite AND verify the self-hosting fixed-point before considering the task done." We're NOT modifying compile.rail — just an app and one stdlib import — so this rule doesn't strictly fire. But touching stdlib/mhd_kernel.rail (which IS imported by other things, like `tools/deploy/gen_plasma_landing.rail`) means we should run `./rail_native test` to confirm 137/137 still pass.

---

## Cross-cutting risks

1. **Public surface stays green during the deploy.** ledatic.org/plasma is live. If we bork the beacon, the public viewer shows stale frames. **Mitigation:** stage in a sibling repo (`~/projects/rail-https-staging` worktree), test against `/tmp/plasma_live_test.bin`, then atomic swap. OR accept ~30s of stale frames during bootout/bootstrap (which is what we did for Phase 1-A — the prior beacon froze for ~5s, no public outcry).
2. **Attestation chain continuity.** Pi witness signs each beacon pulse. A daemon restart resets the chain to a fresh pulse_id. The chain itself is fine (each pulse is independently signed) but cross-day verifiers may notice the discontinuity. Reilly has shipped these restarts many times; consensus pattern is "tag the restart in the chain ledger."
3. **Self-trained model regressions.** If `mhd_kernel.rail` is also called by training corpora gen (`tools/deploy/gen_plasma_landing.rail` or similar), changing semantics could shift downstream data. **Mitigation:** grep for `mk_lxf_step_into`/`mk_lxf_step` callsites before touching.
4. **Bus factor on this code.** Beacon kernel was last touched 2026-05-02 for the RSS leak fix. Anyone (including future-Reilly) who picks up the kernel after our changes needs to be able to reason about the new structure. **Mitigation:** keep semantic equivalence with current loop — same cell visit order, same operation order. Only mechanical inlining + counter restructure.

---

## Recommended execution sequence (revised)

1. **Ship Phase 1-B** (30 min). Single source file, one import, ~4-line diff, low risk.
2. **Measure post-1-B baseline** (15 min). Sample CPU%, frames-per-sec, divB/Δm across 200 frames.
3. **Decision point:** If CPU is now under 20% on one core and the user calls it good — STOP. We're done.
4. **If user still wants more headroom:** Phase 2 Option A in a *separate* session, with its own plan doc + worktree + rollback path. Not a swarm — sequential, careful, byte-exact validation.

---

## Why not a swarm?

The original "execute with a swarm" instruction made sense for the parallel scenario (multiple independent build tasks). Given Phase 2 has collapsed to a single sequential refactor of one file with byte-exact validation requirements, a swarm offers no real speedup and adds coordination overhead. Phase 1-B is a 4-line change — also single-threaded work.

The honest answer: dispatch one careful build pass for Phase 1-B now, then re-evaluate. Save the swarm for genuinely parallel work (e.g., porting both Phase 1-B and the Studio beacon equivalent simultaneously, if Studio has one).
