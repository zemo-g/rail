#!/bin/bash
# tools/lint/run_lint_smoke.sh — smoke test for check_quirks.rail
#
# Compiles the linter once, then asserts:
#   (1) On test_quirks.rail: exactly 3 warnings (Q001, Q002, Q003), exit 1.
#   (2) On a known-clean stdlib file (stdlib/file.rail): 0 warnings, exit 0.

set -u
cd "$(dirname "$0")/../.."

LINTER_SRC="tools/lint/check_quirks.rail"
LINTER_BIN="/tmp/rail_lint"
TEST_FIXTURE="tools/lint/test_quirks.rail"
CLEAN_FIXTURE="stdlib/file.rail"

echo "[smoke] Compiling linter..."
./rail_native "$LINTER_SRC" >/dev/null 2>&1 || {
  echo "FAIL: linter failed to compile"
  exit 1
}
cp /tmp/rail_out "$LINTER_BIN"

echo "[smoke] Test 1: dirty fixture should produce 3 warnings + exit 1"
OUT1=$("$LINTER_BIN" "$TEST_FIXTURE" 2>&1)
EC1=$?
echo "$OUT1"

N_Q001=$(echo "$OUT1" | grep -c "Q001 ")
N_Q002=$(echo "$OUT1" | grep -c "Q002 ")
N_Q003=$(echo "$OUT1" | grep -c "Q003 ")
N_TOTAL=$(echo "$OUT1" | grep -c "warning:")

PASS1=1
if [ "$N_Q001" -ne 1 ]; then echo "FAIL: expected 1 Q001, got $N_Q001"; PASS1=0; fi
if [ "$N_Q002" -ne 1 ]; then echo "FAIL: expected 1 Q002, got $N_Q002"; PASS1=0; fi
if [ "$N_Q003" -ne 1 ]; then echo "FAIL: expected 1 Q003, got $N_Q003"; PASS1=0; fi
if [ "$N_TOTAL" -ne 3 ]; then echo "FAIL: expected 3 total warnings, got $N_TOTAL"; PASS1=0; fi
if [ "$EC1" -ne 1 ]; then echo "FAIL: expected exit 1, got $EC1"; PASS1=0; fi

echo "[smoke] Test 2: clean fixture ($CLEAN_FIXTURE) should produce 0 warnings + exit 0"
OUT2=$("$LINTER_BIN" "$CLEAN_FIXTURE" 2>&1)
EC2=$?
echo "$OUT2"

N_TOTAL2=$(echo "$OUT2" | grep -c "warning:")
PASS2=1
if [ "$N_TOTAL2" -ne 0 ]; then echo "FAIL: expected 0 warnings on clean file, got $N_TOTAL2"; PASS2=0; fi
if [ "$EC2" -ne 0 ]; then echo "FAIL: expected exit 0 on clean file, got $EC2"; PASS2=0; fi

if [ "$PASS1" -eq 1 ] && [ "$PASS2" -eq 1 ]; then
  echo "[smoke] PASS — linter v0 working"
  exit 0
else
  echo "[smoke] FAIL"
  exit 1
fi
