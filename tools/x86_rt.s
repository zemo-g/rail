# x86_rt.s — Rail x86_64 Linux runtime (glibc-linked)
# Build: gcc -o prog prog.s -lc -lpthread
# Or: as -o prog.o prog.s && gcc -o prog prog.o -lc -lpthread
.intel_syntax noprefix

.section .rodata
_fmt_int:
    .asciz "%ld\n"
_fmt_str:
    .asciz "%s\n"
_fmt_ld:
    .asciz "%ld"
_fmt_g:
    .asciz "%g\n"
_fmt_gbare:
    .asciz "%.15g"
_mode_w:
    .asciz "w"
_mode_r:
    .asciz "r"
.p2align 3
_rail_empty_str:
    .byte 0

.data
.p2align 3
_rail_nil:
    .quad 2
.p2align 3
_rail_heap_ptr:
    .quad 0
.p2align 3
_rail_heap_end:
    .quad 0
.p2align 3
_rail_argc:
    .quad 0
_rail_argv:
    .quad 0

.bss
.p2align 3
_rail_heap:
    .space 268435456    # 256MB bump allocator

.text

# ── Entry point ──────────────────────────────────────────────────────────────
.global main
main:
    push rbp
    mov rbp, rsp
    # Init heap
    lea rax, [rip+_rail_heap]
    lea rcx, [rip+_rail_heap_ptr]
    mov [rcx], rax
    lea rdx, [rax+268435456]
    lea rcx, [rip+_rail_heap_end]
    mov [rcx], rdx
    # Call user main with argc, argv
    call _main
    # Untag return value
    sar rax, 1
    pop rbp
    ret

# ── Allocator ────────────────────────────────────────────────────────────────
# Input: rdi = size (tag value)
# Output: rax = pointer (past 8-byte header)
.global _rail_alloc
_rail_alloc:
    push rbp
    mov rbp, rsp
    mov rcx, rdi            # save tag/size
    add rdi, 15
    and rdi, -8             # align to 8
    lea rax, [rip+_rail_heap_ptr]
    mov r8, [rax]           # current ptr
    mov r9, r8
    add r9, rdi             # new ptr
    lea r10, [rip+_rail_heap_end]
    cmp r9, [r10]
    ja .Lalloc_slow
    mov [rax], r9           # update heap ptr
    mov [r8], rcx           # store tag at header
    lea rax, [r8+8]         # return ptr+8
    pop rbp
    ret
.Lalloc_slow:
    # Fallback to malloc
    call malloc@PLT
    pop rbp
    ret

# ── Print ────────────────────────────────────────────────────────────────────
# Input: rdi = tagged value (bit 0 = 1 means integer)
.global _rail_print
_rail_print:
    push rbp
    mov rbp, rsp
    test rdi, 1
    jz .Lprint_heap
    # Integer: untag and printf
    sar rdi, 1
    mov rsi, rdi
    lea rdi, [rip+_fmt_int]
    xor eax, eax
    call printf@PLT
    xor rdi, rdi
    call fflush@PLT
    mov rax, 1
    pop rbp
    ret
.Lprint_heap:
    # Heap object — check tag
    mov rax, [rdi]
    cmp rax, 6
    je .Lprint_float
    # String
    mov rsi, rdi
    lea rdi, [rip+_fmt_str]
    xor eax, eax
    call printf@PLT
    xor rdi, rdi
    call fflush@PLT
    mov rax, 1
    pop rbp
    ret
.Lprint_float:
    sub rsp, 16
    movsd xmm0, [rdi+8]
    lea rdi, [rip+_fmt_g]
    mov eax, 1
    call printf@PLT
    xor rdi, rdi
    call fflush@PLT
    add rsp, 16
    mov rax, 1
    pop rbp
    ret

# ── Show (int → string) ─────────────────────────────────────────────────────
.global _rail_show
_rail_show:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    test rdi, 1
    jz .Lshow_heap
    sar rdi, 1
    mov [rbp-8], rdi        # save untagged int
    mov rdi, 24
    call malloc@PLT
    mov [rbp-16], rax       # save buffer
    mov rdi, rax
    mov rsi, 24
    lea rdx, [rip+_fmt_ld]
    mov rcx, [rbp-8]
    xor eax, eax
    call snprintf@PLT
    mov rax, [rbp-16]
    leave
    ret
.Lshow_heap:
    # Float
    mov rax, [rdi]
    cmp rax, 6
    jne .Lshow_str
    sub rsp, 16
    movsd xmm0, [rdi+8]
    mov [rbp-24], rdi
    mov rdi, 32
    call malloc@PLT
    mov [rbp-16], rax
    mov rdi, rax
    mov rsi, 32
    lea rdx, [rip+_fmt_gbare]
    movsd xmm0, [rbp-24]
    movsd xmm0, [rdi+8]    # reload from saved object...
    # Actually let me fix this — save the float value
    mov rax, [rbp-24]
    movsd xmm0, [rax+8]
    mov rdi, [rbp-16]
    mov rsi, 32
    lea rdx, [rip+_fmt_gbare]
    mov eax, 1
    call snprintf@PLT
    mov rax, [rbp-16]
    add rsp, 16
    leave
    ret
