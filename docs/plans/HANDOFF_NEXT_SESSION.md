# Handoff — autonomous bench + speed improvements

**Goal**: ship at least one bench-rate improvement and one speed/quality
improvement for Spur or Rail substrate. Run autonomously; only stop and
write a fresh handoff when one of the **STOP conditions** below fires.

**Branch state at handoff**: `next` at `589fce1`, pushed to `origin/next` via
Mini relay. 137/137 tests green. `tools/diagnose/forward_dump_{cpu,gpu}_bin`
rebuilt and tracked. `--corpus` flag on the dump bins + `lm_infer_cpu`.
`stdlib/checkpoint.rail::check_vocab_matches` wired in.

---

## Read first (in order, ~5 min total)

1. `MEMORY.md` index — skim the most recent entries
2. `vocab_embedding_shape_mismatch_2026-05-10.md` — the closing finding
3. `divergence_map_2026-05-09.md` — the prior interpretation (now superseded)
4. `rail_join_O_n2_fixed.md` — last session's headline systems win
5. `feedback_endurance_climb.md` + `feedback_local_no_budget.md` — pace + budget norms
6. `studio_panic_pattern.md` — what NOT to stack

## Current state (what's true now)

- **GPU is the substrate oracle** for inference (CPU substrate has a
  latent compile.rail codegen bug — see open item #1).
- `_rail_join` is now linear (200× memory, 120× speed on big joins).
- `forward_diff_analyze.sh` works end-to-end on /tmp dumps; both bins
  refuse to run on vocab-drifted ckpts via `check_vocab_matches`.
- V mappings:
  - `smoke_v54_repro` / `bq_s200_repro` → `training/corpora/spur_compile_back_quarter.txt` (V=93)
  - `halfB_s5555_repro` / `halfB_s7777_fresh` → `training/corpora/spur_compile_half_b.txt` (V=96)
  - default `rail_corpus_stdlib.txt` → V=130 (drift)
- Spur is **demoted** as the project flagship (per `comprehension_cracked_substrate.md`,
  Qwen+spec hits 30/30). But Spur infra wins still compound everything else.

---

## Ranked open levers

### Lever 1 — Fix matmul_i `var * const + var` codegen heisenbug (HIGH ROI; ~1-3h)

**Symptom**: `tools/diagnose/forward_dump_cpu_bin` produces deterministic
garbage for x_embed (0.567272 instead of correct 0.020599) **even with
matched corpus, even with verified-correct inputs, even with literal
integer dims passed to matmul_i**. Same matmul_i call in
`/tmp/matched_smoke.rail` produces correct output. Bug is bin-context-
dependent — almost certainly the `kk * n_dim + j` codegen pattern in
`stdlib/tensor.rail::matmul_k` triggered by the bin's heap layout.

**Likely fix** (test first, then commit if 137/137 stays green AND CPU
dump matches GPU dump on x_embed):

```rail
matmul_k a_data b_data acc_arr k_dim n_dim i j kk =
  if kk >= k_dim then 0
  else
    let av = float_arr_get a_data (i * k_dim + kk)
    let b_off = kk * n_dim                  -- BREAK the multiply-add
    let bv = float_arr_get b_data (b_off + j)
    let cur = float_arr_get acc_arr 0
    let _ = float_arr_set acc_arr 0 (cur + av * bv)
    matmul_k a_data b_data acc_arr k_dim n_dim i j (kk + 1)
```

(also same for `matmul_j`'s `i * n_dim + j` write).

**Verify**: rebuild forward_dump_cpu_bin, run with matched corpus, check
that CPU's x_embed[0] matches `w_e[8, 0] = 0.020599365234375`. If yes,
re-run `forward_diff_analyze.sh` — block-residual divergence should
collapse from ~1700 max to <10 max (real fp16 precision drift only).

**Bootstrap**: stdlib change → 1 cycle (per CLAUDE.md table — source-only
logic; no runtime asm constants touched).

**If it fails** (137/137 breaks OR CPU still wrong): try a different
break: precompute the entire row offset `let row_b = a_data + i * k_dim`
outside the loop. If still failing after 2 attempts, file a memory
entry and pivot to Lever 2.

### Lever 2 — Re-bench v54 / spur lineage on GPU substrate with matched corpus (HIGH ROI; ~30-60 min)

After Lever 1 OR independently. The historical bench numbers
(`spur_v54_peak_30pct.md`: 9/30; `spur_ensemble_ceiling_24_of_30.md`)
were measured against CPU substrate with vocab drift — likely
nondeterministic-OOB-driven.

**Run**:
```bash
# Find the bench harness
ls flywheel-local/bench_strip.rail tools/train/parallel_rerank.sh
# Use the GPU substrate (forward_dump_gpu_bin or lm_infer_v3_mixed)
# with --corpus training/corpora/spur_compile_back_quarter.txt
# Bench v54 with N=20 rerank (per memory parallel_rerank_works.md, ~13min wall)
```

**Acceptance**: a numerical comparison of GPU-substrate-with-matched-corpus
bench scores vs the historical CPU-with-drifted-corpus numbers. Either:
- GPU score is HIGHER → ship the new oracle, retire CPU substrate, update
  every "9/30" / "24/30" memory entry with the inverted interpretation
- GPU score is LOWER → confirms the historical CPU numbers were
  OOB-garbage-lucky; ship the GPU number as the honest baseline

Either outcome is a win.

### Lever 3 — JIT lower.rail vreg widening (MEDIUM ROI; ~3-6h)

JIT Phase B (lex-pre-check) was blocked by lower.rail's 10-vreg caller-save
budget. Widening to allow stack-spill on overflow would unblock the lex
gate (modest bench speedup ~1min/run + wall-clock stability win) AND
permit more complex JIT-target programs.

Start in `jit/lower.rail` near the "caller-save vreg overflow" error
(grep for it). Add stack-spill code path. Verify with `jit/test_*.rail`
fixtures (39/39 must stay green per `jit_v1_validated_2026-05-09.md`).

### Lever 4 — Quartz real-event smoke (LOW-MEDIUM ROI; ~1-2h)

Per `tools/desk/README.md` punch list item #3: write
`tools/desk/quartz_event_smoke.rail` that grants Accessibility once,
then prints the next 100 mouse-move events. Validates the ring buffer
+ tap installation under sustained load. The link path already works
(`quartz_smoke.rail` confirms qb_init/qb_shutdown resolve).

Note: real event flow needs a human to grant Accessibility permission
the first time. If the smoke can't run interactively, document that
and stop — don't try to bypass the permission gate.

### Lever 5 — Update inverted memory entries (LOW LIFT, HIGH SIGNAL; ~30 min)

Per `vocab_embedding_shape_mismatch_2026-05-10.md` "What this means for
past memory entries", these have inverted causal interpretations:
- `cpu_inference_substrate.md`
- `gpu_bench_substrate_failed.md`
- `v54_fp32logits_partial_lift.md`
- `compile_zero_wall.md`

Add a "**SUPERSEDED 2026-05-10**" header to each pointing at the new
findings. Don't rewrite — preserve the historical reasoning + flag
the inversion. Update MEMORY.md index lines accordingly.

This unblocks future readers from pursuing the wrong threads.

### Lever 6 — Bisect bin-context corruption (LOW ROI without Lever 1 outcome)

If Lever 1's let-bind fix doesn't work, this is the deeper investigation:
binary-search what allocation in `forward_dump_cpu`'s main triggers the
matmul_i corruption. Remove half of main's setup steps, see if the bug
disappears. Repeat. ~2-3h.

Probably superseded by Lever 1 fixing the underlying codegen.

---

## Reusable commands

```bash
# Re-build a substrate bin
./rail_native tools/diagnose/forward_dump_cpu.rail && cp /tmp/rail_out tools/diagnose/forward_dump_cpu_bin

# Run forward_diff with matched corpus on smoke_v54_repro_best
rm -f /tmp/forward_dump_{cpu,gpu}/*.txt
tools/diagnose/forward_dump_gpu_bin --prefix runs/smoke_v54_repro/checkpoints/smoke_v54_repro_best --prompt "main = " --corpus training/corpora/spur_compile_back_quarter.txt
tools/diagnose/forward_dump_cpu_bin --prefix runs/smoke_v54_repro/checkpoints/smoke_v54_repro_best --prompt "main = " --max 1 --corpus training/corpora/spur_compile_back_quarter.txt
tools/diagnose/forward_diff_analyze.sh

# Verify matmul_cpu bug in isolation (smoke that SHOULD work)
./rail_native run /tmp/matched_smoke.rail   # produces 0.020599 — correct

# Bench harness
ls flywheel-local/  # find bench_strip.rail and parallel_rerank.sh

# Test suite (must stay green after any stdlib change)
./rail_native test  # 137/137

# Self-compile + cycle check (after stdlib changes)
./rail_native self && cmp rail_native /tmp/rail_self && echo "byte-identical"

# Memory peak measurement
/usr/bin/time -l <command>

# Push (relay handles GitHub)
git push origin next
```

---

## Heisenbug & gotchas

1. **Adding `print` statements changes the bug.** The CPU substrate's
   matmul_i corruption shifts based on heap layout. If you add a probe
   and the bug "disappears", that doesn't mean it's fixed — it means
   the heap shifted. Always verify fixes by READING THE DUMP FILE
   contents (not by adding inline probes).

2. **Stale bins.** Whenever you change a `.rail` source, REBUILD the bin
   (`./rail_native <file>.rail && cp /tmp/rail_out <bin>`). Stale bins
   produce confusing results. Check `ls -la` mtimes if unsure.

3. **`./rail_native run` swallows link errors.** If compilation fails,
   `./rail_native run` may execute a stale `/tmp/rail_out`. Check
   for `as: OK ld: OK` in the compile output before trusting results.

4. **`var * const + var` is the codegen trigger.** Any `float_arr_set
   arr (i * V + j) val` or `float_arr_get arr (i * V + j)` where i, j
   are runtime variables and V is also runtime-variable-but-effectively-
   constant is suspect. Workaround: pre-bind `let off = i * V in ...`.

5. **Studio panics under stacked workloads.** Don't run parallel_rerank
   N=20 and concurrent training. Per `studio_panic_pattern.md`.

6. **Don't cycle the test suite for stdlib-only changes** (1 cycle is
   enough per CLAUDE.md table). Save the 30-60s self-compile budget
   for runtime asm changes.

---

## Commit norms

- Commit per logical change (ship-shape: each commit passes 137/137).
- Commit message format: `<area>: <action> — <one-line outcome>` body
  with concrete numbers + memory pointers.
- Push after each commit (`git push origin next` — relay handles GitHub).
- Update memory entries in `/Users/user/.claude/projects/-Users-user/memory/`
  when findings shift the project picture. Entries are NOT in the rail repo.

---

## STOP conditions (write a fresh handoff and halt)

Stop and write `docs/plans/HANDOFF_NEXT_SESSION.md` (overwriting this) when:

1. **Bench improvement landed** — a measurement that beats the
   `spur_ensemble_ceiling_24_of_30.md` baseline OR establishes a new
   honest baseline on the GPU substrate. Document the number, the
   command that produced it, and the methodology in memory.

2. **Speed improvement landed** — a 2× or better wall-clock reduction
   on a meaningful operation (training step, bench iteration, JIT
   overhead, etc.). Same documentation requirement.

3. **3 consecutive failed attempts on a single lever** — pivot to the
   next lever in the rank. Don't sunk-cost. File a memory entry
   describing what was tried and falsified.

4. **Studio panic risk** — if memory pressure trends toward >50 GB RSS
   on a single process, kill it. Don't stack heavy workloads.

5. **137/137 breaks** — revert immediately. Don't push broken state.

6. **Stuck after 30 min on something not in the lever list** — write up
   the surprise + what was investigated, hand back.

When you stop, the new HANDOFF should:
- Update the "Branch state at handoff" line
- Update "Current state" with what changed
- Re-rank the levers based on what you learned
- Add any new gotchas / heisenbugs to the gotchas section

---

## What success looks like

A clean handoff with at least:
- One bench number (with command + corpus + ckpt) on the GPU substrate
- One commit improving either matmul_cpu correctness OR a wall-clock
  speedup elsewhere
- Updated memory entries reflecting the inverted CPU/GPU oracle story
- 137/137 still green
- Pushed to origin/next
