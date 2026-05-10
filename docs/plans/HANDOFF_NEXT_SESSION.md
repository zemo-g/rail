# Handoff — CPU substrate heisenbug ROOT-CAUSED & FIXED at compiler level

**Headline.** The matmul_cpu "heisenbug" that haunted CPU substrate
inference for months is a **compile.rail codegen bug** in the binary-op
fast path: `emit_x1` (line 940-952) silently emitted `mov x1, x0` when
the LHS variable wasn't in the local env. Top-level nullary bindings
like `seq_len = 1024` therefore mis-compiled `seq_len * V` to
`<previous-x0> * V`. After a conditional whose join leaves x0=1 (tagged
0), the multiply yielded 0; x_data was allocated size 0;
fill_prompt_loop OOB'd; matmul_cpu read garbage.

**Fix shipped** (commit `02a6a1d`): refined `both_simple` at line 1460
so non-env LHS V vars take the slow path, where `cg`→`cg2` correctly
emit `bl _<name>` for nullary fns. 2-cycle bootstrap, byte-identical
fixed point, 137/137 green.

Workarounds in `forward_dump_cpu.rail`, `lm_infer_cpu.rail`,
`lm_infer_v3_mixed.rail` were applied first (commit `47e2e21`) and then
REVERTED once the compile.rail fix landed.

`tools/diagnose/cpu_bisect_v_full.rail` retains the TRIGGER LINE comment;
it now PASSES (0.020599) with the conditional present and serves as the
regression test should anyone touch `emit_x1` again.

---

## Current state

**Branch:** `next` at `02a6a1d`. Studio = bare = GitHub.
**Tests:** 137/137 green.
**Substrates (post-fix):**
- CPU substrate (`lm_infer_cpu.rail`, `forward_dump_cpu_bin`) — produces
  correct outputs. `forward_dump_cpu_bin --max 1` on smoke_v54_repro_best
  + matched back_quarter writes `x_embed[0]=0.020599365234375`.
  Generation at --max 60 takes ~78 s on halfB_s7777_fresh.
- GPU mixed substrate (`lm_infer_v3_mixed.rail`) — unchanged correct
  output. The 10/30 baseline (halfB_s7777_fresh + matched + N=20)
  should hold or shift slightly post-fix.

**Memory entries updated:**
- `cpu_substrate_conditional_trigger_2026-05-10.md` — full investigation,
  fix details, regression test pointer.
- `rail_top_level_int_add_bug.md` — marked FIXED, scope broadened from
  "nullary + nullary" to "any binary op with top-level nullary LHS".
- `MEMORY.md` index — both updated.

---

## Bench finding (post-fix evening 2026-05-10)

**The historical 10/30 was inflated.** Re-bench post-fix on
halfB_s7777_fresh + matched corpus = **6/30 (20%)**, not 10/30.
Reason: pre-fix `seq_len * V = 0` (because of the LHS-nullary bug)
made x_data empty → fill_prompt_loop silently OOB'd → matmul read
zeros → model ran on **zero-input prompt** → outputs were driven by
final-layer biases + sampling, not the prompt. That accidentally
compiled at 10/30 for this ckpt. Post-fix the model uses actual
embeddings → real context-aware generation → exposes the model's
actual ability is ~6/30.

Implication: **the entire pre-2026-05-10 bench lineage is suspect**.
Spur-v0.1's 25/30 ensemble, v54's 9/30 single-ckpt, halfB's 7/30 —
all measured through the buggy substrate. Re-bench gives the honest
number. The substrate-thesis 30/30 (naked Qwen + Rail spec) finding
still stands; that bypasses Spur entirely.

**No "regression" to chase. Honest numbers compound; lucky-buggy
ones don't.** The fix stays.

## Re-rank for next session