.Lshow_str:
    # Already a string, return as-is
    mov rax, rdi
    leave
    ret

# ── String append ────────────────────────────────────────────────────────────
.global _rail_str_append
_rail_str_append:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], rdi        # s1
    mov [rbp-16], rsi       # s2
    call strlen@PLT
    mov [rbp-24], rax       # len1
    mov rdi, [rbp-16]
    call strlen@PLT
    add rax, [rbp-24]
    add rax, 1
    mov rdi, rax
    call malloc@PLT
    mov [rbp-32], rax       # result buffer
    mov rdi, rax
    mov rsi, [rbp-8]
    call strcpy@PLT
    mov rdi, [rbp-32]
    mov rsi, [rbp-16]
    call strcat@PLT
    mov rax, [rbp-32]
    leave
    ret

# ── Tagged arithmetic ────────────────────────────────────────────────────────
.global _rail_add
_rail_add:
    # Inline-codegen fallback enters here when LEFT (rdi) was heap. Test rdi to
    # match that contract: testing rsi mis-routes when the right operand's
    # string-literal address happens to be odd. See str_plus regression.
    test rdi, 1
    jz .Ladd_heap
    add rdi, rsi
    lea rax, [rdi-1]
    ret
.Ladd_heap:
    # Heap: check for string concat or float add
    push rbp
    mov rbp, rsp
    mov rax, [rsi]
    cmp rax, 6
    je .Ladd_float
    # String concat: rdi=first, rsi=second already in place for _rail_str_append
    call _rail_str_append
    pop rbp
    ret
.Ladd_float:
    sub rsp, 16
    movsd xmm0, [rsi+8]
    movsd xmm1, [rdi+8]
    addsd xmm0, xmm1
    mov rdi, 16
    call _rail_alloc
    mov qword ptr [rax], 6
    movsd [rax+8], xmm0
    add rsp, 16
    pop rbp
    ret

.global _rail_sub
_rail_sub:
    test rdi, 1
    jz .Lsub_float
    push rbp
    mov rbp, rsp
    sar rdi, 1
    sar rsi, 1
    sub rdi, rsi
    lea rax, [rdi*2+1]
    pop rbp
    ret
.Lsub_float:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    movsd xmm0, qword ptr [rdi+8]
    movsd xmm1, qword ptr [rsi+8]
    subsd xmm0, xmm1
    mov rdi, 16
    call _rail_alloc
    mov qword ptr [rax], 6
    movsd qword ptr [rax+8], xmm0
    add rsp, 16
    pop rbp
    ret

.global _rail_mul
_rail_mul:
    test rdi, 1
    jz .Lmul_float
    push rbp
    mov rbp, rsp
    sar rdi, 1
    sar rsi, 1
    imul rdi, rsi
    lea rax, [rdi*2+1]
    pop rbp
    ret
.Lmul_float:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    movsd xmm0, qword ptr [rdi+8]
    movsd xmm1, qword ptr [rsi+8]
    mulsd xmm0, xmm1
    mov rdi, 16
    call _rail_alloc
    mov qword ptr [rax], 6
    movsd qword ptr [rax+8], xmm0
    add rsp, 16
    pop rbp
    ret

.global _rail_div
_rail_div:
    test rdi, 1
    jz .Ldiv_float
    push rbp
    mov rbp, rsp
    sar rdi, 1
    sar rsi, 1
    mov rax, rdi
    cqo
    idiv rsi
    lea rax, [rax*2+1]
    pop rbp
    ret
.Ldiv_float:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    movsd xmm0, qword ptr [rdi+8]
    movsd xmm1, qword ptr [rsi+8]
    divsd xmm0, xmm1
    mov rdi, 16
    call _rail_alloc
    mov qword ptr [rax], 6
    movsd qword ptr [rax+8], xmm0
    add rsp, 16
    pop rbp
    ret

.global _rail_mod
_rail_mod:
    push rbp
    mov rbp, rsp
    sar rdi, 1
    sar rsi, 1
    mov rax, rdi
    cqo
    idiv rsi
    lea rax, [rdx*2+1]
    pop rbp
    ret

# ── Comparison ───────────────────────────────────────────────────────────────
.global _rail_eq
_rail_eq:
    push rbp
    mov rbp, rsp
    # Check if integer comparison
    test rdi, 1
    jz .Leq_heap
    test rsi, 1
    jz .Leq_heap
    cmp rdi, rsi
    sete al
    movzx rax, al
    lea rax, [rax*2+1]
    pop rbp
    ret
