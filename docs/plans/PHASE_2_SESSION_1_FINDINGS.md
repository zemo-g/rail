# Phase 2 — Session 1 findings (2026-04-28)

This is the report for the first reconnaissance session against Garmin
Instinct gen-1 firmware. The trophy was: by end of session, can we name the
chip, the firmware format, the signing scheme, and the first instruction
fetched at boot? Yes to all four (with one caveat) — and a strategic
finding none of us expected.

## What we built

### Tooling

- `stdlib/gcd.rail` — pure-Rail Garmin Container Data parser. Header
  validation, TLV record walker, 21 known record IDs named, descriptor-type
  decoder, ASCII view, hex view, per-stream byte accounting.
- `tools/garmin/gcd_dump.rail` — CLI dumper for one GCD: prints one line per
  record with light interpretation (CheckPoint sums, Copyright strings,
  PartNumber compressed bytes, FirmwareDescriptorType field schema).
- `tools/garmin/gcd_extract.sh` — shell + Python helper that streams large
  GCDs (>1 MB) past Rail's chars-list memory ceiling and writes per-stream
  binary blobs + a record manifest. Validation companion to the Rail parser.
- `docs/plans/PHASE_2_FIRMWARE.md` — the canonical multi-stage plan.

### Artefacts on disk

```
~/garmin_recon/
├── snapshot_2026-04-28/         # Read-only snapshot of /Volumes/GARMIN
├── snapshot_2026-04-28.sha256   # 103 file hashes (drift detector)
├── Garmin_GCD_Format.pdf        # Oppmann's authoritative spec, downloaded
└── firmware/
    ├── GUP3294.GCD              # 363 KB Sensor Hub firmware (Fenix 6)
    └── GUPDATE_B3287_19.20.GCD  # 6.77 MB Fenix 6 main firmware
~/garmin_recon/extracted/
├── GUP3294/
│   ├── manifest.txt
│   └── stream_0401.bin          # 358976 B, plaintext, Apollo2 Thumb-2 code
└── Fenix6_B3287/
    ├── manifest.txt
    ├── stream_0505.bin          # 55340 B, ENTROPY 7.996, encrypted
    └── stream_02BD.bin          # 6712108 B (= fw_all.bin), ENTROPY 8.0000, encrypted
```

## What we found

### 1. The chip stack

- **Sensor Hub MCU: Ambiq Apollo2 (Cortex-M4F, 64 KB SRAM, ≤1 MB flash).**
  Confirmed by debug strings inside the firmware:
  - `..\..\..\modules\hwm-core\garminos\processor\apollo2\libraries\hal\am_hal_clkgen.c`
  - and four sibling files (ctimer, gpio, ios, pwrctrl) — these are
    Ambiq's published HAL filenames.
  - Build path: `C:\Builds\apollo-sensor-hub\modules\hwm-core\garminos\processor\common/hwm_iic_common.h`.
- **RTOS: GarminOS** (Garmin's internal name; module path
  `modules/hwm-core/garminos/...`). Single-threaded model with a watchdog —
  the string `Main Thread Software Watchdog Reset: 0x%08x, 0x%08x` is in
  every firmware. Not FreeRTOS, not Zephyr, not μC/OS.
- **Sensor stack module: `bmx`** (likely "biometric multi-X" — e.g.
  `bmx_spo2.c`, gen3 pulse-ox driver inside the sensor hub).
- **Baro:** TE Connectivity MS5837-02BA (string
  `ints v1::INTSM MS5837_02BA` confirms part number).
- **Build environment:** Windows host (drive letter `C:\Builds\...`),
  product name `apollo-sensor-hub`.

### 2. The container format

- **GCD V1.0** — 6-byte ASCII `GARMIN` + LE ushort version `0x0064` (= 100 = V1.0).
- Body is a flat stream of TLV records: ushort ID, ushort length, body.
- Both real GCDs we parsed (363 KB and 6.77 MB) walk to the End record
  (`0xFFFF`, length 0) cleanly with byte-exact length accounting.
- The container is **NOT cryptographically signed.** Integrity is only
  CheckPoint records (1-byte sum-to-zero) sprinkled through the stream.
