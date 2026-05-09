#!/usr/bin/env bash
# tools/garmin/m4_smoke.sh — Cortex-M4 backend smoke test.
#
# Compiles a battery of .rail programs through the cortexm target,
# then disassembles each .o and pattern-matches expected Thumb-2
# instructions. No watch needed; pure compile-side verification.
#
# Run from rail repo root:
#   tools/garmin/m4_smoke.sh

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

pass=0
fail=0
fail_names=()

check() {
  local name=$1
  local src=$2
  local pattern=$3

  echo "$src" > /tmp/m4_smoke_input.rail
  if ! ./rail_native cortexm /tmp/m4_smoke_input.rail > /tmp/m4_smoke.log 2>&1; then
    echo "  FAIL [$name]: cortexm exited non-zero"
    cat /tmp/m4_smoke.log | sed 's/^/    /'
    fail=$((fail + 1))
    fail_names+=("$name")
    return
  fi

  local disasm
  disasm=$(objdump -d --triple=thumbv7em-none-eabi /tmp/rail_m4.o 2>/dev/null)
  if echo "$disasm" | grep -qE "$pattern"; then
    echo "  PASS [$name]"
    pass=$((pass + 1))
  else
    echo "  FAIL [$name]: pattern '$pattern' not found"
    echo "$disasm" | sed 's/^/    /' | head -20
    fail=$((fail + 1))
    fail_names+=("$name")
  fi
}

echo "=== Cortex-M4 backend smoke ==="

check "return-int" \
  'main = 42' \
  'movw[[:space:]]+r0, #0x2a'

check "add" \
  'add x y = x + y
main = add 3 4' \
  'add[[:space:]]+r0, r1'

check "mul" \
  'sq x = x * x
main = sq 7' \
  'mul[[:space:]]+r0, r0, r1'

check "sub" \
  'diff x y = x - y
main = diff 10 3' \
  'sub.w[[:space:]]+r0, r0, r1'

check "if-cmp" \
  'gt x y = if x > y then 1 else 0
main = gt 5 3' \
  'cmp[[:space:]]+r0, r1'

check "if-branch" \
  'pick a b = if a < b then b else a
main = pick 4 7' \
  'bge[[:space:]]'

check "recursion" \
  'fact n = if n <= 1 then 1 else n * fact (n - 1)
main = fact 5' \
  'bl[[:space:]]+0x[0-9a-f]+ <_rail_fact'

check "3-arg-call" \
  'f a b c = a + b + c
main = f 1 2 3' \
  'mov[[:space:]]+r2,'

check "let-binding" \
  'compute = let x = 5 in let y = 7 in x * y + x
