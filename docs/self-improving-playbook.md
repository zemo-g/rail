---
name: self-improving-playbook
description: Complete A-Z playbook for bootstrapping a self-improving model training loop — clean data, train, deploy, harvest, repeat
type: reference
---

## Self-Improving Model Playbook

Proven process for bootstrapping an autocatalytic training loop where a model teaches itself a language through compiler verification. Executed 2026-03-19/20 for Rail language.

### Prerequisites
- A compiler that produces binary pass/fail (the oracle)
- A base model capable of generating code (any size)
- Training data in JSONL chat format (`{"messages": [{role, content}, ...]}`)
- LoRA training infrastructure (MLX on Apple Silicon or CUDA on GPU)

---

### Phase 1: Clean the Data

**Problem**: Accumulated training data is full of garbage — empty responses, duplicates, broken JSON.

```python
# Smart dedup: hash (user+assistant) to keep phrasing variants
import json, hashlib
seen = set()
for line in open('harvest.jsonl'):
    obj = json.loads(line)
    asst = obj['messages'][2]['content']
    if len(asst.strip()) < 10: continue  # empty responses
    h = hashlib.md5((obj['messages'][1]['content'] + asst).encode()).hexdigest()
    if h in seen: continue
    seen.add(h)
    # keep this line
```

**Our numbers**: 7,710 → 2,706 lines (64% was empty assistant responses).

---

### Phase 2: Prepare Training Infrastructure

**MLX on Apple Silicon (preferred for M-series Macs):**
```bash
python -m mlx_lm lora \
  --model ./models/Model-4bit \
  --train --data ./train_data/ \
  --iters 8000 --batch-size 1 --learning-rate 2e-5 \
  --num-layers 8 --max-seq-length 256 \
  --mask-prompt --grad-checkpoint \
  --save-every 2000 --steps-per-report 100 \
  --adapter-path ./adapters/
```

**Key settings that matter:**
- `--mask-prompt`: Only train on assistant tokens. Without this, the model wastes gradient signal learning to repeat system prompts. This was the single biggest quality improvement.
- `--max-seq-length 256`: Most code examples are <200 chars. Shorter seqs = less memory = faster training.
- `--grad-checkpoint`: Trades 2-3x speed for memory safety. Use it on tight memory.
- `--num-layers 8`: LoRA on 8 of 32 layers is enough. More layers = more memory, marginal gains.

**CUDA on dedicated GPU (for remote nodes):**
- Use QLoRA (4-bit quantization) to fit larger models
- `--gradient-checkpointing` essential for 8GB VRAM
- Prompt masking must be implemented manually in training script
- Watch for BitsAndBytes hangs on Windows — clear HF cache + kill stale python processes before training

**Memory reference (4B model):**
| Config | Peak Memory |
|---|---|
| 4B-4bit, 8 layers, seq 256, grad ckpt | 6.8 GB |
| 4B-4bit, 8 layers, seq 1024, grad ckpt | OOM on 8GB |
| 4B-4bit, 16 layers, seq 256, no grad ckpt | ~8 GB |

---

### Phase 3: Train Until Plateau

**Loss curve pattern:**
```
Iter 100:  0.823  ← steep drop (learning syntax)
Iter 300:  0.574  ← still learning
Iter 500:  0.464  ← diminishing returns start
Iter 1000: 0.446  ← plateau zone
Iter 2000: 0.418  ← flat, val loss diverging
```

**Stop when**: Train loss oscillates ±0.05 for 500+ iters AND val loss > 2x train loss (overfitting). Deploy and generate new data instead of grinding.

**Epochs matter**: With 3,575 examples and batch 1, 8000 iters = 2.2 epochs. LoRA needs 2-3 epochs minimum. Calculate: `iters_needed = examples * target_epochs`.

---

### Phase 4: Deploy the Adapter

**MLX native adapter** (trained on same machine):
```bash
python -m mlx_lm.server \
  --model ./models/Model-4bit \
  --adapter-path ./adapters/ \
  --host 0.0.0.0 --port 8080 \
  --trust-remote-code --max-tokens 4096
```

**Cross-platform adapter** (PEFT from CUDA → MLX):
```python
from safetensors.numpy import load_file, save_file
import numpy as np, json

weights = load_file("peft_adapter/adapter_model.safetensors")
mlx_weights = {}
for key, arr in weights.items():
    k = key.replace("base_model.model.", "")
    k = k.replace(".lora_A.weight", ".lora_a")
    k = k.replace(".lora_B.weight", ".lora_b")
    arr = arr.astype(np.float32)
    if ".lora_a" in k: arr = arr.T  # PEFT (rank,in) → MLX (in,rank)
    if ".lora_b" in k: arr = arr.T  # PEFT (out,rank) → MLX (rank,out)
    mlx_weights[k] = arr
save_file(mlx_weights, "mlx_adapter/adapters.safetensors")

# Config must have these exact keys:
cfg = {"fine_tune_type": "lora", "num_layers": 8,
       "lora_parameters": {"rank": 8, "dropout": 0.0, "scale": 2.0}}
```