.Leq_heap:
    # String comparison
    sub rsp, 16
    call strcmp@PLT
    test eax, eax
    sete al
    movzx rax, al
    lea rax, [rax*2+1]
    add rsp, 16
    pop rbp
    ret

.global _rail_ne
_rail_ne:
    push rbp
    mov rbp, rsp
    test rdi, 1
    jz .Lne_heap
    test rsi, 1
    jz .Lne_heap
    cmp rdi, rsi
    setne al
    movzx rax, al
    lea rax, [rax*2+1]
    pop rbp
    ret
.Lne_heap:
    sub rsp, 16
    call strcmp@PLT
    test eax, eax
    setne al
    movzx rax, al
    lea rax, [rax*2+1]
    add rsp, 16
    pop rbp
    ret

# Float-aware ordered compares. Mirror ARM64 (compile.rail:2668-2671).
# Convention: rdi = left, rsi = right. Test rdi tag bit; if even, both heap-floats.
.global _rail_lt
_rail_lt:
    test rdi, 1
    jz .Llt_float
    cmp rdi, rsi
    setl al
    movzx rax, al
    lea rax, [rax*2+1]
    ret
.Llt_float:
    movsd xmm0, qword ptr [rdi+8]
    movsd xmm1, qword ptr [rsi+8]
    ucomisd xmm0, xmm1
    setb al
    movzx rax, al
    lea rax, [rax*2+1]
    ret

.global _rail_gt
_rail_gt:
    test rdi, 1
    jz .Lgt_float
    cmp rdi, rsi
    setg al
    movzx rax, al
    lea rax, [rax*2+1]
    ret
.Lgt_float:
    movsd xmm0, qword ptr [rdi+8]
    movsd xmm1, qword ptr [rsi+8]
    ucomisd xmm0, xmm1
    seta al
    movzx rax, al
    lea rax, [rax*2+1]
    ret

.global _rail_le
_rail_le:
    test rdi, 1
    jz .Lle_float
    cmp rdi, rsi
    setle al
    movzx rax, al
    lea rax, [rax*2+1]
    ret
.Lle_float:
    movsd xmm0, qword ptr [rdi+8]
    movsd xmm1, qword ptr [rsi+8]
    ucomisd xmm0, xmm1
    setbe al
    movzx rax, al
    lea rax, [rax*2+1]
    ret

.global _rail_ge
_rail_ge:
    test rdi, 1
    jz .Lge_float
    cmp rdi, rsi
    setge al
    movzx rax, al
    lea rax, [rax*2+1]
    ret
.Lge_float:
    movsd xmm0, qword ptr [rdi+8]
    movsd xmm1, qword ptr [rsi+8]
    ucomisd xmm0, xmm1
    setae al
    movzx rax, al
    lea rax, [rax*2+1]
    ret

# ── List operations ──────────────────────────────────────────────────────────
.global _rail_cons
_rail_cons:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi        # head
    mov [rbp-16], rsi       # tail
    mov rdi, 24
    call _rail_alloc
    mov qword ptr [rax], 1  # tag = cons
    mov rcx, [rbp-8]
    mov [rax+8], rcx        # head
    mov rcx, [rbp-16]
    mov [rax+16], rcx       # tail
    leave
    ret

.global _rail_head
_rail_head:
    mov rax, [rdi+8]
    ret

.global _rail_tail
_rail_tail:
    mov rax, [rdi+16]
    ret

.global _rail_length
_rail_length:
    push rbp
    mov rbp, rsp
    # Check type
    test rdi, 1
    jnz .Llen_zero
    mov rax, [rdi]
    cmp rax, 1
    je .Llen_list
    cmp rax, 2
    je .Llen_zero
    # String length
    call strlen@PLT
    lea rax, [rax*2+1]
    pop rbp
    ret
.Llen_list:
    xor rcx, rcx
.Llen_loop:
    mov rax, [rdi]
    cmp rax, 2              # nil tag
    je .Llen_done
    mov rdi, [rdi+16]       # tail
    inc rcx
    jmp .Llen_loop
.Llen_done:
    lea rax, [rcx*2+1]
    pop rbp
    ret
.Llen_zero:
    mov rax, 1              # tagged 0
    pop rbp
    ret

.global _rail_append
_rail_append:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi        # list1/str1
    mov [rbp-16], rsi       # list2/str2
    test rdi, 1
    jnz .Lapp_ret2
    mov rax, [rdi]
    cmp rax, 2
    je .Lapp_ret2
    cmp rax, 1
    je .Lapp_list
    # String append
    call _rail_str_append
    leave
    ret
.Lapp_ret2:
    mov rax, [rbp-16]
    leave
    ret
