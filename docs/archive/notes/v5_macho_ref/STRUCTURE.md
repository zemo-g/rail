# Canonical exit-42 Mach-O — structure map

Reference for v5 Phase 1 emitter. Produced by `as -arch arm64` + `ld
-lSystem -e _main` from `exit42.s` (4 instructions: mov x16,#1;
mov x0,#42; svc 0x80; ret). Binary: `exit42.canonical` (16,840 bytes).

## Header (32 bytes, offset 0x0)

| Field | Value | Bytes (LE) |
|---|---|---|
| magic | 0xFEEDFACF | `cf fa ed fe` |
| cputype | 0x0100000C (ARM64) | `0c 00 00 01` |
| cpusubtype | 0 | `00 00 00 00` |
| filetype | 2 (MH_EXECUTE) | `02 00 00 00` |
| ncmds | 16 | `10 00 00 00` |
| sizeofcmds | 664 (0x298) | `98 02 00 00` |
| flags | 0x00200085 | `85 00 20 00` |
| reserved | 0 | `00 00 00 00` |

flags 0x85 = MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL
flags 0x200000 = MH_PIE

## Load Commands (664 bytes total, offsets 0x20..0x2B7)

1. LC_SEGMENT_64 __PAGEZERO    72 B  vmaddr=0, vmsize=4GB, filesize=0
2. LC_SEGMENT_64 __TEXT       152 B  vmaddr=0x100000000, vmsize=16K, 1 section (__text @ 728)
3. LC_SEGMENT_64 __LINKEDIT    72 B  vmaddr=0x100004000, vmsize=16K, filesize=456
4. LC_DYLD_CHAINED_FIXUPS      16 B  (dynamic linker fixups — can skip in MVP)
5. LC_DYLD_EXPORTS_TRIE        16 B  (export table — can skip in MVP)
6. LC_SYMTAB                   24 B  nsyms=2, strsize=32
7. LC_DYSYMTAB                 80 B  iextdefsym=0, nextdefsym=2
8. LC_LOAD_DYLINKER            32 B  name=/usr/lib/dyld
9. LC_UUID                     24 B  16-byte UUID
10. LC_BUILD_VERSION           32 B  platform=1 (macOS), minos, sdk
11. LC_SOURCE_VERSION          16 B
12. LC_MAIN                    24 B  entryoff=728, stacksize=0
13. LC_LOAD_DYLIB              56 B  /usr/lib/libSystem.B.dylib (DROP in v5: no libc)
14. LC_FUNCTION_STARTS         16 B  dataoff=16488, datasize=8
15. LC_DATA_IN_CODE            16 B  dataoff=16496, datasize=0
16. LC_CODE_SIGNATURE          16 B  dataoff=16560, datasize=280

## Code (16 bytes, offset 0x2D8 = 728)

```
30 00 80 d2    mov x16, #1
40 05 80 d2    mov x0,  #42
01 10 00 d4    svc #0x80
c0 03 5f d6    ret
```

Verified: enc_movz 16 1 0 = 0xD2800030 → LE bytes `30 00 80 d2` ✓
Verified: enc_movz 0 42 0  = 0xD2800540 → LE bytes `40 05 80 d2` ✓
Verified: enc_svc 128       = 0xD4001001 → LE bytes `01 10 00 d4` ✓
Verified: enc_ret           = 0xD65F03C0 → LE bytes `c0 03 5f d6` ✓

## Minimal v5.0 MVP plan

Drop commands 4, 5, 11, 13, 14, 15. Provide 1, 2, 3, 6, 7, 8, 9, 10, 12.
Codesign will append 16 (LC_CODE_SIGNATURE) in Phase 2.

That's **9 required load commands** instead of 16.
