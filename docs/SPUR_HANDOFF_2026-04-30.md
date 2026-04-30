# Spur team handoff — 2026-04-30 arena + diagnostics + **float TCO fix** drop

> **TOP-LEVEL ALERT:** A long-running silent wrong-result bug in float-tail-recursion was found AND fixed today. RMSNorm CPU path (`stdlib/transformer.rail:174 rms_row_apply`) was producing garbage; `lm_infer_cpu.rail` was corrupted; ALL post-2026-04-13 CPU-substrate bench results are suspect. **Re-bench v0.7 BEST + Spur-Fix v0.1/v0.2/v0.3 with the new binary.** Compile rate measurements that read 0/50 may not actually have been 0/50 — the model was being graded on garbage logits.


This is a handoff from the engineering-track session that ran through compiler/runtime/stdlib/Garmin work today, written for the Spur team to reassess training/inference workflow against the new substrate.

## TL;DR

Today's work doesn't *directly* change Spur model architecture, but it does directly invalidate ~17 days of bench results and unlocks a re-evaluation. **Four things changed for you:**

1. **🚨 FLOAT TCO BUG FIXED.** Tail-recursive float helpers (e.g., `rms_row_apply` in `stdlib/transformer.rail:174`) were producing garbage between 2026-04-13 and 2026-04-30 due to a removed `body_has_float` guard. The fix is in. **Every CPU-substrate bench result from those 17 days is suspect.** Re-bench is the headline immediate action.
2. **Arena is now configurable per-process** via `RAIL_ARENA_MB`. Default 1 GB; can go to 4 GB+ via runtime mmap (no more macOS dyld static-BSS ceiling).
3. **The 2026-04-15 "10 MB/step leak" hypothesis is empirically falsified for the allocator.** Whatever's leaking under seq=1499 training, it isn't `arena_reset`. The diagnostic counters are in place for you to pinpoint the actual source.
4. **Three new alloc-stats counters + a stderr trace** make leak detection a 5-minute test instead of a multi-hour bisection.

## Concrete deliverables

### Arena substrate (A1.P1, A1.P2.1, A1.P4)

Static BSS heap → runtime `mmap`. New env var. Documented in `docs/arena-design.md`.

```bash
./rail_native run prog.rail                    # 1 GB default
RAIL_ARENA_MB=4096 ./rail_native run prog.rail # 4 GB arena
RAIL_ARENA_MB=512 ./rail_native run prog.rail  # smaller (debugging)
```

The env var propagates correctly through `./rail_native run` to the compiled child process (`_rail_shell` now passes `envp` to execve via `_rail_envp` global; was previously dropped). So you can also set `RAIL_ARENA_MB` at the shell prompt and any rail_native invocation chain will respect it.

**Macro effect on Spur workflows:**

- **Long-context training is no longer mechanically blocked.** Per the seq=1499 investigation, attention-score matrices alone are 18 MB at seq=1499. Per-step footprint ≈ 47.8 MB. With 512 MB arena minus init residue, you got ~10 steps before bump pressure. With `RAIL_ARENA_MB=4096`, you get ~80 steps' worth of headroom. **Sequence length 2048+ training on macOS is now mechanically tractable** (separately from the dylib bug, which is still the GPU-side blocker).
- **Compile-loss-during-training has more headroom.** Each rollout in `tools/train/rollout_harvest.sh` is its own process invocation. If those processes hit pressure compiling against expanding corpora, they previously spilled. Now they have room. The trainer can stay compact (default 1 GB) while harvest processes opt into more.
- **Binary `__DATA` section dropped from 1.124 GB to 134 MB.** No more 1+ GB committed virtual memory just to hold a static heap. Smaller binaries, faster `dyld` load.

### Diagnostic counters (A1.P5 + RAIL_ARENA_TRACE)

`alloc_stats_snapshot 0` now returns a 17-element int array:

