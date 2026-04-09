---
name: Flywheel Data Quality — Golden Reference v4
description: Complete 13-cycle audit — 34 issues, root causes proven (0 fold+lambda examples, 78% cloud_harvest poison, PEFT→MLX zeros adapter), v4 plan ready (2026-03-20 20:20)
type: project
---

## Flywheel Data Quality — Golden Reference v4 (2026-03-20 20:20 UTC)

**Why:** Canonical reference for flywheel data pipeline state. 13-cycle deep audit, all findings compiler-verified.
**How to apply:** Use this as the checklist when touching any flywheel/training code.

---

### System State (live during audit)

| Node | Status | Details |
|------|--------|---------|
| **Razer** | v3 training, iter 1700/3000 | val=0.52 (beat v2 best of 0.58 at iter 1000), ETA ~2.4h |
| **Mini** | Self-training level 2, round 66 | 465 harvested this session, 20-50% pass rate, stuck at L2 |

### Razer v3 Training Curve
```
Iter  250: val=0.82
Iter  500: val=0.62
Iter 1000: val=0.56  ← passed v2 best (0.58)
Iter 1500: val=0.53  ← checkpoint saved
Iter 1700: val=0.52  ← healthy, no overfit
Projected: ~0.48 at iter 3000
```

---

### Data Inventory (4,304 raw → 3,515 unique by code hash)

| Source | Raw | Unique | Status |
|--------|-----|--------|--------|
| `training/train.jsonl` | 244 | 122 | **50% inflated** (3x variants of 122 programs) |
| `training/git_harvest.jsonl` | 150 | ~100 | 50 no-main (33%), 47 >5K chars |
| `training/self_train/harvest.jsonl` | 2,966 | ~2,600 | Growing, 27 mega-entries >10K |
| `training/self_train/harvest_clean.jsonl` | 2,576 | ~2,500 | SHA-256 deduped from harvest |
| `training/real_programs.jsonl` | 34 | 34 | Clean |
| `training/handcrafted_l2_l5.jsonl` | 50 | 50 | Clean |
| `training/self_train/cloud_harvest.jsonl` | 576 | ~550 | Not compiler-verified |
| `training/self_train/cloud_repairs.jsonl` | 110 | ~100 | Clean |
| `training/self_train/repairs.jsonl` | 318 | ~280 | Mixed quality |
| `training/self_train/synthetic_repairs.jsonl` | 204 | ~190 | Clean |
| `training/self_train/session_harvest.jsonl` | 20 | 20 | Clean |
| **Razer (currently training on)** | 2,267 | 2,267 | 2,145 train + 122 valid, quality-filtered |

---

### CONSTRUCT COVERAGE (critical finding — Cycle 6)

**Overrepresented (>30%)**:
let_binding 96%, print 94%, func_def 47%, show 43%, foreign_ffi 30%

**Adequate (10-30%)**:
adt_def 28%, lambda 23%, head 22%, match 18%, split 17%, join 14%, append 13%, tuple 13%, if_then_else 13%, map 12%, tail 10%

**CRITICALLY UNDERREPRESENTED (<5%)**:
write_file 4%, cons 4%, fold 3%, reverse 3%, to_float/to_int 2%, import 2%, arena_mark 1%, spawn 1%, pipe(|>) 0%, channel 0%, refcount 0%

**Complexity distribution (explains L2 plateau)**:
- Trivial (0-1 constructs): 20% → should be 10%
- Basic (2-3): 63% → should be 40%
- Intermediate (4-5): 12% → should be 30%
- Complex (6+): 3% → should be 20%

**83% of training data is trivial/basic. Model learns simple programs, can't compose.**

---

### MASTER ISSUE LIST (24 issues, 6 cycles)

#### P0 — Critical (Actively Harming Training)
1. **waterfall merge hashes full line, not code** — 673 inflated entries (19% waste) [waterfall.rail:52, C4]
2. **LLM-generated tasks have no expected output** — compile-only even at L1-10 [self_train.rail:700-709, C1]
3. **L11-25 seeds + Band 5-6 bench are compile-only** — trivially faked [self_train/bench, C1/C5]
4. **27 degenerate mega-entries (>10K chars, 3 >200K)** — repetitive let-binding hallucinations [harvest.jsonl, C2]
5. **83% trivial/basic complexity distribution** — model can't learn composition [all sources, C6]
6. **11 constructs at <5% coverage** — fold, arena, pipe, spawn, channel virtually untaught [all sources, C6]

#### P1 — Significant (Degrading Quality)
7. 50/150 git harvest entries have no main (33%) [harvest_git.py, C4]
8. 37% of all entries <100 chars [all sources, C2]
9. 4 distinct system prompts across sources [all sources, C1-4]
10. self_train retrain() uses 5 sources, not 10 [self_train.rail:603, C1]
11. waterfall sync sends no validation split [waterfall.rail:59, C4]
12. waterfall references train_cuda.py not v3 [waterfall.rail:160, C4]
13. 35% bench/seed overlap — data contamination [bench vs self_train seeds, C5]
14. Prompt masking skipped for 2-message entries [train_cuda.py:149, C3]
15. Compiler diffs in git harvest teach diff format [harvest_git.py:126-130, C4]
16. build_training_data examples not compiler-verified [build_training_data.rail, C3]
17. bench_log duplicate field name "comp=" [bench.rail:221, C5]
18. No benchmark after adapter swap in post_train.sh [post_train.sh, C6]

