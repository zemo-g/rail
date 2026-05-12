#!/usr/bin/env bash
# Smoke test: confirms _bit_and / _bit_or / _bit_xor / _shl / _shr / _rotl
# runtime symbols exist in tools/x86_rt.s AND that a Rail bit-op program
# emits a callable x86 binary via Colima/Docker.
#
# Run BEFORE the fix to verify it catches the absence:
#   $ bash tools/test/x86_bitops_smoke.sh
#   FAIL pre-fix: linker should report `undefined reference to _bit_and`
#
# Run AFTER the fix to verify pass:
#   $ bash tools/test/x86_bitops_smoke.sh
#   PASS: 15 255 0 16 16 1
#
# Authored by Agent A (feat/a-bitop-runtime-v0).
set -u
cd "$(dirname "$0")/../.."

PROG='main =
  let a = bit_and 255 15
  let b = bit_or 240 15
  let c = bit_xor 4660 4660
  let d = shl 1 4
  let e = shr 256 4
  let f = rotl 256 56
  let _ = print (show a)
  let _ = print (show b)
  let _ = print (show c)
  let _ = print (show d)
  let _ = print (show e)
  let _ = print (show f)
  0'

echo "$PROG" > /tmp/x86_bitops_smoke.rail

# 1. Compile to x86 asm via local rail_native.
./rail_native x86 /tmp/x86_bitops_smoke.rail > /tmp/x86_bitops_smoke.compile.log 2>&1
if [ ! -s /tmp/rail_x86.s ]; then
    echo "FAIL: rail_native x86 did not produce /tmp/rail_x86.s"
    cat /tmp/x86_bitops_smoke.compile.log
    exit 1
fi

# 2. Verify the runtime symbols are present in x86_rt.s.
for sym in _bit_and _bit_or _bit_xor _shl _shr _rotl; do
    if ! grep -q "^${sym}:" tools/x86_rt.s; then
        echo "FAIL: symbol ${sym} not defined in tools/x86_rt.s"
        exit 2
    fi
done

# 3. Stage + link inside Colima/Docker (linux/amd64 via Rosetta).
# rail_native already inlines tools/x86_rt.s into the emitted /tmp/rail_x86.s
# (compile.rail:x86_compile_checked_x86 reads it at compile time), so we only
# link the single .s file.
STAGE="$HOME/.cache/rail-x86-bitops-smoke"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp /tmp/rail_x86.s "$STAGE/prog.s"

docker run --rm --platform linux/amd64 \
    -v "$STAGE":/work -w /work gcc:latest \
    bash -c 'gcc -no-pie -o prog prog.s && ./prog' \
    > /tmp/x86_bitops_smoke.run.log 2>&1
RC=$?

if [ $RC -ne 0 ]; then
    echo "FAIL: docker build/run failed (exit $RC)"
    tail -20 /tmp/x86_bitops_smoke.run.log
    exit 3
fi

EXPECTED=$'15\n255\n0\n16\n16\n1'
# bit_and 255 15 = 15
# bit_or  240 15 = 255
# bit_xor 4660 4660 = 0
# shl 1 4   = 16
# shr 256 4 = 16
# rotl 256 56 = 1   (bit 8 rotates left 56 wraps to bit 0, 64-bit width)
GOT=$(cat /tmp/x86_bitops_smoke.run.log)
if [ "$GOT" != "$EXPECTED" ]; then
    echo "FAIL: output mismatch"
    echo "expected:"
    echo "$EXPECTED"
    echo "got:"
    echo "$GOT"
    exit 4
fi

echo "PASS: $(echo "$GOT" | tr '\n' ' ')"
