#!/bin/bash
# notify.sh — Send Telegram updates for flywheel training
# Usage: ./notify.sh "message"
#        ./notify.sh monitor   — poll Razer training + self-train progress

TOKEN="8393851683:AAH7X_AyUQoNiCMWvfNQI-W9vDqdxUN8amo"
CHAT_ID="7737719797"
FLEET_TOKEN="fleet-test-token-2026"
RAZER="100.109.63.37"
PROGRESS="$HOME/projects/rail/training/self_train/progress.txt"
STLOG="$HOME/projects/rail/training/self_train/log.txt"
PY="/opt/homebrew/bin/python3.11"

send() {
    curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        -d "parse_mode=HTML" \
        -d "text=$1" > /dev/null 2>&1
}

if [ "$1" = "monitor" ]; then
    LAST_CKPT=""
    LAST_ROUND=0
    INTERVAL=${2:-300}
    RAZER_USER="Detro"
    ADAPTER_DIR="~/rail_training/adapters_4b_v2"

    send "📡 <b>Flywheel Monitor Started</b>
Polling Razer via SSH every ${INTERVAL}s"

    while true; do
        sleep "$INTERVAL"

        # Poll Razer GPU + checkpoint status via SSH
        RAZER_INFO=$(ssh -o ConnectTimeout=10 ${RAZER_USER}@${RAZER} "
            GPU_UTIL=\$(nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used --format=csv,noheader 2>/dev/null || echo 'offline')
            GPU_PID=\$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null)
            CKPT=\$(ls -1d ${ADAPTER_DIR}/0*_adapter 2>/dev/null | tail -1 | xargs basename 2>/dev/null)
            LATEST=\$(test -d ${ADAPTER_DIR}/latest && echo yes || echo no)
            echo \"\${GPU_UTIL}||\${GPU_PID}||\${CKPT}||\${LATEST}\"
        " 2>/dev/null || echo "ssh_failed||||")

        GPU_STATUS=$(echo "$RAZER_INFO" | cut -d'|' -f1)
        GPU_PID=$(echo "$RAZER_INFO" | sed 's/.*||\([^|]*\)||.*/\1/' | head -1)
        CKPT=$(echo "$RAZER_INFO" | $PY -c "import sys; parts=sys.stdin.read().strip().split('||'); print(parts[2] if len(parts)>2 else '')" 2>/dev/null)
        HAS_LATEST=$(echo "$RAZER_INFO" | $PY -c "import sys; parts=sys.stdin.read().strip().split('||'); print(parts[3] if len(parts)>3 else 'no')" 2>/dev/null)

        # Self-train progress
        ROUND=$(grep 'round=' "$PROGRESS" 2>/dev/null | cut -d= -f2)
        LEVEL=$(grep 'level=' "$PROGRESS" 2>/dev/null | cut -d= -f2)
        HARVESTED=$(grep '^harvested=' "$PROGRESS" 2>/dev/null | cut -d= -f2)

        # New checkpoint detected
        if [ -n "$CKPT" ] && [ "$CKPT" != "$LAST_CKPT" ]; then
            send "💾 <b>Checkpoint: ${CKPT}</b>
GPU: ${GPU_STATUS}
Self-train: R${ROUND} L${LEVEL} H${HARVESTED}"
            LAST_CKPT="$CKPT"
        fi

        # Self-train round update
        if [ -n "$ROUND" ] && [ "$ROUND" != "$LAST_ROUND" ]; then
            LAST_LOG=$(tail -1 "$STLOG" 2>/dev/null)
            send "🚂 <b>Round ${ROUND}</b> L${LEVEL} H${HARVESTED}
${LAST_LOG}"
            LAST_ROUND="$ROUND"
        fi

        # Training finished or crashed
        if [ -z "$GPU_PID" ] && [ "$GPU_STATUS" != "ssh_failed" ]; then
            if [ "$HAS_LATEST" = "yes" ]; then
                send "✅ <b>Training Complete!</b>
Last checkpoint: ${CKPT}
post_train.sh should pick this up automatically."
                break
            else
                send "⚠️ <b>GPU idle, no adapter.</b> Training may have crashed.
GPU: ${GPU_STATUS}"
            fi
        fi

        # Regular heartbeat (every 3rd poll = 15min)
        POLL_COUNT=$((${POLL_COUNT:-0} + 1))
        if [ $((POLL_COUNT % 3)) -eq 0 ]; then
            send "💓 <b>Heartbeat</b> (${POLL_COUNT} polls)
GPU: ${GPU_STATUS}
Self-train: R${ROUND} L${LEVEL} H${HARVESTED}"
        fi
    done
else
    send "$1"
fi