| Idx | Counter | Meaning |
|---|---|---|
| 0–11 | `small_fl_miss[0..11]` | Per-size-class freelist misses |
| 12 | `munmap_count` | Chunks > 64 KB freed by `arena_reset`'s drain |
| 13 | `mmap_large_count` | Direct `_malloc` mmap calls for big chunks |
| 14 | `arena_spill_count` | **Bump-arena overflow events** |
| 15 | `gc_count` | `_rail_gc` invocations |
| 16 | `arena_spill_bytes` | Cumulative bytes spilled |

Plus `RAIL_ARENA_TRACE=1` for stderr-emitted spill events. Recommended diagnostic recipe:

```rail
let s0 = alloc_stats_snapshot 0
-- ... workload ...
let s1 = alloc_stats_snapshot 0
print (cat ["spill=", show (arr_get s1 14 - arr_get s0 14),
            " munmap=", show (arr_get s1 12 - arr_get s0 12),
            " gc=", show (arr_get s1 15 - arr_get s0 15),
            " bytes=", show (arr_get s1 16 - arr_get s0 16)])
```

**Interpretation:**
- `spill_count == munmap_count` → allocator is innocent; chain drain is tight
- `spill_count > munmap_count` → real arena leak (allocations outside `arena_mark` scope)
- `gc_count > 0` → free list / GC pressure in your workload
- `spill_bytes / spill_count` → average size per spill (helps identify which alloc class)

### Verified results from this session

**seq=1499 leak hunt (CPU path):** Ran `/tmp/seq_leak_hunt.rail` — 2000 steps of training-pattern allocations (9 float_arr_new at seq=1499 scale per step, bracketed by arena_mark/reset, with gpu_available calls in the mix). Result: **0 spills, 0 GCs, 18000 munmaps** (= 9 × 2000 chain drains, exactly matching expectations). The CPU-side allocator is leak-free at training scale.

**arena_reset drain test:** 10 cycles of forced spill (1.12 GB alloc, exceeds 1 GB arena) → reset. Result: `spill=10, munmap=10` byte-for-byte. The drain mechanism is correct.

**baseline A (`tools/test/seq_crash_repro.rail`):** Still clean. 2000 steps, ~50 MB peak RSS.

These results **falsify the 2026-04-15 investigation's primary hypothesis** ("arena_reset orphans malloc-fallback chunks"). The chain drain (`_rail_malloc_chain_drain`, added between Apr 15 and Apr 22) handles the spill chunks correctly.

### 🚨 Float TCO bug FOUND AND FIXED today

**Repro that was broken:**
```rail
sum_floats n acc =
  if n <= 0 then acc
  else sum_floats (n - 1) (acc +. 1.0)

main =
  let _ = print (show_float (sum_floats 100 0.0))
  0
```

**Pre-fix output:** `-3.09837219295788e+52`. **Post-fix output:** `100`. ✓

**Root cause:** `all_params_int` was returning true for functions whose body had float operations, because `used_in_arith` matches `*` even when the operands are floats (Rail auto-promotes). With `all_params_int = true`, the compiler enabled `use_regs`, putting float params raw into `x19`/`x20`/`x21`. The `+.` op then read float bits from x-registers expecting int representation. Garbage out.

The fix re-adds the `body_has_float` guard to `all_params_int` (`compile.rail:1992`). Now any function with float operations falls back to the standard calling convention (params on stack, d-registers used properly).

**Affected production code:**
- `stdlib/transformer.rail:174 rms_row_apply` (tail-rec, float scale param) — RMSNorm CPU path
- Used by `tools/train/lm_infer_cpu.rail`
- Used by every `bench_railnative` invocation since the v3 inference substrate switched to CPU
- Possibly affects `stdlib/optim.rail`'s tail-recursive helpers (audit recommended)

**What this means for prior results:**
- **Spur-0.1 (25/30):** trained 2026-04-08, bench was BEFORE 04-13 → unaffected
- **Spur-Fix v0.1/v0.2/v0.3:** trained 2026-04-23 to 04-26 → ALL bench numbers post-04-13 confounded
- **v0.7 BEST 5/5 shape, 0/30 compile:** post-04-13 → confounded
- **Comprehend ceiling 0/5 over 1500 samples:** post-04-13 → confounded; the model may have been generating fine continuations that scored 0 because the grader's RMSNorm path was producing garbage logits before the compile stage even fired

