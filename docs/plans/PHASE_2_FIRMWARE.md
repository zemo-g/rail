# Phase 2 — Garmin Instinct firmware reverse-engineering

**Target:** Garmin Instinct (original), PartNumber `006-B3126-00`, firmware
`19.10`, device unit ID `3422906732`.

**Strategic frame:** Phase 1 (USB FIT data plane) shipped 2026-04-28. Phase 2
is the trophy result for Rail — proving the language can parse, analyse, and
eventually replace the firmware on a sealed consumer wearable. Phase 1's parser
already handles 100k-record activity files in ~1 s; Phase 2 builds on the same
binary-I/O primitives but takes them down a layer.

The end-state is an authentic Rail demo: a Rail-built watchface running on the
user's actual Instinct. Anything short of that is a step toward it.

## Threat model — what's locked

Garmin's firmware update path is authenticated:

- Firmware ships as `GCD` (Garmin Container Data) — a signed binary container
  with a header, region table, per-region payloads, and a trailing signature
  block.
- Bootloader verifies the signature against an embedded public key on every
  boot and on every update.
- The signing key is held by Garmin; we do not have it. Loading unsigned code
  on a stock device requires either:
  1. **Soft path:** a bootloader / sig-verify bug we can chain into arbitrary
     code execution. Vanishingly rare on a production device.
  2. **Hardware path:** SWD/JTAG access to the MCU + (probably) voltage glitch
     to bypass the read-out protection fuse + flash a custom image. Standard
     ChipWhisperer territory; weeks of bench work.
  3. **Side channel:** Garmin Connect / Express auth flow leak — implausible.

This document plans for path 2, while keeping path 1 alive as a low-cost
parallel investigation (anyone reads firmware long enough often finds bugs).

## Stages

Stages 0–4 are all software / static work — no hardware modification, no
warranty risk. Stages 5–7 require physical access to the PCB and explicit user
authorization before each step.

### Stage 0 — Recon & ground truth (this session)

- [x] Phase 1 FIT decoder (decode every health stat the watch already exposes
  via USB).
- [ ] Snapshot the mounted volume read-only. SHA-256 every file. Establishes a
  baseline; future snapshots will diff against this to detect device-state
  drift during experiments.
- [ ] Inventory: which files contain plaintext config (`Settings/`, `Sports/`,
  `Goals/`), which are FIT data, which are pre-cached binary blobs (`EPO.BIN`,
  `Device.fit`).
- [ ] Identify the SoC (and BLE radio, if separate) from public sources: FCC
  ID `2ADTGSTS003` photos, teardowns, supply-chain leaks. The most likely
  combinations for an Instinct gen-1 are STM32L4 + Nordic nRF52, or Ambiq
  Apollo3 (single-chip MCU+BLE), or Renesas RA. Confirm.
- [ ] Public-document the GCD container format — community reverse engineers
  have published partial specs; pull what exists, fill in the gaps from our
  own samples.

### Stage 1 — Get a copy of the firmware

- [ ] Pull `GUPDATE.GCD` for `006-B3126-00@19.10`. Two paths:
  1. **Rail-native:** call Garmin's Software Update Service over our pure-Rail
     TLS stack. Endpoint:
     `https://omt.garmin.com/Rce/ProtobufApi/SoftwareUpdateService/...`. Body
     is protobuf-encoded; we can hand-craft the wire format for the small set
     of fields we need (unit_id, part_number, current_version).
  2. **Curl fallback:** pragmatic if the protobuf-by-hand lift is too big for
     one session. Document the request, then port to Rail later.
- [ ] Verify against the version string in `GarminDevice.xml` (we expect
  `Major=19`, `Minor=10`).
- [ ] Save to `~/garmin_recon/firmware/`. Hash. Never modify.

### Stage 2 — GCD parse in Rail

- [ ] `stdlib/gcd.rail` — header, region table, region records, signature
  block. Round-trip property: parse → re-emit → byte-identical.
- [ ] `tools/garmin/fw_extract.rail` — extract each region to a separate file
  on disk for downstream analysis (Ghidra, our own Rail tools, hex viewers).
- [ ] Note: GCD is *also* used for the small accessory-firmware blobs in
  `REMOTESW/` — same parser handles both.

### Stage 3 — Static analysis

- [ ] `tools/garmin/fw_recon.rail`: per-region byte-frequency histogram, Shannon
  entropy, printable-string extractor. Encrypted regions look high-entropy and
  near-uniform; code looks low-entropy with ISA-specific bias; data is
  somewhere in between.
