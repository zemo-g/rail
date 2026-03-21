#!/bin/bash
# deploy_v3.sh — Stop Razer training (plateaued), pull best adapter, convert, deploy
# Run in a separate terminal: cd ~/projects/rail && ./tools/train/deploy_v3.sh
set -e
cd ~/projects/rail

RAZER="Detro@100.109.63.37"
RAZER_DIR="rail_training"
LOCAL_ADAPTER="training/adapters_4b_v3"
MLX_ADAPTER="training/adapters_4b_mlx"

echo "=== DEPLOY v3 ADAPTER ==="

# 1. Stop Razer training (it's plateaued)
echo "1. Stopping Razer training..."
ssh $RAZER "pkill -f train_cuda 2>/dev/null || true"
sleep 2
echo "   Done."

# 2. Pull best checkpoint
echo "2. Pulling adapter from Razer..."
mkdir -p $LOCAL_ADAPTER
scp -r $RAZER:~/$RAZER_DIR/adapters_4b_v3/checkpoint-2000/* $LOCAL_ADAPTER/ 2>/dev/null || \
scp -r $RAZER:~/$RAZER_DIR/adapters_4b_v3/latest/* $LOCAL_ADAPTER/ 2>/dev/null || \
scp -r $RAZER:~/$RAZER_DIR/adapters_4b_v3/* $LOCAL_ADAPTER/ 2>/dev/null
echo "   Pulled to $LOCAL_ADAPTER"
ls -la $LOCAL_ADAPTER/

# 3. Convert PEFT → MLX
echo "3. Converting PEFT → MLX..."
/Users/ledaticempire/homebrew/bin/python3.11 -c "
from mlx_lm import convert
convert(
    hf_path='/Users/ledaticempire/models/Qwen3.5-4B-4bit',
    adapter_path='$LOCAL_ADAPTER',
    mlx_path='$MLX_ADAPTER',
    quantize=True
)
print('Conversion complete.')
" 2>&1 || {
    echo "   PEFT→MLX conversion failed. Trying manual copy..."
    # Fallback: if adapter is already MLX-compatible, just copy
    cp -r $LOCAL_ADAPTER/* $MLX_ADAPTER/ 2>/dev/null || true
}
echo "   MLX adapter at $MLX_ADAPTER"

# 4. Restart MLX server
echo "4. Restarting MLX server..."
pkill -f "mlx_lm.server" 2>/dev/null || true
sleep 3
/Users/ledaticempire/homebrew/bin/python3.11 -m mlx_lm.server \
  --model /Users/ledaticempire/models/Qwen3.5-4B-4bit \
  --adapter-path $MLX_ADAPTER \
  --host 0.0.0.0 --port 8080 --trust-remote-code --max-tokens 4096 &
sleep 15
curl -sf http://localhost:8080/v1/models | head -1 && echo "   MLX server UP" || echo "   MLX server FAILED"

# 5. Restart flywheel with fresh binary
echo "5. Restarting flywheel..."
pkill -f rail_st_bin 2>/dev/null || true
sleep 2
./rail_native tools/train/self_train.rail && cp /tmp/rail_out /tmp/rail_st_bin
md5 -q tools/train/self_train.rail > /tmp/rail_st_hash
rm -f /tmp/rail_st_stop
nohup ./tools/train/run_training.sh > /tmp/rail_training.log 2>&1 &
disown
echo "   Flywheel restarted with v3 adapter. PID: $!"

echo ""
echo "=== DONE ==="
echo "Monitor: tail -f /tmp/rail_training.log"
echo "Progress: cat training/self_train/progress.txt"
