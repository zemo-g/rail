# Pi `.s` truncation diagnosis — 2026-05-15 evening

Session pickup: `rail-pi-self-host-2026-05-02.md` (12 days old).
Today's relevant commit: `b5c45f6` — unblocked Pi cross-compile for
hello/fact/fold but compile.rail self-compile on Pi still emits `.s`
short by ~150 lines vs Mac emit. **Pi was unreachable this session**
(test run swap-thrashed userspace; physical reboot required). This doc
ranks hypotheses + lists the exact probes to run when Pi is back.

## Ground truth from corpus

- Mac `/tmp/rail_self.s`: **123,084 lines**, 2,555,305 bytes (2.5 MB).
  Last line: `_gc_desc_table_end:`.
- Final concat in `compile_checked` (compile.rail:3637):
  `cat [hdr, funcs, rt, data_section_asm, gc_desc_block]`
- Section layout in the Mac emit:
  - L1–3 = hdr
  - L4–120498 = funcs (≈335 functions) + rt
  - L120499 = `.section __DATA,__data` (`data_section_asm` literal)
  - L120574–120576 = `.section __DATA,__data` + `_gc_desc_table_start:`
    (`gc_desc_block` prefix)
  - L120577–123084 = gc-descriptor table (≈501 entries × 5 lines)
  - L123084 = `_gc_desc_table_end:`
- "~150 lines short" = ≈30 trailing gc-desc entries dropped from the
  end. Geometry strongly suggests truncation is at the *very tail* of
  the emit (`gc_desc_block` or final cat), **not** in `funcs` / `rt` /
  `data_section_asm`.

## Concat / write pipeline (where it can fail)

```
compile_funcs decls →
  loop: cons fasm onto asm_acc, cons fdesc onto desc_acc
  end: funcs = join "" (reverse asm_acc)
       gc_descs = join "" (reverse desc_acc)
final: gc_desc_block = cat ["\n.section ... _gc_desc_table_start:\n", gc_descs,
                            ".global _gc_desc_table_end\n_gc_desc_table_end:\n"]
       full = cat [hdr, funcs, rt, data_section_asm, gc_desc_block]
       write_file "/tmp/rail_macos.s" full
```

`cat = join "". join` ARM64 impl (`_rail_join`, compile.rail:2685):
two-pass, pass 1 sums strlens + counts, pass 2 allocates via
`_rail_chained_malloc` then memcpy each chunk. Chained-malloc has its
own Linux pool (separate from arena, fixed by master `5334d46`) — so
big string buffers do **not** sit in the bump arena.

`write_file` (compile.rail:2696, runtime stub) →
`_fopen` (openat) → `_strlen(content)` → `_fwrite(ptr, 1, len, fd)` →
`_fclose`. Linux `_fwrite` (linux_libc.s:809) is a SINGLE
`write(fd, ptr, len)` syscall. **No retry on short writes. No
fflush/fsync.**

## Hypotheses, ranked

### H1 — Single `write()` syscall returns short. ⭐ likely
`_fwrite` issues `write(fd, buf, 2_500_000)` and returns whatever the
kernel returns. POSIX permits short writes on regular files; Linux
under memory pressure (Pi has 416 MB RAM, 767 MB swap, baseline ~250
MB used by the test session) can write less than requested. No retry
loop = silent tail truncation. The 150-line shortfall is consistent
with a single short return.

**Probe (Pi):** `strace -e trace=write -o /tmp/wr.trace ~/rail_native_v4 tools/compile.rail`,
then grep the trace for the big write — `write(N, …, 2500000) = K`
where K < 2500000 confirms.

**Fix sketch:** loop in `_fwrite` until `written == total` or `<0`:
```
_fwrite:
    mul x2, x1, x2     # total = size*nmemb
    mov x1, x0         # buf
    mov x0, x3         # fd
.Lfw_loop:
    mov x8, #64        # write
    svc #0
    cmp x0, #0
    b.lt .Lfw_done     # error: return as-is
    add x1, x1, x0     # buf += written
    subs x2, x2, x0    # remaining -= written
    b.ne .Lfw_loop
.Lfw_done:
    ret
```
Single-spot fix in `linux_libc.s` + cycle the binary.

