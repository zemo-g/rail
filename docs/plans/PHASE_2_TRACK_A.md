# Phase 2 Track A — Rail Cortex-M Thumb-2 codegen + bare-metal runtime

The "delivery vehicle" track. Independent of any exploit landing on the
watch — produces a Rail-native toolchain that can emit valid Cortex-M
Thumb-2 binaries for the Instinct's MCU. When Track B finds its parser
bug, the payload that the bug fetches and executes is what Track A built.

## Status (session-by-session)

- [x] **A0** — Pure-Rail Thumb-2 disassembler (`stdlib/thumb2.rail`).
  Decodes 16-bit B/Bcond/BX/POP/PUSH/CBZ/CBNZ/NOP/SVC/UDF and 32-bit
  BL/B.W/Bcond.W. Validated byte-for-byte against capstone on the
  Sensor Hub's Reset_Handler.
- [x] **A1** — Pure-Rail Thumb-2 encoder (`stdlib/thumb2_emit.rail`).
  Encoder for the same instruction families plus enough data-processing
  for an MMIO payload: MOVS imm8, ADDS, SUBS, CMP imm8, MOV reg, LDR PC-rel,
  MOVW imm16, MOVT imm16, LDR.W [Rn,#imm12], STR.W [Rn,#imm12]. Round-trip
  validated against the decoder; bytes match the real firmware exactly
  (e.g. `BL 0xC31C → 0x50320` produces `f044 f800` like the live binary).
- [ ] **A2** — Symbolic assembler. Currently the encoder takes raw operand
  ints. Add a thin layer: declare labels, emit instructions referencing
  labels, two-pass resolve. Output is a byte buffer + a label table.
  ~150 lines.
- [ ] **A3** — Literal pool support. Constants > 8 bits load via PC-relative
  LDR. Encoder needs to emit constants near the function epilogue and
  patch LDR offsets in a second pass. Required for any payload that
  touches an MMIO address.
- [ ] **A4** — Linker layout. Cortex-M Thumb-2 binaries need:
    - vector table at a known flash address (Instinct's app VT is at 0x200,
      so payloads inserted into the running firmware use a different
      VTOR-relative offset)
    - `.text` section (code)
    - `.rodata` (constants, literal pool)
    - `.data` initial values (copied to RAM at startup)
    - `.bss` (zero-initialised RAM)
  Ship as a single contiguous flash image + a reset code path that
  copies `.data` and zeroes `.bss`.
- [ ] **A5** — Bare-metal Rail runtime (no malloc, no GC). Replaces the
  heap-based runtime built into `tools/compile.rail`'s emit:
    - `arr_new` is a fixed pool with bump allocator; no free.
    - No first-class lambdas (or lambdas allocate from the pool with no
      reclaim — accept the leak for short-lived programs).
    - No string concatenation that re-allocates dynamically; ship strings
      as static `.rodata`.
    - No `shell`, `read_file`, `write_file`, no FFI to libc — those don't
      exist in our context.
    - Replace with target-specific MMIO helpers: `mmio_w8`, `mmio_w16`,
      `mmio_w32`, `mmio_r32`, plus delay loops.
- [ ] **A6** — Cortex-M backend in `tools/compile.rail`. Add a third
  target alongside macOS-ARM64, x86_64, WASM. Reuse the existing AST
  walker; replace the codegen pass with calls to `stdlib/thumb2_emit.rail`.
  First-light goal: compile `main = 0` and produce a binary that loops
  at `b .` after returning from main.
- [ ] **A7** — Display driver: Sharp Memory LCD over SPI. The Instinct
  uses an LS013B7DH03 or similar 128x128 1-bit MIP. Public datasheet.
  SPI peripheral is on a known set of GPIO pins per the Kinetis package
  on this board. Driver is ~50 lines once we know which SPI peripheral
  and pins.
- [ ] **A8** — Button driver: GPIO with falling-edge interrupt.
- [ ] **A9** — First Rail watchface: clock, reading the time off the
  RTC (Kinetis has a built-in RTC at a known MMIO base). Drawing four
  digits on the Memory LCD. ~200 lines of Rail.
- [ ] **A10** — Full takeover: drive the IMU, baro, GPS, HR sensors,
  BLE radio. This is months of driver work but each is a public
  datasheet. The hard part is finding which pins map to which signals
  — that comes from staring at the firmware's GPIO setup code, which
  we already have disassembly access to via Rail's tooling.

## Critical open question

What's the EXACT NXP Kinetis variant in the Instinct? SP=0x20002048
plus 2.85 MB of plaintext code suggest at least 4 MB flash + ≥256 KB
SRAM. Candidates:

- **MK28FN2M0ACAU15** (FR 245) — 2 MB flash, 1 MB SRAM. Probably too small.
- **MK64FN1M0xxx12** — 1 MB flash, 256 KB SRAM. Too small.
- **MK66FN2M0xxx18** — 2 MB flash, 256 KB SRAM. Plausible.
- **MK60DN512xxx10** — 512 KB flash. No.
- A higher-density K2x/K6x variant.

We'll narrow it by:
1. Decoding the firmware's MMIO base addresses — Kinetis chips have
   distinctive peripheral memory maps. The `0xE000Exxx` (system control)
   addresses are universal Cortex-M; the `0x40000000`-range addresses
   identify the chip family.
2. Looking for chip-ID constants that the firmware reads (every Kinetis
   has a SIM_SDID register at `0x40047024` that reports the exact part
   number).
3. Cross-referencing the firmware's vector table size (number of IRQ
   entries) against Kinetis IRQ counts per family.

## Files this track owns

```
stdlib/thumb2.rail              # decoder (done)
stdlib/thumb2_emit.rail         # encoder (done)
stdlib/cortexm_runtime.rail     # bare-metal runtime (TODO)
stdlib/kinetis_mmio.rail        # MMIO helpers, peripheral bases (TODO)
tools/garmin/test_thumb2_roundtrip.rail  # round-trip test (done)
tools/compile.rail               # +Cortex-M backend (TODO)
docs/plans/PHASE_2_TRACK_A.md    # this doc
```

## Why this is non-blocking on Track B

Even without Track B finding an exploit, Track A produces:

- A pure-Rail demo of "Rail emits real firmware-quality Thumb-2."
- A reusable Cortex-M backend for any future ARM-Cortex-M Rail
  project (Pi Pico, nRF52, STM32, etc.).
- A precise model of the Instinct's flash/RAM layout, useful for
  any subsequent attack.

If Track B succeeds first, we plug Track A's binary into the exploit's
fetch-and-jump path. If Track A finishes first, we wait for Track B
or switch to a donor unit. Either way, Track A's output is the trophy.
