#!/bin/bash
# tools/orch/tests/test_kill_decision.sh — exercise kill_decision.rail with
# synthetic val_loss.tsv files.

set -u
cd "$(dirname "$0")/../../.."  # repo root
TEST_DIR=/tmp/kd_test
KD=tools/orch/kill_decision.rail

# Compile once for speed
rm -f /tmp/rail_out
./rail_native "$KD" >/dev/null 2>&1 || { echo "COMPILE FAIL"; exit 1; }
cp /tmp/rail_out "$TEST_DIR.bin"
chmod +x "$TEST_DIR.bin"

reset() {
  rm -rf "$TEST_DIR"
  mkdir -p "$TEST_DIR/runs"
}

write_series() {
  # write_series <arm_id> <step1:vl1> <step2:vl2> ...
  local arm=$1; shift
  mkdir -p "$TEST_DIR/runs/$arm"
  local out=$TEST_DIR/runs/$arm/val_loss.tsv
  : > "$out"
  for pair in "$@"; do
    local step=${pair%:*}
    local vl=${pair#*:}
    printf '%s\t%s\n' "$step" "$vl" >> "$out"
  done
}

run_kd() {
  "$TEST_DIR.bin" "$@" 2>&1
}

assert_grep() {
  local label=$1 pattern=$2 input=$3
  if echo "$input" | grep -qE "$pattern"; then
    echo "  PASS  $label"
    return 0
  else
    echo "  FAIL  $label (pattern: $pattern)"
    echo "  --- output ---"
    echo "$input" | sed 's/^/    /'
    echo "  --------------"
    return 1
  fi
}

FAIL_COUNT=0
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); }

# ── TEST 1: HOLD (below kill_min_step) ─────────────────────────────
echo "=== TEST 1: hold (common_step < kill_min_step) ==="
reset
write_series armA 100:3.5 200:3.4 300:3.3
write_series armB 100:3.6 200:3.5 300:3.4
out=$(run_kd --kill_min_step 500 \
  "$TEST_DIR/runs/armA/val_loss.tsv" "$TEST_DIR/runs/armB/val_loss.tsv")
assert_grep "common_step=300"  "common_step=300"  "$out" || fail
assert_grep "decision=hold"    "decision=hold"    "$out" || fail
assert_grep "below kill min"   "below_kill_min_step_500" "$out" || fail

# ── TEST 2: KEEP_ALL (within tolerance) ────────────────────────────
echo "=== TEST 2: keep_all (laggard within 2σ of leader) ==="
reset
# Leader trajectory: smooth decline 3.50 → 3.30; σ over last 10 ≈ 0.06
write_series armA \
  100:3.50 200:3.46 300:3.42 400:3.38 500:3.36 600:3.35 700:3.34 \
  800:3.33 900:3.32 1000:3.31 1100:3.30 1200:3.30 1300:3.30
# Laggard: slightly behind leader; gap ~0.05 at common step (within 2σ ≈ 0.12)
write_series armB \
  100:3.55 200:3.50 300:3.45 400:3.42 500:3.40 600:3.38 700:3.37 \
  800:3.37 900:3.36 1000:3.35 1100:3.35 1200:3.34 1300:3.34
out=$(run_kd --kill_min_step 500 --kill_sigma 2.0 --kill_window 10 \
  "$TEST_DIR/runs/armA/val_loss.tsv" "$TEST_DIR/runs/armB/val_loss.tsv")
assert_grep "leader=armA"      "leader=armA"      "$out" || fail
assert_grep "decision=keep_all" "decision=keep_all" "$out" || fail
assert_grep "no kills"          "^kill="           "<inverted>" "$out" 2>/dev/null \
  ; if echo "$out" | grep -q "^kill="; then echo "  FAIL  no kills (got kill= line)"; fail; else echo "  PASS  no kills"; fi

# ── TEST 3: KILL (laggard >2σ behind) ──────────────────────────────
echo "=== TEST 3: kill (one arm > leader + 2σ) ==="
reset
write_series armA \
  100:3.50 200:3.46 300:3.42 400:3.38 500:3.36 600:3.35 700:3.34 \
  800:3.33 900:3.32 1000:3.31 1100:3.30 1200:3.30 1300:3.30
write_series armB \
  100:3.55 200:3.50 300:3.45 400:3.42 500:3.40 600:3.38 700:3.37 \
  800:3.37 900:3.36 1000:3.35 1100:3.35 1200:3.34 1300:3.34
# armC: dramatically worse — val_loss 4.5 at common step, leader+2σ ≈ 3.42
write_series armC \
  100:5.0 200:4.9 300:4.8 400:4.7 500:4.6 600:4.55 700:4.55 \
  800:4.50 900:4.50 1000:4.50 1100:4.50 1200:4.50 1300:4.50
out=$(run_kd --kill_min_step 500 --kill_sigma 2.0 --kill_window 10 \
  "$TEST_DIR/runs/armA/val_loss.tsv" \
  "$TEST_DIR/runs/armB/val_loss.tsv" \
  "$TEST_DIR/runs/armC/val_loss.tsv")
assert_grep "leader=armA"      "leader=armA"      "$out" || fail
assert_grep "decision=kill"     "decision=kill"    "$out" || fail
assert_grep "kill=armC"         "^kill=armC"       "$out" || fail
if echo "$out" | grep -q "^kill=armB"; then echo "  FAIL  armB shouldn't be killed"; fail; else echo "  PASS  armB kept (within tolerance)"; fi

# ── TEST 4: SINGLE ARM (no laggards possible) ──────────────────────
echo "=== TEST 4: single arm ==="
reset
write_series solo 100:3.5 500:3.3 1000:3.2
out=$(run_kd --kill_min_step 500 "$TEST_DIR/runs/solo/val_loss.tsv")
assert_grep "leader=solo"       "leader=solo"       "$out" || fail
assert_grep "decision=keep_all"  "decision=keep_all" "$out" || fail

# ── SUMMARY ────────────────────────────────────────────────────────
echo ""
if [ $FAIL_COUNT -eq 0 ]; then
  echo "=== ALL TESTS PASS ==="
  exit 0
else
  echo "=== $FAIL_COUNT TEST(S) FAILED ==="
  exit 1
fi
