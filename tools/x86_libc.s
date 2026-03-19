# x86_libc.s — Minimal syscall-based libc for Rail x86_64 Linux
# No glibc, no dynamic linking. Pure syscalls.

.intel_syntax noprefix
.text

# ── printf (integer-only for now) ──────────────────────────────────────────
# Prints a 64-bit signed integer followed by newline
# Input: rdi = integer value
_rail_print_int:
    push rbp
    mov rbp, rsp
    sub rsp, 32          # buffer on stack
    mov rax, rdi
    test rax, rax
    jns .Lpi_positive
    # Negative: print '-' then negate
    push rax
    mov rax, 1           # sys_write
    mov rdi, 1           # stdout
    lea rsi, [rip+.Lminus]
    mov rdx, 1
    syscall
    pop rax
    neg rax
.Lpi_positive:
    lea rdi, [rbp-1]     # end of buffer
    mov byte ptr [rdi], 10  # newline
    lea rcx, [rbp-2]     # write digits backwards
    mov r8, 10
.Lpi_loop:
    xor rdx, rdx
    div r8               # rax = rax/10, rdx = remainder
    add dl, '0'
    mov byte ptr [rcx], dl
    dec rcx
    test rax, rax
    jnz .Lpi_loop
    # Write
    inc rcx              # rcx points to first digit
    lea rdx, [rbp]
    sub rdx, rcx         # length = end - start
    mov rax, 1           # sys_write
    mov rdi, 1           # stdout
    mov rsi, rcx
    syscall
    leave
    ret

.Lminus: .byte '-'

# ── printf string ──────────────────────────────────────────────────────────
# Input: rdi = pointer to null-terminated string
_rail_print_str:
    push rbp
    mov rbp, rsp
    mov rsi, rdi          # string pointer
    # Find length
    xor rcx, rcx
.Lps_len:
    cmp byte ptr [rsi+rcx], 0
    je .Lps_print
    inc rcx
    jmp .Lps_len
.Lps_print:
    mov rdx, rcx          # length
    mov rax, 1            # sys_write
    mov rdi, 1            # stdout
    syscall
    # Print newline
    lea rsi, [rip+.Lnewline]
    mov rdx, 1
    mov rax, 1
    mov rdi, 1
    syscall
    leave
    ret

.Lnewline: .byte 10

# ── rail_print (tagged value) ─────────────────────────────────────────────
# Input: rdi = tagged Rail value (bit 0 = 1 means integer)
_rail_print:
    push rbp
    mov rbp, rsp
    test rdi, 1
    jz .Lrp_heap
    # Integer: untag and print
    sar rdi, 1
    call _rail_print_int
    mov rax, 1            # return tagged 1
    leave
    ret
.Lrp_heap:
    # Heap object: assume string (tag byte at [rdi] == 0 means C string)
    # For now: just treat as string pointer
    call _rail_print_str
    mov rax, 1
    leave
    ret

# ── rail_show (int → string) ──────────────────────────────────────────────
_rail_show:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    sar rdi, 1            # untag
    mov rax, rdi
    test rax, rax
    jns .Lsh_pos
    neg rax
    mov byte ptr [rbp-32], '-'
    lea rcx, [rbp-31]
    jmp .Lsh_digits
.Lsh_pos:
    lea rcx, [rbp-32]
.Lsh_digits:
    lea r8, [rbp-1]       # end of temp buffer
    mov r9, 10
    mov rdi, rax          # save original
.Lsh_dloop:
    xor rdx, rdx
    div r9
    add dl, '0'
    mov byte ptr [r8], dl
    dec r8
    test rax, rax
    jnz .Lsh_dloop
    inc r8                # first digit
    # Copy to malloc'd buffer (use mmap for now)
    lea rdx, [rbp]
    sub rdx, r8           # length
    push rdx
    push r8
    # mmap anonymous
    mov rax, 9            # sys_mmap
    xor rdi, rdi          # addr=NULL
    mov rsi, 64           # 64 bytes
    mov rdx, 3            # PROT_READ|PROT_WRITE
    mov r10, 0x22         # MAP_PRIVATE|MAP_ANONYMOUS
    mov r8, -1            # fd=-1
    xor r9, r9            # offset=0
    syscall
    mov rdi, rax          # dest
    pop rsi               # src
    pop rcx               # len
    push rdi              # save dest
    rep movsb
    mov byte ptr [rdi], 0 # null terminate
    pop rax               # return pointer
    leave
    ret

# ── rail_alloc (bump allocator) ───────────────────────────────────────────
# Input: rdi = size in bytes
# Output: rax = pointer
_rail_alloc:
    push rbp
    mov rbp, rsp
    lea rax, [rip+_rail_heap_ptr]
    mov rcx, [rax]        # current pointer
    mov rdx, rcx
    add rdx, rdi          # new pointer
    mov [rax], rdx        # store new
    mov rax, rcx          # return old
    leave
    ret

# ── rail_eq ───────────────────────────────────────────────────────────────
_rail_eq:
    cmp rdi, rsi
    sete al
    movzx rax, al
    shl rax, 1
    or rax, 1
    ret

# ── rail_ne ───────────────────────────────────────────────────────────────
_rail_ne:
    cmp rdi, rsi
    setne al
    movzx rax, al
    shl rax, 1
    or rax, 1
    ret

# ── arithmetic (tagged) ──────────────────────────────────────────────────
_rail_add:
    sar rdi, 1
    sar rsi, 1
    add rdi, rsi
    lea rax, [rdi*2+1]
    ret

_rail_sub:
    sar rdi, 1
    sar rsi, 1
    sub rdi, rsi
    lea rax, [rdi*2+1]
    ret

_rail_mul:
    sar rdi, 1
    sar rsi, 1
    imul rdi, rsi
    lea rax, [rdi*2+1]
    ret

_rail_div:
    sar rdi, 1
    sar rsi, 1
    mov rax, rdi
    cqo
    idiv rsi
    lea rax, [rax*2+1]
    ret

# ── exit ──────────────────────────────────────────────────────────────────
_rail_exit:
    mov rax, 60           # sys_exit
    # rdi already has exit code
    syscall

.data
_rail_heap_ptr:
    .quad _rail_heap

.bss
.p2align 3
_rail_heap:
    .space 67108864       # 64MB bump allocator