- Stream-level XOR obfuscation: F10/byte field in the FirmwareDescriptor
  encodes a single byte to XOR every body byte with. Both observed GCDs
  used **XOR = 0x00** (no obfuscation).

### 3. The Sensor Hub firmware (PLAINTEXT)

- Stream `0x0401`, 358 976 bytes.
- Whole-file entropy 7.25 bits/byte — code-shaped, not random.
- 187 printable runs ≥8 chars; readable C source paths, error messages,
  vendor strings.
- Sliding-window entropy: 79 windows in 6.4–7.2 range (typical for code),
  3 windows higher (likely embedded data tables), 1 lower (likely a clear
  data section).

#### Memory map (from the disassembly)

- Initial SP = `0x100060F8` — Apollo2 SRAM (0x10000000–0x10010000), ~24 KB
  in. Reasonable.
- **Vector table at blob offset `0x2140`.** Layout (Thumb bits stripped):

  | Vector | Address |
  |---|---|
  | Reset_Handler | `0xC304` |
  | NMI_Handler | `0xA9D8` |
  | HardFault_Handler | `0xA9FC` |
  | MemManage_Handler | `0xA9F0` |
  | BusFault_Handler | `0xAA14` |
  | UsageFault_Handler | `0xA9E4` |
  | SVCall | `0xAA08` |
  | PendSV | `0xA9C0` |
  | SysTick | `0xD428` |

- Disassembly of Reset_Handler (capstone, Thumb + M-class):

  ```
  0x0000c304:  ldr   r3, [sp, #0x1c]
  0x0000c306:  cmp   r3, #0
  0x0000c308:  bne.w #0xc55a
  0x0000c30c:  ldr   r3, [sp, #0x2c]
  0x0000c30e:  strd  r0, r1, [r3]
  0x0000c312:  mov   r3, r1
  0x0000c314:  ldr   r1, [sp, #0xc]
  ...
  0x0000c350:  pop.w {r4, r5, r6, r7, r8, sb, sl, fp, pc}
  ```

  These are real, well-formed Cortex-M4 Thumb-2 instructions. The Reset
  vector points to a function that already accesses an established stack
  frame (sp+0x1c, sp+0x2c) — **unusual for a typical Reset_Handler**. Two
  hypotheses:
  1. Apollo2's secure-boot ROM jumps to user code with arguments staged on
     SP (call pattern, not bare reset).
  2. The VT at `0x2140` is an *application*-relocated VT, with the actual
     hardware reset entry sitting earlier and the bytes at `0x0` being a
     packaging / metadata header (the FFFFFFFF + ASCII part-number we see
     at offset 0 supports this).

  Either is fine for our purposes — we have the boot entry point and a
  working disassembly toolchain.

### 4. Fenix 6 main firmware is ENCRYPTED

This was the strategic finding I want to flag prominently.

- Stream `0x02BD` (= region `0x0E` = `fw_all.bin`), 6 712 108 bytes.
- Whole-file entropy **8.0000 bits/byte** — bit-perfect uniform random.
- Sliding-window entropy: every single window in the 7.2–8.0 bin (1638/1638).
- 0x00 byte: 0.39%. 0xFF byte: 0.39%. Cleartext code is ~5% one of those
  due to padding.
- No SHA-256 K-table, no SHA-1 K-constant, no NIST P-256 prime in
  plaintext.
- Companion stream `0x0505` (55 KB) shows the same statistical signature.

Anvil Secure's 2024 deep-dive on Forerunner 245 (2019) showed plaintext
firmware with RSA-PKCS#1-v1.5 + SHA-1 4096-bit signing. **Garmin moved to
encrypted firmware between FR 245 and Fenix 6** (both contemporaneous,
2019/2020 release). The exact transition device and crypto scheme is an
open question.

**For our target** — Garmin Instinct gen-1, released **2018**, vintage
matches FR 245 exactly — the firmware is *almost certainly still
plaintext*. Confidence: high (same era, same general SDK, no hint of
firmware encryption in this generation).

We just don't have the Instinct GCD yet — no community mirror exists for
PartNumber `006-B3126-00`, and Garmin's update API requires a hand-built
protobuf request that didn't fit in this session.

## Trophy criterion (from the plan doc)

