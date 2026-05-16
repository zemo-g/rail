# Garmin Watch FIT-Parser Research — Findings Note

## Scope & Authorization

This is authorized own-device security research conducted on a personal Garmin Instinct (gen-1) watch, the researcher's own equipment, in support of a personal Phase 2 project (firmware understanding for eventual replacement). All findings below were obtained without remote access, without coordination with Garmin, and without testing against any other person's device. The watch was monitored for crashes/bricks across 38+ eject cycles; none were observed.

Reproduction requires physical access to the device, USB connection in Mass Storage mode, and the pure-Rail FIT toolchain in `tools/garmin/`. None of the findings below are remotely exploitable as documented; they describe local file-write primitives.

This note is a research artifact, not a vulnerability disclosure. If any finding warrants a coordinated disclosure decision, that's a separate workflow.

---

## Methodology

Pass 1–4 (prior sessions) mapped the watch's eight top-level dirs (`Activity/`, `Records/`, `Schedule/`, `Goals/`, `DeleteFiles/`, `NewFiles/`, `Workouts/`, `Settings/`) to behavior:

- "Consumer dirs" (`Activity/`, `Records/`, `Schedule/`, `Goals/`, `DeleteFiles/`) silently sweep unknown drops on remount. **Not parsers** — generic FAT cleanup. Identified during Pass 5 by null-result triage.
- Three real parsers identified: `NewFiles/` (production sync, hardened, exhausted), `Workouts/` (real parser, ~10 evnt-log lines per drop), `Settings/` (real parser, similar telemetry).
- A file-router function pinned at firmware offset `0x08CC58` via cross-reference of FIT/parser strings.

Pass 5 falsified a Pass-4 hypothesis (the consumer dirs being weak parsers) by pushing the same hostile drops through them and observing identical bit-floor noise regardless of content. This narrowed the campaign to the three real parsers.

Pass 6 (2026-04-29) shipped schema-rich mutations. Pass 7 (same day) shipped payload deep-probes targeting the canonical `workout_step.f[8]` slot.

Each pass uses an "eject-cycle" methodology: drop a mutated FIT into the target subdirectory, eject the watch (forces filesystem flush + parser engagement on remount), remount, snapshot all files for sha256-diff and EVNTLOGS-line-count diff, classify the drop. The auto-cycler shell scripts (`auto_cycler_p{5,6,7}.sh`) drive the queue; phase-A stages, phase-B verifies.

---

## Findings (Workouts/ surface)

### Primitive 1 — Workout sideload via `Workouts/` is a live primitive

A well-formed `.fit` workout file dropped into `/Volumes/GARMIN/GARMIN/Workouts/` is parsed by the watch on remount, normalized into the canonical workout schema, re-serialized, and persisted to the filesystem under a watch-chosen filename (`AAAAAAAAAAAAAAA_workout.fit` for our file_id-named drops). It survives power-cycle and remount; it appears in the watch's Workouts library; it is selectable for execution.

Reproducer: `tools/garmin/fuzz_fit_pass6.rail` → `mut_workout_basic` (15-byte name, sport=generic, 1 step claimed).

This is "feature, not bug" if you have a Garmin account and use Garmin Connect to push workouts. It is "primitive, not feature" because the same path accepts arbitrary content with hostile sentinels (Primitive 2) without authentication.

### Primitive 2 — `workout_step.f[8]` is a 200-byte verbatim controllable slot, ×50 steps = 10 KB per workout file

