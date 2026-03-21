#!/bin/bash
# post_train.sh — Automated post-training pipeline
# Polls Razer for training completion, then:
#   1. Pulls adapter from Razer
#   2. Converts PEFT adapter to MLX format
#   3. Restarts MLX server with 4B + adapter
#   4. Recompiles self_train.rail
#   5. Launches the training loop
#   6. Sends Telegram updates at each step
#
# Usage: ./tools/train/post_train.sh
#   Run this and walk away. It handles everything.

set -e
cd ~/projects/rail

NOTIFY="./tools/train/notify.sh"
FLEET_TOKEN="fleet-test-token-2026"
RAZER="100.109.63.37"
RAZER_USER="Detro"
ADAPTER_LOCAL="training/adapters_4b_mlx"
MLX_PYTHON="/Users/ledaticempire/homebrew/bin/python3.11"
MODEL_4B="/Users/ledaticempire/models/Qwen3.5-4B-4bit"
PORT=8080

# --- Step 0: Wait for Razer training to produce a checkpoint ---
RAZER_ADAPTER_PATH="~/rail_training/adapters_4b_v3/latest/adapter_model.safetensors"
LAST_SEEN=""
echo "Polling Razer for adapter checkpoint..."
while true; do
    # Check if adapter file exists and get its timestamp
    TSTAMP=$(ssh -o ConnectTimeout=5 ${RAZER_USER}@${RAZER} \
        "python -c \"import os; p='${RAZER_ADAPTER_PATH}'.replace('~',os.path.expanduser('~')); print(int(os.path.getmtime(p)) if os.path.exists(p) else 'NONE')\" 2>/dev/null || echo NONE")

    if [ -n "$TSTAMP" ] && [ "$TSTAMP" != "NONE" ]; then
        if [ "$TSTAMP" != "$LAST_SEEN" ]; then
            echo "New checkpoint detected! (ts=$TSTAMP)"
            $NOTIFY "✅ <b>Razer checkpoint ready!</b>
Starting post-training pipeline..."
            break
        fi
    fi

    # Also check if training process is still alive
    GPU_PID=$(ssh -o ConnectTimeout=5 ${RAZER_USER}@${RAZER} \
        "nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null" 2>/dev/null)
    if [ -z "$GPU_PID" ]; then
        # No GPU process — check if adapter exists (training finished) or died
        if [ -n "$TSTAMP" ] && [ "$TSTAMP" != "NONE" ]; then
            echo "Training finished (no GPU process, adapter exists)."
            $NOTIFY "✅ <b>Razer Training Complete!</b>
Starting post-training pipeline..."
            break
        else
            echo "  WARNING: No GPU process and no adapter. Training may have crashed."
            $NOTIFY "⚠️ <b>Razer GPU idle, no adapter found.</b> Check manually."
            sleep 300
        fi
    else
        echo "  Training running (PID $GPU_PID) — checking again in 5m..."
        sleep 300
    fi
done