- [ ] ISA identification: Thumb-2 has very specific 16/32-bit boundary patterns
  and a high frequency of certain opcodes (BL, B, LDR, MOV); Xtensa has
  3-byte instructions. Plot it.
- [ ] Vector table scan: ARM Cortex-M boots from address 0x00000000 with the
  initial SP at offset 0 and Reset_Handler at offset 4. If we see a plausible
  SP-like value (RAM-range pointer) followed by an odd-numbered (Thumb)
  function pointer, we've found the vector table. From there: walk
  Reset_Handler, find data init, find main entry.
- [ ] String extraction: error messages, debug strings, vendor/library
  identifiers (`FreeRTOS`, `Nordic`, `STMicro`) reveal the RTOS and SDK.
- [ ] Crypto fingerprinting: SHA-256 K-constants, NIST P-256 curve constants,
  RSA modulus headers — these point to the sig-verify routine and tell us the
  signing scheme.

### Stage 4 — Minimal Rail disassembler

- [ ] `tools/garmin/disasm_thumb.rail` (assuming Cortex-M; or
  `disasm_xtensa.rail` if the recon comes back Xtensa). Decode enough
  instructions to follow function call graphs:
  - Thumb-2: B/BL (branch), LDR/STR (load/store), MOV/ADD/SUB/CMP, IT
    (if-then), BX/BLX.
  - 32-bit register-shift forms can be dropped for the first pass.
- [ ] Function-finder: scan for `push {lr, ...}` prologues; walk forward to
  the matching `pop {pc, ...}` epilogue.
- [ ] Cross-reference: every BL target. Build the call graph. The
  signature-verify routine sits at a hub — called from boot, from update,
  references the embedded public key data.

### Stage 5 — Cable-only firmware acceptance (the sealed path)

User constraint: keep the watch sealed and waterproof. No case-opening,
no soldering. Every approach below works with the existing factory cable
on a stock device.

In normal mode, the Instinct gen-1 exposes ONLY a USB Mass Storage
interface (class 8, subclass 6 SCSI, protocol 80 BBB; idVendor=0x091E,
idProduct=0x0C36, bcdDevice=0x0509). No vendor-specific bulk channel.
Modern Garmin watches deprecated the legacy "GARMIN USB Protocol"
(pygarmin / gpsbabel / libgarmin target). Implication: in normal mode,
our entire command channel to the watch is *files we drop onto the FAT
volume*.

What the firmware accepts via the FAT channel (from in-firmware path
strings):

- `0:/GARMIN/GUPDATE.GCD`               main firmware
- `0:/GARMIN/REMOTESW/*.GCD`            accessory firmware (HRM, sensors)
- `0:/GARMIN/REMOTESW/EPO.BIN` / `EPOB.BIN`  GPS aiding ephemeris
- `0:/GARMIN/Text/<lang>.ln3`           translation strings
- `0:/GARMIN/gmaptz.img`                map/timezone data
- `0:/GARMIN/NewFiles/`                 FIT/GPX upload buffer
- `0:/GARMIN/Settings/`, `Sports/`, `Workouts/`, `Schedule/`,
  `Courses/`, `Location/`              user-data files

Stage 5 plan:

- [x] Establish a SHA-256 baseline of every byte on the device
  (`~/garmin_recon/snapshot_2026-04-28.sha256` — 103 files). Diff after
  every experiment.
- [ ] Round-trip our own signed 19.10 GCD: copy it to
  `/Volumes/GARMIN/GARMIN/GUPDATE.GCD`, eject, observe the watch's
  update flow (idempotent — re-flashes the same version), wait for
  re-mount, diff. This proves the cable update channel works.
- [ ] Backdate test: drop the 19.01 GCD instead. Watch should accept
  (signed by Garmin). After re-mount + visual confirmation, restore by
  dropping 19.10 again. Reversible. Confirms version-comparison logic
  is permissive in *both* directions for legitimate signed images.
- [ ] Acceptance-edge probe (gated): drop a *wrong-PartNumber* but
  Garmin-signed GCD (e.g. our Sensor Hub GUP3294.GCD). The bootloader
  should reject it. If it accepts: that's an exploitable mismatch. We
  test on the backdate version first so a misbehaving accept is
  recoverable.

### Stage 6 — Bootloader mode (different USB descriptor set)

- [ ] Discover the button-combo that puts the Instinct gen-1 into
  bootloader / DFU / recovery mode at power-on. Garmin uses
  device-specific combos; community reverse-engineering exists for FR
  and Fenix lines. Specifically what to test on the Instinct: power-on
  while holding GPS button, while holding SET, while holding both.