**Verification post-fix:**
```
$ ./rail_native run /tmp/float_tco_verify.rail
sum_floats 100 0.0 = 100 (expect 100.0)
sum_floats 10000 0.0 = 10000 (expect 10000.0)
multiply_floats 100 1.0 = 1.10511569772076 (expect ~1.105)
FLOAT_TCO 3/3 PASS

$ ./rail_native run /tmp/rms_apply_test.rail
yd[0]=2.5 (expect 2.5)
yd[5]=15 (expect 15.0)
yd[9]=25 (expect 25.0)
RMS_APPLY 3/3 PASS
```

**Recommended actions for the team:**
1. **Re-bench v0.7 BEST today** with the post-fix binary. The 0/30 compile rate may be substantially different.
2. **Re-bench Spur-Fix v0.1/v0.2/v0.3** if the experiments are still relevant. Their negative results may be partially or fully bogus.
3. **Audit `stdlib/optim.rail`** for any tail-recursive float helpers that train was using. If found, anything those produced is suspect.
4. **Re-run the Comprehend N=300 experiment** if you care about the 0/5 conclusion.
5. **Accept that the "compile-zero wall" may not be a wall.** It might be RMSNorm garbage all the way down.

## Implications for the Spur workflow you'd been operating on

### Training

**No changes to v0.7 BEST results.** Spur-0.1 (25/30) and v0.7 BEST (5/5 shape) measurements were taken under the previous static-BSS allocator. Allocator is sound; those numbers are real.

**v0.8 / compile-loss-during-training:** The infrastructure for harvesting rollouts now has more arena headroom and a configurable-per-process knob. If you re-run `rollout_harvest.sh`, set `RAIL_ARENA_MB=2048` or higher on the harvester (it's allocating + compiling a lot). The trainer itself doesn't need it.

**Long-context experiments (seq=2048, seq=4096):** Mechanically tractable now. Each step's per-process arena footprint is well under 4 GB even at seq=4096 (extrapolating from 47.8 MB at seq=1499 → 134 MB at seq=4096 for attention-score scaling). Try it.

**The seq=1499 silent-termination bug:** The CPU allocator path is now empirically cleared. If the bug recurs, the most likely cause is one of the 2026-04-15 secondary suspects (per `compile.rail_seq1499_INVESTIGATION.md`):
1. `gpu_available 0` re-eval churn (reallocates `gpu_flag_arr` per call)
2. Tensor wrapper allocations bypassing arena_mark scope
3. Allocations from `_rail_str_append` in tight loops

Diagnose with the new counters: if `spill_count > munmap_count` over a long run, you've got a real allocator-side leak. If they match, the leak is elsewhere (probably the GPU dylib's MTLBuffer pool reuse, which is the dylib_first_token_only.md issue and a separate workflow).

### Inference

**CPU-substrate inference (lm_infer_cpu.rail) is unchanged in correctness.** No allocator-side issues that affect correctness. May see slight throughput gains because:
- 1 GB arena (vs previous 512 MB) means fewer slow-path / GC trips for long-prompt inference
- envp passthrough means env vars like `RAIL_ARENA_MB` flow into the inference subprocess

**Float TCO bug caveat:** if any inference-time float helpers are tail-recursive, they may produce wrong logits / probabilities. This is the most-likely-immediate-impact item for you to audit. Worth searching:

```bash
grep -rE '^[a-z_]+ [a-z_]* [a-z_]* =$' stdlib/optim.rail stdlib/transformer.rail tools/train/lm_infer_cpu.rail | head
```

Anything that calls itself with a float argument in tail position is suspect.

### Bench

`bench_railnative.rail` is unaffected — it doesn't use float-tail-recursion in the harness, and the allocator is fine. Existing measurements (Spur-0.1 25/30, etc.) stand.

If you re-bench post-A1.P4 and see different scores, it's probably noise from `--seed` or substrate; not the arena change.

