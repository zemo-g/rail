// Multi-section, multi-mnemonic test: compute fib(10) and exit with the value.
// Exercises: function calls (bl), branches (b.le), arithmetic, stack frame
// with stp/ldp pre/post-index writeback, and ret.
//
// fib(10) = 55, so the binary should `exit(55)`.
.text
.global _start
_start:
    mov x0, #10
    bl _fib
    mov x8, #93
    svc #0

// int _fib(int n) — naive recursive fibonacci
// Stack frame: 32 bytes.  Saves x29/x30, x19, x20.
_fib:
    stp x29, x30, [sp, #-32]!
    stp x19, x20, [sp, #16]
    mov x29, sp
    mov x19, x0          // x19 = n
    cmp x19, #1
    b.le .Lbase
    sub x0, x19, #1
    bl _fib
    mov x20, x0          // x20 = fib(n-1)
    sub x0, x19, #2
    bl _fib              // x0 = fib(n-2)
    add x0, x0, x20      // result = fib(n-1) + fib(n-2)
    b .Ldone
.Lbase:
    mov x0, x19          // return n
.Ldone:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