- [ ] In bootloader mode, re-run the descriptor enumeration. Expect a
  *different* `idProduct` (Garmin convention is base-PN ± constant) and
  possibly a vendor-specific bulk interface in addition to / instead of
  Mass Storage.
- [ ] If a vendor-specific interface appears: build a Rail-native USB
  client over libusb FFI, enumerate the command verbs. The bootloader
  protocol is much more constrained than the application's USB protocol
  — typically: identify, erase, write block, finalize. All gated by
  signature verification at the chip's mask ROM.

### Stage 7 — Acceptance fuzzing on Backdate (gated)

- [ ] With the backdate restore-path proven, fuzz the GCD acceptance
  surface: corrupted CheckPoint records, mismatched stream IDs,
  truncated firmware data records, wrong HWID in the descriptor,
  multiple firmware streams of conflicting versions. Goal: find a
  malformed-but-accepted edge that lets us deliver custom code.
  Recoverable via backdate.

### Stage 8 — Rail on the chip (path A: signed)

If acceptance fuzzing yields nothing exploitable, the cable-only path
hits a ceiling at "load any signed Garmin GCD; cannot load unsigned
code". That's still a win for *some* applications:

- [ ] Build alternate signed GCDs for the watch by combining streams
  from different official Garmin firmwares (legal: we don't sign
  anything; the bootloader sees Garmin's signatures). Useful for
  forced-version research and parameter studies.
- [ ] Document precisely what the bootloader rejects vs accepts.

### Stage 9 — Rail on the chip (path B: unsigned)

This stage requires unsigned-code execution. Three sub-paths, all of
which require either a software exploit found in Stage 7 or, failing
that, hardware. Hardware path is OUT OF SCOPE while the watch stays
sealed:

- [ ] Path B1: signed-image vulnerability discovery (long-tail Stage 7
  result).
- [ ] Path B2: pair a *second* identical Instinct gen-1 (cheap on used
  market, ~$100) to run hardware experiments without compromising the
  user's daily watch. Then SWD / glitch attacks are back on the table —
  on the donor unit only.

### Stage 10 — Rail user-space on a signed shell

Even without unsigned-code execution, "Rail running on the watch" can
mean a Rail program shipped *inside* the official Garmin update path:
a Rail-compiled module that the application firmware loads and calls,
distributed as a Connect-IQ-style sandbox if the platform allows. The
Instinct gen-1 unfortunately doesn't ship Connect IQ. So this stage is
deferred unless we make a Connect IQ device a future target.

### Stage 11 — Rail-built watchface on the chip (the trophy)

Same as old Stage 7 (Rail compiler Cortex-M Thumb-2 backend, bare-metal
runtime, drivers for display/buttons/IMU/baro/GPS/HR/BLE, then a Rail
watchface). Now correctly placed AFTER the unsigned-code-execution
gate, not before.

## What ships *this session* (ambitious targets)

1. This plan doc.
2. Read-only snapshot of the mounted volume + hashes.
3. SoC identification (or strongest-public-evidence guess).
4. Pull a real `GUPDATE.GCD` for our exact device.
5. `stdlib/gcd.rail` — parser.
6. `tools/garmin/fw_extract.rail` — region extractor.
7. `tools/garmin/fw_recon.rail` — entropy / strings / ISA-id.
8. `tools/garmin/disasm_*.rail` — minimal disassembler for the identified
   ISA, enough to map the vector table and a handful of functions.
9. Findings doc with: SoC, RTOS guess, GCD layout, vector table address,
   sig-verify location candidate, public-key candidate.

## Stretch this session

- Locate the embedded sig-verify public key concretely.
- Identify the SHA-256 K-table location (confirms the hash algorithm).
- Map the USB Mass Storage handler (the part of firmware that backs what
  we've already been reading via Phase 1).
- Find debug / printf strings for RTOS / SDK identification.

## Out of scope this session

- Opening the watch case.
- SWD / JTAG / fault injection.
- Cortex-M backend in the Rail compiler.
- Bare-metal Rail runtime.
- Booting our own code on the device.

These are real future work, not paper plans. They want their own sessions
with hardware on the bench and a longer arc to first-light. The point of this
session is to make all of them tractable by knowing exactly what we're
attacking.

## Trophy criterion

Session 1 succeeds if, by end of session, we can answer:

- *What chip is in the watch?* (named SoC + BLE radio if separate)
- *What format is its firmware?* (GCD layout fully parsed, regions extracted)
- *What signs the firmware?* (algorithm + likely key location)
- *What's the first instruction the CPU executes from cold boot?*
  (Reset_Handler address)

If we have those four answers and the Rail tooling that produced them, every
subsequent session has a runway. If we don't, we know where the gaps are.