.Lapp_list:
    mov rdi, [rbp-8]
    mov rcx, [rdi+8]        # head
    mov [rbp-24], rcx
    mov rdi, [rdi+16]       # tail of first
    mov rsi, [rbp-16]       # second list
    call _rail_append
    mov rsi, rax             # appended tail
    mov rdi, [rbp-24]       # head
    call _rail_cons
    leave
    ret

.global _rail_reverse
_rail_reverse:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    lea rax, [rip+_rail_nil]
    mov [rbp-8], rax        # acc = nil
.Lrev_loop:
    mov rax, [rdi]
    cmp rax, 2
    je .Lrev_done
    mov [rbp-16], rdi       # save current
    mov rcx, [rdi+8]        # head
    mov rdi, rcx
    mov rsi, [rbp-8]        # acc
    call _rail_cons
    mov [rbp-8], rax        # acc = cons(head, acc)
    mov rdi, [rbp-16]
    mov rdi, [rdi+16]       # tail
    jmp .Lrev_loop
.Lrev_done:
    mov rax, [rbp-8]
    leave
    ret

.global _rail_range
_rail_range:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    sar rdi, 1
    dec rdi                 # n-1
    mov [rbp-8], rdi
    lea rax, [rip+_rail_nil]
    mov [rbp-16], rax       # acc = nil
.Lrange_loop:
    mov rdi, [rbp-8]
    cmp rdi, 0
    jl .Lrange_done
    lea rdi, [rdi*2+1]      # tag
    mov rsi, [rbp-16]
    call _rail_cons
    mov [rbp-16], rax
    mov rdi, [rbp-8]
    dec rdi
    mov [rbp-8], rdi
    jmp .Lrange_loop
.Lrange_done:
    mov rax, [rbp-16]
    leave
    ret

# ── Higher-order: map, filter, fold ──────────────────────────────────────────
.global _rail_map
_rail_map:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], rdi        # closure
    mov [rbp-16], rsi       # list
    mov rax, [rsi]
    cmp rax, 2
    je .Lmap_nil
    # Get head and tail
    mov rcx, [rsi+8]
    mov [rbp-24], rcx       # head
    mov rcx, [rsi+16]
    mov [rbp-32], rcx       # tail
    # Call closure with head
    mov rax, [rbp-8]        # closure
    mov r14, [rax+8]        # code ptr
    mov r13, [rax+16]       # ncaps
    mov rdi, [rbp-24]       # head as arg
    cmp r13, 0
    je .Lmap_call
    mov rsi, [rax+24]       # first capture
.Lmap_call:
    call r14
    mov [rbp-40], rax       # mapped head
    # Recurse on tail
    mov rdi, [rbp-8]
    mov rsi, [rbp-32]
    call _rail_map
    mov rsi, rax             # mapped tail
    mov rdi, [rbp-40]       # mapped head
    call _rail_cons
    leave
    ret
.Lmap_nil:
    lea rax, [rip+_rail_nil]
    leave
    ret

.global _rail_filter
_rail_filter:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], rdi        # closure
    mov [rbp-16], rsi       # list
    mov rax, [rsi]
    cmp rax, 2
    je .Lfilt_nil
    mov rcx, [rsi+8]
    mov [rbp-24], rcx       # head
    mov rcx, [rsi+16]
    mov [rbp-32], rcx       # tail
    # Call predicate with head
    mov rax, [rbp-8]
    mov r14, [rax+8]
    mov r13, [rax+16]
    mov rdi, [rbp-24]
    cmp r13, 0
    je .Lfilt_call
    mov rsi, [rax+24]
.Lfilt_call:
    call r14
    mov [rbp-40], rax       # predicate result
    # Recurse on tail
    mov rdi, [rbp-8]
    mov rsi, [rbp-32]
    call _rail_filter
    # Check predicate result
    mov rcx, [rbp-40]
    cmp rcx, 3              # tagged true
    jne .Lfilt_skip
    mov rsi, rax             # filtered tail
    mov rdi, [rbp-24]       # head
    call _rail_cons
    leave
    ret
.Lfilt_skip:
    leave
    ret
.Lfilt_nil:
    lea rax, [rip+_rail_nil]
    leave
    ret

.global _rail_fold
_rail_fold:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], rdi        # closure
    mov [rbp-16], rsi       # accumulator
    mov [rbp-24], rdx       # list
    mov rax, [rdx]
    cmp rax, 2
    je .Lfold_done
    mov rcx, [rdx+8]
    mov [rbp-32], rcx       # head
    # Call f(acc, head)
    mov rax, [rbp-8]
    mov r14, [rax+8]
    mov rdi, [rbp-16]       # acc
    mov rsi, [rbp-32]       # head
    mov r13, [rax+16]
    cmp r13, 0
    je .Lfold_call
    mov rdx, [rax+24]