**Gotchas:**
- MLX config needs `num_layers` (not `num_lora_layers`)
- MLX config needs `fine_tune_type` field
- Use `safetensors.numpy` not `safetensors.torch` (torch may not be installed)
- Transpose LoRA A and B matrices when converting PEFT → MLX

---

### Phase 5: Build the Self-Training Loop

**Architecture:**
```
Shell wrapper (immortal loop)
  └→ Rail binary (one round, fresh arena)
       ├→ Load seeds for current level
       ├→ For each task:
       │    ├→ LLM generates code (via llm builtin → local server)
       │    ├→ Compiler verifies (binary pass/fail)
       │    ├→ On fail: feed error back, retry (up to 3x)
       │    ├→ On success: harvest (task, code) as JSONL
       │    └→ On retry success: harvest repair (broken→fixed)
       ├→ Update progress (file-based, survives crashes)
       ├→ Check curriculum advancement (2x 80%+ → level up)
       └→ Exit (wrapper restarts with fresh memory)
```

**Critical design decisions:**
1. **One round per process**: Prevents arena/memory exhaustion. Shell wrapper restarts.
2. **No temperature sweep**: 3 retries at temp 1, then move on. 15 calls per failure is insane waste.
3. **Seeds not LLM-generated tasks**: Pre-written task banks for each level. Only call LLM when no seeds exist.
4. **Single harvest entry**: One JSONL line per success, not 3 phrasings. Volume > variants at this stage.
5. **Cached compile errors**: Save compiler output to file on first compile. Don't re-compile to capture errors.
6. **Repair harvesting**: When retry succeeds, save (broken_code, error, fixed_code) as repair training data.

**Efficiency gains over naive approach:**
| Optimization | Before | After |
|---|---|---|
| LLM calls per failed task | 15 (5 temps × 3 retries) | 3 |
| Task generation | LLM call every round | Seeds only |
| Compile per error | 2x | 1x (cached) |
| Harvest writes | 3 per success | 1 |
| Round time | 8-12 min | 2-4 min |

---

### Phase 6: Monitor and Iterate

**Telegram bot for notifications:**
```bash
curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -d "chat_id=${CHAT_ID}" -d "text=Status update here"
```

**Monitor script polls every 5 min:**
- Training iter + loss (via SSH or fleet agent)
- Self-train round + level + harvested count
- GPU utilization + temperature
- Alert on training completion or crash

**Curriculum progression signals:**
- 2 consecutive rounds at 80%+ → advance level
- 3 consecutive rounds at 0% → fall back one level
- Loss plateau → stop training, deploy, generate new data

---

### Phase 7: The Flywheel

Once the loop is running, the cycle is:

```
1. Model generates code at current level
2. Compiler grades (pass/fail)
3. Successes harvested as training data
4. Failures + fixes harvested as repair data
5. At threshold (200+ new examples):
   a. Ship data to training node
   b. LoRA train with new data + old data
   c. Deploy new adapter
   d. Resume loop — model is better
6. Repeat forever
```

**Distillation path** (bigger teaches smaller):
- Train 9B → run self-train with 9B → harvest high-quality examples
- Train 4B on 9B's harvested data → 4B learns from 9B's best work
- Deploy 4B for fast inference (2-3x faster generation)
- Both retrain on combined data each cycle

---

### Common Failure Modes

| Failure | Symptom | Fix |
|---|---|---|
| Arena exhaustion | Segfault after N rounds | One process per round (shell wrapper) |
| Model generates wrong language | OCaml/Haskell syntax | Fine-tune with language-specific data first |
| Compiler crashes on bad input | Segfault in compiler, not generated code | Treat as compile_fail, not crash |
| Training OOM | Metal/CUDA out of memory | Reduce seq_len, num_layers, add grad_checkpoint |
| Loss plateau | Oscillating ±0.05 | Stop, deploy, generate new data |
| Empty assistant responses | 64% of harvest is garbage | Filter: `len(assistant) < 10 → skip` |
| Stale GPU processes | New training hangs on load | Kill all python, clear GPU, retry |
| PEFT→MLX key mismatch | Adapter load crash | Verify key mapping + transpose + config format |
| Buffered stdout | Can't see training progress | `PYTHONUNBUFFERED=1` or check adapter dir for checkpoints |
| Duplicate processes | Progress file corruption | Check `ps aux`, kill extras |

---

### Files Checklist

```
training/
  train.jsonl              ← base training data
  self_train/
    harvest.jsonl           ← compiler-verified successes
    repairs.jsonl           ← broken→fixed pairs
    progress.txt            ← round, level, counters
    log.txt                 ← one line per round
  adapters_4b_mlx/
    adapters.safetensors    ← current MLX adapter
    adapter_config.json     ← LoRA config

tools/train/
  self_train.rail           ← the training loop (single round)
  run_training.sh           ← shell wrapper (immortal restart)
  post_train.sh             ← auto-deploy pipeline
  notify.sh                 ← Telegram monitor
  train_cuda.py             ← CUDA training script (for remote GPU)
```
