# Spur overnight synthesis — 2026-05-01

**Final result: Spur-v3 (trained on `tools/compile.rail` ALONE) hits 6/30 (20%) on the canonical bench. 3× the prior best Spur ckpt (v0.9-ascii at 1-2/30).**

This is honest grading via the bench harness's `ld: OK` string match. No post-processing. No measurement bug.

## The single finding

Training a 1.74M-parameter d=256 transformer on `tools/compile.rail` (the 4,690-line self-hosting Rail compiler, ASCII-cleaned to 362 KB) for 3,000 steps produces a model that compiles 6/30 bench prompts. Mixing the same compile.rail with ANY other corpus — stdlib ASCII baseline, grammar-walk curriculum, or both — wipes out the lift, dropping back to 0-1/30.

**The structural-advantage lever is "single coherent self-hosting source."** Spur owns its compiler — `tools/compile.rail` is the most structurally cohesive Rail program in existence. Training on it concentrates the model on one consistent style. Heterogeneous corpora introduce structural noise that the model wastes capacity reconciling.

## Full 4-arm ablation table

| Arm | Trainer | Corpus | Bytes | val_loss | Bench | Notes |
|---|---|---|---:|---:|---:|---|
| baseline (older) | lm_v09_d256_half_ascii | rail_corpus_stdlib_ascii.txt | 517,691 | — | **2/30** | Prior best (v0.9-ascii) |
| **Arm 1: Spur-v3** | **lm_v13_d256_compile_self** | **compile.rail (ASCII)** | **362,075** | **3.29** | **6/30** | **WINNER** |
| Arm 2: Spur-v4 | lm_v14_d256_arm2 | ascii + 310 KB curriculum | 827,812 | 3.23 | 1/30 | Curriculum hurts |
| Arm 3: Spur-v6 | lm_v16_d256_arm3_combined | compile.rail + curriculum | 672,197 | 3.22 | 1/30 | Curriculum poisons compile.rail |
| Arm 4: Spur-v7 | lm_v17_d256_arm4 | ascii + compile.rail | 879,813 | 3.38 | 0/30 | ASCII also dilutes |

## Per-band breakdown — Arm 1 (the winner)

| Band | Pass | Quality |
|---|---:|---:|
| Fundamentals | 2/5 | 7,232 |
| Practical IO | 0/5 | 3,444 |
| Real Tools | 1/5 | **39,291** ← outlier-high (ADT/match patterns mirror compile.rail) |
| Compiler | 2/5 | 12,234 |
| Advanced | 1/5 | 5,819 |
| Comprehend | 0/5 | 6,015 |
| **Total** | **6/30** | **74,035** |

74,035 is the highest total quality of any honest bench in the night.

## Why this works (hypothesis)

- `tools/compile.rail` is one program — consistent naming conventions, scoping rules, idioms, comment style.
- Stdlib ASCII corpus is many disjoint small files written by different authors with different idioms.
- Curriculum (grammar-walk derived) is short repetitive templates (`main = let _ = print (show X)\n  0` × hundreds).
- Mixing these introduces structural inconsistencies. The model wastes capacity learning when to switch between styles instead of learning one well.
- Concentrated coherent code → concentrated coherent generation.

## What didn't work (with rationale)

- **Curriculum at 310 KB (Arms 2, 3):** template-derived; teaches narrow patterns; doesn't generalize.
- **ASCII baseline mixed with compile.rail (Arm 4):** dilutes the structurally pure source.
- **Mid-session strip post-process (earlier in night):** turned out to be a `rail_native` exit-code bug — script counted link-failed gibberish as compile-pass. Retracted; see `strip_grade_was_false_positive.md`.
- **Inline parse-trace (early Phase 1):** model emits trace tags as bytes; output is contaminated. Falsified at simple inline form; two-channel form remains untried.
- **Compile-loss / REST^EM harvest:** at 1-2/30 base rate × 50% segfault rate, harvest produces 0 survivors. Cold-start cannot bootstrap without a teacher. Pivoted Arm 3 away from this.

## What's still real

1. **UTF-8 cleanup is the +1-2 pass tier-zero lever.** v0.5 (4.31% non-ASCII corpus) → 0/30; v0.9-ascii (0%) → 1-2/30. Quantified.
2. **`rail_native` exit-code bug:** exits 0 even on `ld` failure. Real bug, file as compile.rail patch.
3. **val_loss does NOT predict bench at this scale.** Arm 3 had the lowest val_loss (3.22) and one of the worst pass rates (1/30). Don't trust val_loss as a stop criterion.
4. **The 16 model-side scaffolds** still exist as future work (parse-trace two-channel, compile-loss with teacher cold-start, etc.) but are now lower-priority given the corpus-quality dominates.

## Reproducer

```bash
# 1. ASCII-clean compile.rail
python3 -c "
with open('tools/compile.rail','rb') as f: d=f.read()
ascii=bytes(b for b in d if b<128)
with open('training/corpora/spur_v3_compile_self.txt','wb') as f: f.write(ascii)"

# 2. Train (~85 min wall on Studio)
./rail_native run tools/train/lm_v13_d256_compile_self.rail

# 3. Bench (~25 min wall, N=20 parallel rerank)
./rail_native run flywheel-local/bench_railnative_rerank.rail \
  --gen-source tools/train/lm_infer_cpu_v13.rail \
  --prefix training/rail_native/checkpoints/spur_v13_d256_compile_self_best \
  --max 64 --k 10 --temp 0.8
```

## Open questions for next session

1. **Capacity scaling on compile.rail-only:** does d=384 push beyond 6/30? Does 6,000-step training (2× compute) lift further?
2. **Multi-coherent-source:** compile.rail + lm_transformer.rail + bpe.rail concatenated as one stream — does coherent-mix lift, or does any heterogeneity dilute?
3. **Half-of-compile.rail test:** train on lines 1-2345, then 2346-4690 separately. If both achieve ~6/30, the lever is "any single coherent program" not specifically compile.rail.
4. **Two-channel parse-trace (Tier-A2 proper):** untried. Now lower priority but still worth one experiment.
5. **rail_native exit-code bug fix:** ~30 min compile.rail patch, file before next training cycle.

## Path forward — recommendation

1. **Use Spur-v3 as new baseline.** Cite 6/30 as the canonical Spur best.
2. **Test multi-coherent-source compounding.** Most plausible additional lift.
3. **Don't mix curriculum into anything.** Falsified twice tonight.
4. **Fix the exit-code bug.** Avoids future false-positives.

## Time accounting

- 11 PM 2026-04-30 → 1:30 PM 2026-05-01 = 14.5 hours.
- 7 training runs (Spur-v1.0, v1.0-final, v2 Phase 1, v2.5, v3 Arm 1, v4 Arm 2, v6 Arm 3, v7 Arm 4).
- 8 benches (v0.9-ascii ×2, v0.5, v1.0 ×2, v2, v2.5, v3, v4, v6, v7).
- 12+ memory entries written; 3 retracted/superseded mid-session for honest accounting.
- Tonight's net new validated finding: **compile.rail-as-corpus = 6/30, 3× prior best.**