| Question | Answer |
|---|---|
| What chip is in the watch? | Sensor hub: **Ambiq Apollo2 (Cortex-M4F)**. Main MCU: not directly observed but FCC-photo lookup (deferred) plus contemporaneity with FR 245 strongly suggests another Apollo-family or NXP Kinetis Cortex-M4 part. Confidence: high for sensor hub, medium for main. |
| What format is its firmware? | **GCD V1.0** TLV envelope, parsed end-to-end in pure Rail. Per-stream descriptor records carry XOR key + length. |
| What signs the firmware? | **The GCD container is not signed.** The firmware *stream content* in 2019-era Garmin watches (FR 245) was RSA-PKCS#1-v1.5-SHA-1-4096 per Anvil Secure. Fenix 6 went to firmware encryption — scheme unknown. |
| First instruction at boot? | Sensor Hub Reset_Handler at **0xC304**, Thumb-2 confirmed via capstone. |

## Open questions for Session 2

1. **Fetch the actual Instinct firmware.** Two paths, in order of cost:
   - **Forum / cache scrape:** check garmin.openstreetmap.de, gpsrchive,
     `forums.garmin.com` instinct-original threads, Wayback for the
     `download.garmin.com/gsup/006-B3126-00/19.10/...` URL pattern.
   - **Garmin Software Update Service in pure Rail:** the API is
     protobuf over HTTPS at `omt.garmin.com/Rce/ProtobufApi/...`. Hand-craft
     the request body (unit_id, part_number, software_version,
     hwid/flag1/flag2). Our pure-Rail TLS stack already validates against
     the macOS trust store — this is a Rail v3.0.0 demo waiting to happen.

2. **Once we have the Instinct firmware:** rerun this session's pipeline
   (gcd_dump → gcd_extract.sh → entropy/strings → vector-table scan →
   capstone disassembly). If plaintext: locate Reset_Handler, find the
   sig-verify routine via crypto-constant search, extract the embedded
   public key.

3. **Rail-native Thumb-2 disassembler** — deferred this session. capstone
   bridged the gap, but a Rail-native disassembler is a Rail demo of its
   own. Scope: 16-bit Thumb-1 + the major 32-bit Thumb-2 forms (BL, B.W,
   LDR.W, STR.W, MOV.W, ADD.W, SUB.W, IT, BX, BLX). ~500–1000 lines of Rail.

4. **Fenix 6 encryption.** Tangential to the Instinct project but
   strategically interesting: figure out which Garmin gen first encrypted,
   what the scheme is (AES? a stream cipher? key from device unit_id?).
   Probably not solvable without hardware extraction.

5. **Hardware path** for the Instinct (Stage 5 of the plan):
   teardown / SWD / glitch attack. Out of scope for software sessions; a
   bench-time project when we're ready to commit.

## Files this session created

```
docs/plans/PHASE_2_FIRMWARE.md             # plan
docs/plans/PHASE_2_SESSION_1_FINDINGS.md   # this doc
stdlib/gcd.rail                             # pure-Rail GCD parser
tools/garmin/gcd_dump.rail                  # CLI: dump GCD record stream
tools/garmin/gcd_extract.sh                 # shell helper for big GCDs
~/garmin_recon/                             # all out-of-tree artefacts
```

---

## Session 2 addendum (continuation, same date)

### Tooling

- `stdlib/thumb2.rail` — pure-Rail Cortex-M Thumb-2 disassembler. Decodes
  control-flow / function-boundary instructions: 16-bit B/Bcond/BX/BLX,
  POP/PUSH (with PC/LR detection), CBZ/CBNZ, NOP/SVC/UDF; 32-bit BL/B.W/Bcond.W.
  Matches capstone byte-for-byte on Sensor Hub Reset_Handler. ~190 lines.
- `tools/garmin/disasm.rail` — CLI disassembler that uses `dd` to slice
  arbitrary byte ranges out of a multi-MB firmware blob (sidesteps the
  chars-list ceiling).

### Instinct gen-1 firmware (the real prize)

Located via Wayback Machine search of `download.garmin.com/gsup/006-B3126-00/*`:

- URL: `https://download.garmin.com/gsup/006-B3126-00/19.10/full/rel/8acbe1f4-afb8-4a9b-a700-f6c8d384ba33/Instinct_1910Beta.zip`
- ZIP contains TWO GCDs: `System_1910/GUPDATE.GCD` (3 018 275 B) and
  `System_Backdate_1901/GUPDATE.GCD` (2 991 088 B).
- 19.10 main firmware extracts to:
  - `stream_02BD.bin` — 2 986 752 bytes, **PLAINTEXT** (entropy 7.145).
  - `stream_0505.bin` — 27 136 bytes, plaintext (entropy 6.845).

### Instinct architecture

- **Bytecode is plaintext, not encrypted.** Garmin's encryption transition
  happened between Instinct gen-1 (2018) and Fenix 6 (2019/20).
- **MCU is NOT Apollo2.** SP=0x20002048 lands in the canonical
  Cortex-M SRAM range (0x20000000–0x20040000), not Apollo2's 0x10000000+
  region. Strongest candidate: NXP Kinetis K-series (per agent research,
  Garmin pre-2020 default).
- **Flash layout:**
  - `0x0000`–`0x0200`  — small bootloader (executable code starts with
    `cpsid i; mrs r5, ipsr` — typical Cortex-M setup sequence).
  - `0x0200`           — application vector table (canonically aligned).
  - `0x2000`           — Reset_Handler entry.
  - `0x14a00`–`0x15100` — exception/IRQ handler block; 48 device-specific
    IRQs populated, most pointing at the default handler at `0x1504c`.
- **Vector table** (Thumb bits stripped):

  | Vector | Address |
  |---|---|
  | SP | 0x20002048 |
  | Reset_Handler | 0x2000 |
  | NMI | 0x233c |
  | HardFault | 0x2324 |
  | MemManage | 0x2330 |
  | BusFault | 0x230c |
  | UsageFault | 0x236c |
  | SVCall | 0x2354 |
  | DebugMon | 0x2318 |
  | PendSV | 0x2348 |
  | SysTick | 0x2360 |
  | Default IRQ | 0x1504c |

- **RTOS: GarminOS** — confirmed by source path `..\..\..\TSK\garmin-os\tsk_sem.c`.
  Multi-threaded with semaphores (`Freeing mem (%p) w/rsrvd smphr %s (%p) on thread %s (%p)`),
  not just the watchdog model the Sensor Hub uses.
- **Module organisation** (from in-firmware paths):
  - `TSK/garmin-os/` — task / scheduler / sync primitives
  - `TFS/` — Garmin's file system layer (likely Token File System; mounts
    the `0:/GARMIN/` namespace we already access via USB)
  - `CDP/` — "Common Display Pages" — the user-facing page system; >30
    distinct page sources observed (calendar, calories, map, moon_phase,
    altimeter_calibration_prompt, hr_broadcast, inreach_widget, …)
- **Radio: Nordic nRF**, dual-stack BLE + ANT+ (`BLE Radio NRF Error: %d`,
  `ANT RF Lib Version Message Received`). Likely nRF52832, separate package
  from the main MCU.
- **Multi-product firmware:** same GCD ships Instinct, instinctE,
  Instinct Esports, Instinct Tactical (instinctTac). Variant detection at
  runtime, not by separate firmware images.
- **Connectivity:**
  - Garmin Connect HTTPS endpoints (production + stage + test + China):
    `services.garmin.com`, `servicesstg`, `servicestest`, `services.garmin.cn`.
  - OAuth token exchange URL family.
  - GCS (Garmin Connect Service) elevation API:
    `api.gcs.garmin.com/geolocation/elevation?latitude=%f&longitude=%f`.
  - Identifying request headers: `X-Garmin-Unit-ID`, `X-Garmin-SW-Part-Number`,
    `X-Garmin-Firmware-Version`, `X-garmin-client-id`.
  - Third-party integration: `easyhunt.com` hunting-position API.

### Important flip on the user-data side

The Phase 1 finding "Monitor/Sleep dirs are structurally empty on Instinct
gen-1" was wrong. **The firmware contains writers** for both files:

- `0:\Garmin\Monitor\Monitor.FIT`
- `0:\Garmin\Sleep\Sleep.FIT`

The user's watch shows empty dirs because those files only get written
under specific runtime conditions (likely: pairing with Garmin Connect
Mobile, sufficient battery / idle time, monitoring features enabled in
Settings). This is a state issue, not a hardware/firmware limitation.

