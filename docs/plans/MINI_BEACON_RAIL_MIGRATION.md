# Mini Session — Migrate the entropy beacon from Python to Rail

You are continuing the Rail compiler project from a fresh context. Read this whole document before touching anything.

## The motivation

The site (ledatic.org) is built on a thesis: *Rail runs on Rail. The rest runs on physics.* Plasma page advertises "Rail Runtime." Entropy page tells visitors a Rail-driven solver hashes plasma state into a public chain.

But the daemon **actually emitting pulses today is `tools/plasma/mhd_ot_beacon.py`** — Python. There's a perfectly good Rail solver at `tools/plasma/mhd.rail` (128² Orszag-Tang, conservation to 1e-15) sitting unused for the production hot path. Your job: **make the production beacon run on Rail end-to-end, retire the Python daemon.**

## Cold-start (do these first, in order)

1. `git fetch && git checkout master && git pull` on Mini's `~/projects/rail`. Confirm you have the recent compiler bug fixes (`77c4f5f` SIGSEGV, `f4f3e07` parser multi-line) and the `v3.6.1` CHANGELOG entry. Note original `rail_native` md5 — if the binary's broken, you're stuck before you start.
2. Read `~/.claude/projects/-Users-user/memory/MEMORY.md` and the memories it points at. Pay special attention to:
   - `rail_quirks.md` — multi-line parsing, helper-arity limits
   - `rail_native_gotchas.md` — re-sign after `cp`, no-args silent exit
   - `incremental_testing.md` — never launch long runs without staged short tests
   - `studio_xcode_toolchain.md` — relevant if you touch Metal-backed paths
3. Read these, in this order:
   - `tools/plasma/mhd_ot_beacon.py` — the **canonical reference for what to replicate**. This is the contract. Pulse format, frame format, hashing scheme, write cadence — all defined here.
   - `tools/plasma/mhd.rail` — the Rail solver you're going to wrap.
   - `~/projects/ledatic-site/worker/worker.js`, specifically the `/entropy/pulse` PUT handler around line 516 and `/entropy/frame/current` PUT around line 584. **This is the server contract.** Whatever your daemon writes must match.
   - `tools/plasma/PLASMA.md` for design notes on the solver.
4. Live-probe the existing endpoints to anchor what "correct output" looks like:
   ```
   curl -s https://ledatic.org/entropy/pulse | jq .
   curl -sI https://ledatic.org/entropy/frame/current | head
   ```
   Note the JSON keys, the frame's `Content-Type`, and the `Content-Length`. Your Rail daemon must produce the same shape.

## The contract you must match

### Pulse JSON (PUT to `/entropy/pulse`, header `x-beacon-token: $BEACON_TOKEN`)

```json
{
  "pulse_id": <int, monotonically increasing by 1>,
  "timestamp_utc": "<ISO8601 Z>",
  "unix_timestamp": <int seconds>,
  "value_hex": "<sha256_hex>",
  "prev_value_hex": "<sha256_hex of previous pulse's value_hex>",
  "source": {"type":"2D_MHD_OrszagTang","grid":"128x128","node":"mini"},
  "frame_bytes": <int>,
  "frame_url": "https://ledatic.org/entropy/frame/current",
  "version": "<string>"
}
```

`value_hex` is **SHA-256(prev_value_hex_bytes || state_hash_bytes)** where `state_hash` is **SHA-256(frame bytes)**. Confirm the exact byte ordering by reading the Python source — do not guess.

### Frame binary (PUT to `/entropy/frame/current`, same auth)

Per `_shared/site.js:340-360`, the frame is a 48-byte header followed by a payload:

- 4 × u32 (LE): `width`, `height`, `channels`, `step`
- 8 × f32 (LE): metrics (look at the Python emitter for which 8 — likely density min/max, energy, ∇·B, etc.)
- payload: `width × height × channels × sizeof(f32)` floats, density-first channel layout

Total bytes for 128×128×6×4 = 393216 + 48 header = **393264** (matches the live `frame_bytes` field).

### Auth

`BEACON_TOKEN` lives in `~/.ledatic/entropy/beacon_token` on Mini and is uploaded to the Worker as the `BEACON_TOKEN` env secret via `~/projects/ledatic-site/worker/deploy_worker.sh`. **You don't need to rotate it.** Just read the file in your daemon.

## What to do — phased, with gates

### Phase 1: read and reproduce

1. Run `python3 tools/plasma/mhd_ot_beacon.py` on Mini for ~30 seconds. Confirm the live `/entropy/pulse` is being written (pulse_id should be incrementing). This is your reference behavior.
2. Capture **5 consecutive** pulses to `/tmp/ref_pulses/{0,1,2,3,4}.json` and the corresponding frames to `/tmp/ref_frames/{0,1,2,3,4}.bin`. These are your golden outputs.
3. Document the byte-exact frame header layout in `/tmp/frame_format.md` based on what you read in `mhd_ot_beacon.py`. **Do not move on until you can describe the frame format in three sentences.**

### Phase 2: stand up the Rail driver

4. Create `tools/plasma/beacon_loop.rail` — the daemon shell. It imports `tools/plasma/mhd.rail`, drives it forward 1 step every 2 seconds, hashes the frame, builds the pulse JSON, and PUTs both to the Worker. Use:
   - `stdlib/sha256.rail` for SHA-256
   - `stdlib/https_client.rail` (the strict default `https_get_url` / `https_post_url`) for the PUTs — note the BEACON_TOKEN goes in a custom header, may need `stdlib/https_session.rail` for explicit header control
   - `stdlib/json_emit.rail` (or hand-roll `cat ["{\"pulse_id\":", show id, ...]`) for the JSON
