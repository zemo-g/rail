#!/bin/bash
# grammar_walk_probe.sh — unified probe driver for the verifier-augmented
# inference pipeline. Replaces the /tmp/probe_step3*.sh ad-hocs from the
# 2026-05-05 climb session.
#
# Capabilities:
#   - run baseline + verified at one or many seeds against a prompt
#   - sweep K values
#   - tabulate parse-pass + compile-pass per (seed, K, mode)
#   - dump output snippets for diversity check
#
# Defaults match the spur_v54_BQ2_s77 floor recipe. Override via env vars.
#
# Examples:
#   # 5-seed N=5 baseline+verify on the default Real-Tools prompt:
#   tools/train/grammar_walk_probe.sh
#
#   # K-sweep at single seed:
#   SEEDS=100 KS="10 30 50" tools/train/grammar_walk_probe.sh
#
#   # Custom prompt + max:
#   PROMPT="add a b = a + b\nmain = " MAX=32 tools/train/grammar_walk_probe.sh
#
#   # Use a specific probe binary (default: build from lm_infer_v2b_probe.rail):
#   BIN=/tmp/v2b_probe5 tools/train/grammar_walk_probe.sh
#
# Output:
#   /tmp/gw_<tag>_s<seed>_k<K>_<mode>.txt   — raw inference output
#   /tmp/gw_<tag>_summary.txt               — grading table
#
# Pre-existing inference_seed_segfault.md note: even with the
# 2026-05-05 V-from-shape fix, certain (seed, prompt_len) combos may
# still crash via independent allocator paths. Re-run with a different
# seed if a single trial returns exit=139.

set -u
cd "$(dirname "$0")/../.."

# ── Config (env-overridable) ────────────────────────────────────────
CKPT="${CKPT:-training/rail_native/checkpoints/spur_v54_BQ2_s77_best}"
PROMPT="${PROMPT:-type Opt = | Some x | None
get_or o = match o | Some x -> x | None -> 0
main = }"
TAG="${TAG:-default}"
MAX="${MAX:-64}"
TEMP="${TEMP:-0.8}"
NO_WS_FIRST="${NO_WS_FIRST:-16}"
SEEDS="${SEEDS:-100 101 102 103 104}"
KS="${KS:-10}"
MODES="${MODES:-base verify}"
BIN="${BIN:-}"

# ── Build probe binary if not provided ──────────────────────────────
if [ -z "$BIN" ]; then
  echo "[build] compiling lm_infer_v2b_probe.rail..."
  ./rail_native tools/train/lm_infer_v2b_probe.rail >/dev/null 2>&1 || {
    echo "ERROR: probe compile failed"; exit 1
  }
  BIN=/tmp/gw_probe_bin
  cp /tmp/rail_out "$BIN"
  echo "[build] -> $BIN ($(stat -f %z $BIN) bytes)"
fi

# ── Run grid ────────────────────────────────────────────────────────
run_one() {
  local seed="$1" k="$2" mode="$3"
  local out="/tmp/gw_${TAG}_s${seed}_k${k}_${mode}.txt"
  if [ -f "$out" ] && [ -s "$out" ]; then
    echo "  [skip] s=$seed k=$k mode=$mode (cached)"
    return
  fi
  local verify_flag=0
  [ "$mode" = "verify" ] && verify_flag=1
  echo "  [run]  s=$seed k=$k mode=$mode"
  /usr/bin/time -p "$BIN" \
    --prefix "$CKPT" \
    --max "$MAX" --k "$k" --temp "$TEMP" --seed "$seed" \
    --no-ws-first "$NO_WS_FIRST" --verify "$verify_flag" \
    --prompt "$PROMPT" > "$out" 2>&1
}

echo "=== grammar_walk_probe TAG=$TAG ==="
echo "  ckpt=$CKPT max=$MAX temp=$TEMP no_ws_first=$NO_WS_FIRST"
echo "  seeds=[$SEEDS] ks=[$KS] modes=[$MODES]"
echo

for k in $KS; do
  for seed in $SEEDS; do
    for mode in $MODES; do
      run_one "$seed" "$k" "$mode"
    done
  done
done

# ── Grade + summarize ───────────────────────────────────────────────
grade_parse() {
  grep -a -v '^real \|^user \|^sys ' "$1" > /tmp/gw_grade.rail 2>/dev/null
  ./rail_native parse-check /tmp/gw_grade.rail >/dev/null 2>&1 && echo "P" || echo "."
}
grade_compile() {
  grep -a -v '^real \|^user \|^sys ' "$1" > /tmp/gw_grade.rail 2>/dev/null
  ./rail_native /tmp/gw_grade.rail >/dev/null 2>&1 && echo "C" || echo "."
}

SUMMARY="/tmp/gw_${TAG}_summary.txt"
{
  echo "=== Grading table (P=parse C=compile, '.' = fail) ==="
  printf "%-8s" "seed"
  for k in $KS; do
    for mode in $MODES; do
      printf " %-12s" "k${k}_${mode:0:6}"
    done
  done
  printf "\n"
  for seed in $SEEDS; do
    printf "%-8s" "$seed"
    for k in $KS; do
      for mode in $MODES; do
        out="/tmp/gw_${TAG}_s${seed}_k${k}_${mode}.txt"
        p=$(grade_parse "$out")
        c=$(grade_compile "$out")
        printf " %-12s" "${p}${c}"
      done
    done
    printf "\n"
  done

  echo
  echo "=== Totals ==="
  for k in $KS; do
    for mode in $MODES; do
      pn=0; cn=0; tot=0
      for seed in $SEEDS; do
        out="/tmp/gw_${TAG}_s${seed}_k${k}_${mode}.txt"
        tot=$((tot + 1))
        [ "$(grade_parse "$out")"   = "P" ] && pn=$((pn + 1))
        [ "$(grade_compile "$out")" = "C" ] && cn=$((cn + 1))
      done
      printf "  K=%-3s mode=%-7s  parse=%d/%d  compile=%d/%d\n" \
        "$k" "$mode" "$pn" "$tot" "$cn" "$tot"
    done
  done

  echo
  echo "=== Output snippets ==="
  for k in $KS; do
    for mode in $MODES; do
      echo "--- K=$k mode=$mode ---"
      for seed in $SEEDS; do
        out="/tmp/gw_${TAG}_s${seed}_k${k}_${mode}.txt"
        line=$(grep -a -v '^real \|^user \|^sys ' "$out" 2>/dev/null \
               | tail -n +3 | head -c 80 | tr '\n' '|')
        echo "    s=$seed: $line"
      done
    done
  done
} | tee "$SUMMARY"

echo
echo "Full summary saved to: $SUMMARY"
echo "Per-trial outputs: /tmp/gw_${TAG}_s<seed>_k<K>_<mode>.txt"
