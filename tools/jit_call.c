// tools/jit_call.c
// Pre-compiled trampolines for the pure-Rail JIT.
//
// Build:
//   bash jit/build_trampoline.sh
//
// Three roles, all wired through compile.rail's `-L jit -weak-ljit_call`:
//   1) jit_call:        indirect-call trampoline (replaces pthread_create).
//   2) jit_print_float: float printing path for op_print_float (snprintf %g).
//   3) jit_float_bits_lo / jit_float_bits_hi: bit-cast double -> 2x32-bit halves.
//   4) jit_print_float_addr: dlsym replacement; returns absolute address of
//      jit_print_float so the JIT-emitted blr can jump to it.
//
// The float helpers use 32-bit halves rather than a single 64-bit return
// because Rail's `-> int` retag does `lsl x0, x0, #1; orr x0, x0, #1` and
// would lose the top bit for negative-float bit patterns.

#include <stdio.h>
#include <stdint.h>

long jit_call(long (*fn)(long), long arg) { return fn(arg); }

char *jit_print_float(double x, char *cursor) {
    int n = snprintf(cursor, 64, "%g\n", x);
    return cursor + n;
}

long jit_float_bits_lo(double x) {
    uint64_t b;
    __builtin_memcpy(&b, &x, 8);
    return (long)(b & 0xFFFFFFFFu);
}

long jit_float_bits_hi(double x) {
    uint64_t b;
    __builtin_memcpy(&b, &x, 8);
    return (long)((b >> 32) & 0xFFFFFFFFu);
}

long jit_print_float_addr(long _ignored) {
    (void)_ignored;
    return (long)(void *)jit_print_float;
}
