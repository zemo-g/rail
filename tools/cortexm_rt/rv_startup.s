# tools/cortexm_rt/rv_startup.s — RISC-V (rv32imc) bare-metal startup.
# Targets qemu-system-riscv32 -M virt. On entry, jumps to _main, then exits
# via the sifive_test device at 0x100000 ((a0 << 16) | 0x5555 = PASS with
# main's return value as the qemu process exit code).

    .section .text.init, "ax"
    .global _start
_start:
    la sp, _stack_top

    # Zero .bss
    la t0, _bss_start
    la t1, _bss_end
1:
    bge t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 1b
2:

    # Call user main.
    call _main

    # Exit via sifive_test FAIL with code = a0. PASS (0x5555) always exits
    # qemu with code 0; FAIL (0x3333) propagates the upper-16-bit code as
    # the qemu process exit code, which is what we want for verification.
    slli a0, a0, 16
    li t0, 0x3333
    or a0, a0, t0
    li t0, 0x100000
    sw a0, 0(t0)

    # If qemu didn't exit, spin.
3:  j 3b
