#!/bin/bash
# waterfall.sh — Coordinated dual-node flywheel
#
# Mac Mini (24GB): serves models + generates training data via self_train
# Razer3070 (8GB VRAM): CUDA training for 4B (QLoRA, 16 layers, 1024 seq)
#
# Usage:
#   ./flywheel/waterfall.sh start       — launch both nodes
#   ./flywheel/waterfall.sh stop        — stop both nodes
#   ./flywheel/waterfall.sh status      — check both nodes
#   ./flywheel/waterfall.sh sync        — push latest data to Razer
#   ./flywheel/waterfall.sh pull        — pull trained adapter from Razer
#   ./flywheel/waterfall.sh cycle       — sync data → restart training on Razer
#   ./flywheel/waterfall.sh serve NAME  — start model server (2b-rail, 0.8b-rail, etc.)
#   ./flywheel/waterfall.sh bench PORT  — run benchmark against model on PORT

set -euo pipefail
cd "$(dirname "$0")/.."

# ── Fleet Config ──────────────────────────────────────────────────────────────

RAZER="Detro@100.109.63.37"
RAZER_DIR="rail_training"  # no ~, expanded by ssh
AIR="reillygomez@100.120.203.70"

# Models (Qwen3.5 family — March 2026)
MODEL_08B="Qwen/Qwen3.5-0.8B"
MODEL_2B="Qwen/Qwen3.5-2B"
MODEL_4B="Qwen/Qwen3.5-4B"
MODEL_DIR="/Users/ledaticempire/models"

# Ports
PORT_4B=8081
PORT_2B=8082
PORT_08B=8083

# Data paths
HARVEST_CLEAN="training/self_train/harvest_clean.jsonl"
TRAIN_CLEAN="/tmp/rail_train_clean/train.jsonl"
MERGED="/tmp/rail_dataset_merged.jsonl"

# PID tracking
PID_DIR="/tmp/waterfall"
mkdir -p "$PID_DIR"