The canonical `workout_step` message (global_msg_num=27) defines field 8 as a 200-byte fixed-size string slot ("notes"). Pass 7 cycle 2 sent 50 workout_step records with f[8] filled with a cycling A..Z byte pattern. The persisted file (re-serialized by the watch's canonical parser) contains the bytes verbatim at the canonical f[8] offsets.

Verified in `~/garmin_recon/fuzz/p7_persisted/c2_notes_pattern.fit` at offset 0x110+:
```
00000110: 0000 0000 0000 4142 4344 4546 4748 494a  ......ABCDEFGHIJ
00000120: 4b4c 4d4e 4f50 5152 5354 5556 5758 595a  KLMNOPQRSTUVWXYZ
```

Pass 7 cycle 4 confirmed format-string bytes (`%n%x%n%x...`) survive identically. No scrubbing or normalization of notes content.

### Primitive 3 — No value-domain validation on canonical `workout_step` fields

Pass 7 cycle 3 set every canonical `workout_step` field (17 of them) to invalid sentinels (`0xFF`/`0xFFFFFFFF`/`0xFFFF`). All 50 step records persisted intact. The watch's parser accepts:
- `target_value = 0xFFFFFFFF`
- `target_type = 0xFF`
- `intensity = 0xFF`
- `duration_value = 0xFFFFFFFF`
- and similar for every other numeric field.

By contrast, Settings parser (Primitive 6 below) rejects out-of-range values for `user_profile` and `hr_zone` fields. The two parsers have divergent validation discipline despite living in the same firmware.

### Primitive 4 — `num_valid_steps` vs. record-count desync persists intact

Pass 7 cycle 5 emitted a workout message with `num_valid_steps = 5` but **50** actual workout_step records. The persisted file retains the contradiction: count=5, records=50. The watch's local parser does not enforce `num_valid_steps == record_count`.

Downstream consumer impact (untested, theoretical): any consumer that:
- trusts the count for buffer allocation but reads to EOF for records → potential overflow
- trusts the count for UI iteration → 45 records hidden / off-by-many
- trusts the records for canonical layout → desync at every step

Garmin Connect mobile sync, GCM cloud parsing, and downstream third-party tooling (e.g., Strava, TrainingPeaks, etc.) ingest these files. No tests have been performed against any of those.

### Primitive 5 — Watch's own serial number is leaked into every persisted workout file

The watch re-stamps the persisted file's `file_id` with its own `manufacturer/product/serial_number` regardless of what the source drop declared. Per the persisted Pass 6 file, `serial_number = 3422906732`. Anyone who recovers the file post-write gets the device serial. Trivial information leak by design.

Whether the device serial is a sensitive identifier in Garmin's threat model is a separate question.

### Primitive 6 — Oversize field declaration → silent truncation

Pass 7 cycle 6 declared `workout_step.f[8]` as 255 bytes (in the def message) instead of the canonical 200. The watch's parser accepted the def, presumably read 255 bytes per record, then re-serialized to canonical 200. The 55 extra bytes per step were dropped silently. No observable filesystem-visible overflow; no crash; no event-log entry.

This is an interesting partial-validation behavior: the schema gate accepts non-canonical sizes but silently normalizes during re-serialization. Whether the read path's 255-byte buffer is independent of the canonical 200-byte write path (and therefore potentially a heap-write past a 200-byte staging buffer) is unverified — would need firmware analysis or a different probe to confirm.

---

## Findings (Settings/ surface) — hardened

The settings parser (`Settings.fit`) does NOT exhibit the same value-domain laxity as the workout parser. Pass 6 cycles confirmed:

- **Hostile `user_profile`** (gender=2, age=255, weight=65535, height=0): all rejected at field validation. Persisted Settings.fit retains the watch's real values (gender=0, real birthdate epoch days, real resting_HR, etc.).
- **Hostile `hr_zone`** (5 zones in descending order, 250→100): rejected. Persisted hr_zone values remain ascending (117/137/156/176/195) — the watch's real zones.
- **Settings.fit hash changes on every drop** purely because the watch re-serializes with a fresh internal timestamp. The hash change is NOT evidence of value persistence; the bytes-decoded comparison shows our hostile values never landed.

Settings/ is therefore a closed surface for value-injection. The schema-passing gate is real.

---

## Negative Results (intentionally documented)

- **Consumer dirs are not parsers.** Pass 5 falsified the Pass-4 hypothesis. Don't waste cycles on `Activity/`, `Records/`, `Schedule/`, `Goals/`, `DeleteFiles/`.
- **NewFiles/ is hardened (production sync path).** All Pass 1–4 mutations rejected at gates. Exhausted as a fuzz target.
- **No crash observed across 38+ cycles.** Watch is healthy; bit-floor noise on EVNTLOGS is consistent with normal HWM heartbeat, not parser distress.
- **No remote attack surface here.** All primitives require physical USB connection in Mass Storage mode. No network surface implicated.

---

## Open Questions (Pass 8 territory)

The producer-side surface is well-mapped. What's unknown is consumer behavior:

1. **Does the watch UI render `workout_step` notes when displaying a workout?** If so, the format-string bytes from Pass 7 cycle 4 might trigger a printf-style sink crash (or not, if the UI uses a non-format string path). Single test = load the AAA workout in the watch UI, observe.
2. **Does Garmin Connect mobile sync pull these workout files?** Server-side parser behavior unknown. Outside the authorized scope of this research without explicit Garmin coordination — flagged as a future-work boundary.
3. **Does workout EXECUTION (start workout from menu) read notes or hit the count desync?** Potential trigger path that doesn't engage on parse-only.
4. **Does a malformed workout in Workouts/ cause boot-time crash if many are queued?** Untested. Watch survives one drop fine; resilience under 50+ AAA-named files unknown.
5. **Is Primitive 6's oversize-read independent of the canonical-write?** If the read buffer is a separate heap allocation, an out-of-bounds read might be possible. Would require firmware analysis.

---

## Reproducibility

All artifacts are in this repo (compiler, mutator, decoder, cycler) and `~/garmin_recon/fuzz/` (corpora, persisted samples, cycle dirs).

Key files:

| Artifact | Path |
|---|---|
| FIT decoder (header-level) | `stdlib/fit.rail` |
| FIT emitter | `stdlib/fit_emit.rail` |
| Pass 6 mutator | `tools/garmin/fuzz_fit_pass6.rail` |
| Pass 7 mutator | `tools/garmin/fuzz_fit_pass7.rail` |
| Auto-cycler (Pass 5/6/7) | `tools/garmin/auto_cycler_p{5,6,7}.sh` |
| Phase-A stage | `tools/garmin/fuzz_phase_a_dir_p{5,6,7}.sh` |
| Phase-B verify | `tools/garmin/fuzz_phase_b.sh` |
| Records-level decoder | `/tmp/p6_walk.rail` (one-shot) |
| Persisted samples (Pass 6) | `~/garmin_recon/fuzz/p6_persisted/` |
| Persisted samples (Pass 7) | `~/garmin_recon/fuzz/p7_persisted/c{1..6}_*.fit` |
| Per-cycle artifacts | `~/garmin_recon/fuzz/cycle_*/` |

Repro for Primitive 2 (workout f[8] payload survival):

```bash
# Build corpus
./rail_native run tools/garmin/fuzz_fit_pass7.rail
# Stage drop manually
cp ~/garmin_recon/fuzz/fit_corpus_p7/p7_notes_pattern.fit \
   /Volumes/GARMIN/GARMIN/Workouts/p7_notes_pattern.fit
# Eject, replug, remount
diskutil eject /Volumes/GARMIN
# (Wait for replug)
# Pull persisted file
cp /Volumes/GARMIN/GARMIN/Workouts/AAAAAAAAAAAAAAA_workout.fit /tmp/p7_check.fit
# Verify pattern bytes survived
xxd /tmp/p7_check.fit | grep -E "4142 4344 4546" | head -3
```

The `xxd` line should show `ABCDEFGHIJKLMNOP...` somewhere in the file at canonical f[8] offsets.

---

## Device Specificity

All findings to date are on a Garmin Instinct gen-1 (NRF52840 SoC, GarminOS-style stack confirmed via Sensor Hub firmware reverse). Whether they generalize to:

- **Other Instinct generations** (Instinct 2, Instinct Crossover): unknown. Same FIT format spec, likely same parser laxity, but firmware isn't shared.
- **Fenix series**: Fenix 6 main firmware was found encrypted (per `garmin_phase2.md`). Direct firmware diff not possible without decryption keys. Watch UI / parser behavior may diverge.
- **Forerunner/Edge/Vivosmart**: untested. Same FIT spec; production sync path is shared per Garmin's developer docs; per-device parser laxity unknown.

Treat all findings as device-specific until reproduced on a second Instinct gen-1 minimum.

---

## What This Note Is Not

- **Not** a CVE filing or security advisory. Findings are documented for the researcher's own reference and for accurate session-handoff continuity.
- **Not** instructions for attacking devices the researcher doesn't own. All primitives require physical USB Mass Storage access; nothing here remotely targets a device.
- **Not** a complete map of the firmware's attack surface. Three parsers found; one fully audited (NewFiles, exhausted); one mapped (Workouts, multiple primitives); one partially probed (Settings, value-domain hardened). Other surfaces (over-the-air sync, BLE, ANT+) not in scope.

---

## Status

- Pass 6 complete (6 cycles, decoded, summarized in memory `garmin_pass6_workout_sideload.md`).
- Pass 7 complete (6 cycles, decoded, summarized in memory `garmin_pass7_workout_payload.md`).
- Pass 8 (consumer-side rendering / sync interaction) not yet planned; gated on whether the open questions above are still in-scope for the project.

Last update: 2026-04-30.
