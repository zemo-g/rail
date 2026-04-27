# Spur 2B roadmap — sub-1MB binary to 40GB model on a single Studio

**Date:** 2026-04-26.
**Goal:** grow Rail from "Spur-0.1 ships at 1.74M params, 25/30 bench" to "Spur-2B ships at ~2B params, competitive on a 30-task Rail benchmark, runs end-to-end on one M1 Ultra Studio with a 729KB self-hosted binary."

The constraint is not the binary. The binary stays small. The constraint is **runtime memory** for training a model whose weights + Adam state + activations exceed the current 512MB arena.

This roadmap is **5 sequential lifts**, each a known scope. Total calendar: ~6-8 focused weeks.

## Phase ordering at a glance

| # | lift | wall | unlocks | risk |
|---:|---|---:|---|---|
| 1 | Arena bump 512MB → 4GB | 30 min | d≤1024 × 12-block fits | trivial |
| 2 | bf16 Adam state | ~3 days | -24GB at 2B; unlocks d=2048+ | medium |
| 3 | Gradient checkpointing | ~1 week | -60% activation cache; d=3072 × 16 fits | high |
| 4 | BPE tokenizer + retrain pipeline | ~1-2 weeks | 5× effective training data per step | medium |
| 5 | Self-distillation flywheel | ~2-3 weeks (+ runtime) | corpus grows from 544KB → 50MB+ | research |

After Phase 5, Studio runs a 2B-param compile-verified LM. The 40 GB peak RSS budget is feasible.

---

## Phase 1 — Arena bump to 4 GB (30 min)

### What

Change two literals in `tools/compile.rail`. The bump arena scales linearly with the BSS reservation. macOS lazy-pages the zerofill so disk size and unused-memory cost are zero.

### Where

`tools/compile.rail` line ~3475 (in `data_section_asm`):
```rail
.zerofill __DATA,__bss,_rail_heap,4294967296,3   -- was 536870912
```

`tools/compile.rail` line ~3913 (Linux .bss section):
```rail
let bss = "\n.bss\n.p2align 3\n_rail_heap:\n    .space 4294967296\n"
```

### How

```bash
sed -i '' 's/536870912/4294967296/g' tools/compile.rail
./rail_native self
cp /tmp/rail_self rail_native
codesign -s - --force rail_native
./rail_native test                      # expect 136/137 (Studio) or 137/137 (Mini)
./rail_native self
cmp /tmp/rail_self_pass1 /tmp/rail_self_pass2   # byte-identical
```

### Validation

`./rail_native run tools/train/lm_v3_chunked_d256_half.rail` should run unchanged (same training, same Spur-0.1 numbers). Larger configs that previously fell back to malloc now stay in the bump arena.

### Output gate

Phase 1 ships when:
- 137/137 tests on Mini (or known 136/137 on Studio)
- Spur-0.1 reproduces 13/30 single-sample bench
- Fixed-point self-compile verified
- Commit + push

### Why first

Every later phase assumes the arena fits the working set. Without this, Lift 2's bigger Adam state still falls to malloc. Cheap, blocks nothing, lifts the floor.

---

## Phase 2 — bf16 Adam state (~3 days)

### What

Today's Adam uses f64 for `m` and `v` (16 bytes per parameter). At 2B params that's 32 GB just for Adam state. **Switch m and v to bf16 (4 bytes/param) with a per-tensor f32 scale factor to prevent underflow.**

