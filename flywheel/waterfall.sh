#!/bin/bash
# waterfall.sh — Coordinated dual-node flywheel
#
# Mac Mini: generates training data via self_train (1.5B on :8082)
# Razer3070: trains 4B model on CUDA (16 layers, 1024 seq, QLoRA)
#
# Usage:
#   ./flywheel/waterfall.sh start     — launch both nodes
#   ./flywheel/waterfall.sh status    — check both nodes
#   ./flywheel/waterfall.sh stop      — stop both nodes
#   ./flywheel/waterfall.sh sync      — push latest data to Razer
#   ./flywheel/waterfall.sh pull      — pull trained adapter from Razer
#   ./flywheel/waterfall.sh cycle     — sync data → restart training on Razer

set -euo pipefail
cd "$(dirname "$0")/.."

RAZER="Detro@100.109.63.37"
RAZER_DIR="~/rail_training"
LOCAL_HARVEST="training/self_train/harvest_clean.jsonl"
LOCAL_MERGED="/tmp/rail_train_clean/train.jsonl"
MERGED="/tmp/rail_dataset_merged.jsonl"
SELF_TRAIN_PORT=8082
SELF_TRAIN_PID="/tmp/waterfall_selftrain.pid"
RAZER_TRAIN_PID="/tmp/waterfall_razer_train.pid"

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[0;33m'
RST='\033[0m'

log() { echo -e "${GRN}[waterfall]${RST} $*"; }
warn() { echo -e "${YEL}[waterfall]${RST} $*"; }
err() { echo -e "${RED}[waterfall]${RST} $*"; }

# --- Data Operations ---

merge_data() {
    log "Merging datasets..."
    cat "$LOCAL_MERGED" "$LOCAL_HARVEST" 2>/dev/null | python3 -c "
import sys
seen = set()
out = []
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    h = hash(line)
    if h not in seen:
        seen.add(h)
        out.append(line)
print(f'  {len(out)} unique examples', file=sys.stderr)
for l in out:
    print(l)
" > "$MERGED" 2>&1
    wc -l < "$MERGED" | xargs -I{} log "  Merged dataset: {} examples"
}

sync_to_razer() {
    merge_data
    log "Pushing dataset to Razer..."
    scp -q "$MERGED" "$RAZER:$RAZER_DIR/data/train.jsonl"
    log "  Done."
}

pull_adapter() {
    local dest="training/adapters_4b_cuda"
    mkdir -p "$dest"
    log "Pulling 4B adapter from Razer..."
    scp -rq "$RAZER:$RAZER_DIR/adapters_4b/latest/*" "$dest/" 2>/dev/null || {
        err "No adapter checkpoint found on Razer yet"
        return 1
    }
    log "  Saved to $dest/"
    ls -lh "$dest/" | head -5
}

# --- Mini: Self-Train (Data Generation) ---

start_mini() {
    # Check 1.5B server is up
    if ! curl -s http://localhost:$SELF_TRAIN_PORT/v1/models >/dev/null 2>&1; then
        err "1.5B server not running on :$SELF_TRAIN_PORT — start it first"
        return 1
    fi

    # Check if already running
    if [ -f "$SELF_TRAIN_PID" ] && kill -0 "$(cat "$SELF_TRAIN_PID")" 2>/dev/null; then
        warn "Self-train already running (PID $(cat "$SELF_TRAIN_PID"))"
        return 0
    fi

    log "Starting self_train on Mini (1.5B, port $SELF_TRAIN_PORT)..."
    nohup ./rail_native_llm run tools/train/self_train.rail --port $SELF_TRAIN_PORT --no-retrain yes \
        > /tmp/waterfall_selftrain.log 2>&1 &
    echo $! > "$SELF_TRAIN_PID"
    log "  PID: $(cat "$SELF_TRAIN_PID") — log: /tmp/waterfall_selftrain.log"
}

stop_mini() {
    if [ -f "$SELF_TRAIN_PID" ]; then
        local pid=$(cat "$SELF_TRAIN_PID")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            log "Stopped self_train (PID $pid)"
        fi
        rm -f "$SELF_TRAIN_PID"
    else
        warn "No self_train PID file found"
    fi
}

# --- Razer: 4B CUDA Training ---

start_razer() {
    log "Starting 4B training on Razer (QLoRA, 16 layers, 1024 seq)..."
    # Run in background on Razer via nohup
    ssh "$RAZER" "cd $RAZER_DIR && nohup python train_cuda.py \
        --model Qwen/Qwen3.5-4B \
        --data ./data \
        --adapter-path ./adapters_4b \
        --iters 2000 \
        --batch-size 1 \
        --learning-rate 1e-5 \
        --lora-rank 8 \
        --num-layers 16 \
        --max-seq-length 1024 \
        --quantize-4bit \
        --gradient-checkpointing \
        --save-every 250 \
        --report-every 50 \
        > train.log 2>&1 &
    echo \$!" | tee "$RAZER_TRAIN_PID"
    log "  Training launched. Check: ssh $RAZER 'tail -f $RAZER_DIR/train.log'"
}

stop_razer() {
    log "Stopping Razer training..."
    ssh "$RAZER" "pkill -f train_cuda.py 2>/dev/null || true"
    rm -f "$RAZER_TRAIN_PID"
    log "  Done."
}

# --- Status ---

status() {
    echo "=============================="
    echo "  WATERFALL STATUS"
    echo "=============================="
    echo ""

    # Mini
    echo -e "${GRN}[Mini — Data Generation]${RST}"
    if curl -s http://localhost:$SELF_TRAIN_PORT/v1/models >/dev/null 2>&1; then
        echo "  1.5B server: UP (:$SELF_TRAIN_PORT)"
    else
        echo -e "  1.5B server: ${RED}DOWN${RST}"
    fi
    if [ -f "$SELF_TRAIN_PID" ] && kill -0 "$(cat "$SELF_TRAIN_PID")" 2>/dev/null; then
        echo "  self_train: RUNNING (PID $(cat "$SELF_TRAIN_PID"))"
        if [ -f training/self_train/progress.txt ]; then
            echo "  $(grep -E '^(round|level|harvested)=' training/self_train/progress.txt | tr '\n' ' ')"
        fi
    else
        echo -e "  self_train: ${YEL}STOPPED${RST}"
    fi
    echo "  harvest_clean: $(wc -l < "$LOCAL_HARVEST" 2>/dev/null || echo 0) examples"
    echo ""

    # Razer
    echo -e "${GRN}[Razer — 4B Training]${RST}"
    if ssh -o ConnectTimeout=3 "$RAZER" "true" 2>/dev/null; then
        echo "  Connection: UP"
        ssh "$RAZER" "
            nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null | xargs -I{} echo '  GPU: {}'
            if pgrep -f train_cuda.py >/dev/null 2>&1; then
                echo '  Training: RUNNING'
                tail -1 $RAZER_DIR/train.log 2>/dev/null | xargs -I{} echo '  Last: {}'
            else
                echo '  Training: STOPPED'
                tail -1 $RAZER_DIR/train.log 2>/dev/null | xargs -I{} echo '  Last: {}'
            fi
            echo \"  Dataset: \$(wc -l < $RAZER_DIR/data/train.jsonl 2>/dev/null || echo 0) examples\"
            ls -d $RAZER_DIR/adapters_4b/0*_adapter 2>/dev/null | wc -l | xargs -I{} echo '  Checkpoints: {}'
        " 2>/dev/null
    else
        echo -e "  Connection: ${RED}OFFLINE${RST}"
    fi
    echo ""

    # Dataset
    echo -e "${GRN}[Dataset]${RST}"
    echo "  train_clean: $(wc -l < "$LOCAL_MERGED" 2>/dev/null || echo 0) (original)"
    echo "  harvest_clean: $(wc -l < "$LOCAL_HARVEST" 2>/dev/null || echo 0) (self_train)"
    echo "  merged: $(wc -l < "$MERGED" 2>/dev/null || echo 0) (deduped)"
    echo ""
}

# --- Cycle (sync + restart) ---

cycle() {
    log "=== WATERFALL CYCLE ==="
    stop_razer
    sync_to_razer
    start_razer
    log "=== Cycle complete. Razer retraining on fresh data. ==="
}

# --- Main ---

case "${1:-status}" in
    start)
        start_mini
        start_razer
        log "Waterfall running on both nodes."
        ;;
    stop)
        stop_mini
        stop_razer
        log "Waterfall stopped."
        ;;
    status)
        status
        ;;
    sync)
        sync_to_razer
        ;;
    pull)
        pull_adapter
        ;;
    cycle)
        cycle
        ;;
    mini)
        start_mini
        ;;
    razer)
        start_razer
        ;;
    *)
        echo "Usage: $0 {start|stop|status|sync|pull|cycle|mini|razer}"
        exit 1
        ;;
esac
