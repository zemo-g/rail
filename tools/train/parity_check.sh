#!/usr/bin/env bash
# parity_check.sh — three-way precision diff for inference paths.
#
# For a given checkpoint + prompt + max + seed, runs all three available
# inference substrates and prints byte-level diffs:
#
#   1. CPU substrate    (lm_infer_cpu.rail)         — f64 weights, f64 acts
#   2. GPU half         (lm_infer_v3_half.rail)     — fp16 weights, fp16 acts
#   3. GPU mixed (NEW)  (lm_infer_v3_mixed.rail)    — fp16 weights, f64 acts
#
# Output: a row per substrate with bytes-out + first-divergence byte index
# vs the CPU reference. Establishes how each precision path drifts from the
# nominal f64 forward.
#
# Usage:
#   tools/train/parity_check.sh \
#       --prefix training/rail_native/checkpoints/d256_half_step3000 \
#       --prompt "main = " --max 20

set -u

PREFIX="training/rail_native/checkpoints/d256_half_step3000"
PROMPT="main = "
MAX="20"
K="1"
SEED="42"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --max)    MAX="$2"; shift 2 ;;
    --k)      K="$2"; shift 2 ;;
    --seed)   SEED="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -x ./rail_native ]]; then
  echo "ERROR: ./rail_native not in cwd" >&2
  exit 2
fi

echo "=== parity_check ==="
echo "  prefix: $PREFIX"
echo "  prompt: $PROMPT"
echo "  max:    $MAX"
echo "  k:      $K"
echo "  seed:   $SEED"
echo

CPU_OUT="/tmp/parity_cpu.txt"
HALF_OUT="/tmp/parity_half.txt"
MIXED_OUT="/tmp/parity_mixed.txt"

run_one() {
  local label="$1"; local harness="$2"; local out="$3"
  printf "%-12s " "$label"
  local t0=$(date +%s)
  DYLD_LIBRARY_PATH=tools/metal ./rail_native run "$harness" \
      --prefix "$PREFIX" --prompt "$PROMPT" --max "$MAX" \
      --k "$K" --seed "$SEED" \
      > "$out" 2>&1
  local rc=$?
  local t1=$(date +%s)
  local elapsed=$((t1 - t0))
  local bytes=$(wc -c < "$out" | tr -d ' ')
  echo "rc=$rc bytes=$bytes elapsed=${elapsed}s -> $out"
}

run_one "cpu_f64"   "tools/train/lm_infer_cpu.rail"      "$CPU_OUT"
run_one "gpu_half"  "tools/train/lm_infer_v3_half.rail"  "$HALF_OUT"
run_one "gpu_mixed" "tools/train/lm_infer_v3_mixed.rail" "$MIXED_OUT"

echo
echo "=== generated text (after compile banner stripped) ==="
strip_banner() {
  # Strip "Compiling ...\n  as: OK\n  ld: OK\n" preamble from Rail run output.
  grep -v -E '^(Compiling |  WARNING |  as:|  ld:|tgl: )' "$1" | sed -n '/./,$p'
}
echo "[cpu_f64 ]"
strip_banner "$CPU_OUT" | head -30
echo "[gpu_half]"
strip_banner "$HALF_OUT" | head -30
echo "[gpu_mixed]"
strip_banner "$MIXED_OUT" | head -30

echo
echo "=== first-byte divergence vs cpu_f64 ==="
divergence_byte() {
  local ref="$1"; local cmp="$2"
  python3 - "$ref" "$cmp" <<'PY'
import sys
ref = open(sys.argv[1], 'rb').read()
cmp = open(sys.argv[2], 'rb').read()
n = min(len(ref), len(cmp))
for i in range(n):
    if ref[i] != cmp[i]:
        print(f"first diff at byte {i}: ref={ref[i]:#04x} ({chr(ref[i]) if 32<=ref[i]<127 else '?'}) cmp={cmp[i]:#04x} ({chr(cmp[i]) if 32<=cmp[i]<127 else '?'})")
        sys.exit(0)
if len(ref) != len(cmp):
    print(f"identical for first {n} bytes; lengths differ ({len(ref)} vs {len(cmp)})")
else:
    print("byte-identical")
PY
}
echo -n "gpu_half  vs cpu_f64: "; divergence_byte "$CPU_OUT" "$HALF_OUT"
echo -n "gpu_mixed vs cpu_f64: "; divergence_byte "$CPU_OUT" "$MIXED_OUT"
echo -n "gpu_mixed vs gpu_half: "; divergence_byte "$HALF_OUT" "$MIXED_OUT"