#### P0 — CRITICAL (Architecture / Conversion, Cycles 7-9)
25. **Only 8/32 layers LoRA-trained on Razer** — DeltaNet layers invisible to `self_attn` filter [train_cuda.py:68-69, C7]
26. **PEFT→MLX drops MLP+DeltaNet LoRA weights** — 6MB vs 16MB (40% capability) [post_train.sh:92-147, C7]
30. **⚠️ PEFT→MLX conversion SILENTLY PRODUCES ZERO-ADAPTER** — key prefix `model.layers` vs `language_model.model.layers` + `strict=False` drops ALL weights. DO NOT RUN post_train.sh without fixing. [post_train.sh:117, C9]
    - Fix: add `language_model.` prefix, remap layer indices, add DeltaNet+MLP keys
    - Or: **train on MLX instead (RECOMMENDED)** — auto-discovers correct layers+keys

#### P0 — CRITICAL (Data Poison / Skill Gaps, Cycles 10-13)
31. **cloud_harvest.jsonl is 78% POISON** — 450/576 entries don't compile. Teaches wrong Rail syntax (`let x = 5 in x`, type params). Compiler-verified. PURGE ENTIRE FILE. [C11]
32. **cloud_repairs.jsonl is 76% POISON** — 38/50 tested don't compile. Same wrong syntax. PURGE. [C13]
33. **ZERO training examples for `fold (\a -> \b -> a + b)`** — the #1 failing L2 task. Only 1 example of fold+nested_lambda in clean data. DIRECT CAUSE of L2 plateau. [C10,C12]
34. **3 of 10 L2 tasks have 0 clean training examples** — fold+sum, fold+product, recursive list sum. Model cannot learn what it has never seen. [C12]

#### P1 — Significant (Architecture, Cycle 7)
27. Scale factor oscillates: MLX scale=20.0 vs PEFT scale=2.0 — adapter behavior changes every cycle [post_train.sh:138, C7]
28. 68% sequence padding waste — avg 163 tokens at seq_len=512 [Razer v3 log, C7]
29. train_cuda.py targets only q/k/v/o_proj, misses DeltaNet projections + MLP [train_cuda.py:78, C7]

#### P2 — Minor
19. 83 remaining no-main entries in sources [various, C2]
20. Stretch tasks pollute curriculum pass rate [self_train.rail:782, C1]
21. since_retrain counter never resets [self_train.rail:795, C1]
22. HOME path leaks in training data [build_training_data.rail:91, C3]
23. LoRA rank=8 conservative (16 recommended) [train_cuda.py:32, C3]
24. waterfall cycle() hardcodes 2000 iters [waterfall.rail:216, C4]

---

### QWEN3.5 HYBRID ARCHITECTURE (critical discovery — Cycle 7)

Qwen3.5 is NOT a standard transformer. Uses **Gated DeltaNet** (NOT Mamba) for 75% of layers.

**Layer structure (32 layers):**
- 8 full self-attention (indices 3,7,11,15,19,23,27,31): `q_proj, k_proj, v_proj, o_proj`
- 24 Gated DeltaNet (all other indices): `in_proj_qkv, in_proj_z, in_proj_b, in_proj_a, out_proj`
- 32 MLP (every layer): `gate_proj, up_proj, down_proj`

**Current train_cuda.py targets only q/k/v/o_proj → hits 8/32 layers (25%)**
**Recommended target_modules for v4:**
```python
["q_proj","k_proj","v_proj","o_proj",           # 8 full-attn
 "in_proj_qkv","in_proj_z","in_proj_b",         # 24 DeltaNet
 "in_proj_a","out_proj",                          # 24 DeltaNet
 "gate_proj","up_proj","down_proj"]               # 32 MLP
```
Would increase trainable params from 1.6M (0.065%) to ~12-15M (0.5-0.6%), still fits 8GB VRAM with QLoRA.

**Adapter conversion discrepancy:**
- MLX adapter (current): 16MB, scale=20.0, targets attn+MLP
- PEFT adapter (Razer v3): 6MB, scale=2.0, targets attn only
- Conversion will produce structurally different adapter each cycle

**Sources:** Unsloth Qwen3.5 guide, HF transformers modular_qwen3_5.py, NVlabs GatedDeltaNet repo

---

### THREE PIPELINES PROBLEM

| Pipeline | Code | Sources | Dedup | Shuffle | Filters |
|----------|------|---------|-------|---------|---------|
| build_training_data.rail | Static gen | Hardcoded | None | None | None |
| dataset.rail | Dynamic merger | 10 sources | SHA-256 on **code** | random.shuffle(42) | None |
| waterfall.rail merge | Sync to Razer | 10 sources | SHA-256 on **full line** ← WRONG | None | None |
| train_cuda.py | Trainer load | Whatever pushed | SHA-256 on code | per-epoch | no-main, <20char, >4000char |

