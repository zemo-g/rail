#!/bin/bash
# repl_jit_bench.sh — measure per-line latency of tools/repl_jit.rail.
#
# Strategy: build N small batch transcripts, time the *additional* cost
# per line by running an N-line transcript and a 0-line transcript and
# taking the delta. This isolates per-line eval from REPL startup.
#
# Usage: bash tools/test/repl_jit_bench.sh
set -e

REPL=tools/repl_jit.rail
SENTINEL=/tmp/rail_repl_jit_input.txt

# Run once to make sure REPL builds and warms file caches.
echo "main = 0" > /tmp/rail_jit_warm.rail
./rail_native run "$REPL" </dev/null >/dev/null 2>&1 || true

build_session() {
    local n=$1
    local mode=$2  # "jit" or "shell"
    local out=$3
    : > "$out"
    if [ "$mode" = "jit" ]; then
        # Arithmetic — JIT lowers fine.
        for i in $(seq 1 "$n"); do
            echo "$i + $i" >> "$out"
        done
    else
        # ADT match — forces shell fallback.
        echo "type Pair = | P a b" >> "$out"
        for i in $(seq 1 "$n"); do
            echo "match (P $i $i) | P a b -> a + b" >> "$out"
        done
    fi
}

bench_one() {
    local n=$1
    local mode=$2
    local input=/tmp/rail_repl_jit_bench_${mode}_${n}.txt
    build_session "$n" "$mode" "$input"
    echo "$input" > "$SENTINEL"
    # 3 runs, take median via sort -n + middle.
    local t1 t2 t3
    t1=$( { time ./rail_native run "$REPL" >/dev/null 2>&1; } 2>&1 | awk '/real/ {print $2}' )
    t2=$( { time ./rail_native run "$REPL" >/dev/null 2>&1; } 2>&1 | awk '/real/ {print $2}' )
    t3=$( { time ./rail_native run "$REPL" >/dev/null 2>&1; } 2>&1 | awk '/real/ {print $2}' )
    echo "  n=$n mode=$mode times: $t1 $t2 $t3"
}

# Convert mm:ss.SSS to seconds-with-decimal.
to_ms() { python3 -c "
import sys
s=sys.argv[1]
if ':' in s:
    m,r=s.split(':')
    print(int((int(m)*60+float(r))*1000))
else:
    print(int(float(s)*1000))" "$1"; }

# Times: use Python for precise math.
measure() {
    local mode=$1
    local n=$2
    local input=/tmp/rail_repl_jit_bench_${mode}_${n}.txt
    build_session "$n" "$mode" "$input"
    echo "$input" > "$SENTINEL"
    local ms_total
    ms_total=$(python3 -c "
import subprocess, time
runs=[]
for _ in range(3):
    t0=time.time()
    subprocess.run(['./rail_native','run','$REPL'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    runs.append((time.time()-t0)*1000)
runs.sort()
print(int(runs[1]))")
    echo "$ms_total"
}

echo "=== Bench: tools/repl_jit.rail ==="
echo "Baseline (no inputs):"
echo "n=0" > "$SENTINEL"
python3 -c "
import subprocess, time
# Need an empty input file
open('/tmp/rail_repl_jit_bench_empty.txt','w').write('')
open('$SENTINEL','w').write('/tmp/rail_repl_jit_bench_empty.txt')
runs=[]
for _ in range(3):
    t0=time.time()
    subprocess.run(['./rail_native','run','$REPL'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    runs.append((time.time()-t0)*1000)
runs.sort()
print(f'  REPL startup median: {int(runs[1])} ms (3 runs: {[int(x) for x in runs]})')"

echo ""
echo "JIT path (arithmetic, n inputs):"
for n in 5 20 50; do
    ms=$(measure jit "$n")
    echo "  n=$n -> $ms ms"
done

echo ""
echo "Shell path (ADT match, n inputs):"
for n in 5 20; do
    ms=$(measure shell "$n")
    echo "  n=$n -> $ms ms"
done

# Compute per-line cost as the slope: (ms_at_n - ms_at_0) / n.
echo ""
echo "Per-line cost (median, deltas):"
ms0=$(python3 -c "
import subprocess, time
open('/tmp/rail_repl_jit_bench_empty.txt','w').write('')
open('$SENTINEL','w').write('/tmp/rail_repl_jit_bench_empty.txt')
runs=[]
for _ in range(3):
    t0=time.time()
    subprocess.run(['./rail_native','run','$REPL'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    runs.append((time.time()-t0)*1000)
runs.sort(); print(int(runs[1]))")

for n in 20 50; do
    msj=$(measure jit "$n")
    per=$(python3 -c "print(round(($msj - $ms0) / $n, 1))")
    echo "  JIT  per-line (n=$n): $per ms"
done

for n in 20; do
    mss=$(measure shell "$n")
    per=$(python3 -c "print(round(($mss - $ms0) / $n, 1))")
    echo "  Shell per-line (n=$n): $per ms"
done

rm -f "$SENTINEL"
