#!/usr/bin/env bash
# parallel_rerank.sh — fire N inference attempts concurrently.
#
# The Rail rerank workflow generates N samples per prompt with different RNG
# seeds and grades each by compilation. Today bench_railnative.rail does this
# sequentially: each sample blocks the next. Each sample is independent
# (shared weights, different seed), so they parallelize embarrassingly.
#
# This wrapper launches N Rail subprocesses concurrently. Each binds a
# unique --seed (BASE_SEED + i) and writes to /tmp/rerank_<run_id>_<i>.txt.
# Caller can compile-grade the outputs after `wait`.
#
# Usage:
#   tools/train/parallel_rerank.sh \
#       --harness tools/train/lm_infer_v3_mixed.rail \
#       --prefix training/rail_native/checkpoints/d256_half_step3000 \
#       --prompt "main = " \
#       --max 60 --k 10 --n 8 --base-seed 100
#
# Output: writes each sample to a numbered file; prints a summary line per
# sample on stdout: "<i> <exit_rc> <bytes_out> /tmp/rerank_<id>_<i>.txt".
#
# Concurrency: up to MAX_PARALLEL processes at once (default 8 — matches
# Studio's perf-core count). Higher than that and Metal context contention
# kills the win.

set -u

# Default args.
HARNESS="tools/train/lm_infer_v3_mixed.rail"
PREFIX=""
PROMPT="main = "
MAX="60"
K="10"
TEMP="0.8"
N_SAMPLES=8
BASE_SEED=100
MAX_PARALLEL=8
NO_WS_FIRST="0"
RUN_ID="$$"
DYLD_PATH="tools/metal"
BIN_OVERRIDE=""
CORPUS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness)     HARNESS="$2"; shift 2 ;;
    --bin)         BIN_OVERRIDE="$2"; shift 2 ;;
    --prefix)      PREFIX="$2"; shift 2 ;;
    --prompt)      PROMPT="$2"; shift 2 ;;
    --max)         MAX="$2"; shift 2 ;;
    --k)           K="$2"; shift 2 ;;
    --temp)        TEMP="$2"; shift 2 ;;
    --n)           N_SAMPLES="$2"; shift 2 ;;
    --base-seed)   BASE_SEED="$2"; shift 2 ;;
    --max-parallel) MAX_PARALLEL="$2"; shift 2 ;;
    --no-ws-first) NO_WS_FIRST="$2"; shift 2 ;;
    --run-id)      RUN_ID="$2"; shift 2 ;;
    --dyld)        DYLD_PATH="$2"; shift 2 ;;
    --corpus)      CORPUS="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$PREFIX" ]]; then
  echo "ERROR: --prefix is required" >&2
  exit 2
fi
if [[ ! -x "./rail_native" ]]; then
  echo "ERROR: ./rail_native not found in cwd" >&2
  exit 2
fi
if [[ ! -f "$HARNESS" ]]; then
  echo "ERROR: harness not found: $HARNESS" >&2
  exit 2
fi

# Pre-compile the harness once so the N subprocesses don't all race on the
# Rail compiler. With --bin, skip pre-compile and use the supplied binary
# directly (caller has already compiled it; lets the bench harness avoid
# redundant compiles and keeps /tmp/rail_out free for compile-grading).
if [[ -n "$BIN_OVERRIDE" ]]; then
  if [[ ! -x "$BIN_OVERRIDE" ]]; then
    echo "ERROR: --bin path is not executable: $BIN_OVERRIDE" >&2
    exit 1
  fi
  COMPILED_BIN="$BIN_OVERRIDE"
  echo "tgl: using pre-built binary -> $COMPILED_BIN" >&2
else
  COMPILED_BIN="/tmp/rail_rerank_${RUN_ID}"
  echo "tgl: pre-compiling harness once -> $COMPILED_BIN" >&2
  DYLD_LIBRARY_PATH="$DYLD_PATH" ./rail_native "$HARNESS" >/dev/null 2>&1
  if [[ ! -x /tmp/rail_out ]]; then
    echo "ERROR: harness compile failed; /tmp/rail_out not produced" >&2
    exit 1
  fi
  cp /tmp/rail_out "$COMPILED_BIN"
  codesign -s - --force "$COMPILED_BIN" 2>/dev/null || true
fi

# Launch N samples with rolling parallelism. Each sample uses a unique seed
# so the topk multinomial draws diverge. All share the same prefix/prompt.
declare -a PIDS
declare -a OUTFILES
launch_one() {
  local i="$1"
  local seed=$((BASE_SEED + i))
  local out="/tmp/rerank_${RUN_ID}_${i}.txt"
  OUTFILES[$i]="$out"
  if [[ -n "$CORPUS" ]]; then
    DYLD_LIBRARY_PATH="$DYLD_PATH" "$COMPILED_BIN" \
      --prefix "$PREFIX" \
      --prompt "$PROMPT" \
      --max "$MAX" \
      --k "$K" \
      --temp "$TEMP" \
      --seed "$seed" \
      --no-ws-first "$NO_WS_FIRST" \
      --corpus "$CORPUS" \
      > "$out" 2>&1 &
  else
    DYLD_LIBRARY_PATH="$DYLD_PATH" "$COMPILED_BIN" \
      --prefix "$PREFIX" \
      --prompt "$PROMPT" \
      --max "$MAX" \
      --k "$K" \
      --temp "$TEMP" \
      --seed "$seed" \
      --no-ws-first "$NO_WS_FIRST" \
      > "$out" 2>&1 &
  fi
  PIDS[$i]=$!
}

active_count() {
  local n=0
  for pid in "${PIDS[@]:-}"; do
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      n=$((n + 1))
    fi
  done
  echo "$n"
}

start_t=$(date +%s)
for i in $(seq 0 $((N_SAMPLES - 1))); do
  while [[ "$(active_count)" -ge "$MAX_PARALLEL" ]]; do
    sleep 0.1
  done
  launch_one "$i"
done

# Wait for all and emit per-sample summary.
for i in $(seq 0 $((N_SAMPLES - 1))); do
  pid="${PIDS[$i]}"
  out="${OUTFILES[$i]}"
  wait "$pid"
  rc=$?
  bytes=$(wc -c < "$out" 2>/dev/null | tr -d ' ')
  echo "$i $rc $bytes $out"
done

end_t=$(date +%s)
elapsed=$((end_t - start_t))
echo "tgl: $N_SAMPLES samples in ${elapsed}s (max-parallel=$MAX_PARALLEL)" >&2
