// linux_libc.s — Syscall-based C library for Rail Linux ARM64 binaries
// No external dependencies. Pure syscalls + assembly string ops.
// Syscalls: write=64, read=63, openat=56, close=57, lseek=62, exit=93, mmap=222

// ---- String functions ----

_strlen:
    mov x1, x0
    mov x0, #0
.Lsl_loop:
    ldrb w2, [x1, x0]
    cbz w2, .Lsl_done
    add x0, x0, #1
    b .Lsl_loop
.Lsl_done:
    ret

_strcmp:
    mov x2, #0
.Lsc_loop:
    ldrb w3, [x0, x2]
    ldrb w4, [x1, x2]
    cmp w3, w4
    b.ne .Lsc_diff
    cbz w3, .Lsc_eq
    add x2, x2, #1
    b .Lsc_loop
.Lsc_diff:
    sub x0, x3, x4
    ret
.Lsc_eq:
    mov x0, #0
    ret

_strcpy:
    mov x2, x0
    mov x3, #0
.Lscp_loop:
    ldrb w4, [x1, x3]
    strb w4, [x0, x3]
    cbz w4, .Lscp_done
    add x3, x3, #1
    b .Lscp_loop
.Lscp_done:
    mov x0, x2
    ret

_strcat:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x0, [x29, #16]
    str x1, [x29, #24]
    bl _strlen
    ldr x1, [x29, #24]
    ldr x2, [x29, #16]
    add x0, x2, x0
    bl _strcpy
    ldr x0, [x29, #16]
    ldp x29, x30, [sp], #32
    ret

// ---- Memory ----

_malloc:
    mov x1, x0
    mov x0, #0
    mov x2, #3          // PROT_READ|PROT_WRITE
    mov x3, #0x22       // MAP_PRIVATE|MAP_ANONYMOUS
    mov x4, #-1
    mov x5, #0
    mov x8, #222        // mmap
    svc #0
    ret

_free:
    ret

// ---- Printf: handles %ld\n, %s\n, raw strings ----

_printf:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    ldrb w1, [x0]
    cmp w1, #37          // '%'
    b.ne .Lpf_raw
    ldrb w1, [x0, #1]
    cmp w1, #108         // 'l' → %ld
    b.eq .Lpf_int
    cmp w1, #115         // 's' → %s
    b.eq .Lpf_str
    cmp w1, #103         // 'g' → %g (float stub)
    b.eq .Lpf_raw
    b .Lpf_raw

.Lpf_int:
    ldr x0, [x29, #48]   // value from caller stack
    // itoa into buffer at x29+16
    mov x1, #0            // negative flag
    cmp x0, #0
    b.ge .Lpfi_pos
    neg x0, x0
    mov x1, #1
.Lpfi_pos:
    str x1, [x29, #40]   // save neg flag
    mov x2, #0            // digit count
    mov x3, #10
    add x4, x29, #16     // buffer start
.Lpfi_div:
    udiv x5, x0, x3
    msub x6, x5, x3, x0
    add x6, x6, #48      // '0' + digit
    str x6, [sp, #-16]!  // push digit
    add x2, x2, #1
    mov x0, x5
    cbnz x0, .Lpfi_div
    // reverse digits into buffer
    mov x7, #0
    ldr x1, [x29, #40]
    cbz x1, .Lpfi_nosgn
    mov w1, #45           // '-'
    strb w1, [x4, x7]
    add x7, x7, #1
.Lpfi_nosgn:
.Lpfi_rev:
    ldr x6, [sp], #16
    strb w6, [x4, x7]
    add x7, x7, #1
    sub x2, x2, #1
    cbnz x2, .Lpfi_rev
    // write to stdout
    mov x2, x7
    mov x0, #1
    mov x1, x4
    mov x8, #64
    svc #0
    // newline
    mov w1, #10
    strb w1, [x29, #16]
    mov x0, #1
    add x1, x29, #16
    mov x2, #1
    mov x8, #64
    svc #0
    b .Lpf_done

.Lpf_str:
    ldr x0, [x29, #48]
    str x0, [x29, #16]
    bl _strlen
    mov x2, x0
    mov x0, #1
    ldr x1, [x29, #16]
    mov x8, #64
    svc #0
    mov w1, #10
    strb w1, [x29, #24]
    mov x0, #1
    add x1, x29, #24
    mov x2, #1
    mov x8, #64
    svc #0
    b .Lpf_done

.Lpf_raw:
    str x0, [x29, #16]
    bl _strlen
    mov x2, x0
    mov x0, #1
    ldr x1, [x29, #16]
    mov x8, #64
    svc #0

.Lpf_done:
    ldp x29, x30, [sp], #48
    ret

// ---- snprintf: handles %ld → int-to-string ----

_snprintf:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    str x0, [x29, #16]   // buf
    str x1, [x29, #24]   // size
    ldrb w3, [x2, #1]
    cmp w3, #108          // 'l' → %ld
    b.eq .Lsnpf_int
    cmp w3, #46           // '.' → %.15g (float stub: write "0")
    b.eq .Lsnpf_float
    b .Lsnpf_done

.Lsnpf_int:
    ldr x0, [x29, #48]   // value from caller stack
    ldr x4, [x29, #16]   // buf
    mov x1, #0            // neg flag
    cmp x0, #0
    b.ge .Lsnpi_pos
    neg x0, x0
    mov x1, #1
.Lsnpi_pos:
    str x1, [x29, #32]
    mov x2, #0
    mov x3, #10
.Lsnpi_div:
    udiv x5, x0, x3
    msub x6, x5, x3, x0
    add x6, x6, #48
    str x6, [sp, #-16]!
    add x2, x2, #1
    str x2, [x29, #40]
    mov x0, x5
    cbnz x0, .Lsnpi_div
    // reverse into buf
    ldr x2, [x29, #40]
    ldr x4, [x29, #16]
    mov x7, #0
    ldr x1, [x29, #32]
    cbz x1, .Lsnpi_nosgn
    mov w1, #45
    strb w1, [x4, x7]
    add x7, x7, #1
.Lsnpi_nosgn:
.Lsnpi_rev:
    ldr x6, [sp], #16
    strb w6, [x4, x7]
    add x7, x7, #1
    sub x2, x2, #1
    cbnz x2, .Lsnpi_rev
    mov w6, #0
    strb w6, [x4, x7]
    mov x0, x7
    b .Lsnpf_done

.Lsnpf_float:
    ldr x0, [x29, #16]
    mov w1, #48           // '0'
    strb w1, [x0]
    mov w1, #0
    strb w1, [x0, #1]
    mov x0, #1

.Lsnpf_done:
    ldp x29, x30, [sp], #48
    ret

// ---- File I/O via syscalls ----

_fopen:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ldrb w2, [x1]
    cmp w2, #119          // 'w'
    b.eq .Lfop_w
    // default: read
    mov x1, x0
    mov x0, #-100         // AT_FDCWD
    mov x2, #0            // O_RDONLY
    mov x3, #0
    mov x8, #56           // openat
    svc #0
    b .Lfop_done
.Lfop_w:
    mov x1, x0
    mov x0, #-100
    mov x2, #0x241        // O_WRONLY|O_CREAT|O_TRUNC
    mov x3, #0x1a4        // 0644
    mov x8, #56
    svc #0
.Lfop_done:
    cmp x0, #0
    b.ge .Lfop_ok
    mov x0, #0
.Lfop_ok:
    ldp x29, x30, [sp], #16
    ret

_fwrite:
    mul x2, x1, x2
    mov x1, x0
    mov x0, x3
    mov x8, #64           // write
    svc #0
    ret

_fread:
    mul x2, x1, x2
    mov x1, x0
    mov x0, x3
    mov x8, #63           // read
    svc #0
    ret

_fclose:
    mov x8, #57           // close
    svc #0
    ret

_fseek:
    mov x8, #62           // lseek
    svc #0
    mov x0, #0
    ret

_ftell:
    mov x1, #0
    mov x2, #1            // SEEK_CUR
    mov x8, #62
    svc #0
    ret

_fflush:
    mov x0, #0
    ret

_open:
    mov x3, #0x1B6
    mov x2, x1
    mov x1, x0
    mov x0, #-100
    mov x8, #56
    svc #0
    ret

_ioctl:
    mov x8, #29
    svc #0
    ret

_sys_write:
    mov x8, #64
    svc #0
    ret

_sys_close:
    mov x8, #57
    svc #0
    ret

_usleep:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    mov x1, #1000
    mul x1, x0, x1
    mov x0, #0
    stp x0, x1, [x29, #16]
    add x0, x29, #16
    mov x1, #0
    mov x8, #101
    svc #0
    ldp x29, x30, [sp], #32
    ret

_poke_byte:
    strb w2, [x0, x1]
    mov x0, #0
    ret

_peek_byte:
    ldrb w0, [x0, x1]
    ret

_memset2:
    cbz x3, .Lms2_done
.Lms2_loop:
    strb w1, [x0], #1
    strb w2, [x0], #1
    sub x3, x3, #1
    cbnz x3, .Lms2_loop
.Lms2_done:
    mov x0, #0
    ret

// ---- popen/pclose: fork + execve + pipe ----

_popen:
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    str x0, [x29, #16]    // cmd
    // pipe2(fds, 0)
    add x0, x29, #24
    mov x1, #0
    mov x8, #59
    svc #0
    // clone(SIGCHLD, 0, 0, 0, 0)
    mov x0, #0x11
    mov x1, #0
    mov x2, #0
    mov x3, #0
    mov x4, #0
    mov x8, #220
    svc #0
    cbnz x0, .Lpop_parent
    // Child: dup2 write end → stdout
    ldr w0, [x29, #28]
    mov x1, #1
    mov x8, #24            // dup3
    svc #0
    ldr w0, [x29, #24]
    mov x8, #57
    svc #0
    ldr w0, [x29, #28]
    mov x8, #57
    svc #0
    // execve("/bin/sh", ["/bin/sh", "-c", cmd, NULL], NULL)
    b .Lpop_ashell
.Lpop_shell:
    .asciz "/bin/sh"
    .p2align 2
.Lpop_cflag:
    .asciz "-c"
    .p2align 2
.Lpop_ashell:
    adr x0, .Lpop_shell
    str x0, [x29, #40]
    adr x1, .Lpop_cflag
    str x1, [x29, #48]
    ldr x2, [x29, #16]
    str x2, [x29, #56]
    str xzr, [x29, #64]
    adr x0, .Lpop_shell
    add x1, x29, #40
    mov x2, #0
    mov x8, #221           // execve
    svc #0
    mov x0, #1
    mov x8, #93
    svc #0
.Lpop_parent:
    str x0, [x29, #32]
    ldr w0, [x29, #28]
    mov x8, #57
    svc #0
    ldr w0, [x29, #24]
    ldp x29, x30, [sp], #80
    ret

_pclose:
    mov x8, #57
    svc #0
    mov x0, #-1
    mov x1, #0
    mov x2, #0
    mov x3, #0
    mov x8, #260           // wait4
    svc #0
    ret

// ---- Conversions ----

// atoi: x0=string → x0=int
_atoi:
    mov x1, #0            // result
    mov x2, #0            // neg flag
    ldrb w3, [x0]
    cmp w3, #45           // '-'
    b.ne .Latoi_loop
    mov x2, #1
    add x0, x0, #1
.Latoi_loop:
    ldrb w3, [x0], #1
    cbz w3, .Latoi_done
    cmp w3, #48
    b.lt .Latoi_done
    cmp w3, #57
    b.gt .Latoi_done
    sub w3, w3, #48
    mov x4, #10
    mul x1, x1, x4
    add x1, x1, x3
    b .Latoi_loop
.Latoi_done:
    cbz x2, .Latoi_pos
    neg x1, x1
.Latoi_pos:
    mov x0, x1
    ret

_atof:
    fmov d0, xzr
    ret
