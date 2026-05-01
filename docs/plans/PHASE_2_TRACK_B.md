# Phase 2 Track B — Parser fuzz campaign on the sealed Instinct

The "find a way in" track. Goal: identify a memory-corruption bug in
one of the running firmware's FAT-file parsers that we can chain into
arbitrary code execution. Once we have code-exec, Track A's payload runs.

The user's watch stays sealed. No SWD, no case-opening. Every test is
recoverable via the 19.10 / 19.01 backdate path established in Stage 5.

## Targets, in order

1. **FIT files** — primary target. We own the format (Phase 1's decoder).
   Drop crafted `.fit` files in `0:/GARMIN/NewFiles/`. The watch parses
   them on next boot. The firmware writes errors to
   `0:/Garmin/Debug/err_log.txt` (string verified in disassembly), giving
   us a crash oracle without a debugger.
2. **`.ln3` translation files** — proprietary Garmin format,
   substantially less audited than FIT. Loaded on language change.
3. **`gmaptz.img`** — Garmin IMG format, partial public reverse
   engineering. Loaded at startup. May only parse a small header
   pre-mount, limiting our reach.
4. **GCD bootloader header** — highest value, most dangerous. Forum
   reports of malformed headers bricking units mean *something* there
   crashes BEFORE sig-verify finishes. We test only on the 19.01
   backdate (recoverable via re-pushing 19.10).

## Mutation strategies (per format)

### FIT corruption knobs

For each baseline FIT (a known-good 1-record activity):

- **F-DEF-0**: definition-message `total_size` set to {0, 1, 65535, MAX_U16}.
- **F-DEF-1**: definition-message claims N fields but only N-1 follow before
  next record header.
- **F-DEF-2**: two definition messages reuse the same local_id with
  conflicting schemas; first matching data record's interpretation
  depends on which is "current".
- **F-FLD-0**: field type that doesn't match its size byte
  (e.g. base_type=uint32 with size=1).
- **F-FLD-1**: string field with no NUL terminator running off the end
  of the data record.
- **F-FLD-2**: array field with element_count exceeding remaining data.
- **F-MSG-0**: data message whose size differs from the schema's
  `total_size`.
- **F-MSG-1**: data message referencing a local_id never defined.
- **F-COMP-0**: compressed-timestamp record with delta producing
  wraparound past 0xFFFFFFFF.
- **F-DEV-0**: developer-data field index off the end of the
  developer-data table.
- **F-CRC-0**: file-trailing CRC clearly wrong; do we even get parsed?
- **F-HDR-0**: header `data_size` larger than the actual file.
- **F-HDR-1**: header `data_size` smaller than the actual data.

Each mutation is one knob; we never combine. Goal is to attribute any
crash to a single corruption.

### `.ln3` corruption knobs

(Format-specific; needs a brief reverse-engineering session before
mutating. Stub for now.)

### `gmaptz.img` corruption knobs

(Same — stub.)

### GCD header (HIGH RISK, 19.01 backdate only)

- **G-HDR-0**: bad signature ("GORMIN" instead of "GARMIN"). Should be
  rejected pre-records-loop.
- **G-HDR-1**: version 0xFFFF.
- **G-REC-0**: oversized CheckPoint length (claims 65000 bytes but
  followed by a normal record).
- **G-REC-1**: zero-length firmware data record.
- **G-DESC-0**: Firmware Descriptor Type schema reusing same field-id
  with conflicting types.
- **G-FLOW-0**: End record `0xFFFF` mid-file followed by more records.

## Harness (`tools/garmin/fuzz_harness.sh`)

Per cycle:

1. Pick the next mutation from the corpus index file.
2. Compute pre-state: SHA-256 of every file currently on
   `/Volumes/GARMIN/`, plus a copy of `Garmin/Debug/err_log.txt` if
   present.
3. Stage the mutated file in the appropriate watch directory
   (`NewFiles/` for FIT, `Text/` for .ln3, `GARMIN/` for `gmaptz.img`,
   `GARMIN/GUPDATE.GCD` for GCD-header tests).
4. Print: "EJECT THE WATCH NOW. Wait for it to reboot and re-mount,
   then press Enter."
5. User ejects + the watch reboots + re-mounts.
6. Compute post-state. Diff.
7. Pull `Garmin/Debug/err_log.txt`. Diff against pre.
8. Archive: pre-snapshot, post-snapshot, mutation file, log diff,
   into `~/garmin_recon/fuzz/<format>/cycle_<n>/`.
9. Categorise:
   - "ignored" — no err_log entry, no behaviour change
   - "rejected" — err_log entry but watch boots normally
   - "crashed" — err_log entry with stack trace, but watch recovers
   - "stuck"   — watch fails to re-mount after eject; user power-cycles
   - "exploited" — anything else weird (wrong screen content, persistent
     state change, behaviour drift)
10. Loop.

## Success criteria

A mutation is "interesting" if it produces a `crashed` or `exploited`
classification. We then deep-dive: identify which parser, what corruption,
what the firmware's error path looked like, whether we can cause a
controllable crash (overwrite return address, jump to attacker-controlled
data, etc.).

A single controllable crash with attacker-controlled PC is the win
condition. From there we build a ROP chain that:

1. Reads `0:/GARMIN/RAIL_PAYLOAD.BIN` into RAM.
2. Branches to it with the appropriate Thumb bit.
3. Returns to the main firmware loop afterwards (so the watch keeps
   working as a watch, just briefly running our code).

The payload is whatever `tools/compile.rail` (Track A) emits.

## Cycle budget

Each test cycle is ~60–120 seconds (eject, watch reboots, re-mounts,
diff). At a leisurely pace we can run 20–40 cycles per session. Across
all four target formats with ~12 mutation strategies each, that's a
single corpus pass in 2–4 sessions. Realistic time-to-first-bug:
weeks-to-months, depending on how clean Garmin's parsers are.

## Parallel work

Track B runs as foreground when the user is ejecting; Track A's work
(compiler, runtime, drivers) fills the background between ejects.

## Files this track owns

```
tools/garmin/fuzz_fit.rail       # FIT mutator (TODO)
tools/garmin/fuzz_ln3.rail       # .ln3 mutator (TODO; needs RE first)
tools/garmin/fuzz_img.rail       # gmaptz.img mutator (TODO)
tools/garmin/fuzz_gcd.rail       # GCD header mutator (TODO; gated)
tools/garmin/fuzz_harness.sh     # eject-cycle orchestrator (TODO)
docs/plans/PHASE_2_TRACK_B.md    # this doc
~/garmin_recon/fuzz/             # corpus + per-cycle archives (out of tree)
```
