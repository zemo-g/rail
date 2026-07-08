#!/bin/bash
# build_safe.sh — Build rail_safe with mandatory adversarial test gate.
# If ANY test fails, the build is rejected and rail_safe is NOT updated.
cd "$(dirname "$0")/.."
echo "=== Building rail_safe ==="

# Step 1+2: Two-stage in-process self-compile (v5 toolchain — no as/ld,
# no sed arena patch). Since v5 the arena is NOT baked into the binary:
# _rail_arena_init mmaps it at startup, sized by the RAIL_ARENA_MB env var
# (default 1GB). The sandbox therefore enforces 32MB at LAUNCH
# (RAIL_ARENA_MB=32 in Dockerfile.safe / safe_server), not at build time.
# rail_safe is the two-stage fixed-point of the current compiler source.
echo "  Stage 1: rail_native -> stage1 (in-process rail-link)"
RAIL_ARENA_MB=6000 ./rail_native self 2>&1 | grep -q "Binary: /tmp/rail_self"
if [ $? -ne 0 ]; then echo "FAIL: stage1 compile"; exit 1; fi
cp /tmp/rail_self /tmp/rail_safe_s1
chmod +x /tmp/rail_safe_s1

echo "  Stage 2: stage1 -> rail_safe candidate (fixed point)"
RAIL_ARENA_MB=6000 /tmp/rail_safe_s1 self 2>&1 | grep -q "Binary: /tmp/rail_self"
if [ $? -ne 0 ]; then echo "FAIL: stage2 compile"; exit 1; fi
cp /tmp/rail_self /tmp/rail_safe_candidate
chmod +x /tmp/rail_safe_candidate

# Fixed point: stage2 output must equal a stage-3 recompile by the candidate
RAIL_ARENA_MB=6000 /tmp/rail_safe_candidate self 2>&1 | grep -q "Binary: /tmp/rail_self"
if [ $? -ne 0 ]; then echo "FAIL: stage3 compile"; exit 1; fi
if ! cmp -s /tmp/rail_self /tmp/rail_safe_candidate; then
  echo "FAIL: candidate is not a byte-identical fixed point"
  exit 1
fi
echo "  Fixed point verified (stage2 == stage3, byte-identical)"

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
