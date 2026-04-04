#!/bin/bash
# build_safe.sh — Build rail_safe with mandatory adversarial test gate.
# If ANY test fails, the build is rejected and rail_safe is NOT updated.
cd "$(dirname "$0")/.."
echo "=== Building rail_safe ==="

# Step 1: Patch arena to 32MB and compile
cp tools/compile.rail /tmp/compile_safe_build.rail
sed -i '' 's/536870912/33554432/g' /tmp/compile_safe_build.rail
echo "  Arena patched to 32MB"

# Step 2: Two-stage bootstrap
echo "  Stage 1: rail_native → stage1 (512MB BSS, 32MB strings)"
./rail_native /tmp/compile_safe_build.rail 2>&1 | grep -q "ld: OK"
if [ $? -ne 0 ]; then echo "FAIL: stage1 compile"; exit 1; fi
cp /tmp/rail_out /tmp/rail_safe_s1
chmod +x /tmp/rail_safe_s1

echo "  Stage 2: stage1 → rail_safe (32MB BSS, 32MB strings)"
/tmp/rail_safe_s1 /tmp/compile_safe_build.rail 2>&1 | grep -q "ld: OK"
if [ $? -ne 0 ]; then echo "FAIL: stage2 compile"; exit 1; fi
cp /tmp/rail_out /tmp/rail_safe_candidate
chmod +x /tmp/rail_safe_candidate

# Verify BSS is 32MB
BSS=$(otool -l /tmp/rail_safe_candidate | grep -A5 "__bss" | grep size | awk '{print $2}')
if [ "$BSS" != "0x0000000002000000" ]; then
  echo "FAIL: BSS is $BSS, expected 0x0000000002000000 (32MB)"
  exit 1
fi
echo "  BSS verified: 32MB"

# Step 3: Adversarial test suite — ALL must pass
echo "=== Adversarial Test Suite ==="
SAFE=/tmp/rail_safe_candidate
PASS=0
FAIL=0

# Banned construct tests (must REJECT)
printf 'main = shell "ls"' > /tmp/at1.rail
printf 'main = let f = shell\n  0' > /tmp/at2.rail
printf 'main = let f = \\x -> shell x\n  0' > /tmp/at3.rail
printf 'classify n = match n\n  | _ -> shell "ls"\nmain = classify 1' > /tmp/at4.rail
printf 'main = let _ = read_file "/etc/passwd"\n  0' > /tmp/at5.rail
printf 'main = let _ = write_file "/tmp/x" "y"\n  0' > /tmp/at6.rail
printf 'main = let _ = spawn 0\n  0' > /tmp/at7.rail
printf 'main = let _ = arena_mark 0\n  0' > /tmp/at8.rail
printf 'main = let f = \\x -> \\y -> shell x\n  0' > /tmp/at9.rail
printf 'type T = | shell x\nmain = let v = shell 42\n  0' > /tmp/at10.rail
printf 'go f = match f\n  | _ -> 0\nmain =\n  let g = \\x -> let _ = shell x\n    0\n  go g' > /tmp/at11.rail

for i in 1 2 3 4 5 6 7 8 9 10 11; do
  R=$($SAFE safe /tmp/at$i.rail 2>&1)
  if echo "$R" | grep -q "REJECTED"; then
    PASS=$((PASS+1))
  else
    echo "  FAIL: banned test $i not rejected"
    FAIL=$((FAIL+1))
  fi
done

# Source size limit
python3 -c "print('main = ' + ' + '.join(['1']*40000))" > /tmp/at_big.rail
R=$($SAFE safe /tmp/at_big.rail 2>&1)
if echo "$R" | grep -q "too large"; then PASS=$((PASS+1)); else echo "  FAIL: size limit"; FAIL=$((FAIL+1)); fi

# Empty source
printf '' > /tmp/at_empty.rail
R=$($SAFE safe /tmp/at_empty.rail 2>&1)
if echo "$R" | grep -q "ERROR"; then PASS=$((PASS+1)); else echo "  FAIL: empty source"; FAIL=$((FAIL+1)); fi

# Valid programs (must compile)
printf 'main = 0' > /tmp/av1.rail
printf 'fib n = if n < 2 then n else fib (n - 1) + fib (n - 2)\nmain = let _ = print (show (fib 10))\n  0' > /tmp/av2.rail
printf 'type C = | R | G | B\nname c = match c\n  | R -> "r"\n  | G -> "g"\n  | B -> "b"\nmain = let _ = print (name G)\n  0' > /tmp/av3.rail
printf 'apply f x = f x\nmain =\n  let y = 10\n  let f = \\x -> x + y\n  let _ = print (show (apply f 32))\n  0' > /tmp/av4.rail

for i in 1 2 3 4; do
  R=$($SAFE safe /tmp/av$i.rail 2>&1)
  if echo "$R" | grep -q "wat2wasm: OK"; then
    PASS=$((PASS+1))
  else
    echo "  FAIL: valid test $i"
    FAIL=$((FAIL+1))
  fi
done

# Import validation
IMPORTS=$(grep -c "(import" /tmp/rail_safe.wat 2>/dev/null || echo 0)
if [ "$IMPORTS" -eq 2 ]; then PASS=$((PASS+1)); else echo "  FAIL: $IMPORTS imports (expected 2)"; FAIL=$((FAIL+1)); fi

# Determinism
$SAFE safe /tmp/av2.rail 2>/dev/null; H1=$(shasum -a 256 /tmp/rail_safe.wasm | awk '{print $1}')
$SAFE safe /tmp/av2.rail 2>/dev/null; H2=$(shasum -a 256 /tmp/rail_safe.wasm | awk '{print $1}')
if [ "$H1" = "$H2" ]; then PASS=$((PASS+1)); else echo "  FAIL: non-deterministic"; FAIL=$((FAIL+1)); fi

echo "  Results: $PASS pass, $FAIL fail"

# Step 4: Gate — reject build on ANY failure
if [ "$FAIL" -gt 0 ]; then
  echo "=== BUILD REJECTED: $FAIL adversarial test(s) failed ==="
  exit 1
fi

# Step 5: Install + SHA-256
cp /tmp/rail_safe_candidate rail_safe
SHA=$(shasum -a 256 rail_safe | awk '{print $1}')
echo "$SHA" > rail_safe.sha256
echo "=== BUILD PASSED ==="
echo "  Binary: rail_safe ($(wc -c < rail_safe | tr -d ' ') bytes)"
echo "  SHA-256: $SHA"
echo "  Tests: $PASS/$PASS"
