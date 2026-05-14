// Tests .bss + .comm + adrp/:lo12: + ldr/str for BSS-resident counters.
// Counts to 7 in BSS, then exits with the value (= 7).
.text
.global _start
_start:
    mov x0, #0
    adrp x1, _counter
    add x1, x1, :lo12:_counter
    str x0, [x1]
.Lloop:
    ldr x0, [x1]
    add x0, x0, #1
    str x0, [x1]
    cmp x0, #7
    b.lt .Lloop
    // exit(counter)
    mov x8, #93
    svc #0

.bss
.p2align 3
_counter:
    .space 8
