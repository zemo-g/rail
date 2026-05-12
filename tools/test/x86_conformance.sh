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
'strne|0|main = if "ab" == "cd" then 1 else 0'
'str_plus|foobar|main =\n  let _ = print ("foo" + "bar")\n  0'
'listapp|5|main = length (append [1, 2] [3, 4, 5])'
'tupret|21|swap a b = (b, a)\nmain =\n  let (x, y) = swap 1 2\n  x * 10 + y'
'tup3|123|main =\n  let (a, b, c) = (100, 20, 3)\n  a + b + c'
'chars|a|main =\n  let cs = chars "abc"\n  let _ = print (head cs)\n  length cs'
'split_csv|b|main =\n  let _ = print (head (tail (split "," "a,b,c")))\n  0'
'bigint|42|main =\n  let x = 100000\n  x - 99958'
'adt_pair|10|type Pair = | MkPair a b\nfst p = match p | MkPair a b -> a\nmain = fst (MkPair 10 32)'
'wildcard|42|type T = | A x | B x | C\nmain = match (B 99)\n  | A x -> 0\n  | _ -> 42'
'reverse|3|main =\n  let xs = reverse [1, 2, 3]\n  head xs'
'not|1|main = if not false then 1 else 0'
'neg_arith|7|main = 10 + (-3)'
'match_int|one|classify n = match n\n  | 0 -> "zero"\n  | 1 -> "one"\n  | _ -> "other"\nmain =\n  let _ = print (classify 1)\n  0'
'guard|5|type Option = | Some x | None\nsafe_div a b = match b\n  | 0 -> None\n  | _ -> Some (a / b)\nmain = match (safe_div 10 2)\n  | Some x -> x\n  | None -> 0'
'map_fusion|6|double x = x * 2\ntriple x = x * 3\nmain = head (map double (map triple [1, 2, 3]))'
'nested_lam|7|main = (\\a -> \\b -> a + b) 3 4'
'nested_lam_let|7|main =\n  let f = \\a -> \\b -> a + b\n  f 3 4'
'nested_lam_cap|17|main =\n  let n = 10\n  let f = \\a -> \\b -> a + b + n\n  f 3 4'
'pipe|8|inc x = x + 1\ndbl x = x * 2\nmain = 3 |> inc |> dbl'
'match_str|hello|greet s = match s\n  | "hi" -> "hello"\n  | _ -> "huh"\nmain =\n  let _ = print (greet "hi")\n  0'
'fold_str|abc|cat2 a b = append a b\nmain =\n  let _ = print (fold cat2 "" ["a", "b", "c"])\n  0'
'arr_set|99|main =\n  let a = arr_new 3 0\n  let _ = arr_set a 1 99\n  arr_get a 1'
'arr_len|10|main =\n  let a = arr_new 10 0\n  arr_len a'
'arr_sum|50|sum a i = if i >= arr_len a then 0 else arr_get a i + sum a (i + 1)\nmain =\n  let a = arr_new 5 10\n  sum a 0'
'error|1|main =\n  let e = error "oops"\n  let ok = is_error e\n  let bad = is_error 42\n  ok - bad'
'char_to_int|65|main = char_to_int "A"'
'parse_int|1134|main =\n  let a = parse_int "1234"\n  let b = parse_int "-100"\n  let _ = print (show (a + b))\n  0'
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