bf16 has the same 8-bit exponent as f32 (vs fp16's 5-bit), so dynamic range is fine for accumulating gradients. The 7-bit mantissa loses precision but the per-tensor scale recovers it.

Saves **24 GB at 2B params**. The single biggest memory unlock in this roadmap.

### Where

- `stdlib/tensor.rail` — add `BfTensor` ADT parallel to `HalfTensor`. Two halfs per f64 slot; reinterpret cast at the dylib boundary.
- `stdlib/optim.rail` — add `adam_update_raw_bf` that:
  - Reads bf16 m, bf16 v
  - Casts to f32 in CPU registers
  - Applies scale factor
  - Computes Adam update in f32
  - Casts back to bf16, updates scale if needed
- `tools/metal/tensor_gpu_lib.m` — add `tgl_f64_to_bf` and `tgl_bf_to_f64` host helpers
- `tools/metal/tensor_gpu.metal` — Metal kernels for bf16 ops if needed (mostly the f64→bf cast goes through the host)
- `tools/train/lm_v3_chunked_d256_half.rail` — clone to `lm_v3_chunked_d256_bf_adam.rail` with `adam_state` replaced by `adam_state_bf`
- New AdamState ADT variant: `BfAdamState m_bf v_bf step_arr scale_arr`

### How

1. Day 1 — write `BfTensor` + pack/unpack primitives. Smoke-test round-trip accuracy.
2. Day 2 — write `adam_update_raw_bf`. Smoke-test against an f64 reference at small N: max-abs-diff after 100 update steps should be < 1e-5.
3. Day 3 — wire into a training file. Run d=256 × 2-block × 500 steps with bf16 Adam. Compare to Spur-0.1's eval trajectory at the same checkpoint cadence; should track within 0.05 eval mean across the run.

### Validation

Two-axis checkpoint:
1. **Numerical:** trained model's eval trajectory matches f64-Adam baseline within 0.05 over 1000 steps.
2. **Memory:** peak RSS for d=256 × 2-block training drops by ~28 MB (the saved Adam state). Will be small at this scale; the real win shows at d≥1024.

### Risk

Adam-with-narrow-mantissa is documented to sometimes diverge on long training. Mitigation: the per-tensor scale factor + an optional fallback to f32 m for layers with high gradient variance. If divergence appears at d=512, ship f32 m + bf16 v as the compromise (saves 12 bytes/param instead of 24).

### Output gate

Phase 2 ships when:
- d=512 × 4-block × 3000 steps trains to a normal eval trajectory with bf16 Adam
- Memory savings measured and confirmed
- Add `Spur-0.1-bf` reproduction to model card to demonstrate parity on small scale

---

## Phase 3 — Gradient checkpointing (~1 week)

### What

Today's training caches 12 activation tensors per block through backward. At d=2048 × 16 blocks, cache is ~3 GB. **Recompute forward during backward instead of caching.** Trade ~30% compute for ~60% memory savings on the cache line.

### Where

- `tools/train/lm_v3_chunked_d256_half.rail` (and successors) — add a `--checkpoint` mode that uses recompute-instead-of-cache backward
- New helper `m_block_fwd_nocache` in the training file: returns only `x_out`, no cache list
- New helper `m_block_bwd_recompute`: takes `(x_in, w_block)` instead of `(x_out_dx, cache, w_block)`, internally calls `m_block_fwd` to materialize the cache, then runs `m_block_bwd`
- Inference path uses existing `m_block_fwd` (no change — inference doesn't backward)

### How

1. Day 1-2 — implement `m_block_bwd_recompute`. The trick: re-run forward inside backward, but the recompute should be done with `arena_mark`/`arena_reset` around it so the cache is reclaimed after the gradient is computed. Net result: forward runs twice per training step, but at any moment the live cache is just one block's worth, not all blocks'.
2. Day 3-4 — wire into the training loop. Add a CLI flag `--checkpoint` to opt in (so we can ablate against without-checkpointing for validation).
3. Day 5 — measure: d=512 × 8-block training, RSS without checkpointing vs with. Should see ~50% reduction in cache footprint and ~30% slower per-step.

### Validation

- d=512 × 8-block × 1000 steps with checkpointing should produce identical loss trajectory to without (only memory and wall-time differ)
- Peak RSS reduction matches projection (~50% of activation cache)

### Risk

Numerical drift if the recompute uses different RNG or different floating-point order than the original forward. Standard fix: thread the same RNG state, use deterministic ordering. Should not be a real issue for forward (the only RNG is in `sample_chunk` which lives outside the per-block fwd).

### Output gate

Phase 3 ships when:
- d=1024 × 12-block × 1000 steps trains to completion within Studio's RAM budget under checkpointing
- Demo before/after RSS in the docs
- Loss trajectories match within numerical noise

---

## Phase 4 — BPE tokenizer + retrain pipeline (~1-2 weeks)

### What

Today's vocab is 130 char-level symbols. BPE compresses ~5× — meaning a 2B-param model trained with BPE sees 5× more semantic content per training step than the same model with char-level tokenization.

### Where

- `tools/train/bpe_rail.rail` (currently untracked WIP) — finish + ship
- BPE merge-table format on disk: simple TSV of `<lhs>\t<rhs>\t<merged>` lines
- `stdlib/bpe.rail` — encode/decode primitives reusable across training and inference
- `stdlib/checkpoint.rail` — extend to save BPE merge table alongside weights (so checkpoints are self-contained)
- New training variant `lm_v3_bpe_chunked_d256_half.rail` that consumes BPE tokens instead of char ids
- Inference harness `lm_infer_v3_bpe.rail` mirroring the existing `lm_infer_v3_half.rail` but with BPE tokenization
- Bench: `bench_railnative_rerank.rail` and friends will need their checkpoint-loader to detect BPE vs char-level (manifest header bit) and tokenize prompts accordingly

### How

1. Week 1, days 1-3 — finish `bpe_rail.rail`. Implement the BPE training algorithm (greedy frequency-count + merge), produce a 2K-token merge table from the stdlib corpus.
2. Week 1, days 4-5 — encoder/decoder smoke tests. Round-trip the stdlib corpus through encode-then-decode; should be byte-identical.
3. Week 2, days 1-3 — wire into the training file. New ADT for tokenized chunks. Adam updates unchanged.
4. Week 2, days 4-5 — train Spur-BPE-0.1 at d=256 × 2-block on the same 544KB corpus, but with BPE tokens. ~84 min.
5. Week 2, days 6-7 — bench and compare to Spur-0.1's 13/30 single-sample. Expect Spur-BPE-0.1 to score 18-22/30 single-sample at the same model size. The compiler-rerank ceiling should also rise.

### Validation

- Round-trip encode/decode over the entire stdlib corpus: byte-identical
- Held-out eval ≤ 2.0 (vs Spur-0.1's 3.49) at the same step count — BPE compresses, so the perplexity number is on a different unit
- Bench: Spur-BPE-0.1 single-sample ≥ Spur-0.1 single-sample at matched training compute

### Risk

BPE merge selection on a small corpus can over-fit to specific patterns. Mitigation: cap merge table at 2-4K tokens; smaller is better for tiny corpora.

### Output gate

Phase 4 ships when:
- BPE encode/decode round-trips losslessly
- A BPE-trained model exists, benches at-or-above Spur-0.1
- Checkpoint format documented in `stdlib/checkpoint.rail` so future tooling knows the format

---

## Phase 5 — Self-distillation flywheel (~2-3 weeks of engineering, plus weeks of runtime)

### What

The final scaling lever. Stop being corpus-bottlenecked. Use the model + compiler + (optionally) the 35B teacher to grow the corpus organically.

### Where

- `tools/train/self_train.rail` — already has primitives `harvest_snapshot`, `harvest_rollback`, `harvest_ab_gate`. Wire them.
- New orchestrator `tools/train/flywheel_loop.rail`:
  1. Generate N candidate Rail programs from prompts (prompts harvested from bench-like task templates)
  2. Compile each via diagnose; classify by failure mode
  3. For compile-clean candidates with high oracle quality: harvest into corpus
  4. For close-misses: optionally hand to 35B teacher on port 8081 as fix-oracle, harvest agreed-on fixes as triples
  5. Retrain on grown corpus
  6. Bench retrained model; if regression on `bench_railnative` ≥ 5/30 baseline, rollback
  7. Loop

### How

The flywheel runs continuously in the background, retraining once per N hours of harvest. The model improves; the model harvests better candidates; the corpus grows; the next retrain has more signal. A 50MB corpus over a few weeks of running is plausible.

### Validation

- After 1 week of flywheel runtime: bench score climbs from 25/30 toward 27-29/30 without manual intervention
- Corpus size grows monotonically; quality (compile-pass rate of harvested candidates) stays ≥ 60%
- `harvest_ab_gate` correctly rolls back any retrain that regresses

### Risk

Echo-chamber collapse: model learns to write only the kind of Rail it's good at, losing diversity. Mitigation: corpus growth requires not just compile-pass but also **diversity score** (oracle's `unique_chars`, `decl_count`, etc.). Reject candidates too similar to existing corpus.

### Output gate

Phase 5 is a research project that produces ongoing returns. Ships when:
- Flywheel runs unattended for 1 week without operator intervention
- Documented quality + diversity guarantees
- Spur-N+1 from flywheel-grown corpus benches strictly better than Spur-N

---

## Calendar

| week | phase work |
|---:|---|
| 1 | Phase 1 (arena bump). Phase 2 starts. |
| 2 | Phase 2 (bf16 Adam) finishes. Phase 4 starts (BPE) — depth-1 task interleavable with checkpoint validation work. |
| 3 | Phase 3 (gradient checkpointing) starts. Phase 4 continues. |
| 4 | Phase 3 finishes. Phase 4 finishes. First training of d=1024 × 12-block (~164M params) — overnight. |
| 5 | Bench d=1024. Iterate. Begin Phase 5 (flywheel skeleton wiring). |
| 6 | First flywheel runtime. Train d=2048 × 16-block (~830M) — multi-day. |
| 7-8 | Train d=3072 × 16-block (~2B params) — ~5 days. Bench. Update model card. |

**Calendar total: ~8 weeks**, of which roughly 4 weeks are engineering (Phases 1-4) and 4 weeks are training-and-iteration (Phase 5 + multi-scale benches).

## Hardware budget

All on the existing M1 Ultra Studio (64 GB unified memory). Mini stays in role as canonical-push + flywheel grader. No new hardware.

Expected peak RSS at full scale: **~40-45 GB** for d=3072 × 16-block training. Within Studio's budget; ~20 GB headroom for OS, claude-code sessions, the 35B MLX teacher.

## What ships at the end

- **Spur-2B**: ~2B-param self-hosted Rail transformer
- Trained on a flywheel-grown corpus of 50+ MB of compile-verified Rail
- Inference via compiler-re-rank at N=20-100 depending on task class
- Expected bench: 28-30/30 on `bench_railnative` (current target)
- Binary: still ~1 MB
- Stack: still ~5K lines of Rail + ~1K lines of Metal

The architectural claim then becomes:

> **A self-hosted programming language can train, on its own infrastructure, a 2B-parameter transformer that writes its own language, graded by its own compiler, end-to-end on a single 64 GB Mac. The binary is 1 MB. There are no C dependencies, no Python framework, no third-party ML library. This stack does not yet exist anywhere else.**

## What this roadmap does NOT promise

- **Doesn't compete with Llama / Mistral on general English benchmarks.** Spur-2B is Rail-specialized.
- **Doesn't beat compiler-re-rank's ceiling** on tasks the model can't structurally generate (semantic-intent tasks like Comprehend) without Phase 5 successfully growing the right kind of corpus.
- **Doesn't solve scaling beyond 2B.** d=4096 × 24-block needs distributed training across machines; not in this roadmap.

## Where this lives

- This document: source of truth for the roadmap
- `docs/plans/SCALING_POSITION.md`: detailed memory math (already shipped)
- `docs/plans/DIAGNOSTIC_CORPUS.md`: Spur-Fix research direction (Phase 5 input)
- `docs/plans/PHASE_5H_COMPREHEND_CEILING.md`: empirical ceiling that Phase 5 needs to crack
- `~/.claude/projects/-Users-user/memory/`: the lessons (compiler_rerank_wins, sampling_was_the_lever, comprehend_is_semantic) that constrain how this roadmap should be executed

Each phase will get its own writeup as it lands (`PHASE_6A_ARENA_BUMP.md`, `PHASE_6B_BF16_ADAM.md`, etc.). Spur-0.1 → Spur-2B is the v0.1 → v1.0 progression.

---

The 25/30 result Spur-0.1 ships today proves the loop. This roadmap turns the loop into a **growth engine**.
