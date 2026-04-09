---
name: railgpt-from-scratch
description: RailGPT — from-scratch Rail language model, 10M→50M→200M→400M growth, completion flywheel pipeline
type: project
---

## RailGPT — From-Scratch Model (2026-03-23)

**Status: LIVE** — RailGPT-400M serving on :8082, completion flywheel running, 83% pass rate at L2

### Architecture
- Custom 4K-vocab BPE tokenizer (Rail-specific, all keywords single-token)
- GPT-2 style: RoPE + SwiGLU MLP + pre-norm + tied embeddings
- Trained from random init on Rail corpus ONLY — no pretrained weights

### Growth History (Alpine Spring)
```
10M (6L/384d)  → 50M (12L/512d)  → 200M (18L/768d) → 400M (24L/1024d)
   Razer              Razer              Razer             Mini (MPS)
   loss 0.33          loss 0.04          loss 0.005        loss 0.005
```
Each stage: pretrain on Rail corpus, grow via Net2Net (width+depth), retrain warm-start

### Key Finding: Completion > Instruction
- **Instruct training DESTROYS pretrain knowledge** (catastrophic forgetting)
- **Pretrain-only model generates valid Rail** as code completion
- Solution: use as completion engine, not chat model
- Skeletons (partial programs) → model completes → compiler verifies → harvest

### Files
- `flywheel/train_scratch.py` — model def + training + serve (:8082)
- `flywheel/prepare_corpus.py` — corpus builder + BPE tokenizer
- `flywheel/grow_model.py` — Net2Net growth operators (width+depth)
- `flywheel/eval_oracle.py` — compiler-based evaluation
- `flywheel/completion_flywheel.py` — THE PIPELINE: skeleton → complete → compile → harvest
- `flywheel/retrain_cycle.sh` — rebuild corpus → retrain → restart server
- `flywheel/railgpt_data/` — corpus + tokenizer
- `flywheel/railgpt_checkpoints/` — all checkpoints

### Configs (in train_scratch.py)
| Config | Params | Architecture |
|--------|--------|-------------|
| 10m | 16M | 6L, d=384, 6 heads |
| 50m | 52M | 12L, d=512, 8 heads |
| 200m | 173M | 18L, d=768, 12 heads |
| 400m | 407M | 24L, d=1024, 16 heads |
| 600m | 739M | 28L, d=1280, 20 heads |

### Retrain Loop
```
flywheel harvests → retrain_cycle.sh → rebuild corpus → retrain 5 epochs → restart server → flywheel resumes
```

### What Works
- 80%+ compile rate on L1-L2 skeletons
- Generates valid: print, let chains, functions, recursion, if/else, nested calls
- Each growth stage starts with lower loss (knowledge transfers)
- Compiler is the only judge — no human labeling

### What Doesn't Work
- Instruction following (catastrophic forgetting during instruct)
- `show arithmetic` skeleton fails consistently (model generates wrong closing)
- L3+ (lists, fold, map) not yet tested at scale

**Why:** A language that trains its own AI from zero. No pretrained model. Every bit of knowledge comes from Rail code, verified by Rail's compiler.
**How to apply:** Serve pretrain model on :8082. Run completion_flywheel.py. Retrain periodically with retrain_cycle.sh. Grow with grow_model.py.