.Lfold_call:
    call r14
    # Recurse: fold(f, result, tail)
    mov rdi, [rbp-8]
    mov rsi, rax             # new acc
    mov rax, [rbp-24]
    mov rdx, [rax+16]       # tail
    call _rail_fold
    leave
    ret
.Lfold_done:
    mov rax, [rbp-16]       # return accumulator
    leave
    ret

# ── String operations ────────────────────────────────────────────────────────
.global _rail_join
_rail_join:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], rdi        # separator
    mov [rbp-16], rsi       # list
    mov rax, [rsi]
    cmp rax, 2
    je .Ljoin_empty
    mov rcx, [rsi+8]
    mov [rbp-24], rcx       # head
    mov rcx, [rsi+16]
    mov rax, [rcx]
    cmp rax, 2
    je .Ljoin_single
    # head + sep + join(sep, tail)
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    mov rsi, [rsi+16]       # tail
    call _rail_join
    mov [rbp-32], rax       # joined rest
    # head + sep
    mov rdi, [rbp-24]
    mov rsi, [rbp-8]
    call _rail_str_append
    mov [rbp-40], rax
    # (head+sep) + rest
    mov rdi, rax
    mov rsi, [rbp-32]
    call _rail_str_append
    leave
    ret
.Ljoin_empty:
    lea rax, [rip+_rail_empty_str]
    leave
    ret
.Ljoin_single:
    mov rax, [rbp-24]
    leave
    ret

.global _rail_cat
_rail_cat:
    push rbp
    mov rbp, rsp
    mov rsi, rdi             # list
    lea rdi, [rip+_rail_empty_str]
    call _rail_join
    pop rbp
    ret

.global _rail_chars
_rail_chars:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], rdi         # string
    call strlen@PLT
    mov [rbp-16], rax        # length
    lea rax, [rip+_rail_nil]
    mov [rbp-24], rax        # acc = nil
    mov rax, [rbp-16]
    dec rax
    mov [rbp-32], rax        # i = len-1
.Lchars_loop:
    mov rax, [rbp-32]
    cmp rax, 0
    jl .Lchars_done
    # Allocate 2-byte string for single char
    mov rdi, 2
    call malloc@PLT
    mov [rbp-40], rax
    mov rcx, [rbp-8]
    mov rdx, [rbp-32]
    movzx edx, byte ptr [rcx+rdx]
    mov byte ptr [rax], dl
    mov byte ptr [rax+1], 0
    # cons(char_str, acc)
    mov rdi, rax
    mov rsi, [rbp-24]
    call _rail_cons
    mov [rbp-24], rax
    dec qword ptr [rbp-32]
    jmp .Lchars_loop
.Lchars_done:
    mov rax, [rbp-24]
    leave
    ret

.global _rail_split
_rail_split:
    push rbp
    mov rbp, rsp
    sub rsp, 64
    mov [rbp-8], rdi         # delimiters string
    mov [rbp-16], rsi        # string to split
    movzx eax, byte ptr [rdi] # first delimiter char
    mov [rbp-24], rax
    mov rdi, rsi
    call strlen@PLT
    mov [rbp-32], rax        # string length
    lea rax, [rip+_rail_nil]
    mov [rbp-40], rax        # result = nil
    mov qword ptr [rbp-48], 0 # start = 0
    mov qword ptr [rbp-56], 0 # i = 0
.Lsplit_loop:
    mov rax, [rbp-56]
    cmp rax, [rbp-32]
    jge .Lsplit_last
    mov rcx, [rbp-16]
    movzx edx, byte ptr [rcx+rax]
    cmp rdx, [rbp-24]
    je .Lsplit_hit
    inc qword ptr [rbp-56]
    jmp .Lsplit_loop
.Lsplit_hit:
    # Extract substring from start to i
    mov rax, [rbp-56]
    sub rax, [rbp-48]        # len = i - start
    inc rax                  # +1 for null
    mov rdi, rax
    call malloc@PLT
    mov [rbp-64], rax        # buffer
    mov rdi, rax
    mov rsi, [rbp-16]
    add rsi, [rbp-48]        # src = str + start
    mov rdx, [rbp-56]
    sub rdx, [rbp-48]        # len = i - start
    mov rcx, rdx
    rep movsb
    mov byte ptr [rdi], 0    # null terminate
    # cons(substr, result)... actually prepend, we'll reverse later
    # For correct order, build in reverse
    mov rdi, [rbp-64]
    mov rsi, [rbp-40]
    call _rail_cons
    mov [rbp-40], rax
    mov rax, [rbp-56]
    inc rax
    mov [rbp-48], rax        # start = i + 1
    mov [rbp-56], rax        # i = i + 1
    jmp .Lsplit_loop