| Lever | Title | Status | ROI | Notes |
|---|---|---|---|---|
| **A1** | Re-bench CPU substrate at full scale | NEW | HIGH | First HONEST CPU number. CPU should match GPU (~6/30) since both are now correct. If they differ meaningfully, that's a new finding. ~2 hr. |
| ~~A2~~ | Re-bench GPU mixed (sanity) | DONE | — | 6/30 measured. The 10/30 baseline is retired. |
| B | GPU mixed segfault on V=93 ckpts (max≥24) | OPEN | MEDIUM | Was a separate Lever B; now that CPU substrate works, this is less urgent. May want to test if CPU at scale solves the V=93 problem instead. |
| C | Retrain ckpts on V=130 corpus | OPEN | HIGH | `spur_halfB_better_than_full` lineage, ~1-2 hr training + ~25 min bench. Now-honest CPU bench could compare apples-to-apples. |
| D | JIT lower.rail vreg widening | OPEN | MEDIUM | Carried over. `jit/lower.rail:121` allocator hard-fails on 10th simultaneous vreg. ~3-6 hr. |
| E | Quartz real-event smoke | OPEN | LOW-MED | Carried over. `tools/desk/README.md` punch list #3. |
| F | forward_dump_gpu residual leak | OPEN | LOW | Was 141 GB → 11 GB after `_rail_join` fix. Distinct bug; CPU now runs to completion. Lever moved down because CPU dump pipeline works. |

**Recommendation:** A2 first (cheap sanity), then A1 (~2 hr) to get the
honest CPU number. Then revisit which substrate to use as the bench
oracle going forward.

---

## What's NOT broken anymore

- The "matmul_cpu produces deterministic-but-wrong x_embed in real-model
  contexts" finding from `cpu_substrate_bisect_progress_2026-05-10.md`
  is RESOLVED.
- The Lever 1 falsification still holds at the symptom level — those 3
  let-bind decompositions in matmul_k legitimately didn't help. The bug
  was elsewhere.
- The "conditional-in-let-chain trigger" from
  `cpu_substrate_conditional_trigger_2026-05-10.md` is the same bug —
  conditionals were just a way to leave x0=1 (tagged 0) before the
  miscompiled multiply.

## What might still be true

- The `inference_seed_segfault.md` repro at active=65 may or may not be
  the same bug. The bisect entry talks about a `1.0` fp64 bit pattern
  in the freelist — that's a separate symptom that may or may not be
  driven by the same codegen bug. **Re-test the segfault repro post-fix
  to confirm.**
- `vocab_embedding_shape_mismatch_2026-05-10.md` (V_corpus > W[0].rows
  causes OOB) is a distinct bug, also still relevant. The `--corpus`
  flag is the workaround there.

---

## Floor (don't break)

- 137/137 green
- Byte-identical self-compile fixed point (cycle ≥ 2)
- Push flow: `git push origin next` (relay handles GitHub)
- v_full bisect harness produces 0.020599 (correct) on the trigger line —
  if it ever flips again, emit_x1 has regressed.

## Reusable commands

```bash
# Quick correctness check on CPU substrate
rm -f /tmp/forward_dump_cpu/*.txt
tools/diagnose/forward_dump_cpu_bin \
  --prefix runs/smoke_v54_repro/checkpoints/smoke_v54_repro_best \
  --corpus training/corpora/spur_compile_back_quarter.txt \
  --prompt "main = " --max 1
head -1 /tmp/forward_dump_cpu/x_embed.txt   # must be 0.020599365234375

# Bisect harness regression test (must produce 0.020599)
./rail_native run tools/diagnose/cpu_bisect_v_full.rail \
  -- --prefix runs/smoke_v54_repro/checkpoints/smoke_v54_repro_best \
     --corpus training/corpora/spur_compile_back_quarter.txt \
     --prompt "main = " --max 1 --k 1

# Self-compile + cycle check
./rail_native self && cmp rail_native /tmp/rail_self && echo "byte-identical"

# Full GPU mixed bench (25 min) — sanity
./rail_native flywheel-local/bench_strip.rail
cp /tmp/rail_out /tmp/rail_bench_strip
/tmp/rail_bench_strip \
  --prefix runs/halfB_s7777_fresh/checkpoints/halfB_s7777_fresh_best \
  --max 60 --k 10 --temp 0.8 \
  --tag halfB_s7777_post_fix \
  --gen-source tools/train/lm_infer_v3_mixed.rail
```

## Commits this session

```
02a6a1d compile: fix nullary-LHS binary-op codegen — emit_x1 fast path skipped for non-env V
47e2e21 substrate: fix CPU heisenbug — alias `seq_len` workaround for nullary-LHS codegen bug
0b83f34 diagnose: cpu_bisect_{base,v_full,v_clone} — heisenbug trigger isolated
```
