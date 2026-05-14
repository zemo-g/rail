# Canonical ad-hoc signature — byte-level annotation

`codesign --sign - /tmp/v5_hello` (the Phase 1 Mach-O) appends an 18,304-byte
blob at file offset 16,384 and modifies one load command in place
(LC_CODE_SIGNATURE inserted at the end of the LC array).

Of those 18,304 bytes only the first **290 are substantive**; the rest is
zero-pad to make codesign re-signing easier. The substantive bytes parse as:

## SuperBlob (offset 0x000, 12 bytes)

| Bytes | Field | Value |
|---|---|---|
| 0x000..0x003 | magic | `fa de 0c c0` = CSMAGIC_EMBEDDED_SIGNATURE |
| 0x004..0x007 | length | `00 00 01 22` = **290** (big-endian) |
| 0x008..0x00B | count  | `00 00 00 03` = **3** index entries |

## BlobIndex × 3 (offset 0x00C, 24 bytes)

| Bytes | type | offset |
|---|---|---|
| 0x00C..0x013 | `00 00 00 00` (CodeDirectory) | 36 |
| 0x014..0x01B | `00 00 00 02` (Requirements wrapper) | 270 |
| 0x01C..0x023 | `00 01 00 00` (slot 0x10000) | 282 |

## CodeDirectory (offset 0x024, 234 bytes)

| Field | Bytes | Value | Notes |
|---|---|---|---|
| magic | `fa de 0c 02` | CSMAGIC_CODEDIRECTORY | |
| length | `00 00 00 ea` | 234 | |
| version | `00 02 04 00` | 0x20400 | minimum for ad-hoc on Apple Silicon |
| flags | `00 00 00 02` | adhoc | |
| hashOffset | `00 00 00 ca` | 202 | (from CD start; absolute 36+202=238) |
| identOffset | `00 00 00 58` | 88 | (from CD start) |
| nSpecialSlots | `00 00 00 02` | 2 | (Info.plist, Requirements) |
| nCodeSlots | `00 00 00 01` | 1 | one hash covers all 16384 bytes |
| codeLimit | `00 00 40 00` | 16384 | bytes hashed |
| hashSize | `20` | 32 | SHA-256 |
| hashType | `02` | 2 | SHA-256 |
| platform | `00` | 0 | not platform-binary |
| pageSize | `0e` | log2(16384) | pages of 16 KB |
| spare2 | `00 00 00 00` | 0 | |
| scatterOffset | `00 00 00 00` | 0 | (v0x20100+) |
| teamOffset | `00 00 00 00` | 0 | (v0x20200+) |
| spare3 | `00 00 00 00` | 0 | (v0x20300+) |
| codeLimit64 | 8 bytes | 0 | |
| execSegBase | 8 bytes | 0x4000 | |
| execSegLimit | 8 bytes | 0x4000 | |
| execSegFlags | 8 bytes | 1 | CS_EXECSEG_MAIN_BINARY |
| identifier | `v5_hello-…` + NUL | 50 bytes | derived from filename + UUID |
| pad | NUL | 1 byte | |
| special slot -2 | 32 bytes | sha256(empty Requirements blob) | |
| special slot -1 | 32 bytes | 32 zero bytes | (Info.plist absent) |
| code slot 0 | 32 bytes | sha256(bytes[0..16384]) | |

## Requirements wrapper (offset 0x10E, 12 bytes)

```
fa de 0c 01    magic = CSMAGIC_REQUIREMENTS
00 00 00 0c    length = 12
00 00 00 00    count = 0
```

## Empty requirement (offset 0x11A, 8 bytes)

```
fa de 0b 01    magic = CSMAGIC_REQUIREMENT
00 00 00 08    length = 8
```

## What v5.0 will emit

A simpler 2-entry SuperBlob:

- SuperBlob header (12 B)
- 2 × BlobIndex (16 B)
- CodeDirectory (234 B — same layout, adhoc flag set)
- Requirements wrapper (12 B)

Total: **274 bytes**. The 3rd blob (empty requirement at 0x11A) appears
optional based on Apple's open-sourced cs_blob reference and gets dropped.
If the kernel rejects the simpler form, add it back.
