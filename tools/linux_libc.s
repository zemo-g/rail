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


_atof:
    fmov d0, xzr
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
// We deliberately do NOT write a size header (unlike _rail_alloc), because
// _malloc callers expect raw bytes starting at the returned pointer.
// Side effect: if the GC ever runs a sweep, it cant walk past these
// header-less buffers. dns-sink stays well under 512 MB so GC never runs;
// for any program that does, this fast _malloc would be unsafe.
//
// Overflow falls back to the original mmap path so we still work when the
// bump arena is exhausted.
_malloc:
    // x0 = requested size, in bytes.
    // Align up to 8 (matching _rail_allocs alignment so the shared
    // bump pointer stays 8-aligned for both allocators). Stash in x9
    // and keep x0 intact for the mmap fallback path below.
    add x9, x0, #7
    and x9, x9, #-8
    // Load current bump pointer.
    adrp x10, _rail_heap_ptr
    add x10, x10, :lo12:_rail_heap_ptr
    ldr x11, [x10]
    add x12, x11, x9            // new bump pointer
    // Boundary check against _rail_heap_end.
    adrp x13, _rail_heap_end
    add x13, x13, :lo12:_rail_heap_end
    ldr x13, [x13]
    cmp x12, x13
    b.hi .Lmalloc_mmap_fallback
    // Fast path: commit and return.
    str x12, [x10]
    mov x0, x11
    ret
.Lmalloc_mmap_fallback:
    // Slow path: original mmap-per-call. x0 still has original requested size.
    mov x1, x0
    mov x0, #0
    mov x2, #3                  // PROT_READ|PROT_WRITE
    mov x3, #0x22               // MAP_PRIVATE|MAP_ANONYMOUS
    mov x4, #-1
    mov x5, #0
    mov x8, #222                // mmap
    svc #0
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
