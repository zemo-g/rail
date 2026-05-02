// linux_libc.s — Syscall-based C library for Rail Linux ARM64 binaries
// No external dependencies. Pure syscalls + assembly string ops.
// Syscalls: write=64, read=63, openat=56, close=57, lseek=62, exit=93, mmap=222
// ---- String functions (pure assembly, all platforms) ----

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

_atoi:
    mov x1, #0
    mov x2, #0
    ldrb w3, [x0]
    cmp w3, #45
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

_strstr:
    ldrb w2, [x1]
    cbz w2, .Lstrstr_match
.Lstrstr_outer:
    ldrb w2, [x0]
    cbz w2, .Lstrstr_notfound
    mov x3, x0
    mov x4, x1
.Lstrstr_inner:
    ldrb w5, [x4]
    cbz w5, .Lstrstr_match
    ldrb w6, [x3]
    cbz w6, .Lstrstr_advance
    cmp w5, w6
    b.ne .Lstrstr_advance
    add x3, x3, #1
    add x4, x4, #1
    b .Lstrstr_inner
.Lstrstr_advance:
    add x0, x0, #1
    b .Lstrstr_outer
.Lstrstr_match:
    ret
.Lstrstr_notfound:
    mov x0, #0
    ret


// ---- Memory ----
// _malloc moved further down: it now bump-allocates from _rail_heap.
// _free remains a no-op (the bump arena does not support per-object free;
// reclamation only happens via _rail_gc, which dns-sink never triggers).

_free:
    ret

// ============ Rail runtime (Linux replacements) ============
// compile.rail emits Mac-ABI versions of the following _rail_* runtime
// stubs (svc #0x80 + Darwin syscall classes in x16). build_linux's
// strip awk drops them; these replacements use Linux conventions
// (svc #0, syscall # in x8). Keep both lists in sync — anything added
// here must also be added to the strip awk in build_linux.

// _rail_arena_init — Linux variant.
// Mach-O auto-invokes via __mod_init_func; on ELF we drop that stanza
// and call this explicitly from _start. Sets up the 1 GB _rail_heap
// region (BSS-allocated by build_linux's bss snippet) as the bump
// arena. No mmap needed since _rail_heap is statically reserved.
_rail_arena_init:
    adrp x0, _rail_heap
    add x0, x0, :lo12:_rail_heap
    adrp x1, _rail_heap_base
    add x1, x1, :lo12:_rail_heap_base
    str x0, [x1]
    adrp x1, _rail_heap_ptr
    add x1, x1, :lo12:_rail_heap_ptr
    str x0, [x1]
    mov x2, #0x40000000            // 1 GB
    add x2, x0, x2
    adrp x1, _rail_heap_end
    add x1, x1, :lo12:_rail_heap_end
    str x2, [x1]
    ret

// _rail_print — Linux variant.
// Same shape as the Mac version but with Linux syscall conventions
// (write = 64 in x8, svc #0). Handles tagged ints, heap floats, and
// heap strings. Always appends a trailing '\n'.
_rail_print:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    tst x0, #1
    b.eq .Lprnt_l_heap
    asr x0, x0, #1
    mov x1, #0
    cmp x0, #0
    b.ge .Lprnt_l_pos
    neg x0, x0
    mov x1, #1