### H2 — Conservative GC reclaims tail of `desc_acc` / `asm_acc`. plausible
`compile_funcs_loop` is tail-recursive; per-iteration it conses two
new cells. Conservative GC walks the stack; if a register holding the
list head is scrubbed between iterations and GC fires under physical-
RAM pressure on Pi, the unreachable cells (which still chain to the
"live" front of the list) get swept. Subsequent `reverse → join` sees
a truncated list.

The geometry fits exactly: the *most recently consed* entries are at
the *head* of the un-reversed acc, and would be the *last* entries
after reverse — i.e. the tail of the final .s. Losing ~30 entries
from a 500-entry list is consistent with GC clearing ~one young-gen
worth and missing a root.

**Probe (Pi):**
1. Add `let _ = print (cat ["asm_acc len: ", show (length asm_acc)])`
   right before the join in `compile_funcs_loop` base case (Mac:
   should equal function count; Pi: short by ≈30).
2. Run with `RAIL_ARENA_TRACE=1` to see if GC fired during
   compile_funcs.

**Fix sketch:** the structural fix is improving root scanning, but a
local mitigation for compile.rail is to wrap the loop body in
`arena_mark` / `arena_reset` … no, that would FREE the strings being
accumulated. The right local mitigation is `RAIL_ARENA_MB=128` env to
keep bump-arena GC from firing at all on Pi (and use a smaller
default arena cap so GC stays off the hot path). Or `_rail_str_*`
already escapes to chained_malloc pool — extend that to list cells of
asm_acc/desc_acc.

### H3 — `_rail_chained_malloc` falls through to `_malloc` which
mmaps and partially-faults. unlikely
On large allocs (>64KB), `_malloc` does direct mmap of `total+1`
bytes. mmap returns a virtual range with pages faulted in lazily on
write. If a write fault gets ENOMEM mid-loop, the kernel sends SIGBUS
to the process — wouldn't truncate; would crash. Rejected.

### H4 — OOM killer reaps rail_native between write() and close().
unlikely
Even if killed mid-`_fwrite`, the file would simply be partial up to
whatever was written by then. But `_fwrite` is a single `write()` and
`_fclose` is a single `close()`. The kernel completes the write
before returning to userspace, so OOM-kill between syscalls doesn't
truncate the write. Rejected.

## Plan for Pi recovery

Wait for Pi power-cycle. Then:

1. **Get a real Pi `.s`.** On Pi:
   ```bash
   cd ~ && ./rail_native_v4 compile.rail   # produces /tmp/rail_out (won't run)
   # but writes /tmp/rail_macos.s as a side effect inside build_linux
   wc -l /tmp/rail_macos.s
   tail -50 /tmp/rail_macos.s
   ```
   Then `scp` to Mac and `diff /tmp/rail_self.s /tmp/rail_pi_macos.s | tail -200`.
   The diff localizes the truncation point exactly.

2. **Run strace to test H1:**
   ```bash
   strace -e trace=write -o /tmp/wr.trace ~/rail_native_v4 tools/compile.rail
   grep "write(.*,.*[0-9]\\{6,\\})" /tmp/wr.trace | head
   ```
   Look for `write(N, …, 2500000) = <smaller>`.

3. **If H1 confirmed:** patch `_fwrite` in `linux_libc.s` with the
   retry loop (15 LOC), rsync to Pi (`~/tools/linux_libc.s`),
   recompile rail_native on Pi (or cross-compile from Mac), retest.

4. **If H1 disproven:** instrument compile_funcs_loop with the
   length-printing probe per H2.

## Out-of-scope (parked)

- Pi network recovery: Tailscale shows `tx 624 rx 0` from Studio → Pi.
  Pi cabled at LAN `192.168.40.223`, TCP `:22` + `:9101` listening but
  userspace frozen. Needs physical power cycle. User confirmed cable
  in place; reboot not currently possible.
- Crypto test count: stdlib was rsynced (94/94) before Pi froze; the
  expected post-rsync test count climb (was 98/137 in
  rail-pi-self-host-2026-05-02.md) is not yet measured.

## When you resume

This file + `rail-pi-self-host-2026-05-02.md` (memory) + `b5c45f6`
commit message are the brief. Probe 1 (Pi `.s` diff) is the single
fastest move — it eliminates 3 of the 4 hypotheses in one shot.
