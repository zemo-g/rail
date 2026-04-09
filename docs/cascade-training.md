---
name: cascade-training
description: Alpine spring training method — progressive model scaling 0.8B→2B→4B, each stage refines data upward
type: project
---

## Cascade Training — The Alpine Spring Method (2026-03-22)

**Concept:** Start small, grow upward. Each model size masters its level range, produces clean training data for the next size up. Like an alpine spring becoming a river becoming a waterfall.

### The Pipeline

| Stage | Model | Target Levels | Train Time | Purpose |
|-------|-------|---------------|------------|---------|
| S1 — Spring | Qwen3.5-0.8B | L1-L3 | ~70 min | Perfect the basics |
| S2 — Stream | Qwen3.5-2B | L1-L5 | ~3h | Push to intermediate |
| S3 — River | Qwen3.5-4B | L1-L7+ | ~6h | Break through to advanced |

### How It Works
1. Train 0.8B on existing data → deploy to MLX → harvest L1-L3 at 90%+ → clean foundation
2. Merge S1's clean outputs into training data → train 2B → harvest L1-L5
3. Merge S2's outputs → train 4B → this model sees ONLY refined data from specialists
4. The 4B never sees noisy L1 garbage — it sees perfected L1-L3 from a specialist

### Key Insight
Previous approach trained 4B on all data at once — mostly noisy L1-L3 examples from a model that was still learning. The 4B memorized noise instead of learning patterns. Progressive scaling means each level is clean before the next model builds on it.

### Razer Training Params
- 0.8B: `--lora-rank 16 --num-layers 24 --max-seq-length 256 --iters 2000` (~67 tok/s)
- 2B: `--lora-rank 16 --num-layers ?? --max-seq-length 384 --iters 2500`
- 4B: `--lora-rank 8 --num-layers 32 --max-seq-length 512 --iters 3000`

### Claude Injection
When the flywheel stalls at a level boundary (falls back twice), inject 20-50 Claude-generated examples at that level → merge → retrain. Claude as the safety net at the frontier.

### fleet_query.py
Updated to check `s1_train.log` → `s2_train.log` → `s3_train.log` → `v7_train.log` (cascade priority).

**Why:** The old approach was flat — one model, one dataset, grind forever. The cascade is how you actually build capability: foundations first, then layers.
**How to apply:** Always train smallest model first. Each stage's outputs feed the next. Never skip stages.