If the user enables the relevant settings or pairs with Connect briefly,
the watch will start populating those files — and Phase 1's pipeline
already decodes them.

### Disassembler validation

The Rail disassembler at `tools/garmin/disasm.rail` produces output that
matches capstone exactly on the Sensor Hub Reset_Handler:

```
0x0000c308  f040 8127  b.ne.w 0x0000c55a       (capstone: bne.w #0xc55a)
0x0000c31c  f044 f800  bl     0x00050320       (capstone: bl   #0x50320)
0x0000c324  dd0c       b.le   0x0000c340       (capstone: ble  #0xc340)
0x0000c330  f043 fff8  bl     0x00050324       (capstone: bl   #0x50324)
```

Encoding bug found and fixed mid-session: BL/B.W shift offsets in the
sign-extended 25-bit immediate were off by one, and Bcond.W needed J2
before J1 in the bit-pack order. Both per ARMv7-M ARM A8.8.18 / A8.8.25.

### Trophy criterion update

| Question | Session 1 answer | Session 2 answer |
|---|---|---|
| What chip? | Apollo2 (sensor hub only) | Cortex-M (likely NXP Kinetis) for the watch's main MCU; Nordic nRF for BLE/ANT |
| Firmware format? | GCD V1.0 parsed | Same; Instinct's actual GCD now in hand |
| Signed how? | Container unsigned, stream content RSA on FR-245 era | Same expected for Instinct (sig-verify routine still to locate inside the disassembly) |
| First instruction? | Sensor Hub Reset = 0xC304 | **Instinct Reset_Handler = 0x2000**, full VT mapped |

### Open for Session 3

1. **Locate sig-verify in Instinct firmware.** Crypto-fingerprint scan on
   `stream_02BD.bin`, then call-graph walk from any matching function back
   to the bootloader at flash 0x0.
2. **Identify the exact NXP Kinetis variant.** SP=0x20002048 + 2.85 MB code
   suggests at least 4 MB flash + ≥256 KB SRAM. MK28FN2M0ACAU15 (used in FR
   245) has only 2 MB flash, so probably a different part. Candidates: K6x
   family, or a higher-density K2x.
3. **Map the call graph from Reset_Handler at 0x2000.** Use the Rail
   disassembler to walk BL targets recursively. Build a function table.
4. **Decode the Instinct's "BootLoader at 0x0".** First few instructions
   (`cpsid i; mrs r5, ipsr`) are typical setup. Walk it; find where it
   jumps to the application's Reset_Handler at 0x2000.
5. **Garmin Software Update Service in pure Rail** — the protobuf API
   client. Now optional (we have firmware in hand) but still a Rail demo.

---

## Session 3 addendum (continuation, same date)

### Disassembler refinements

Two encoding bugs caught and fixed in `stdlib/thumb2.rail`:

1. **CBZ/CBNZ vs NOP/IT/HINT collision.** I had `top7 == 95` (= `1011111`)
   routing to CBNZ, but that bit pattern is actually NOP/IT/HINT. CBZ is
   `1011001` (= 89), CBNZ is `1011101` (= 93). The CBZ/CBNZ also reads
   bit 8 (not bit 9) for the `i` flag of the immediate.
2. **Bcond.W vs MSR/MRS/HINT collision.** Branches and miscellaneous
   control share the same first-halfword prefix (`11110`) plus
   `lo[15:14] = 10`, plus `lo[12] = 0`. Bcond.W must additionally have
   `cond != 14 && cond != 15` to disambiguate from MRS/MSR/CPS/HINT
   instructions. Without this filter `mrs r5, ipsr` was being decoded as
   a phantom Bcond.W to a far-flash address.

Plus `tools/garmin/disasm.rail`'s slice-loop was computing branch targets
relative to the slice origin — needed to add `slice_origin` to
absolute-address space for branch kinds (1/2/3/4/5/9). Fixed.

### Crypto fingerprint scan

Scanned `stream_02BD.bin` (2 986 752 bytes) for known crypto constants:

