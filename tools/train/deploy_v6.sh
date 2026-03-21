#!/bin/bash
# deploy_v6.sh — Pull v6 adapter from Razer, convert PEFT→MLX, restart flywheel
# v6: 32 layers (8 self_attn + 24 DeltaNet), 4118 examples, rank 8
# Run: cd ~/projects/rail && ./tools/train/deploy_v6.sh
set -e
cd ~/projects/rail

RAZER="Detro@100.109.63.37"
PEFT_TMP="/tmp/peft_adapter_v6"
MLX_ADAPTER="training/adapters_4b_v6_mlx"
MLX_PYTHON="/Users/ledaticempire/homebrew/bin/python3.11"
MODEL_4B="/Users/ledaticempire/models/Qwen3.5-4B-4bit"
PORT=8080

echo "=== DEPLOY v6 ADAPTER (32-layer, DeltaNet-aware) ==="

# 1. Pull adapter from Razer
echo "1. Pulling v6 adapter from Razer..."
mkdir -p "$PEFT_TMP"
scp -r $RAZER:~/rail_training/adapters_4b_v6/latest/* "$PEFT_TMP/" 2>&1 || \
scp -r $RAZER:~/rail_training/adapters_4b_v6/0003000_adapter/* "$PEFT_TMP/" 2>&1 || {
    echo "ERROR: No adapter found on Razer"
    exit 1
}
echo "   Pulled to $PEFT_TMP"
ls -la "$PEFT_TMP/"

# 2. Convert PEFT → MLX (handles both self_attn + DeltaNet keys)
echo "2. Converting PEFT → MLX..."
mkdir -p "$MLX_ADAPTER"
$MLX_PYTHON << 'CONVERT_EOF'
import json, numpy as np
from pathlib import Path
from safetensors.numpy import load_file, save_file

peft_dir = Path("/tmp/peft_adapter_v6")
out_dir = Path("/Users/ledaticempire/projects/rail/training/adapters_4b_v6_mlx")
out_dir.mkdir(exist_ok=True)

weights = load_file(str(peft_dir / "adapter_model.safetensors"))
with open(peft_dir / "adapter_config.json") as f:
    peft_cfg = json.load(f)

r = peft_cfg.get("r", 8)
alpha = peft_cfg.get("lora_alpha", 16)

# Convert PEFT → MLX key names
mlx_weights = {}
for key, arr in weights.items():
    k = key.replace("base_model.model.", "")
    k = k.replace(".lora_A.weight", ".lora_a")
    k = k.replace(".lora_B.weight", ".lora_b")
    arr = arr.astype(np.float32)
    if ".lora_a" in k:
        arr = arr.T
    elif ".lora_b" in k:
        arr = arr.T
    mlx_weights[k] = arr

save_file(mlx_weights, str(out_dir / "adapters.safetensors"))

# Auto-detect LoRA keys + layer count
lora_keys = set()
lora_layers = set()
for k in mlx_weights:
    if ".lora_a" in k and "layers" in k:
        parts = k.split(".")
        li = parts.index("layers") + 1
        lora_layers.add(int(parts[li]))
        module_key = ".".join(parts[li+1:]).replace(".lora_a", "")
        lora_keys.add(module_key)

mlx_cfg = {
    "fine_tune_type": "lora",
    "num_layers": len(lora_layers),
    "lora_parameters": {
        "rank": r,
        "dropout": 0.0,
        "scale": float(alpha) / r,
        "keys": sorted(lora_keys)
    },
    "model": "/Users/ledaticempire/models/Qwen3.5-4B-4bit"
}
with open(out_dir / "adapter_config.json", "w") as f:
    json.dump(mlx_cfg, f, indent=2)

print(f"Converted {len(mlx_weights)} weights across {len(lora_layers)} layers")
print(f"Keys: {sorted(lora_keys)}")
print(f"Config: rank={r}, alpha={alpha}, scale={float(alpha)/r}")
CONVERT_EOF

if [ $? -ne 0 ]; then
    echo "ERROR: Conversion failed"
    exit 1
fi
echo "   Converted to $MLX_ADAPTER"
cat "$MLX_ADAPTER/adapter_config.json"

# 3. Restart MLX server with v6 adapter
echo "3. Restarting MLX server with v6 adapter..."
pkill -f "mlx_lm.server" 2>/dev/null || true
sleep 3
$MLX_PYTHON -m mlx_lm.server \
    --model "$MODEL_4B" \
    --adapter-path "$MLX_ADAPTER" \
    --host 0.0.0.0 --port $PORT \
    --trust-remote-code --max-tokens 2048 &
echo "   Waiting for warmup..."
for i in $(seq 1 12); do
    sleep 5
    if curl -sf "http://localhost:${PORT}/v1/models" > /dev/null 2>&1; then
        echo "   MLX server UP on :${PORT}"
        break
    fi
    echo "   Attempt $i/12..."
done

# 4. Recompile and restart self-training
echo "4. Restarting flywheel..."
pkill -f rail_st_bin 2>/dev/null || true
sleep 1
./rail_native tools/train/self_train.rail 2>&1 | tail -1
cp /tmp/rail_out /tmp/rail_st_bin
nohup ./tools/train/run_training.sh > /tmp/rail_training.log 2>&1 &
disown
sleep 3
if pgrep -f rail_st_bin > /dev/null; then
    echo "   Flywheel LIVE with v6 adapter"
else
    echo "   WARNING: Flywheel failed to start"
fi

# 5. Quick bench
echo "5. Running benchmark..."
./rail_native run flywheel/bench.rail 2>&1 | tail -5

echo ""
echo "=== v6 DEPLOYMENT COMPLETE ==="
echo "Monitor: tail -f /tmp/rail_training.log"
echo "Progress: cat training/self_train/progress.txt"