# Python (MLX server)
PYTHON="/Users/ledaticempire/homebrew/bin/python3.11"

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[0;33m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

log()  { echo -e "${GRN}[waterfall]${RST} $*"; }
warn() { echo -e "${YEL}[waterfall]${RST} $*"; }
err()  { echo -e "${RED}[waterfall]${RST} $*"; }
hdr()  { echo -e "\n${BLD}${CYN}$*${RST}"; }

# ── Data Operations ───────────────────────────────────────────────────────────

merge_data() {
    log "Merging datasets..."
    local count=0
    if [ -f "$TRAIN_CLEAN" ] || [ -f "$HARVEST_CLEAN" ]; then
        cat "$TRAIN_CLEAN" "$HARVEST_CLEAN" 2>/dev/null | python3 -c "
import sys, json
seen = set()
out = []
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    # Dedupe by content hash
    h = hash(line)
    if h not in seen:
        seen.add(h)
        # Validate JSON
        try:
            obj = json.loads(line)
            if 'messages' in obj and len(obj['messages']) >= 2:
                out.append(line)
        except: pass
for l in out:
    print(l)
print(len(out), file=sys.stderr)
" > "$MERGED" 2>/tmp/waterfall_merge_count.txt
        count=$(cat /tmp/waterfall_merge_count.txt)
    fi
    log "  Merged: $count valid examples"
}

sync_to_razer() {
    merge_data
    log "Pushing dataset to Razer..."
    scp -q "$MERGED" "$RAZER:~/$RAZER_DIR/data/train.jsonl"
    local remote_count
    remote_count=$(ssh -o ConnectTimeout=5 "$RAZER" "wc -l < ~/$RAZER_DIR/data/train.jsonl 2>/dev/null || echo 0")
    log "  Razer has $remote_count examples"
}

pull_adapter() {
    local dest="training/adapters_4b_cuda"
    mkdir -p "$dest"
    log "Pulling 4B adapter from Razer..."
    scp -rq "$RAZER:~/$RAZER_DIR/adapters_4b/latest/*" "$dest/" 2>/dev/null || {
        err "No adapter checkpoint found on Razer yet"
        return 1
    }
    local files
    files=$(ls "$dest/" | wc -l)
    log "  Pulled $files files to $dest/"
}

# ── Model Server Management ──────────────────────────────────────────────────

serve_model() {
    local model_path="$1" adapter_path="$2" port="$3" name="$4"

    # Check if already running
    if curl -s -m 2 "http://localhost:$port/v1/models" >/dev/null 2>&1; then
        warn "$name already running on :$port"
        return 0
    fi

    log "Starting $name on :$port..."
    local adapter_flag=""
    if [ "$adapter_path" != "none" ] && [ -d "$adapter_path" ]; then
        adapter_flag="--adapter-path $adapter_path"
    fi

    nohup $PYTHON -m mlx_lm.server \
        --model "$model_path" $adapter_flag \
        --host 0.0.0.0 --port "$port" \
        --trust-remote-code --max-tokens 4096 \
        > "/tmp/waterfall_${name}.log" 2>&1 &
    echo $! > "$PID_DIR/${name}.pid"

    # Wait for server
    local attempt=0
    while [ $attempt -lt 12 ]; do
        sleep 5
        if curl -s -m 2 "http://localhost:$port/v1/models" >/dev/null 2>&1; then
            log "  $name ready on :$port (PID $(cat "$PID_DIR/${name}.pid"))"
            return 0
        fi
        attempt=$((attempt + 1))
    done
    err "  $name failed to start — check /tmp/waterfall_${name}.log"
    return 1
}

stop_server() {
    local port="$1" name="$2"
    if [ -f "$PID_DIR/${name}.pid" ]; then
        local pid
        pid=$(cat "$PID_DIR/${name}.pid")
        kill "$pid" 2>/dev/null && log "Stopped $name (PID $pid)" || true
        rm -f "$PID_DIR/${name}.pid"
    fi
    # Belt and suspenders
    lsof -ti:"$port" 2>/dev/null | xargs kill 2>/dev/null || true
}

serve_cmd() {
    local name="${1:-}"
    case "$name" in
        2b|2b-rail)
            serve_model "$MODEL_DIR/Qwen3.5-2B" "training/adapters_2b" "$PORT_2B" "2b-rail"
            ;;
        0.8b|0.8b-rail)
            serve_model "$MODEL_DIR/Qwen3.5-0.8B" "training/adapters_0.8b" "$PORT_08B" "0.8b-rail"
            ;;
        4b|4b-rail)
            serve_model "$MODEL_DIR/Qwen3.5-4B-4bit" "training/adapters_4b" "$PORT_4B" "4b-rail"
            ;;
        1.5b|1.5b-rail)
            # Legacy — keep for backward compat during transition
            serve_model "$MODEL_DIR/Qwen2.5-1.5B-Instruct" "training/adapters_1.5b" "$PORT_2B" "1.5b-rail"
            ;;
        *)
            echo "Usage: $0 serve {2b|0.8b|4b|1.5b}"
            echo "  2b   → Qwen3.5-2B   on :$PORT_2B  (data gen, primary)"
            echo "  0.8b → Qwen3.5-0.8B on :$PORT_08B (fast, edge)"
            echo "  4b   → Qwen3.5-4B   on :$PORT_4B  (eval only)"
            echo "  1.5b → Qwen2.5-1.5B on :$PORT_2B  (legacy)"
            return 1
            ;;
    esac
}

# ── Mini: Self-Train (Data Generation) ───────────────────────────────────────

start_mini() {
    local port="${1:-$PORT_2B}"

    # Check server is up
    if ! curl -s -m 2 "http://localhost:$port/v1/models" >/dev/null 2>&1; then
        err "No model server on :$port — run: $0 serve 2b"
        return 1
    fi

    # Check if already running
    if [ -f "$PID_DIR/selftrain.pid" ] && kill -0 "$(cat "$PID_DIR/selftrain.pid")" 2>/dev/null; then
        warn "Self-train already running (PID $(cat "$PID_DIR/selftrain.pid"))"
        return 0
    fi

    log "Starting self_train on Mini (port $port)..."
    nohup ./rail_native_llm run tools/train/self_train.rail --port "$port" --no-retrain yes \
        > /tmp/waterfall_selftrain.log 2>&1 &
    echo $! > "$PID_DIR/selftrain.pid"
    log "  PID: $(cat "$PID_DIR/selftrain.pid")"
}