# --- Step 1: Pull adapter from Razer ---
echo "Pulling adapter from Razer..."
mkdir -p /tmp/peft_adapter_4b
scp -r ${RAZER_USER}@${RAZER}:~/rail_training/adapters_4b_v3/latest/* /tmp/peft_adapter_4b/ 2>&1
if [ ! -f /tmp/peft_adapter_4b/adapter_model.safetensors ] && [ ! -f /tmp/peft_adapter_4b/adapter_config.json ]; then
    $NOTIFY "❌ <b>Adapter pull failed</b> — no adapter files found"
    exit 1
fi
echo "  Adapter pulled."
$NOTIFY "📥 <b>Adapter pulled from Razer</b>"

# --- Step 2: Convert PEFT adapter to MLX format ---
echo "Converting PEFT adapter to MLX format..."

# First check if we have 4B in MLX format locally
if [ ! -d "$MODEL_4B" ]; then
    echo "  Converting base 4B model to MLX first..."
    $MLX_PYTHON -m mlx_lm convert \
        --hf-path Qwen/Qwen3.5-4B \
        --mlx-path "$MODEL_4B" \
        -q --q-bits 4 \
        --trust-remote-code 2>&1
    echo "  Base model converted."
fi

# Convert PEFT LoRA weights to MLX adapter format
# MLX expects: adapters.safetensors + adapter_config.json
$MLX_PYTHON << 'CONVERT_EOF'
import json, numpy as np
from pathlib import Path
from safetensors.numpy import load_file, save_file

peft_dir = Path("/tmp/peft_adapter_4b")
out_dir = Path("/Users/ledaticempire/projects/rail/training/adapters_4b_mlx")
out_dir.mkdir(exist_ok=True)

# Load PEFT adapter (as numpy — no torch needed)
weights = load_file(str(peft_dir / "adapter_model.safetensors"))

# Load PEFT config
with open(peft_dir / "adapter_config.json") as f:
    peft_cfg = json.load(f)

r = peft_cfg.get("r", 8)
alpha = peft_cfg.get("lora_alpha", 16)
layers = peft_cfg.get("layers_to_transform", [])

# Convert PEFT key names to MLX key names
# PEFT: base_model.model.model.layers.{N}.self_attn.{qkvo}_proj.lora_{A,B}.weight
# MLX:  model.layers.{N}.self_attn.{qkvo}_proj.lora_{a,b}
mlx_weights = {}
for key, arr in weights.items():
    k = key.replace("base_model.model.", "")
    k = k.replace(".lora_A.weight", ".lora_a")
    k = k.replace(".lora_B.weight", ".lora_b")
    arr = arr.astype(np.float32)
    # Transpose: PEFT lora_A is (rank, in), MLX wants (in, rank)
    # PEFT lora_B is (out, rank), MLX wants (rank, out)
    if ".lora_a" in k:
        arr = arr.T
    elif ".lora_b" in k:
        arr = arr.T
    mlx_weights[k] = arr

save_file(mlx_weights, str(out_dir / "adapters.safetensors"))

# Auto-detect LoRA keys from converted weights
lora_keys = set()
for k in mlx_weights:
    if ".lora_a" in k:
        parts = k.split(".")
        li = parts.index("layers") + 1
        module_key = ".".join(parts[li+1:]).replace(".lora_a", "")
        lora_keys.add(module_key)

# Write MLX adapter config (must match mlx_lm expected format)
num_lora_layers = len(set(
    int(k.split(".")[k.split(".").index("layers")+1])
    for k in mlx_weights if "layers" in k
))
mlx_cfg = {
    "fine_tune_type": "lora",
    "num_layers": num_lora_layers,
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

print(f"Converted {len(mlx_weights)} weight tensors across {num_lora_layers} layers")
print(f"LoRA keys: {sorted(lora_keys)}")
print(f"Config: rank={r}, alpha={alpha}")
print(f"Saved to {out_dir}")
CONVERT_EOF

if [ $? -ne 0 ]; then
    $NOTIFY "❌ <b>Adapter conversion failed</b>"
    exit 1
fi
echo "  Adapter converted."
$NOTIFY "🔄 <b>Adapter converted to MLX format</b>"

# --- Step 3: Stop MLX server, restart with 4B + adapter ---
echo "Restarting MLX server..."
pkill -9 -f 'mlx_lm' 2>/dev/null
launchctl bootout gui/$(id -u)/com.ledatic.mlx 2>/dev/null
launchctl bootout gui/$(id -u)/com.ledatic.mlx_fast 2>/dev/null
sleep 3

$MLX_PYTHON -m mlx_lm.server \
    --model "$MODEL_4B" \
    --adapter-path "$ADAPTER_LOCAL" \
    --host 0.0.0.0 --port $PORT \
    --trust-remote-code --max-tokens 4096 \
    > /tmp/mlx_st_server.log 2>&1 &

echo "  Waiting for server warmup..."
for i in $(seq 1 12); do
    sleep 5
    CHECK=$(curl -s -m 5 "http://localhost:${PORT}/v1/models" 2>/dev/null | head -1)
    if [ -n "$CHECK" ] && [ ${#CHECK} -gt 5 ]; then
        echo "  Server ready!"
        break
    fi
    echo "  Attempt $i/12..."
done

# Verify
CHECK=$(curl -s -m 5 "http://localhost:${PORT}/v1/models" 2>/dev/null | head -1)
if [ -z "$CHECK" ] || [ ${#CHECK} -le 5 ]; then
    $NOTIFY "❌ <b>MLX server failed to start</b>
Check: tail /tmp/mlx_st_server.log"
    exit 1
fi
echo "  MLX server running on :${PORT}"
$NOTIFY "🟢 <b>MLX server live</b> — 4B + Rail adapter on :${PORT}"

# --- Step 4: Recompile self_train.rail ---
echo "Recompiling self_train.rail..."
./rail_native tools/train/self_train.rail 2>&1
cp /tmp/rail_out /tmp/rail_st_bin
echo "  Compiled."

# --- Step 5: Launch training loop ---
echo "Launching self-training loop..."
rm -f /tmp/rail_st_stop
nohup ./tools/train/run_training.sh > /tmp/rail_training.log 2>&1 &
disown
sleep 5

# Verify it's running
if pgrep -f 'rail_st_bin' > /dev/null; then
    $NOTIFY "🚀 <b>Flywheel is LIVE!</b>
4B + Rail adapter → compiler oracle → harvest → repeat
Tail: tail -f /tmp/rail_training.log"
    echo "=== FLYWHEEL RUNNING ==="
else
    $NOTIFY "❌ <b>Self-train failed to start</b>
Check: tail /tmp/rail_training.log"
    exit 1
fi
