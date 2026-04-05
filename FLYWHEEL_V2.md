# FLYWHEEL V2 — ANE-Powered Self-Improving Rail

The architecture that replaces everything.

## The Loop

```
                    ANE (3W, background)
                         │
                    trains 48.8M transformer
                    on verified Rail programs
                         │
                    ┌────▼────┐
                    │  Model  │ ← weights checkpoint
                    └────┬────┘
                         │
                    generates Rail code
                         │
              ┌──────────▼──────────┐
              │   Rail Compiler     │ ← the oracle
              │   (./rail_native)   │
              └──────────┬──────────┘
                         │
                ┌────────┴────────┐
                │                 │
           compiles ✓         fails ✗
                │                 │
           ┌────▼────┐     ┌─────▼─────┐
           │ harvest │     │  repair   │
           │ .jsonl  │     │  example  │
           └────┬────┘     └─────┬─────┘
                │                 │
                └────────┬────────┘
                         │
                    tokenize + append
                    to training data
                         │
                    ┌────▼────┐
                    │  ANE   │
                    │ retrain │
                    └─────────┘
```

## What Changed

**Before (Flywheel V1):**
- Gemma 4 E4B on MLX GPU (5.3GB, 67 tok/s)
- CUDA QLoRA on Razer for training (8GB VRAM, SSH flaky)
- Python everywhere: mlx_lm, transformers, peft, bitsandbytes
- 14/30 bench via prompt engineering
- Training and inference on different machines, different frameworks

**Now (Flywheel V2):**
- ANE trains 48.8M transformer at 1s/step, 3W power
- GPU is FREE — available for inference, compilation, anything
- Training data: compiler-verified Rail programs (perfect oracle)
- One machine. One chip. ANE trains, GPU serves, compiler verifies.
- No Python in the training loop (rustane is Rust + ANE)
- No network dependency (no Razer SSH, no Tailscale)

## Components

### 1. Training (ANE via rustane)
```bash
cargo run -p engine --release --bin train -- \
  --data training/railml_data/train.bin \
  --val training/railml_data/val.bin \
  --model gpt_karpathy \
  --steps 10000 \
  --val-interval 500 \
  --ckpt-interval 1000
```
- 48.8M params (768 dim, 6 layers, 6 heads, 512 seq)
- 10 fused ANE kernels, Metal Adam optimizer
- 1s/step, loss 8.9 → 3.2 in 100 steps
- Runs 24/7 at 3W without touching GPU

### 2. Data Pipeline
```
harvest.jsonl (10K+ programs)
  → char tokenizer (ASCII → uint16)
  → train.bin / val.bin (1.18M tokens)
  → rustane training format
```
Rebuild: `python3 tools/railml/tokenize_rail.py`

### 3. Inference (GPU via MLX or Rail)
- **Option A**: Export rustane checkpoint → safetensors → MLX server
- **Option B**: Rail native inference (tools/railml/inference.rail)
- **Option C**: Metal GPU dispatch from Rail (proven: matmul works)

### 4. Oracle (Rail compiler)
```bash
./rail_native /tmp/candidate.rail 2>&1
```
Binary: compiles or doesn't. Runs or doesn't. Output correct or not.
No RLHF, no human preference, no vibes. Perfect training signal.

### 5. Harvesting
Same as V1: generate → compile → verify → append to training JSONL.
But now the model is 48.8M params with real attention, not a prompted 8B.

## The Schedule

ANE trains in background. Every N steps:
1. Export checkpoint
2. Generate 100 Rail programs
3. Compile each with rail_native
4. Harvest passes, create repair examples from failures
5. Tokenize new data, append to train.bin
6. Continue training (no restart needed — rustane supports data reload)

## Power Budget

| Component | Power | Role |
|---|---|---|
| ANE | 3-5W | Training (continuous) |
| GPU | 0W idle, 15W active | Inference (on demand) |
| CPU | 5W | Compilation, orchestration |
| **Total during training** | **~10W** | |
| **Total during generation** | **~25W** | |

24/7 training at 10W = 0.24 kWh/day. The model improves while you sleep.

## Migration from V1

### Kill
- Gemma 4 MLX server (5.3GB GPU memory freed)
- CUDA training on Razer (8GB VRAM freed, SSH dependency gone)
- mlx_lm LoRA crash workarounds (semaphore leak, 50-iter bursts)
- adapter conversion scripts (PEFT → MLX)

### Keep
- Rail compiler (the oracle, unchanged)
- bench.rail (scoring, unchanged)
- self_train.rail curriculum (25 levels, task seeds)
- harvest pipeline (JSONL format, SHA-256 dedup)
- Pi fleet display (reads from Mini)

### Add
- rustane ANE training loop
- Checkpoint → inference conversion
- Data pipeline: JSONL → uint16 tokens
- Orchestrator: training + generation + harvesting in one script

## Why This Is Better

1. **One machine**: No Razer SSH timeouts, no weight transfer, no adapter conversion
2. **Always training**: ANE runs at 3W, GPU stays free for inference and compilation
3. **48.8M real transformer**: Attention, positional encoding, layer norm — learns syntax, not just char frequency
4. **Perfect data**: Every training example compiled and verified by the oracle
5. **No Python in training**: Rust + ANE + Metal. Rail compiles and verifies. Python only for tokenization.