.Lsplit_last:
    # Last segment
    mov rax, [rbp-32]
    sub rax, [rbp-48]
    inc rax
    mov rdi, rax
    call malloc@PLT
    mov [rbp-64], rax
    mov rdi, rax
    mov rsi, [rbp-16]
    add rsi, [rbp-48]
    mov rdx, [rbp-32]
    sub rdx, [rbp-48]
    mov rcx, rdx
    rep movsb
    mov byte ptr [rdi], 0
    mov rdi, [rbp-64]
    mov rsi, [rbp-40]
    call _rail_cons
    mov [rbp-40], rax
    # Reverse the result
    mov rdi, rax
    call _rail_reverse
    leave
    ret

# ── I/O ──────────────────────────────────────────────────────────────────────
.global _rail_write_file
_rail_write_file:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi         # filename
    mov [rbp-16], rsi        # content
    lea rsi, [rip+_mode_w]
    call fopen@PLT
    mov [rbp-24], rax        # FILE*
    test rax, rax
    jz .Lwf_fail
    mov rdi, [rbp-16]
    call strlen@PLT
    mov rdi, [rbp-16]        # buf
    mov rsi, 1               # size
    mov rdx, rax             # count
    mov rcx, [rbp-24]        # FILE*
    call fwrite@PLT
    mov rdi, [rbp-24]
    call fclose@PLT
.Lwf_fail:
    mov rax, 1               # tagged 0... actually return 1
    leave
    ret

.global _rail_read_file
_rail_read_file:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], rdi
    lea rsi, [rip+_mode_r]
    call fopen@PLT
    test rax, rax
    jz .Lrf_empty
    mov [rbp-16], rax        # FILE*
    mov rdi, rax
    xor rsi, rsi
    mov rdx, 2               # SEEK_END
    call fseek@PLT
    mov rdi, [rbp-16]
    call ftell@PLT
    mov [rbp-24], rax        # file size
    mov rdi, [rbp-16]
    xor rsi, rsi
    xor rdx, rdx             # SEEK_SET
    call fseek@PLT
    mov rdi, [rbp-24]
    inc rdi
    call malloc@PLT
    mov [rbp-32], rax        # buffer
    mov rdi, rax
    mov rsi, 1
    mov rdx, [rbp-24]
    mov rcx, [rbp-16]
    call fread@PLT
    mov rdi, [rbp-32]
    mov rsi, [rbp-24]
    mov byte ptr [rdi+rsi], 0
    mov rdi, [rbp-16]
    call fclose@PLT
    mov rax, [rbp-32]
    leave
    ret
.Lrf_empty:
    lea rax, [rip+_rail_empty_str]
    leave
    ret

.global _rail_shell
_rail_shell:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    lea rsi, [rip+_mode_r]
    call popen@PLT
    mov [rbp-8], rax         # pipe
    mov rdi, 65536
    call malloc@PLT
    mov [rbp-16], rax        # buffer
    mov qword ptr [rbp-24], 0 # total read
.Lsh_read:
    mov rdi, [rbp-16]
    add rdi, [rbp-24]
    mov rsi, 1
    mov rdx, 4096
    mov rcx, [rbp-8]
    call fread@PLT
    test rax, rax
    jz .Lsh_done
    add [rbp-24], rax
    jmp .Lsh_read
.Lsh_done:
    mov rdi, [rbp-16]
    mov rsi, [rbp-24]
    mov byte ptr [rdi+rsi], 0
    mov rdi, [rbp-8]
    call pclose@PLT
    mov rax, [rbp-16]
    leave
    ret

.global _rail_args
_rail_args:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    lea rax, [rip+_rail_nil]
    mov [rbp-8], rax         # result = nil
    lea rax, [rip+_rail_argc]
    mov rax, [rax]
    sar rax, 1               # untag argc
    dec rax
    mov [rbp-16], rax        # i = argc - 1
.Largs_loop:
    cmp qword ptr [rbp-16], 0
    jl .Largs_done
    lea rax, [rip+_rail_argv]
    mov rax, [rax]
    mov rcx, [rbp-16]
    mov rdi, [rax+rcx*8]     # argv[i]
    mov rsi, [rbp-8]
    call _rail_cons
    mov [rbp-8], rax
    dec qword ptr [rbp-16]
    jmp .Largs_loop
.Largs_done:
    mov rax, [rbp-8]
    leave
    ret

# ── Mutable arrays ──────────────────────────────────────────────────────────
# Layout matches ARM64: [tag=7 | length(untagged) | elem0 | elem1 | ...].
# _rail_arr_new(size_tagged, init_tagged) -> ptr
.global _rail_arr_new
_rail_arr_new:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    sar rdi, 1               # untag size
    mov [rbp-8], rdi         # save size (untagged)
    mov [rbp-16], rsi        # save init (tagged)
    lea rdi, [rdi*8+16]      # size*8 + 16 header
    call _rail_alloc
    mov [rbp-24], rax        # save buffer
    mov qword ptr [rax], 7   # tag = 7
    mov rcx, [rbp-8]
    mov [rax+8], rcx         # length (untagged)
    mov rsi, [rbp-16]        # init
    xor rcx, rcx             # i = 0
