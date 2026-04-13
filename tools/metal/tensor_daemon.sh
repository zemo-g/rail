#!/bin/bash
# tensor_daemon.sh — Start tensor_gpu as a persistent daemon with named pipes
# Usage: ./tensor_daemon.sh start | stop | status
#
# Creates /tmp/rail_gpu_in (request pipe) and /tmp/rail_gpu_out (response pipe).
# tensor_gpu reads binary requests from in, writes binary responses to out.
# Rail's tensor.rail writes to /tmp/rail_gpu_in and reads from /tmp/rail_gpu_out.
#
# This eliminates Metal device init + shader compilation per operation (~200ms savings).

PIPE_IN="/tmp/rail_gpu_in"
PIPE_OUT="/tmp/rail_gpu_out"
PID_FILE="/tmp/rail_gpu_daemon.pid"
GPU_BIN="$HOME/projects/rail/tools/metal/tensor_gpu"

case "${1:-status}" in
  start)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat $PID_FILE)" 2>/dev/null; then
      echo "Already running (PID $(cat $PID_FILE))"
      exit 0
    fi
    rm -f "$PIPE_IN" "$PIPE_OUT"
    mkfifo "$PIPE_IN" "$PIPE_OUT"
    # Launch: reads from pipe_in, writes to pipe_out
    ($GPU_BIN < "$PIPE_IN" > "$PIPE_OUT" 2>/tmp/rail_gpu_daemon.log) &
    echo $! > "$PID_FILE"
    echo "Started tensor_gpu daemon (PID $!)"
    ;;
  stop)
    if [ -f "$PID_FILE" ]; then
      kill "$(cat $PID_FILE)" 2>/dev/null
      rm -f "$PID_FILE" "$PIPE_IN" "$PIPE_OUT"
      echo "Stopped"
    else
      echo "Not running"
    fi
    ;;
  status)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat $PID_FILE)" 2>/dev/null; then
      echo "Running (PID $(cat $PID_FILE))"
    else
      echo "Not running"
    fi
    ;;
esac
