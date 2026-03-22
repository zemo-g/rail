#!/bin/bash
# monitor_razer.sh — Poll Razer training, auto-deploy when complete
# Usage: ./tools/train/monitor_razer.sh [--auto-deploy]
# Without --auto-deploy, just reports status.
set -e
cd ~/projects/rail

RAZER="Detro@100.109.63.37"
AUTO_DEPLOY="${1:-}"

check_razer() {
    # Check GPU process
    GPU_PID=$(ssh -o ConnectTimeout=5 "$RAZER" \
        "nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null" 2>/dev/null || echo "")

    # Check log
    LOG_TAIL=$(ssh -o ConnectTimeout=5 "$RAZER" \
        "tail -3 ~/rail_training/v6_train.log 2>/dev/null" 2>/dev/null || echo "unreachable")

    # Check adapter
    HAS_ADAPTER=$(ssh -o ConnectTimeout=5 "$RAZER" \
        "ls ~/rail_training/adapters_4b_v6/latest/adapter_model.safetensors 2>/dev/null && echo YES || echo NO" 2>/dev/null || echo "NO")

    echo "$(date '+%H:%M:%S') | GPU_PID=${GPU_PID:-none} | Adapter=${HAS_ADAPTER} | Log: ${LOG_TAIL##*$'\n'}"

    # If GPU idle and adapter exists → training complete
    if [ -z "$GPU_PID" ] && [ "$HAS_ADAPTER" = "YES" ]; then
        echo "=== TRAINING COMPLETE ==="
        if [ "$AUTO_DEPLOY" = "--auto-deploy" ]; then
            echo "Auto-deploying v6 adapter..."
            exec ./tools/train/deploy_v6.sh
        else
            echo "Run: ./tools/train/deploy_v6.sh"
        fi
        exit 0
    fi

    # Crash detection: GPU idle but no adapter = training died
    if [ -z "$GPU_PID" ] && [ "$HAS_ADAPTER" = "NO" ]; then
        echo "$(date '+%H:%M:%S') | WARNING: GPU idle, no adapter — training may have crashed!"
        echo "Check: ssh $RAZER 'tail -20 ~/rail_training/v6_train.log'"
    fi
}

echo "Monitoring Razer v6 training (check every 5min)..."
echo "Press Ctrl+C to stop."
while true; do
    check_razer
    sleep 300
done