stop_mini() {
    if [ -f "$PID_DIR/selftrain.pid" ]; then
        local pid
        pid=$(cat "$PID_DIR/selftrain.pid")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            log "Stopped self_train (PID $pid)"
        fi
        rm -f "$PID_DIR/selftrain.pid"
    else
        warn "No self_train PID file"
    fi
}

# ── Razer: CUDA Training ─────────────────────────────────────────────────────

razer_alive() {
    ssh -o ConnectTimeout=3 "$RAZER" "true" 2>/dev/null
}

razer_training() {
    # Windows: use tasklist instead of pgrep
    ssh -o ConnectTimeout=3 "$RAZER" "tasklist 2>/dev/null | grep -q python.exe" 2>/dev/null
}

start_razer() {
    local model="${1:-$MODEL_4B}"
    local iters="${2:-2000}"

    if ! razer_alive; then
        err "Razer not reachable"
        return 1
    fi

    log "Starting training on Razer ($model, $iters iters)..."
    # Use 'start' on MINGW to background properly, redirect to train.log
    ssh "$RAZER" "cd ~/$RAZER_DIR && python train_cuda.py \
        --model $model \
        --data ./data \
        --adapter-path ./adapters_4b \
        --iters $iters \
        --batch-size 1 \
        --learning-rate 1e-5 \
        --lora-rank 8 \
        --lora-alpha 16 \
        --num-layers 16 \
        --max-seq-length 1024 \
        --quantize-4bit \
        --gradient-checkpointing \
        --warmup-steps 100 \
        --grad-clip 1.0 \
        --save-every 250 \
        --report-every 50 \
        > train.log 2>&1 &
    disown
    echo \$!"
    log "  Launched. Monitor: ssh $RAZER 'tail -f ~/$RAZER_DIR/train.log'"
}

stop_razer() {
    log "Stopping Razer training..."
    ssh "$RAZER" "taskkill //F //IM python.exe 2>/dev/null || true" 2>/dev/null || true
    log "  Done."
}

# ── Status ────────────────────────────────────────────────────────────────────

status() {
    hdr "WATERFALL STATUS"
    echo ""

    # Mini — Servers
    hdr "Mini — Model Servers"
    for port_name in "$PORT_2B:2B" "$PORT_08B:0.8B" "$PORT_4B:4B"; do
        local port="${port_name%%:*}"
        local name="${port_name##*:}"
        if curl -s -m 2 "http://localhost:$port/v1/models" >/dev/null 2>&1; then
            echo -e "  ${GRN}UP${RST}   :$port  $name"
        else
            echo -e "  ${YEL}--${RST}   :$port  $name"
        fi
    done

    # Mini — Self-train
    hdr "Mini — Data Generation"
    if [ -f "$PID_DIR/selftrain.pid" ] && kill -0 "$(cat "$PID_DIR/selftrain.pid")" 2>/dev/null; then
        echo -e "  self_train: ${GRN}RUNNING${RST} (PID $(cat "$PID_DIR/selftrain.pid"))"
    else
        echo -e "  self_train: ${YEL}STOPPED${RST}"
    fi
    if [ -f training/self_train/progress.txt ]; then
        echo "  $(grep -E '^(round|level|harvested)=' training/self_train/progress.txt | tr '\n' ' ')"
    fi
    echo "  harvest_clean: $(wc -l < "$HARVEST_CLEAN" 2>/dev/null || echo 0) examples"

    # Razer
    hdr "Razer — CUDA Training"
    if razer_alive; then
        echo -e "  Connection: ${GRN}UP${RST}"
        ssh -o ConnectTimeout=3 "$RAZER" "
            nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv,noheader 2>/dev/null | while read line; do echo \"  GPU: \$line\"; done
            if tasklist 2>/dev/null | grep -q python.exe; then
                echo '  Training: RUNNING'
            else
                echo '  Training: STOPPED'
            fi
            tail -1 ~/$RAZER_DIR/train.log 2>/dev/null | while read line; do echo \"  Last: \$line\"; done
            echo \"  Dataset: \$(wc -l < ~/$RAZER_DIR/data/train.jsonl 2>/dev/null || echo 0) examples\"
            ls -d ~/$RAZER_DIR/adapters_4b/0*_adapter 2>/dev/null | wc -l | while read n; do echo \"  Checkpoints: \$n\"; done
        " 2>/dev/null
    else
        echo -e "  Connection: ${RED}OFFLINE${RST}"
    fi

    # Dataset
    hdr "Dataset"
    echo "  train_clean:   $(wc -l < "$TRAIN_CLEAN" 2>/dev/null || echo 0) (base)"
    echo "  harvest_clean: $(wc -l < "$HARVEST_CLEAN" 2>/dev/null || echo 0) (self_train)"
    echo "  merged:        $(wc -l < "$MERGED" 2>/dev/null || echo 0) (deduped)"
    echo ""
}