.Larn_loop:
    cmp rcx, [rbp-8]
    jae .Larn_done
    lea rdx, [rcx+2]
    mov [rax+rdx*8], rsi     # arr[(i+2)*8] = init
    inc rcx
    jmp .Larn_loop
.Larn_done:
    mov rax, [rbp-24]
    leave
    ret

# ── GC stub (no-op for now) ─────────────────────────────────────────────────
.global _rail_gc
_rail_gc:
    ret

.global _rail_free_list_alloc
_rail_free_list_alloc:
    xor rax, rax
    ret

.global _rail_free_list_clear
_rail_free_list_clear:
    ret

# ── RC stubs ─────────────────────────────────────────────────────────────────
.global _rail_rc_alloc
_rail_rc_alloc:
    push rbp
    mov rbp, rsp
    add rdi, 8
    call _rail_alloc
    pop rbp
    ret

.global _rail_rc_release
_rail_rc_release:
    ret

# ── String runtime: find/contains/sub/replace/split ─────────────────────────
# ARM64 oracle: compile.rail rt_string (sfind/scont/ssub/srepl/ssplit).
# x86 strings are raw char* (no heap wrapper), so no str_unwrap/wrap_str
# needed; we call glibc strstr/strlen/strcpy/memcpy/malloc directly.
#
# Arg passing (SysV ABI):
#   _rail_str_find(rdi=needle, rsi=haystack)
#   _rail_str_contains(rdi=needle, rsi=haystack)
#   _rail_str_sub(rdi=str, rsi=start_tagged, rdx=len_tagged)
#   _rail_str_replace(rdi=find, rsi=replace, rdx=str)
#   _rail_str_split(rdi=delim, rsi=str)

# _rail_str_find(needle, haystack) -> tagged int offset, or tagged -1
.global _rail_str_find
_rail_str_find:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp-8], rsi         # save haystack
    # strstr(haystack, needle) — glibc: rdi=haystack, rsi=needle
    mov rax, rdi             # swap: rax = needle
    mov rdi, rsi             # rdi = haystack
    mov rsi, rax             # rsi = needle
    call strstr@PLT
    test rax, rax
    jz .Lsf_notfound
    sub rax, [rbp-8]         # offset = match - haystack
    lea rax, [rax*2+1]       # tag
    leave
    ret
.Lsf_notfound:
    mov rax, -1
    lea rax, [rax*2+1]       # tag -1 -> -1 (0xFFFFFFFFFFFFFFFF)
    leave
    ret

# _rail_str_contains(needle, haystack) -> tagged bool (3=true, 1=false)
.global _rail_str_contains
_rail_str_contains:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    # strstr(haystack, needle)
    mov rax, rdi             # rax = needle
    mov rdi, rsi             # rdi = haystack
    mov rsi, rax             # rsi = needle
    call strstr@PLT
    test rax, rax
    setne al
    movzx rax, al
    lea rax, [rax*2+1]       # 0 -> 1 (false), 1 -> 3 (true)
    leave
    ret

# _rail_str_sub(str, start_tagged, len_tagged) -> new string (untagged char*)
.global _rail_str_sub
_rail_str_sub:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    sar rsi, 1               # untag start
    sar rdx, 1               # untag len
    mov [rbp-8], rdi         # save str
    mov [rbp-16], rsi        # save start
    mov [rbp-24], rdx        # save len
    # malloc(len + 1)
    mov rdi, rdx
    inc rdi
    call malloc@PLT
    mov [rbp-32], rax        # save dest buffer
    # memcpy(dest, str+start, len)
    mov rdi, rax             # dest
    mov rsi, [rbp-8]
    add rsi, [rbp-16]        # src = str + start
    mov rdx, [rbp-24]        # n = len
    call memcpy@PLT
    # null-terminate at dest[len]
    mov rax, [rbp-32]
    mov rcx, [rbp-24]
    mov byte ptr [rax+rcx], 0
    mov rax, [rbp-32]
    leave
    ret