main = compute' \
  'str[[:space:]]+r0, \[r7, #-4\]'

check "let-load" \
  'pair a b = let s = a + b in s * s
main = pair 3 4' \
  'ldr[[:space:]]+r0, \[r7, #-4\]'

check "bool-eq" \
  'is_zero x = x == 0
main = is_zero 0' \
  'ite[[:space:]]+eq'

check "bool-lt" \
  'lt x y = x < y
main = lt 3 5' \
  'ite[[:space:]]+lt'

echo
echo "=== QEMU execution (Cortex-M4 boot) ==="

qemu_check() {
  local name=$1
  local src=$2
  local expected=$3

  echo "$src" > /tmp/m4_smoke_qemu.rail
  set +e
  ./tools/garmin/m4_qemu.sh /tmp/m4_smoke_qemu.rail > /tmp/m4_smoke_qemu.log 2>&1
  local got=$?
  set -e

  if [[ "$got" == "$expected" ]]; then
    echo "  PASS [$name] qemu exit=$got"
    pass=$((pass + 1))
  else
    echo "  FAIL [$name]: expected exit=$expected, got exit=$got"
    cat /tmp/m4_smoke_qemu.log | sed 's/^/    /'
    fail=$((fail + 1))
    fail_names+=("$name")
  fi
}

if command -v qemu-system-arm >/dev/null 2>&1; then
  qemu_check "qemu-return-42" 'main = 42' 42
  qemu_check "qemu-fact-5" 'fact n = if n <= 1 then 1 else n * fact (n - 1)
main = fact 5' 120
  qemu_check "qemu-let" 'compute = let x = 10 in let y = 5 in x * y + x
main = compute' 60

  qemu_check "qemu-ctor-tag" 'type Color = | Red | Green | Blue
main = Green' 1

  qemu_check "qemu-match" 'type State = | Idle | Running | Halted
to_int s = match s | Idle -> 10 | Running -> 20 | Halted -> 30
main = to_int Running' 20

  qemu_check "qemu-hex-literal" 'main = if 0x40004000 == 1073758208 then 99 else 1' 99

  qemu_check "qemu-adt-payload-some" 'type Option = | Some x | None
unwrap_or opt d = match opt | Some x -> x | None -> d
main = unwrap_or (Some 17) 99' 17

  qemu_check "qemu-adt-payload-none" 'type Option = | Some x | None
unwrap_or opt d = match opt | Some x -> x | None -> d
main = unwrap_or None 42' 42

  qemu_check "qemu-neg-literal" 'main = 0 - 100' 156

  # MMIO UART check: Rail program writes "Hi!\n" to CMSDK UART. Qemu prints
  # those bytes to stdout. Capture and grep.
  if [[ -f examples/m4_uart_hello.rail ]]; then
    set +e
    ./tools/garmin/m4_qemu.sh examples/m4_uart_hello.rail > /tmp/m4_smoke_uart.log 2>&1
    set -e
    if grep -q '^Hi!$' /tmp/m4_smoke_uart.log; then
      echo "  PASS [qemu-uart-hello] saw 'Hi!' in qemu stdout"
      pass=$((pass + 1))
    else
      echo "  FAIL [qemu-uart-hello]: 'Hi!' not in qemu output"
      cat /tmp/m4_smoke_uart.log | sed 's/^/    /'
      fail=$((fail + 1))
      fail_names+=("qemu-uart-hello")
    fi
  fi

  # SysTick demo: ISR increments counter; main prints count after delay.
  if [[ -f examples/m4_systick.rail ]]; then
    set +e
    ./tools/garmin/m4_qemu.sh examples/m4_systick.rail > /tmp/m4_smoke_systick.log 2>&1
    set -e
    if grep -qE '^[1-9][0-9]*$' /tmp/m4_smoke_systick.log; then
      echo "  PASS [qemu-systick] ISR fired (non-zero counter printed)"
      pass=$((pass + 1))
    else
      echo "  FAIL [qemu-systick]: no counter increment observed"
      fail=$((fail + 1))
      fail_names+=("qemu-systick")
    fi
  fi

  # Fib demo: Rail computes + prints fib(0..10) using sdiv + recursion + MMIO.
  if [[ -f examples/m4_fib_print.rail ]]; then
    set +e
    ./tools/garmin/m4_qemu.sh examples/m4_fib_print.rail > /tmp/m4_smoke_fib.log 2>&1
    set -e
    expected=$'0\n1\n1\n2\n3\n5\n8\n13\n21\n34\n55'
    actual=$(grep -E '^[0-9]+$' /tmp/m4_smoke_fib.log | head -11)
    if [[ "$actual" == "$expected" ]]; then
      echo "  PASS [qemu-fib-print] saw fib(0..10) in qemu stdout"
      pass=$((pass + 1))
    else
      echo "  FAIL [qemu-fib-print]: expected fib sequence; got:"
      echo "$actual" | sed 's/^/    /'
      fail=$((fail + 1))
      fail_names+=("qemu-fib-print")
    fi
  fi
else
  echo "  SKIP: qemu-system-arm not installed (brew install qemu)"
fi

echo
echo "=== ELF link verification ==="

# Last cortexm run produced /tmp/rail_m4.elf — verify vector table and Reset_Handler.
if [[ ! -f /tmp/rail_m4.elf ]]; then
  echo "  FAIL: /tmp/rail_m4.elf missing (link step failed?)"
  fail=$((fail + 1))
  fail_names+=("elf-exists")
else
  # Vector[0] should be 0x10060000 (top of SRAM), little-endian "00000610"
  if objdump -s -j .vectors /tmp/rail_m4.elf | grep -q '0000 00000610'; then
    echo "  PASS [elf-stack-top]"
    pass=$((pass + 1))
  else
    echo "  FAIL [elf-stack-top]: vector[0] != 0x10060000"
    fail=$((fail + 1))
    fail_names+=("elf-stack-top")
  fi

  # Vector[1] (reset) should match Reset_Handler symbol | 1 (Thumb LSB)
  rh_addr=$(objdump -t /tmp/rail_m4.elf | awk '/Reset_Handler/ { print "0x" $1 }')
  if [[ -n "$rh_addr" ]]; then
    expected=$(printf '%08x' $((rh_addr | 1)))
    expected_le="${expected:6:2}${expected:4:2}${expected:2:2}${expected:0:2}"
    if objdump -s -j .vectors /tmp/rail_m4.elf | grep -qi " $expected_le "; then
      echo "  PASS [elf-reset-vector]"
      pass=$((pass + 1))
    else
      echo "  FAIL [elf-reset-vector]: expected vector[1]=$expected_le"
      fail=$((fail + 1))
      fail_names+=("elf-reset-vector")
    fi
  fi
fi

echo
echo "=== $pass passed, $fail failed ==="
if (( fail > 0 )); then
  echo "Failed: ${fail_names[*]}"
  exit 1
fi
exit 0