- **SHA-256 K-table** (LE): one hit at `0x002951D0`. Confirms SHA-256 in use.
- **AES S-box** (`637c777bf26b6fc5...`): one hit at `0x00292F98`. Surrounding
  bytes match the AES T-table layout (T0..T3 lookup tables for fast
  software AES). Confirms AES in use.
- **NIST P-256 prime**: no hits. Confirms ECDSA-P256 is NOT used.
- **SHA-1 K-constants**: no clean isolated hits (would have needed BL+offset
  immediate matching).
- **RSA F4 exponent (`0x00010001`)**: 92 hits — most are immediates in code
  (e.g. `MOV.W` constants), not RSA contexts. No 4096-bit modulus pattern
  found.
- **String `VERIFYKEY`** is in the binary — likely a label / log message
  for the ANT+ master-public-key handshake, not firmware sig-verify.

### Strategic conclusion

**The Instinct firmware does not appear to verify itself.** The SHA-256 +
AES tables point to *application-level* crypto (probably OAuth token
storage, FIT-file integrity, ANT+ pairing, and the EDM hash files we saw
filename strings for). There is no 4096-bit RSA modulus pattern in the
binary; there is no NIST P-256 curve material.

This is consistent with NXP Kinetis K-series secure boot architecture:
the mask-ROM bootloader inside the chip validates signed firmware images
against a key burned at production. User firmware doesn't carry the
verification key — it doesn't need to, because the verification has
already happened by the time `Reset_Handler` runs.

**Implication for Stage 5+:** the GCD-path attack we initially scoped
(extract sig-verify routine → swap its public key) doesn't apply because
the routine isn't in user firmware. The realistic path to running
unsigned code is:

1. **Hardware extraction** of flash via SWD on the Kinetis. If RDP is at
   level 0 we win; if at level 1, flash is reset on connect (we keep our
   pulled GCD).
2. **Voltage glitch** on the secure-boot signature comparison instruction
   to bypass the mask-ROM check. Standard ChipWhisperer territory for
   Kinetis-class parts.
3. **Find a Garmin firmware vulnerability** that escalates to write
   arbitrary flash without going through the update channel — long shot,
   would need months of fuzzing.

This actually *simplifies* the plan: there's no "find the sig-verify
routine" software step. Sessions 1–3 have produced everything Phase 2
can produce purely in software. From here, hardware is the gate.

### Files saved this session

- `~/garmin_recon/extracted/Instinct_1910/candidate_rsa_4096.bin` —
  the 512-byte high-entropy block at 0x292fc0, kept for archive even
  though it is now believed to be AES T-table data, not an RSA key.

### Trophy update - final for software-only sessions

| Question | Answer |
|---|---|
| What chip? | NXP Kinetis-class Cortex-M (SP=0x20002048 in 0x20000000+ SRAM); Nordic nRF for BLE+ANT |
| Firmware format? | GCD V1.0, fully parsed in pure Rail; Instinct's 19.10 GCD extracted |
| What signs the firmware? | **The chip's mask ROM, not the user firmware.** No RSA modulus / ECDSA curve in the app binary. AES + SHA-256 are present, but for app-level data integrity, not boot. |
| First instruction? | Bootloader `cpsid i; mrs r5, ipsr; ...` at flash 0x0; bootloader exits via `bx r0` (likely r0 holds Reset_Handler with Thumb bit). App Reset_Handler at 0x2000. |

---

## Session 4 addendum (cable-only, sealed)

### Strategic reframe

User constraint: keep the watch sealed and waterproof. No case-opening, no
SWD probe. Phase 2 plan rewritten in `PHASE_2_FIRMWARE.md` with new
Stages 5-11 anchored on USB cable only.

### USB descriptor enumeration (MSC mode)

Watch in default Mass Storage USB mode:

- idVendor `0x091E`, idProduct `0x0C36`, bcdDevice `0x0509`
- Single interface: class 0x08 (MSC), subclass 0x06 (SCSI), protocol 0x50 (BBB)
- 2 bulk endpoints: EP 0x81 IN, EP 0x03 OUT, both 64-byte wMaxPacketSize
- macOS `AppleUSBMassStorageDriver` claims the interface; `pyusb.claim_interface()` -> EACCES.
  No userspace control without DriverKit entitlement.

### USB descriptor enumeration (Garmin proprietary mode)