# ── Cycle (sync + restart training) ──────────────────────────────────────────

cycle() {
    hdr "WATERFALL CYCLE"
    stop_razer
    sleep 2
    sync_to_razer
    start_razer
    log "Cycle complete — Razer retraining on fresh data."
}

# ── Bench (run benchmark) ────────────────────────────────────────────────────

bench() {
    local port="${1:-$PORT_2B}"
    if ! curl -s -m 2 "http://localhost:$port/v1/models" >/dev/null 2>&1; then
        err "No server on :$port"
        return 1
    fi
    log "Running benchmark against :$port..."
    ./rail_native_llm run flywheel/bench.rail --port "$port"
}

# ── Full Pipeline ─────────────────────────────────────────────────────────────

start_all() {
    hdr "STARTING WATERFALL"

    # 1. Serve 2B for data gen
    serve_model "$MODEL_DIR/Qwen3.5-2B" "training/adapters_2b" "$PORT_2B" "2b-rail"

    # 2. Start self_train
    start_mini "$PORT_2B"

    # 3. Sync and start Razer
    sync_to_razer
    start_razer

    log "Waterfall running on both nodes."
    status
}

stop_all() {
    hdr "STOPPING WATERFALL"
    stop_mini
    stop_razer
    for name in 2b-rail 0.8b-rail 4b-rail 1.5b-rail; do
        local port
        case "$name" in
            2b-rail|1.5b-rail) port=$PORT_2B ;;
            0.8b-rail) port=$PORT_08B ;;
            4b-rail) port=$PORT_4B ;;
        esac
        stop_server "$port" "$name"
    done
    log "Waterfall stopped."
}

# ── Main ──────────────────────────────────────────────────────────────────────

case "${1:-status}" in
    start)   start_all ;;
    stop)    stop_all ;;
    status)  status ;;
    sync)    sync_to_razer ;;
    pull)    pull_adapter ;;
    cycle)   cycle ;;
    serve)   serve_cmd "${2:-}" ;;
    bench)   bench "${2:-$PORT_2B}" ;;
    mini)    start_mini "${2:-$PORT_2B}" ;;
    razer)   start_razer "${2:-$MODEL_4B}" "${3:-2000}" ;;
    *)
        echo "Usage: $0 {start|stop|status|sync|pull|cycle|serve|bench|mini|razer}"
        echo ""
        echo "  start   — launch servers + self_train + Razer training"
        echo "  stop    — stop everything"
        echo "  status  — check all nodes"
        echo "  sync    — merge data + push to Razer"
        echo "  pull    — pull trained adapter from Razer"
        echo "  cycle   — sync + restart Razer training"
        echo "  serve   — start a model server (2b, 0.8b, 4b)"
        echo "  bench   — run 25-task benchmark"
        echo "  mini    — start self_train only"
        echo "  razer   — start Razer training only"
        exit 1
        ;;
esac