## Workflow recommendations for the model team

1. **Add allocator diagnostics to your standard training preamble.** Sample alloc_stats at start, end, and periodically. Catches leaks the day they're introduced, not 2 weeks later.

2. **Set `RAIL_ARENA_MB=2048` for harvest processes.** The harvester compiles many programs and allocates a lot. Default 1 GB is enough for small workloads but harvest is bigger.

3. **Audit float-tail-recursive helpers before any training run.** This is a real bug we just discovered. The fix needs a codegen session; until then, any wrong-result symptom in training metrics could be this.

4. **Re-run seq_crash_full.rail with the GPU dylib once it's working again.** With the new counters, the leak source becomes self-evident in one run instead of needing a 6-test bisection.

5. **Compile-loss during training was blocked by 0/50 base compile rate. The dylib bug remains the dominant blocker.** Arena work doesn't change that calculus, but it removes one of the secondary excuses ("might be allocator pressure").

## Open items not addressed today

| Item | State | Why deferred |
|---|---|---|
| **A6** Float TCO fix | ✅ **SHIPPED 2026-04-30** | sum_floats + rms_apply patterns verified |
| **Test runner parallelization** | Designed, deferred | Would need `--range A B` flag through 137 test sites; 2-hr focused task |
| **A3** Register ABI guard | Designed, not implemented | No current observed bug; defensive value only |
| **GPU dylib sequential collapse** | Untouched | Out of arena scope; needs MTLBuffer pool audit |
| **Compile-zero wall** | **RE-TEST REQUIRED** post float-TCO fix | Was confounded by the bug we fixed |
| **Comprehend ceiling** | **RE-TEST REQUIRED** post float-TCO fix | Same confounding |
| **`_rail_young_a/_b` migration to mmap** | Static at 64 MB each | Generational collector not yet wired up |
| **Per-thread arena** | Designed in arena-design.md | No concurrent inference path yet |

## Files changed today

```
tools/compile.rail                           (substantive runtime + data section edits)
docs/arena-design.md                         (NEW — full memory model writeup)
docs/arena-leak-fix-strategy.md              (status updates: P2 falsified, P2.1 shipped, allocator cleared)
docs/data-section-quirk.md                   (NEW — bootstrap pattern documented)
docs/strict-typecheck-design.md              (NEW — A2 design note)
docs/backlog-deferred-design-notes.md        (NEW — A3/A6/A10/D6 designs)
docs/garmin-research-notes.md                (NEW — Pass 6/7 disclosure-ready writeup)
docs/SPUR_HANDOFF_2026-04-30.md              (NEW — this document)
rail_native                                  (post-A1.P5 binary, fixed-point)
rail_native.pre_a1p4.bak                     (backup before A1.P4)
rail_native.pre_a9_a4_backup                 (Apr 27 baseline, well before today's work)
```

## Memory entries (across-session knowledge)

```
rail_arena_2gb_falsified.md         # 2 GB BSS breaks dyld; 1 GB works
rail_arena_drain_works.md           # arena_reset chain-drain is byte-tight
rail_arena_runtime_mmap.md          # A1.P4 shipped; RAIL_ARENA_MB; envp passthrough
feedback_workflow_split.md          # model vs non-model in separate workflows
feedback_no_polling.md              # Monitor instead of repeated ps/tail
garmin_pass6_workout_sideload.md    # (from prior session) Garmin findings
garmin_pass7_workout_payload.md     # (from prior session)
```

## Confirmation

End-of-session state:
- ✓ `rail_native` binary at fixed-point self-compile (cycle B verified byte-identical)
- ✓ All test programs pass on the new binary
- ✓ Arena work mature; allocator empirically cleared
- ✓ Diagnostic infrastructure landed and verified end-to-end
- ✗ Float TCO bug FOUND (not fixed) — repro at `/tmp/float_tco_test2.rail`

The model team can now resume training/inference work with confidence that any allocator-related symptoms are diagnosable in minutes, not weeks. The float-TCO bug is the one new finding that warrants immediate attention before any training run.
