// linux_data.s — Runtime data symbols for Rail Linux binaries
// Used when the compiler's generated assembly doesn't include its own data section
// (happens when cross-compiled compiler runs on Pi with limited heap)

.data
_fmt_int:
    .byte 37, 108, 100, 10, 0
_fmt_str:
    .byte 37, 115, 10, 0
_fmt_ld:
    .byte 37, 108, 100, 0
_fmt_g:
    .asciz "%g\n"
_fmt_gbare:
    .asciz "%.15g"
.p2align 3
_rail_empty_str:
    .byte 0
_mode_w:
    .asciz "w"
_mode_r:
    .asciz "r"
.p2align 3
_rail_nil:
    .quad 2
.p2align 3
_rail_heap_ptr:
    .quad _rail_heap
.p2align 3
_rail_heap_end:
    .quad _rail_heap + 268435456
.p2align 3
_rail_argc:
    .quad 0
_rail_argv:
    .quad 0