.Lprnt_l_pos:
    str x1, [x29, #48]
    mov x2, #0
    mov x3, #10
    add x4, x29, #16
.Lprnt_l_div:
    udiv x5, x0, x3
    msub x6, x5, x3, x0
    add x6, x6, #48
    str x6, [sp, #-16]!
    add x2, x2, #1
    mov x0, x5
    cbnz x0, .Lprnt_l_div
    cbz x2, .Lprnt_l_zero
    mov x7, #0
    ldr x1, [x29, #48]
    cbz x1, .Lprnt_l_nosign
    mov w1, #45
    strb w1, [x4, x7]
    add x7, x7, #1
.Lprnt_l_nosign:
.Lprnt_l_rev:
    ldr x6, [sp], #16
    strb w6, [x4, x7]
    add x7, x7, #1
    sub x2, x2, #1
    cbnz x2, .Lprnt_l_rev
    mov w1, #10
    strb w1, [x4, x7]
    add x7, x7, #1
    mov x0, #1
    mov x1, x4
    mov x2, x7
    mov x8, #64
    svc #0
    b .Lprnt_l_done
.Lprnt_l_zero:
    mov w0, #48
    strb w0, [x4]
    mov w0, #10
    strb w0, [x4, #1]
    mov x0, #1
    mov x1, x4
    mov x2, #2
    mov x8, #64
    svc #0
    b .Lprnt_l_done
.Lprnt_l_heap:
    ldr x1, [x0]
    and x1, x1, #0x7fffffffffffffff
    cmp x1, #6
    b.eq .Lprnt_l_float
    bl _str_unwrap
    str x0, [x29, #16]
    bl _strlen
    mov x2, x0
    mov x0, #1
    ldr x1, [x29, #16]
    mov x8, #64
    svc #0
    mov w0, #10
    strb w0, [x29, #24]
    mov x0, #1
    add x1, x29, #24
    mov x2, #1
    mov x8, #64
    svc #0
    b .Lprnt_l_done
.Lprnt_l_float:
    // Float printing path uses _snprintf (already in linux_libc.s).
    ldr d0, [x0, #8]
    str d0, [x29, #16]
    mov x0, #32
    bl _malloc
    str x0, [x29, #24]
    ldr d0, [x29, #16]
    str d0, [sp, #-16]!
    ldr x0, [x29, #24]
    mov x1, #32
    adrp x2, _fmt_gbare
    add x2, x2, :lo12:_fmt_gbare
    bl _snprintf
    add sp, sp, #16
    ldr x0, [x29, #24]
    bl _strlen
    mov x2, x0
    mov x0, #1
    ldr x1, [x29, #24]
    mov x8, #64
    svc #0
    mov w0, #10
    strb w0, [x29, #32]
    mov x0, #1
    add x1, x29, #32
    mov x2, #1
    mov x8, #64
    svc #0
    ldr x0, [x29, #24]
    bl _free
.Lprnt_l_done:
    mov x0, #1
    ldp x29, x30, [sp], #64
    ret

// _rail_print_float — Linux variant. fmov-style branch is impossible
// from x0 because Mac _rail_print_float is called with d0 already set;
// the codegen for show_float / print_float dispatches via fmov d0, x0
// at the call site. Same convention here.
_rail_print_float:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    str d0, [x29, #16]
    mov x0, #32
    bl _malloc
    str x0, [x29, #24]
    ldr d0, [x29, #16]
    str d0, [sp, #-16]!
    ldr x0, [x29, #24]
    mov x1, #32
    adrp x2, _fmt_gbare
    add x2, x2, :lo12:_fmt_gbare
    bl _snprintf
    add sp, sp, #16
    ldr x0, [x29, #24]
    bl _strlen
    mov x2, x0
    mov x0, #1
    ldr x1, [x29, #24]
    mov x8, #64
    svc #0
    mov w0, #10
    strb w0, [x29, #32]
    mov x0, #1
    add x1, x29, #32
    mov x2, #1
    mov x8, #64
    svc #0
    ldr x0, [x29, #24]
    bl _free
    mov x0, #1
    ldp x29, x30, [sp], #48
    ret

// _rail_shell — Linux variant. Mac uses Darwin syscalls 42 (pipe),
// 2 (fork), 90 (dup2), 6 (close), 59 (execve), 1 (exit), 3 (read),
// 7 (waitpid). Linux equivalents: 59 (pipe2), 220 (clone), 24 (dup3),
// 57 (close), 221 (execve), 93 (exit), 63 (read), 260 (wait4).
//
// We use clone with SIGCHLD flag for fork-equivalence, dup3 with
// flags=0 for dup2-equivalence, pipe2 with flags=0 for pipe-equivalence.
// Linux ABI for clone: x0=flags, x1=child_stack (NULL=share parent's
// via copy-on-write). We pass SIGCHLD (0x11) so wait4 works.
_rail_shell:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    bl _str_unwrap
    str x0, [x29, #16]               // saved cmd string
    // pipe2(fds, 0)
    add x0, x29, #24
    mov x1, #0
    mov x8, #59                       // pipe2
    svc #0
    // ldr fds: x29#24 = read fd (32 bits), x29#28 = write fd
    // clone(SIGCHLD, NULL, ...)
    mov x0, #0x11                     // SIGCHLD
    mov x1, #0
    mov x2, #0
    mov x3, #0
    mov x4, #0
    mov x8, #220                      // clone
    svc #0
    cbz x0, .Lsh_l_child
    // parent: store pid
    str x0, [x29, #32]
    ldr w0, [x29, #28]                // close write end
    mov x8, #57                       // close
    svc #0
    // malloc 64K read buffer
    mov x0, #65536
    bl _malloc
    str x0, [x29, #40]
    str xzr, [x29, #48]
.Lsh_l_read:
    ldr w0, [x29, #24]
    ldr x1, [x29, #40]
    ldr x2, [x29, #48]
    add x1, x1, x2
    mov x2, #4096
    mov x8, #63                       // read
    svc #0
    cmp x0, #0
    b.le .Lsh_l_done
    ldr x1, [x29, #48]
    add x1, x1, x0
    str x1, [x29, #48]
    b .Lsh_l_read
.Lsh_l_done:
    ldr w0, [x29, #24]
    mov x8, #57                       // close
    svc #0
    // wait4(-1, &status, 0, NULL)
    mov x0, #-1
    add x1, x29, #56
    mov x2, #0
    mov x3, #0
    mov x8, #260                      // wait4
    svc #0
    // null-terminate buf
    ldr x0, [x29, #40]
    ldr x1, [x29, #48]
    mov w2, #0
    strb w2, [x0, x1]
    ldr x0, [x29, #40]
    bl _rail_wrap_str
    str x0, [x29, #56]
    ldr x0, [x29, #40]
    bl _free
    ldr x0, [x29, #56]
    ldp x29, x30, [sp], #96
    ret
.Lsh_l_child:
    // child: dup3(write_fd, 1, 0)
    ldr w0, [x29, #28]
    mov x1, #1
    mov x2, #0
    mov x8, #24                       // dup3
    svc #0
    ldr w0, [x29, #24]
    mov x8, #57
    svc #0
    ldr w0, [x29, #28]
    mov x8, #57
    svc #0
    // execve("/bin/sh", argv, envp)
    adr x0, .Lsh_l_binsh
    str x0, [x29, #48]
    adr x0, .Lsh_l_cflag
    str x0, [x29, #56]
    ldr x0, [x29, #16]
    str x0, [x29, #64]
    str xzr, [x29, #72]
    adr x0, .Lsh_l_binsh
    add x1, x29, #48
    adrp x2, _rail_envp
    ldr x2, [x2, :lo12:_rail_envp]
    mov x8, #221                      // execve
    svc #0
    // exec failed; exit
    mov x0, #1
    mov x8, #93
    svc #0
.Lsh_l_binsh:
    .asciz "/bin/sh"
    .p2align 2
.Lsh_l_cflag:
    .asciz "-c"
    .p2align 2

// _rail_malloc_chain_drain — Linux variant.
// Walk the malloc chain back to _rail_chain_mark, releasing chunks.
// The Mac stub uses Darwin syscall #0x80 + class-0x02000000 munmap (73)
// in x16. On Linux, svc #0x80 with x8 holding stale data triggers
// arbitrary syscalls — the SEGV in pi_sign_server's serve_loop on the
// 2nd request was traced to that.
_rail_malloc_chain_drain:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    str x19, [x29, #16]
    str x20, [x29, #24]
    adrp x19, _rail_malloc_chain
    add x19, x19, :lo12:_rail_malloc_chain
    adrp x20, _rail_chain_mark
    add x20, x20, :lo12:_rail_chain_mark
.Lmdrn_l_loop:
    ldr x0, [x19]
    ldr x1, [x20]
    cmp x0, x1
    b.eq .Lmdrn_l_done
    cbz x0, .Lmdrn_l_done
    ldr x2, [x0]
    str x2, [x19]
    ldr x3, [x0, #8]
    cmp x3, #0x10000             // 65536
    b.ls .Lmdrn_l_small
    // large chunk: munmap. Linux munmap = syscall 215, x0=addr,
    // x1=length. The Mac version was svc #0x80 with x16=73|0x02000000.
    str x0, [x29, #32]
    str x3, [x29, #40]
    mov x1, x3
    mov x8, #215
    svc #0
    adrp x4, _rail_munmap_count
    add x4, x4, :lo12:_rail_munmap_count
    ldr x5, [x4]
    add x5, x5, #1
    str x5, [x4]
    b .Lmdrn_l_loop
.Lmdrn_l_small:
    sub x4, x3, #1
    clz x4, x4
    mov x5, #64
    sub x4, x5, x4
    sub x4, x4, #5
    adrp x5, _rail_small_fl
    add x5, x5, :lo12:_rail_small_fl
    add x5, x5, x4, lsl #3
    ldr x6, [x5]
    str x6, [x0]
    str x0, [x5]
    b .Lmdrn_l_loop
.Lmdrn_l_done:
    ldr x20, [x29, #24]
    ldr x19, [x29, #16]
    ldp x29, x30, [sp], #64
    ret

// _getenv(name) -> char* | 0 — Linux stub. The full impl would walk
// _rail_envp comparing each entry against name+'='. We're only called
// from _rail_arena_init (RAIL_ARENA_MB / RAIL_ARENA_TRACE), and
// _rail_envp is populated by _main's prologue which hasn't run yet
// at arena-init time. Returning 0 (env-var-not-found) is correct: the
// caller falls through to defaults (1 GB arena, no trace).
_getenv:
    mov x0, #0
    ret

// read(fd, buf, count) — syscall 63
_read:
    mov x8, #63               // read
    svc #0
    ret

// write(fd, buf, count) — syscall 64
_write:
    mov x8, #64               // write
    svc #0
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
    // d0 still holds the float value (callers do `str d0, [sp, #-16]!`
    // before bl _snprintf, but that's a Mac-vararg quirk; AAPCS64
    // keeps it in d0 and we never clobber it before this point).
    ldr x4, [x29, #16]   // buf
    mov x7, #0            // write idx
    // sign
    fmov x1, d0
    tst x1, #0x8000000000000000
    b.eq .Lsnpf_f_pos
    fneg d0, d0
    mov w1, #45           // '-'
    strb w1, [x4, x7]
    add x7, x7, #1
.Lsnpf_f_pos:
    // zero
    fcmp d0, #0.0
    b.ne .Lsnpf_f_nonzero
    mov w1, #48           // '0'
    strb w1, [x4, x7]
    add x7, x7, #1
    b .Lsnpf_f_emit_done
.Lsnpf_f_nonzero:
    // d0 *= 1e6 (shift 6 decimal places into the integer part).
    adrp x0, _1e6_f64
    ldr d1, [x0, :lo12:_1e6_f64]
    fmul d0, d0, d1
    frinta d0, d0
    fcvtzs x0, d0
    // Push x0's decimal digits (LSD first) onto the stack in 16-byte
    // slots, count digits in x2.
    mov x2, #0
    mov x3, #10
    cbnz x0, .Lsnpf_f_div
    // After multiply+round, x0 is 0 — the original was so small it
    // collapsed. Emit "0" and exit.
    mov w1, #48
    strb w1, [x4, x7]
    add x7, x7, #1
    b .Lsnpf_f_emit_done
.Lsnpf_f_div:
    udiv x5, x0, x3
    msub x6, x5, x3, x0
    add x6, x6, #48
    str x6, [sp, #-16]!
    add x2, x2, #1
    mov x0, x5
    cbnz x0, .Lsnpf_f_div
    // Pad with leading zeros so total digit count is at least 7
    // (leaves room for the implicit "0." prefix on values < 1).
.Lsnpf_f_pad:
    cmp x2, #7
    b.ge .Lsnpf_f_pad_done
    mov x6, #48
    str x6, [sp, #-16]!
    add x2, x2, #1
    b .Lsnpf_f_pad
.Lsnpf_f_pad_done:
    // x2 = total digit count. Decimal point goes at column (x2-6) from
    // the left (so the last 6 digits become the fractional part).
    sub x3, x2, #6
    mov x9, #0
.Lsnpf_f_emit:
    cmp x9, x3
    b.ne .Lsnpf_f_emit_no_dot
    cbz x9, .Lsnpf_f_emit_no_dot
    mov w1, #46           // '.'
    strb w1, [x4, x7]
    add x7, x7, #1
.Lsnpf_f_emit_no_dot:
    ldr x6, [sp], #16
    strb w6, [x4, x7]
    add x7, x7, #1
    add x9, x9, #1
    cmp x9, x2
    b.lt .Lsnpf_f_emit
    // Trim trailing zeros after the decimal. Walk back from x7-1 while
    // we see '0'. If we end on '.', drop it too.
    sub x9, x7, #1
.Lsnpf_f_trim:
    ldrb w6, [x4, x9]
    cmp w6, #48
    b.ne .Lsnpf_f_trim_done
    sub x9, x9, #1
    sub x7, x7, #1
    b .Lsnpf_f_trim
.Lsnpf_f_trim_done:
    cmp w6, #46
    b.ne .Lsnpf_f_emit_done
    sub x7, x7, #1
.Lsnpf_f_emit_done:
    // NUL-terminate
    mov w1, #0
    strb w1, [x4, x7]
    mov x0, x7
    b .Lsnpf_done

.Lsnpf_done:
    ldp x29, x30, [sp], #48
    ret

// 1e6 as IEEE-754 double: 0x412E848000000000.
.section .rodata
.p2align 3
_1e6_f64:
    .quad 0x412E848000000000
.text

// ---- File I/O via syscalls ----

_fopen:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    ldrb w2, [x1]
    cmp w2, #119          // 'w'
    b.eq .Lfop_w
    cmp w2, #97           // 'a'
    b.eq .Lfop_a
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
    b .Lfop_done
.Lfop_a:
    mov x1, x0
    mov x0, #-100
    mov x2, #0x441        // O_WRONLY|O_CREAT|O_APPEND
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


// _atof(const char *s) -> double
// Parses [sign]? [digits]? [.digits]? ([eE][sign]?digits]+)? per the
// usual rules. Was a stub returning 0.0; replaced 2026-05-02 because
// the cross-compile path emits float literals as `_atof("X.YY")` and
// every literal was reading as 0. Standard scan-and-build approach;
// no IEEE rounding subtleties addressed (just plain accumulate-then-
// scale) which is fine for the magnitudes we use.
_atof:
    mov x1, x0                  // s pointer
    fmov d0, xzr                // accumulator
    fmov d1, xzr                // sign as f64; 0.0=positive
    mov x2, #1                  // sign multiplier (int): 1 or -1
    // skip whitespace (space, tab)
.Latof_ws:
    ldrb w3, [x1]
    cmp w3, #32
    b.eq .Latof_ws_inc
    cmp w3, #9
    b.ne .Latof_sign
.Latof_ws_inc:
    add x1, x1, #1
    b .Latof_ws
.Latof_sign:
    cmp w3, #45                  // '-'
    b.ne .Latof_plus
    mov x2, #-1
    add x1, x1, #1
    b .Latof_int
.Latof_plus:
    cmp w3, #43                  // '+'
    b.ne .Latof_int
    add x1, x1, #1
.Latof_int:
    // d0 = integer part (as f64)
    fmov d2, #10.0
.Latof_int_loop:
    ldrb w3, [x1]
    cmp w3, #48
    b.lt .Latof_after_int
    cmp w3, #57
    b.gt .Latof_after_int
    sub w3, w3, #48
    scvtf d3, x3                 // d3 = digit
    fmul d0, d0, d2              // d0 *= 10
    fadd d0, d0, d3              // d0 += digit
    add x1, x1, #1
    b .Latof_int_loop
.Latof_after_int:
    // optional fractional part
    cmp w3, #46                  // '.'
    b.ne .Latof_after_frac
    add x1, x1, #1
    fmov d4, #1.0                // place value
.Latof_frac_loop:
    ldrb w3, [x1]
    cmp w3, #48
    b.lt .Latof_after_frac
    cmp w3, #57
    b.gt .Latof_after_frac
    sub w3, w3, #48
    scvtf d3, x3
    fdiv d4, d4, d2              // place /= 10
    fmul d3, d3, d4              // d3 = digit * place
    fadd d0, d0, d3
    add x1, x1, #1
    b .Latof_frac_loop
.Latof_after_frac:
    // optional exponent: [eE][+-]?digits
    cmp w3, #69                  // 'E'
    b.eq .Latof_exp
    cmp w3, #101                 // 'e'
    b.ne .Latof_done
.Latof_exp:
    add x1, x1, #1
    mov x4, #1                   // exp sign
    mov x5, #0                   // exp value
    ldrb w3, [x1]
    cmp w3, #45
    b.ne .Latof_exp_plus
    mov x4, #-1
    add x1, x1, #1
    b .Latof_exp_loop
.Latof_exp_plus:
    cmp w3, #43
    b.ne .Latof_exp_loop
    add x1, x1, #1
.Latof_exp_loop:
    ldrb w3, [x1]
    cmp w3, #48
    b.lt .Latof_exp_apply
    cmp w3, #57
    b.gt .Latof_exp_apply
    sub w3, w3, #48
    mov x6, #10
    mul x5, x5, x6
    add x5, x5, x3
    add x1, x1, #1
    b .Latof_exp_loop
.Latof_exp_apply:
    // multiply d0 by 10^(x5*x4) via repeated mul/div
    cmp x5, #0
    b.eq .Latof_done
    cmp x4, #0
    b.ge .Latof_exp_pos
    // negative exp: divide
.Latof_exp_neg_loop:
    fdiv d0, d0, d2
    sub x5, x5, #1
    cbnz x5, .Latof_exp_neg_loop
    b .Latof_done
.Latof_exp_pos:
.Latof_exp_pos_loop:
    fmul d0, d0, d2
    sub x5, x5, #1
    cbnz x5, .Latof_exp_pos_loop
.Latof_done:
    cmp x2, #0
    b.ge .Latof_ret
    fneg d0, d0
.Latof_ret:
    ret

// ============ Networking syscalls (added for dns-sink, 2026-04-07) ============
//
// All Linux ARM64 syscalls follow the convention:
//   syscall nr in x8, args in x0..x5, svc #0, return in x0.
// The Rail FFI ABI already places call args in x0..x5 (System V on Linux),
// so each wrapper just sets x8 and traps. Return value flows back in x0
// where Rail's FFI codegen will retag it as a tagged int.
//
// Syscall numbers from /usr/include/asm-generic/unistd.h:
//   close=57  socket=198  bind=200  listen=201  accept4=242  connect=203
//   sendto=206  recvfrom=207  setsockopt=208  clock_gettime=113

_close:
    mov x8, #57
    svc #0
    ret

_socket:
    mov x8, #198
    svc #0
    ret

_bind:
    mov x8, #200
    svc #0
    ret

_listen:
    mov x8, #201
    svc #0
    ret

_connect:
    mov x8, #203
    svc #0
    ret

_accept4:
    mov x8, #242
    svc #0
    ret

_sendto:
    mov x8, #206
    svc #0
    ret

_recvfrom:
    mov x8, #207
    svc #0
    ret

_setsockopt:
    mov x8, #208
    svc #0
    ret

// ============ Byte-order helpers (not syscalls) ============

// htons(x): swap the low 16 bits of x.
// rev16 reverses bytes within each 16-bit halfword of the source.
_htons:
    and x0, x0, #0xFFFF
    rev16 w0, w0
    and x0, x0, #0xFFFF
    ret

// htonl(x): swap the bytes of the low 32 bits of x.
_htonl:
    and x0, x0, #0xFFFFFFFF
    rev w0, w0
    and x0, x0, #0xFFFFFFFF
    ret

// ============ time wrapper ============
//
// Linux ARM64 has no time() syscall — use clock_gettime(CLOCK_REALTIME, &ts)
// and return ts.tv_sec. Caller's t arg (x0) is ignored (we never write
// it back; Rail callers always pass NULL).
_time:
    sub sp, sp, #16          // 16-byte aligned timespec on stack
    mov x0, #0               // CLOCK_REALTIME
    mov x1, sp               // &timespec
    mov x8, #113             // clock_gettime
    svc #0
    ldr x0, [sp]             // tv_sec
    add sp, sp, #16
    ret

// ============ sleep (proper kernel sleep, no fork) ============
//
// sleep(seconds) — blocks for N seconds via nanosleep(2).
// Used by dns-sink LCD instead of shell "sleep N" which forks.
_sleep:
    sub sp, sp, #16
    str x0, [sp]              // req.tv_sec = seconds
    str xzr, [sp, #8]        // req.tv_nsec = 0
    mov x0, sp               // req
    mov x1, #0               // rem = NULL
    mov x8, #101             // nanosleep
    svc #0
    add sp, sp, #16
    mov x0, #0               // return 0
    ret

// ============ clock_ms (monotonic millisecond clock) ============
//
// clock_ms() — returns current time in milliseconds (CLOCK_MONOTONIC).
// Used by dns-sink to measure upstream query latency.
_clock_ms:
    sub sp, sp, #16
    mov x0, #1               // CLOCK_MONOTONIC
    mov x1, sp               // &timespec
    mov x8, #113             // clock_gettime
    svc #0
    ldr x0, [sp]             // tv_sec
    ldr x1, [sp, #8]         // tv_nsec
    add sp, sp, #16
    mov x2, #1000
    mul x0, x0, x2           // sec * 1000
    udiv x1, x1, x2          // nsec / 1000 = usec
    udiv x1, x1, x2          // usec / 1000 = ms remainder
    add x0, x0, x1           // total ms
    ret

// ============ Stubs for symbols dns-sink doesnt use ============
//
// Rails runtime emits these unconditionally (spawn_thread, try-handle).
// dns-sink never calls them. We provide stubs so the link succeeds.
// If anyone actually invokes them at runtime, the program will misbehave.

_pthread_create:
    mov x0, #-1
    ret

_pthread_join:
    mov x0, #-1
    ret

_pthread_mutex_init:
    mov x0, #-1
    ret

_setjmp:
    mov x0, #0
    ret

_longjmp:
    // We should never get here. If we do, exit cleanly so we dont
    // continue executing with corrupted control flow.
    mov x0, #1
    mov x8, #93
    svc #0
    ret

// ============ Bump-allocated _malloc replacement ============
//
// Patched 2026-04-08: the original _malloc was a thin mmap wrapper —
// every call did its own syscall, getting a fresh 4 KB page minimum.
// _rail_split allocates one buffer per substring. For an oisd 56 k-domain
// blocklist that meant 56 k * 4 KB = 224 MB physical, OOM-killing the Pi.
//
// The Rail-compiled binary already has a 512 MB virtual bump arena
// (_rail_heap + _rail_heap_ptr) used by _rail_alloc for cons cells / tuples
// / closures. We share that same arena for _malloc.
//
// _malloc — separate-pool bump allocator for Linux.
//
// Earlier impl piggybacked on _rail_heap_ptr (the same bump pointer
// _rail_alloc uses), so arena_reset would roll the pointer back through
// chunks that _rail_chained_malloc had pushed onto its small free-list
// (_rail_small_fl). Iter 2's recv buffer would then overwrite those
// chunks; the next chained_malloc small-bin pop read garbage out of
// chunk[0] and either crashed at `ldr x7, [x6]` (when the garbage
// looked like a small/junk pointer like 0x1) or kept walking corrupt
// state until it tripped a NULL deref.
//
// Mac's _malloc uses _rail_malloc_ptr / _rail_malloc_end — a separate
// 4 MB-chunked pool that arena_reset never touches. Match that.
// _rail_malloc_ptr / _rail_malloc_end are declared in compile.rail's
// data section, both initialized to 0 (lazy-init on first call).
_malloc:
    // x0 = requested size in bytes.
    add x9, x0, #15
    and x9, x9, #-16
    cmp x9, #0x10000              // 65536
    b.hi .Lmalloc_large_l
    str x9, [sp, #-16]!
    // Load _rail_malloc_ptr; if NULL, fall through to newpage.
    adrp x10, _rail_malloc_ptr
    add x10, x10, :lo12:_rail_malloc_ptr
    ldr x11, [x10]
    cbz x11, .Lmalloc_newpage_l
    add x12, x11, x9
    adrp x13, _rail_malloc_end
    add x13, x13, :lo12:_rail_malloc_end
    ldr x13, [x13]
    cmp x12, x13
    b.hi .Lmalloc_newpage_l
    str x12, [x10]
    add sp, sp, #16
    mov x0, x11
    ret
.Lmalloc_newpage_l:
    // mmap 4 MB, set _rail_malloc_ptr = base + size, end = base + 4 MB.
    mov x0, #0
    mov x1, #0x400000
    mov x2, #3
    mov x3, #0x22                 // MAP_PRIVATE|MAP_ANONYMOUS (Linux)
    mov x4, #-1
    mov x5, #0
    mov x8, #222                  // mmap
    svc #0
    cmn x0, #4095
    b.hs .Lmalloc_fail_l
    ldr x9, [sp], #16
    adrp x10, _rail_malloc_ptr
    add x10, x10, :lo12:_rail_malloc_ptr
    add x11, x0, x9
    str x11, [x10]
    adrp x10, _rail_malloc_end
    add x10, x10, :lo12:_rail_malloc_end
    add x11, x0, #0x400000
    str x11, [x10]
    ret
.Lmalloc_large_l:
    // size > 64K: direct mmap. The chained-malloc chain walker (Lmdrn_l)
    // will munmap this chunk on arena_reset.
    mov x1, x9
    mov x0, #0
    mov x2, #3
    mov x3, #0x22
    mov x4, #-1
    mov x5, #0
    mov x8, #222
    svc #0
    cmn x0, #4095
    b.hs .Lmalloc_fail_l
    ret
.Lmalloc_fail_l:
    mov x0, #0
    ret

// ============ fputs (used by dns/log.rail) ============
//
// int fputs(const char *s, FILE *fp)
// Writes the C string to fp via fwrite. Returns whatever fwrite returns.
_fputs:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x0, [x29, #16]   // save s
    str x1, [x29, #24]   // save fp
    bl _strlen            // x0 = strlen(s)
    mov x2, x0            // count = strlen(s)
    ldr x0, [x29, #16]    // ptr = s
    mov x1, #1            // size = 1
    ldr x3, [x29, #24]    // FILE* = fp
    bl _fwrite
    ldp x29, x30, [sp], #32
    ret

// ============ Cross-compile additions (2026-04-17) ============

// accept(fd, addr, addrlen) — wrap accept4 with flags=0
// Linux ARM64 dropped legacy accept (202); use accept4 (242) with 0 flags.
_accept:
    mov x3, #0           // flags = 0
    mov x8, #242         // accept4
    svc #0
    ret

// send(fd, buf, len, flags) — wrap sendto with NULL dest
_send:
    mov x4, #0           // dest_addr = NULL
    mov x5, #0           // addrlen = 0
    mov x8, #206         // sendto
    svc #0
    ret

// recv(fd, buf, len, flags) — wrap recvfrom with NULL src
_recv:
    mov x4, #0           // src_addr = NULL
    mov x5, #0           // addrlen = NULL
    mov x8, #207         // recvfrom
    svc #0
    ret

// strtol(nptr, endptr, base) — Rail's parse_int primitive emits `bl _strtol`.
// We support base 10 (matching the compiler's `mov x2, #10`). endptr ignored.
// Skips leading whitespace, optional +/- sign, then digits.
_strtol:
    mov x9, x0           // x9 = ptr
    mov x10, #0          // result
    mov x11, #1          // sign
.Lstrtol_skipws:
    ldrb w12, [x9]
    cmp w12, #32         // ' '
    b.eq .Lstrtol_advws
    cmp w12, #9          // '\t'
    b.ne .Lstrtol_sign
.Lstrtol_advws:
    add x9, x9, #1
    b .Lstrtol_skipws
.Lstrtol_sign:
    cmp w12, #45         // '-'
    b.ne .Lstrtol_plus
    mov x11, #-1
    add x9, x9, #1
    b .Lstrtol_loop
.Lstrtol_plus:
    cmp w12, #43         // '+'
    b.ne .Lstrtol_loop
    add x9, x9, #1
.Lstrtol_loop:
    ldrb w12, [x9]
    cmp w12, #48         // '0'
    b.lt .Lstrtol_done
    cmp w12, #57         // '9'
    b.gt .Lstrtol_done
    sub w12, w12, #48
    mov x13, #10
    mul x10, x10, x13
    add x10, x10, x12
    add x9, x9, #1
    b .Lstrtol_loop
.Lstrtol_done:
    mul x0, x10, x11
    ret

// BSS reservations for young-generation semispace GC.
// Mac codegen declares these via .zerofill which the transform sed strips.
// .comm provides equivalent BSS allocation in ELF.
.comm _rail_young_a, 67108864, 8
.comm _rail_young_b, 67108864, 8
