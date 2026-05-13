#!/usr/bin/env bash
# tools/garmin/m4_qemu.sh — Boot a Rail program in QEMU as a Cortex-M4.
#
# Compiles the input .rail through the cortexm backend, re-links with the
# mps2-an386 linker script (qemu's RAM is at 0x20000000, not Apollo2's
# 0x10000000), boots qemu-system-arm with semihosting, prints the exit
# code (which is _main's return value mod 256).
#
# Usage:
#   tools/garmin/m4_qemu.sh path/to/file.rail
#
# Exit code: _main's return value mod 256 (0-255). On failure: 1.

set -u

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <file.rail>" >&2
  exit 1
fi
src=$1

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# 1. Compile to .s and .o (pure cortexm backend run).
if ! ./rail_native cortexm "$src" > /tmp/m4_qemu_compile.log 2>&1; then
  echo "FAIL: cortexm compile" >&2
  cat /tmp/m4_qemu_compile.log >&2
  exit 1
fi

# 2. Re-link with the qemu linker script.
if ! clang --target=thumbv7em-none-eabi -mthumb -mcpu=cortex-m4 \
        -c tools/cortexm_rt/startup.s -o /tmp/rail_m4_rt.o 2>/tmp/m4_qemu_compile.log; then
  echo "FAIL: assemble startup.s" >&2
  cat /tmp/m4_qemu_compile.log >&2
  exit 1
fi

if ! ld.lld -T tools/cortexm_rt/mps2_an386.ld /tmp/rail_m4.o /tmp/rail_m4_rt.o \
        -o /tmp/rail_m4_qemu.elf 2>/tmp/m4_qemu_compile.log; then
  echo "FAIL: link with qemu script" >&2
  cat /tmp/m4_qemu_compile.log >&2
  exit 1
fi

# 3. Boot in qemu. Semihosting target=native lets the guest do SYS_EXIT_EXTENDED
#    which qemu translates into its own exit code.
qemu-system-arm \
    -M mps2-an386 \
    -kernel /tmp/rail_m4_qemu.elf \
    -nographic \
    -semihosting-config enable=on,target=native \
    -monitor none \
    -no-reboot
ec=$?
echo "qemu exit: $ec"
exit "$ec"