5. Build it offline first — write to `/tmp/test_pulse.json` and `/tmp/test_frame.bin` instead of the live endpoint. **No live writes yet.**
6. Diff your output against the captured Phase-1 references:
   - `cmp /tmp/test_frame.bin /tmp/ref_frames/0.bin` — byte-identical (modulo the f32 metrics that legitimately drift between runs; pick one stable run to compare against)
   - `jq '. | del(.timestamp_utc, .unix_timestamp, .pulse_id, .value_hex, .prev_value_hex)' /tmp/test_pulse.json /tmp/ref_pulses/0.json | diff` — non-volatile fields must match exactly
7. **Gate: if your offline output doesn't match the reference shape, stop.** You're going to break the chain otherwise.

### Phase 3: shadow run

8. Wire the live PUTs but **point them at a shadow endpoint** — `/entropy/pulse_test` and `/entropy/frame_test`. Add temporary Worker handlers (and remove them when done) so you can observe your daemon's writes without disturbing production.
9. Let the shadow run for ~10 minutes. Walk the shadow chain with the same one-liner the public verifier uses:
   ```
   curl -s https://ledatic.org/entropy/pulse_test/log | jq -e '. as $l | all(range(1; length); $l[.].prev_value_hex == $l[.-1].value_hex)' && echo "shadow OK"
   ```
   (you'll need to wire `/entropy/pulse_test/log` similarly to the real one).
10. **Gate: shadow chain must hold for 300 consecutive pulses (10 minutes at 2s).** No skipped pulse_ids, no chain breaks. If you can't hold the shadow, the production swap will fail visibly.

### Phase 4: production swap

11. Stop `mhd_ot_beacon.py` (the existing process on Mini — find with `pgrep -f mhd_ot_beacon`, then `kill <pid>`).
12. Read the current `/entropy/pulse` once and use its `value_hex` as your daemon's initial `prev_value_hex` and `pulse_id + 1` as your starting id. **The chain must not skip.**
13. Start `beacon_loop.rail` in a launchd plist (or systemd-equivalent — match however `mhd_ot_beacon.py` was being supervised). Path: `~/Library/LaunchAgents/com.ledatic.beacon.plist` if launchd.
14. Watch `/entropy/pulse` for the next 60 seconds. Confirm pulses keep flowing, IDs keep incrementing.
15. Run the public verifier:
    ```
    curl -s https://ledatic.org/entropy/pulse/log | jq -e '. as $l | all(range(1; length); $l[.].prev_value_hex == $l[.-1].value_hex)' && echo "chain OK"
    ```
    **Gate: must return "chain OK".** If it doesn't, the swap broke the chain and the public site's verifier will say `chain BROKEN`. Restart the Python daemon as a rollback, fix offline, retry.
16. Watch the plasma page (`https://ledatic.org/plasma`) in a browser for 30 seconds. The canvas must render frames continuously. If it freezes, the frame format is wrong — rollback and fix.

### Phase 5: cleanup

17. Once the Rail daemon has been stable for 30 minutes, retire `mhd_ot_beacon.py`:
    - Move it to `tools/plasma/legacy/mhd_ot_beacon.py` so git history is preserved but it's clearly out-of-band.
    - Add a `tools/plasma/legacy/README.md` noting the migration date and the replacement path.
18. Update `tools/plasma/PLASMA.md` to point at `beacon_loop.rail` as the production driver.
19. Add a CHANGELOG entry — `v3.7.0 — 2026-MM-DD — Beacon migrated to Rail` — short bullets.
20. Run `gen_feed.rail` so `/feed.xml` picks up the new release. The site footer's `data-live="rail-version"` will pick up `v3.7.0` automatically on next page load.
21. Commit + push. One commit, clean message: `plasma: production entropy beacon now runs on Rail`.

## Hard rules

- **Don't break the chain.** The on-page verifier is currently `chain OK`. If your swap makes it `chain BROKEN`, the site loses credibility. Phases 2 and 3 exist specifically so this can't happen.
- **No live writes until Phase 4.** Offline + shadow only until you have proof the format is right.
- **Don't touch the Worker except for adding/removing the temporary `/entropy/pulse_test` shadow handlers.** No edits to the production `/entropy/pulse` PUT path; the contract stays fixed.
- **Don't skip hooks** (`--no-verify`), don't `--force` push, don't `--amend` pushed commits.
- **If the Rail solver's output doesn't match Python's bit-for-bit on the frame payload**, that's an algorithmic difference (Lax-Friedrichs flux ordering, boundary handling, etc.) — investigate before claiming success. The plasma canvas relies on the float layout being exactly what `_shared/site.js:initLiveMHD` expects.
- **If you find yourself rewriting the solver itself** (`mhd.rail`), stop. The solver is already known-good. The migration is *daemon shell only*: read state, hash, post. ~150 lines tops.

## Done criteria

- `/entropy/pulse` is written by a Rail daemon (`pgrep -f beacon_loop` returns a PID; `pgrep -f mhd_ot_beacon.py` returns nothing).
- 300+ consecutive pulses verify with the public chain-walk verifier.
- The plasma canvas renders smoothly for at least 60 seconds.
- The Python daemon is moved to `tools/plasma/legacy/` with a README.
- CHANGELOG entry committed; `gen_feed.rail` re-run; site footer updates to the new version.
- The site's "Read the solver" CTA on plasma.html (currently pointing at `mhd.rail`) is now accurate end-to-end — it links to the source that's actually emitting the live pulses.