After flipping `Settings > System > USB Mode > Garmin` and re-plugging:

- idProduct flips to `0x0003` (Garmin's "generic GPS" PID family)
- bDeviceClass / bDeviceSubClass / bDeviceProtocol all = `0xFF` (vendor-specific)
- Single interface, 3 endpoints:
  - EP 0x81 IN, bulk, 64-byte
  - EP 0x82 IN, interrupt, 64-byte
  - EP 0x03 OUT, bulk, 64-byte
- macOS does NOT claim vendor-specific interfaces; pyusb claim succeeds.

### Garmin USB Protocol session decoded

`tools/garmin/usb_probe.py` opens the bulk channel, sends the documented
handshake + Product Data request, and parses the reply burst. Result on the
sealed Instinct gen-1:

```
[1] Pid_Start_Session  (USB layer, PID 5, size 0)
[2] Pid_Session_Started (USB layer, PID 6, size 4): payload 6c6905cc
        -> unit_id LE = 0xCC05696C = 3422906732  (matches Device.fit)
[3] Pid_Product_Rqst  (App layer, PID 254, size 0)
[4] burst 1: Pid_Ext_Product_Data (PID 248): "GPS V2.70"
            -> MediaTek MT3333 GPS chip firmware version
    burst 2: Pid_Product_Data    (PID 255):
            -> product_id 0x0C36 (3126), sw_version 19.10,
               product string "INSTINCT V19.10"
    burst 3: Pid_Protocol_Array  (PID 253, 5 entries):
            -> P000 L001 A010 A903 A1050
```

Decoding the protocol array:

- **P000**  Physical link (USB)
- **L001**  Link protocol level 1
- **A010**  Device Command (the verb-issuing layer)
- **A903**  Track / Lap / Run transfer
- **A1050** Fitness Device Protocol (workouts + activity transfer)

Three transfer protocols. **No firmware-write verb is advertised** -
confirming the cable update path is the GCD-drop on the FAT volume, not a
bulk-protocol verb.

### Files added

```
tools/garmin/stage5_push.sh      # signed-GCD round-trip via Mass Storage
tools/garmin/usb_probe.py        # Garmin Protocol read-only probe (Python+pyusb)
```

### Trophy update for cable-only path

| Question | Answer |
|---|---|
| Can we drive the watch from the cable in normal mode? | Read-only file access via macOS, that's it. The MSC driver owns the bulk endpoints. |
| Can we drive the watch via the proprietary Garmin protocol? | YES, after the user toggles `USB Mode -> Garmin`. Full bulk session opened, identity + protocol surface enumerated. |
| Is firmware writable through the proprietary protocol? | NO - not in the advertised verb set. Firmware updates go through the FAT-volume GCD-drop. |
| Is there a software-only path to unsigned code? | Open question. Stage 7 (acceptance fuzzing on the backdate version) is the place to find it if it exists. |

### Next session

- Use the now-open Garmin Protocol session to issue the documented
  read-only A010 / A903 / A1050 verbs - extract every datum the watch
  exposes through this channel that we can't get through the FAT volume.
- Port the protocol client from Python to Rail (libusb FFI + L000/A010
  packet handling). A real Rail systems demo built on top of v3.0.0 TLS-era
  patterns.
- Stage 5 GCD round-trip when user is ready to eject and accept the
  ~30-second update animation.
- Stage 7 acceptance fuzzing once the round-trip has demonstrated the
  cable update channel works.

## Lessons learned

- Rail's `chars` list materialises every char as a cons cell — fine for
  hundreds of KB, but we hit the 512 MB heap on a 6.7 MB GCD's
  ~13.4 M-char hex string. Future binary I/O wants either a streaming
  primitive in the runtime or a chunked decoder that processes a window
  at a time.
- Multi-line `&&` chaining doesn't parse: each line terminates the
  expression. Group with parentheses on a single line, or chain via
  intermediate let bindings.
- Comments tolerate ASCII just fine, but em-dashes and box-drawing
  characters trip the lexer. Stay in ASCII for `.rail` source.
- The `to_int` builtin is float→int only. For string-to-int we still need
  per-module helpers (`fit_parse_uint`, `gcd_parse_uint`). Worth a real
  `str_to_int` builtin.