**dataset.rail and waterfall.rail disagree on dedup strategy → 673 phantom "unique" entries**

---

### RESEARCH-BACKED RECOMMENDATIONS

**Data Quality (from 3 research agents)**:
- Filter to ~2,000-2,500 clean examples (from 3,500+) — smaller, cleaner beats larger, noisier
- Cap trivial at 10% of dataset, target 30/50/20 simple/medium/complex
- Structural dedup: normalize literals + 5-gram Jaccard at 0.7 (StarCoder2 method)
- Add construct-targeted generation for the 11 underrepresented constructs
- Sequence packing or length-stratified sampling (73% of gradient steps currently teach trivials)

**Architecture (validated by literature)**:
- Compiler oracle prevents model collapse (ICLR 2025 — verified synthetic data is provably safe)
- Off-policy data is fine — compiler correctness doesn't drift (no stale model problem)
- Full-file training beats diffs for generation tasks (LintSeq, ICLR 2025)
- Adapter swap: fuse + restart MLX server (no runtime unload API in MLX)
- 60-80% advancement threshold is optimal (ADARFT 2025), your 80% is at upper bound

**Training (concrete numbers)**:
- LoRA rank 16 for code tasks (currently 8)
- seq_len 1024 if VRAM allows (512 truncates 3% of data)
- Retrain every 300-600 new harvested examples (10-20% of dataset)
- 3-phase curriculum: balanced fundamentals → composition → full programs
- Construct-stratified batching: ensure rare constructs in every batch

---

### NEXT TRAINING CYCLE PLAN (after v3 completes)

### V4 TRAINING PLAN — READY TO EXECUTE

**Decision: Train v4 on MINI (MLX), not Razer.**
- Zero conversion risk (native keys, correct layers)
- 2.5x more trainable params (4.1M vs 1.6M)
- Proven pipeline (current adapter is MLX-trained)
- ~4h training time

**Step 1: Data cleanup (2-3h)**
1. PURGE cloud_harvest.jsonl entirely (78% poison, 450 broken entries)
2. PURGE cloud_repairs.jsonl entirely (76% poison)
3. Purge mega-entries >4000 chars code from harvest.jsonl
4. Purge remaining no-main entries from all sources
5. Generate 30-50 fold+nested_lambda examples, compiler-verify each:
   - `fold (\a -> \b -> a + b) 0 [1,2,3,4,5]` → 15
   - `fold (\a -> \b -> a * b) 1 [1,2,3,4,5]` → 120
   - Variations with different ops, lists, init values
6. Generate 10-20 recursive sum/fibonacci examples
7. Re-merge with dataset.rail prepare
8. Validate: compiler-verify random sample of merged data

**Step 2: Prepare MLX training data (~10 min)**
```bash
cd ~/projects/rail
./rail_native run flywheel/dataset.rail prepare
cp /tmp/rail_flywheel_data/train.jsonl /tmp/rail_v4_data/train.jsonl
cp /tmp/rail_flywheel_data/valid.jsonl /tmp/rail_v4_data/valid.jsonl
```

**Step 3: Train v4 on Mini (~4h)**
```bash
/Users/ledaticempire/homebrew/bin/python3.11 -m mlx_lm lora \
  --model /Users/ledaticempire/models/Qwen3.5-4B-4bit \
  --train --data /tmp/rail_v4_data/ \
  --iters 3000 --batch-size 1 --learning-rate 1e-5 \
  --num-layers 8 --steps-per-report 100 --steps-per-eval 500 \
  --save-every 1000 --max-seq-length 512 --mask-prompt \
  --adapter-path training/adapters_4b_v4
```

**Step 4: Validate & deploy (~30 min)**
- Restart MLX server with v4 adapter
- Run bench.rail against v4
- Compare vs v3 bench scores
- If improved, restart self-training loop

**Expected v4 dataset: ~2,931 clean examples (0% poison)**
**Expected improvement: L2 pass rate 44% → 70-85%, val loss 0.51 → 0.44-0.48**
**Expected time to L3 advancement: 6-15 rounds (was: never)**

### Key Academic Papers

| Paper | Finding | Relevance |
|-------|---------|-----------|
| RLEF (ICML 2025) | Execution feedback as RL reward for code | Validates compiler-as-oracle |
| "Beyond Model Collapse" (ICLR 2025) | Verified synthetic data prevents collapse | Our compiler IS verification |
| SelfCodeAlign (NeurIPS 2024) | 7B beats 70B with execution filter | Small model + oracle works |
| ADARFT (2025) | 2-3 round advancement optimal | We use 3 |
| StepCoder (ACL 2024) | Compiler feedback + curriculum subtasks | Directly maps to our levels |
| LintSeq (ICLR 2025) | Edit sequences help editing, full-file helps generation | Stick with full-file |
| StarCoder2 | 5-gram Jaccard 0.7 for near-dedup | Use for structural dedup |
| "Prosperity before Collapse" (2025) | Stale data OK if verifier doesn't drift | No staleness problem for us |
| Compositional Generalization (2025) | CoT training enables construct composition | Add decomposition comments |
