#!/bin/bash
MODEL="/Users/ledaticempire/models/Qwen3.5-4B-4bit"
ADAPTER="/Users/ledaticempire/projects/rail/training/adapters_4b_v5_mlx"
PORT=8080
PYTHON="/Users/ledaticempire/homebrew/bin/python3.11"
LOG="/tmp/mlx_server.log"
RESTART_INTERVAL=1800

start_server() {
    pkill -f "mlx_lm.server.*$PORT" 2>/dev/null
    sleep 3
    $PYTHON -m mlx_lm.server \
        --model "$MODEL" --adapter-path "$ADAPTER" \
        --host 0.0.0.0 --port $PORT --trust-remote-code --max-tokens 2048 \
        >> "$LOG" 2>&1 &
    sleep 15
}

echo "$(date): Watchdog v3 — 4B+v4 adapter (restart every ${RESTART_INTERVAL}s)" >> /tmp/mlx_watchdog.log
LAST_RESTART=$(date +%s)

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - LAST_RESTART))
    if ! curl -sf http://localhost:$PORT/v1/models > /dev/null 2>&1; then
        echo "$(date): MLX server down, restarting..." >> /tmp/mlx_watchdog.log
        start_server
        LAST_RESTART=$(date +%s)
    elif [ $ELAPSED -ge $RESTART_INTERVAL ]; then
        echo "$(date): Proactive restart (${ELAPSED}s)" >> /tmp/mlx_watchdog.log
        start_server
        LAST_RESTART=$(date +%s)
    fi
    sleep 10
done