# _rail_str_replace(find, replace, str) -> new string (replaces all occurrences)
# Allocate generous buffer: 4 * len(str) + 64 (matches ARM64 heuristic).
# This works for replace strings up to ~4x the find string; long replacements
# could in theory overflow but the ARM64 oracle has the same limit.
.global _rail_str_replace
_rail_str_replace:
    push rbp
    mov rbp, rsp
    sub rsp, 96
    mov [rbp-8], rdi         # find
    mov [rbp-16], rsi        # replace
    mov [rbp-24], rdx        # str (cursor advances)
    # str_len = strlen(str)
    mov rdi, rdx
    call strlen@PLT
    mov [rbp-32], rax        # str_len
    # find_len = strlen(find)
    mov rdi, [rbp-8]
    call strlen@PLT
    mov [rbp-40], rax        # find_len
    # replace_len = strlen(replace)
    mov rdi, [rbp-16]
    call strlen@PLT
    mov [rbp-48], rax        # replace_len
    # alloc buf = malloc(4*str_len + 64)
    mov rdi, [rbp-32]
    shl rdi, 2
    add rdi, 64
    call malloc@PLT
    mov [rbp-56], rax        # buf
    mov qword ptr [rbp-64], 0  # buf_off
    mov rax, [rbp-24]
    mov [rbp-72], rax        # cursor = str
.Lsr_loop:
    # strstr(cursor, find)
    mov rdi, [rbp-72]
    mov rsi, [rbp-8]
    call strstr@PLT
    test rax, rax
    jz .Lsr_rest
    mov [rbp-80], rax        # match_ptr
    # Copy cursor..match_ptr to buf+buf_off
    mov rsi, [rbp-72]
    mov rdx, rax
    sub rdx, rsi             # gap_len = match - cursor
    mov rdi, [rbp-56]
    add rdi, [rbp-64]        # dest = buf + buf_off
    mov [rbp-88], rdx        # save gap_len
    call memcpy@PLT
    # buf_off += gap_len
    mov rax, [rbp-88]
    add [rbp-64], rax
    # Copy replace to buf+buf_off
    mov rdi, [rbp-56]
    add rdi, [rbp-64]
    mov rsi, [rbp-16]
    mov rdx, [rbp-48]
    call memcpy@PLT
    # buf_off += replace_len
    mov rax, [rbp-48]
    add [rbp-64], rax
    # cursor = match_ptr + find_len
    mov rax, [rbp-80]
    add rax, [rbp-40]
    mov [rbp-72], rax
    jmp .Lsr_loop
.Lsr_rest:
    # Copy remainder of cursor (including null terminator) to buf+buf_off
    mov rdi, [rbp-56]
    add rdi, [rbp-64]
    mov rsi, [rbp-72]
.Lsr_cp3:
    movzx eax, byte ptr [rsi]
    mov [rdi], al
    inc rdi
    inc rsi
    test al, al
    jnz .Lsr_cp3
    mov rax, [rbp-56]
    leave
    ret

# _rail_str_split(delim, str) -> Rail list of strings (multi-char delimiter)
# Iterate strstr(cursor, delim); for each hit, cons substring onto acc.
# After loop, cons remainder, then reverse.
.global _rail_str_split
_rail_str_split:
    push rbp
    mov rbp, rsp
    sub rsp, 64
    mov [rbp-8], rdi         # delim
    mov [rbp-16], rsi        # str (also initial cursor)
    # delim_len
    call strlen@PLT
    mov [rbp-24], rax        # delim_len
    lea rax, [rip+_rail_nil]
    mov [rbp-32], rax        # acc = nil
    mov rax, [rbp-16]
    mov [rbp-40], rax        # cursor = str
.Lssp_loop:
    mov rdi, [rbp-40]
    mov rsi, [rbp-8]
    call strstr@PLT
    test rax, rax
    jz .Lssp_last
    mov [rbp-48], rax        # match_ptr
    # seg_len = match_ptr - cursor
    mov rcx, rax
    sub rcx, [rbp-40]
    mov [rbp-56], rcx        # seg_len
    # alloc seg_len+1
    lea rdi, [rcx+1]
    call malloc@PLT
    mov [rbp-64], rax        # seg_buf
    # memcpy(seg_buf, cursor, seg_len)
    mov rdi, rax
    mov rsi, [rbp-40]
    mov rdx, [rbp-56]
    call memcpy@PLT
    # null-terminate
    mov rax, [rbp-64]
    mov rcx, [rbp-56]
    mov byte ptr [rax+rcx], 0
    # cons(seg_buf, acc)
    mov rdi, [rbp-64]
    mov rsi, [rbp-32]
    call _rail_cons
    mov [rbp-32], rax
    # cursor = match_ptr + delim_len
    mov rax, [rbp-48]
    add rax, [rbp-24]
    mov [rbp-40], rax
    jmp .Lssp_loop
.Lssp_last:
    # Cons remainder (everything from cursor)
    mov rdi, [rbp-40]
    call strlen@PLT
    lea rdi, [rax+1]
    mov [rbp-56], rax        # rem_len (without null)
    call malloc@PLT
    mov [rbp-64], rax
    mov rdi, rax
    mov rsi, [rbp-40]
    call strcpy@PLT
    mov rdi, [rbp-64]
    mov rsi, [rbp-32]
    call _rail_cons
    mov [rbp-32], rax
    # Reverse
    mov rdi, rax
    call _rail_reverse
    leave
    ret
