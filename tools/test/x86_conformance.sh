#!/usr/bin/env bash
# x86_64 conformance harness for Rail.
# Pipeline per test:
#   src → ./rail_native x86 → /tmp/rail_x86.s → docker(gcc -no-pie) → run → diff stdout/exit
# Output: PASS/FAIL lines + final N/M summary. Non-zero exit if any FAIL.
#
# Tests are a representative subset of run_tests (~30) covering ints, strings,
# lists, ADTs, closures, floats, FFI, TCO, arena. Used to baseline x86 backend
# before triaging the top failure cluster.

# Deliberately no `set -eu`: test failures are expected, and empty bash arrays
# trip nounset. Each phase handles its own errors.

cd "$(dirname "$0")/../.."

# Colima/Lima mounts $HOME by default; /tmp is NOT mounted. Stage under $HOME.
STAGE="$HOME/.cache/rail-x86-conformance"
rm -rf "$STAGE"
mkdir -p "$STAGE/src" "$STAGE/asm" "$STAGE/out"

# Each test: name|expected|source
# Sources may contain \n for newlines; we'll printf %b them.
TESTS=(
'main42|42|main = 42'
'add|7|main = 3 + 4'
'if|42|main = if 1 == 1 then 42 else 0'
'double|42|double x = x * 2\nmain = double 21'
'fact|120|fact n =\n  if n <= 1 then 1\n  else n * fact (n - 1)\nmain = fact 5'
'print|42|main =\n  let _ = print 42\n  0'
'lets|48|main =\n  let a = 7\n  let b = a * a\n  b - 1'
'strprint|hello|main =\n  let _ = print "hello"\n  0'
'streq|1|main = if "ab" == "ab" then 1 else 0'
'show|42|main =\n  let _ = print (show 42)\n  0'
'append|hello|main =\n  let _ = print (append "hel" "lo")\n  0'
'listlen|3|main = length [10, 20, 30]'
'headtail|20|main = head (tail [10, 20, 30])'
'cons|42|main = head (cons 42 [1, 2])'
'empty|0|main = length []'
'strlen|5|main = length "hello"'
'mapfn|6|double x = x * 2\nmain = head (map double [3, 5, 7])'
'maplam|15|main = head (map (\\x -> x + 10) [5, 6, 7])'
'closure|101|main =\n  let n = 100\n  head (map (\\x -> x + n) [1, 2, 3])'
'join|a-b-c|main =\n  let _ = print (join "-" ["a", "b", "c"])\n  0'
'tuple|42|main =\n  let (a, b) = (10, 32)\n  a + b'
'tco|42|loop n = if n == 0 then 42 else loop (n - 1)\nmain =\n  let _ = print (show (loop 50000))\n  0'
'adt_none|42|type Option = | Some x | None\nmain = match None | Some x -> x | None -> 42'
'adt_some|42|type Option = | Some x | None\nmain = match (Some 42) | Some x -> x | None -> 0'
'neg|-42|main =\n  let _ = print (show (-42))\n  0'
'float|3.75|main =\n  let _ = print (show (1.5 + 2.25))\n  0'
'float_mul|7.5|main =\n  let _ = print (show (3.0 * 2.5))\n  0'
'float_cmp|1|main = if 3.14 > 2.71 then 1 else 0'
'fold|15|add a b = a + b\nmain = fold add 0 [1, 2, 3, 4, 5]'
'filter|3|gt2 x = if x > 2 then true else false\nmain = length (filter gt2 [1, 2, 3, 4, 5])'
'range|10|main = length (range 10)'
'fold_sum|5050|add a b = a + b\nmain =\n  let _ = print (show (fold add 0 (range 101)))\n  0'
)

# Phase 1: emit asm for every test
EMITTED=()
EMIT_FAILS=()
for entry in "${TESTS[@]}"; do
  name="${entry%%|*}"
  rest="${entry#*|}"
  expected="${rest%%|*}"
  src="${rest#*|}"
  printf "%b" "$src" > "$STAGE/src/$name.rail"
  # rail_native writes to /tmp/rail_x86.s; capture stderr too
  if ./rail_native x86 "$STAGE/src/$name.rail" > "$STAGE/out/$name.emit.log" 2>&1; then
    if [[ -s /tmp/rail_x86.s ]]; then
      cp /tmp/rail_x86.s "$STAGE/asm/$name.s"
      EMITTED+=("$name|$expected")
    else
      EMIT_FAILS+=("$name|empty-asm")
    fi
  else
    EMIT_FAILS+=("$name|emit-exit-$?")
  fi
done

# Phase 2: single docker invocation to assemble+link+run everything
# We mount $STAGE so the container can see asm/ and write out/.
cat > "$STAGE/runner.sh" <<'EOF'
#!/bin/sh
cd /stage
for s in asm/*.s; do
  name=$(basename "$s" .s)
  if gcc -no-pie -o "/tmp/$name.bin" "$s" 2> "out/$name.link.log"; then
    actual=$(/tmp/$name.bin 2>&1)
    ec=$?
    printf "%s\n--EXIT--\n%s\n" "$actual" "$ec" > "out/$name.run.log"
    rm -f "/tmp/$name.bin"
  else
    printf "LINK-FAIL\n" > "out/$name.run.log"
  fi
done
EOF
chmod +x "$STAGE/runner.sh"

docker run --rm --platform=linux/amd64 -v "$STAGE":/stage gcc:latest /stage/runner.sh

# Phase 3: diff results
PASS=0
FAIL=0
declare -a FAIL_LINES=()
for entry in "${EMITTED[@]}"; do
  name="${entry%%|*}"
  expected="${entry#*|}"
  log="$STAGE/out/$name.run.log"
  if [[ ! -f "$log" ]]; then
    FAIL=$((FAIL+1))
    FAIL_LINES+=("$name: no-run-log")
    continue
  fi
  if grep -q "^LINK-FAIL" "$log"; then
    FAIL=$((FAIL+1))
    linkerr=$(head -3 "$STAGE/out/$name.link.log" 2>/dev/null | tr '\n' ' ')
    FAIL_LINES+=("$name: link-fail [$linkerr]")
    continue
  fi
  stdout=$(awk 'NR==1{print; next} /^--EXIT--$/{exit}{print}' "$log" | head -1)
  exit_code=$(awk '/^--EXIT--$/{getline; print; exit}' "$log")
  # Mirror native runner: if stdout is empty, use exit_code as the "actual" value
  if [[ -n "$stdout" ]]; then
    actual="$stdout"
  else
    actual="$exit_code"
  fi
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS+1))
    printf "  PASS: %-25s = %s\n" "$name" "$actual"
  else
    FAIL=$((FAIL+1))
    FAIL_LINES+=("$name: got [$actual] expected [$expected] (exit=$exit_code)")
    printf "  FAIL: %-25s got [%s] expected [%s]\n" "$name" "$actual" "$expected"
  fi
done

# Phase 4: emit-failure summary
for ef in "${EMIT_FAILS[@]}"; do
  name="${ef%%|*}"
  reason="${ef#*|}"
  FAIL=$((FAIL+1))
  printf "  EMIT-FAIL: %-22s %s\n" "$name" "$reason"
done

TOTAL=$((PASS+FAIL))
echo "---"
echo "x86_64 conformance: $PASS/$TOTAL"
if (( FAIL > 0 )); then
  echo "Failures:"
  for line in "${FAIL_LINES[@]}"; do
    echo "  $line"
  done
fi
exit $([[ $FAIL -eq 0 ]] && echo 0 || echo 1)
