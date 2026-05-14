// Exercises .data + adrp + add :lo12: + write syscall.
// Prints "v5 lives\n" to stdout and exits with the byte count.
.text
.global _start
_start:
    // x0 = fd (stdout = 1)
    mov x0, #1
    // x1 = ptr — adrp + add :lo12:
    adrp x1, _msg
    add x1, x1, :lo12:_msg
    // x2 = length
    mov x2, #9
    // x8 = syscall write = 64
    mov x8, #64
    svc #0
    // exit(9)
    mov x0, #9
    mov x8, #93
    svc #0

.data
_msg:
    .ascii "v5 lives\n"
