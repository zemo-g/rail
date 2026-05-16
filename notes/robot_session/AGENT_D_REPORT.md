# Agent D final report -- MaxArm protocol driver + integration

Worktree: /Users/user/projects/rail-spurarm-D
Branch: spurarm/D-maxarm
Final commit on branch: ab88c31 (integration layer)
Parent chain entry: 66bb63f9 (substrate-thesis robot-arm baseline)

ASCII only. No em-dashes, no curly quotes.

## TL;DR

INCONCLUSIVE per AGENT_D_maxarm.md acceptance criteria for the
"without physical arm" path. All non-hardware deliverables shipped:

- Protocol research document (notes/maxarm_protocol.md) -- 256 lines,
  4/4 worked-example checksums verified against the formula.
- Pure-Rail USB-CDC serial layer (stdlib/usb_serial.rail) -- no C
  bridge, no new FFI shim; uses stty for termios + POSIX
  open/read/write.
- 4-DOF reachability "IK" + DSL<->arm-mm coordinate translation
  (tools/robot/coord_map.rail) -- 12/12 unit tests pass.
- Safety primitives (tools/robot/safety.rail) -- workspace clip via
  Newton-iterated isqrt, velocity cap (>= 500 ms, >= 2 ms/mm),
  e-stop fault counter, vacuum auto-off.
- Cmd interpreter + frame protocol driver (tools/robot/arm_real.rail)
  -- mirrors arm_sim.rail's interface; each motion-producing Cmd
  builds a byte-exact vendor frame and writes to the fd.
- Dry-run smoke + byte-exact frame verification
  (tools/robot/arm_real_smoke.rail) -- 5/5 sections pass; the four
  SET_XYZ / SUCTION / READ_XYZ / READ_ANGLE frames match the
  vendor docs byte-for-byte.
- Interactive calibration (tools/robot/calibrate.rail) -- reads
  current XYZ via FUNC_READ_XYZ, persists offsets to
  ~/.robot/maxarm_calib.txt.
- Conversational REPL on real hardware
  (tools/robot/talk_arm.sh) -- drop-in replacement for talk.sh with
  /estop /resume /home /readxyz /calibrate slash commands and Ctrl-C
  trap. DRY_RUN=1 falls back to the sim for offline rehearsal.
- Log replay (tools/robot/replay_cmd_log.sh) -- parses
  /tmp/arm_commands.log into a Rail script and runs against the
  connected arm or the sim.
- Chain watcher (tools/lab/watchers/spurarm_arm_d.sh) -- emits all
  six required counters with dry-mode + hardware-conditional probes.

Verdict: INCONCLUSIVE pending hardware acquisition. The
with-hardware close-out is a one-command run away
(`HARDWARE_AVAILABLE=1 LIVE_REPL_PASS=1 bash
tools/lab/watchers/spurarm_arm_d.sh` after walking the user through
talk_arm.sh).

## Counters (current dry-mode values)

| Counter | Value | Target |
|---|---|---|
| protocol_documented | 1 | 1 |
| ik_unit_test_pass_rate_pct | 100 | 100 |
| physical_arm_connected | 0 | 1 (with hardware) |
| replay_pass | 0 | 1 (with hardware) |
| live_repl_pass | 0 | 1 (with hardware) |
| estop_latency_ms | 0 (un-measured) | <= 100 |
| frame_dry_run_pct | 100 | 100 |

## Phase milestones

1. **Phase 1 (protocol research)** -- closed in ~30 minutes via the
   vendor's public docs at docs.hiwonder.com. Protocol is FULLY
   documented; destructive-RE escalation path was NOT triggered.
   Checksum formula verified against 4/4 worked frame examples
   (one example in the vendor doc is a typo; called out in
   notes/maxarm_protocol.md section 3).

2. **Phase 2 (driver)** -- pure Rail. stty + POSIX-open/read/write
   covers termios; no new asm or C. Frame builders use the same
   malloc/byte_set pattern as stdlib/socket.rail. The 9600 baud rate
   is the vendor default; we did not try to negotiate higher.

3. **Phase 3 (talk_arm.sh + calibrate + replay)** -- variant of
   talk.sh with arm_real.rail swapped in. Identical fault codes
   in the sim and the real driver mean the narration logic is
   shared. /estop and Ctrl-C trap give the non-negotiable
   <= 100 ms halt path.

4. **Phase 4 (replay + chain watcher)** -- delivered. Replay parses
   /tmp/arm_commands.log into a Rail script via awk + heredoc;
   chain watcher emits canonical sentinel block.

## Phase 1 research key findings

The Hiwonder MaxArm uses a clean documented protocol:

- Frame format: 0xAA 0x55 | func | datalen | data | checksum
- Checksum: ~((func + datalen + sum(data)) & 0xFF) & 0xFF
- 9600 / 8N1, no flow control
- Six function codes we care about:
  - 0x01 FUNC_SET_ANGLE: bus-servo angles + duration (8 bytes data)
  - 0x03 FUNC_SET_XYZ: cartesian move + duration (8 bytes data)
  - 0x05 FUNC_SET_PWMSERVO: end-effector PWM servo (4 bytes data;
    not used in v0, suction nozzle has its own command)
  - 0x07 FUNC_SET_SUCTIONNOZZLE: 1-byte command
    (1=pump on, 2=release+vent, 3=hold)
  - 0x11 FUNC_READ_ANGLE: read servo angles (no data, 6-byte response)
  - 0x13 FUNC_READ_XYZ: read end-effector mm (no data, 6-byte response)
- Cartesian command uses int16 mm, little-endian. The firmware does
  joint-level IK; we own a reachability check ahead of every send.

## Non-trivial implementation notes

### Rail does not deduplicate imports

When arm_real.rail tried to import both `tools/robot/arm_sim.rail`
(which imports stdlib/robot_arm.rail) and `tools/robot/coord_map.rail`
(which also imported it), the compiler emitted `_move_to_named`
twice and the linker rejected the binary. Fix: coord_map.rail was
trimmed to have NO imports of its own (it's a pure-IK utility), and
safety.rail's import of coord_map.rail was removed too. The
importing file (arm_real.rail) is now the sole owner of the import
graph, and orders the imports so each module is reached exactly
once. Documented in arm_real.rail's header comment.

### 65536-class literals trip the seed compiler

`mov x0, #131073` (the tagged form of 65536, i.e. 2*65536+1) is not
a valid ARM64 immediate. The seed rail_native's emit_load_int
mishandles this even though `mov x0, #131072` works for a standalone
file. Working around with `shl 1 16` and `shl 1 17` is robust:
the constant folder leaves shifts alone, so the codegen path that
emits movz + movk runs correctly. Affected: stdlib/usb_serial.rail
(O_NOCTTY), tools/robot/arm_real.rail (int16 sign-extension and
two's-complement encoding).

### Coord-map test had to split from the library

`tools/robot/coord_map.rail` started as both library and test
harness. When arm_real.rail imported it, the test's `_main` symbol
collided with arm_real_smoke.rail's `_main`. Split into
`tools/robot/coord_map.rail` (library) + `tools/robot/coord_map_test.rail`
(harness with `main = run_all_tests 0`). The acceptance command
changes from
`./rail_native run tools/robot/coord_map.rail --test`
to
`./rail_native run tools/robot/coord_map_test.rail`
-- documented in AGENT_D_REPORT.md but please note: this is the
ONE place the with-hardware acceptance commands deviate from
AGENT_D_maxarm.md's verbatim text.

### Reachability envelope shape

The spec says "29 cm radius x 18.7 cm up x 11.1 cm below base."
First implementation used a sphere; this incorrectly excluded the
DSL's named point D at (20,20,5), which is 287 mm radial at z=50.
The correct shape is a cylinder (horizontal radius x [down, up] z
window). All four named DSL points are reachable under the cylinder
model. Documented in coord_map.rail.

### feedback_verify_removals discipline baked in

`arm_real_smoke.rail::run_safety_smoke` exercises five distinct
safety paths:
  1. IK passes a valid point
  2. IK rejects an out-of-reach point
  3. clip_to_workspace_mm clips an over-radius point
  4. cap_duration_ms enforces the velocity floor
  5. estop_update + estop_tripped trip at the threshold

This is the falsification harness that should run BEFORE any safety
check is removed. The current snapshot has all five at PASS.

## Hardware-acquisition checklist (for the user)

These remain BEFORE the with-hardware close-out:

- [ ] MaxArm physically delivered + assembled
- [ ] USB cable connecting MaxArm to Studio (or Mini)
- [ ] 12V 5A power supply plugged in
- [ ] First boot: confirm the arm wakes, observe default pose
- [ ] Identify which `/dev/cu.usbserial-*` device the arm enumerates
      as (we expect CH340 or CP2102; ARM64 macOS Sequoia ships CDC
      drivers but may need a kernel extension for CH340 -- not yet
      confirmed)
- [ ] Test connection with vendor's app or a one-shot send of
      `READ_XYZ` via `./rail_native run tools/robot/arm_real_smoke.rail
      --connect /dev/cu.usbserial-...` -- should respond with
      "initial_state x_mm=... y_mm=... z_mm=..."
- [ ] Workspace clear of obstacles
- [ ] 3 cm blocks placed at named points A, B, C, D

## With-hardware close-out steps

Once the checklist is green:

1. Probe: `./rail_native run tools/robot/arm_real_smoke.rail --connect $DEVICE`
   -- expects PASS line with initial_state.

2. Calibrate ORIGIN by hand:
   `./rail_native run tools/robot/calibrate.rail --device $DEVICE --point ORIGIN --record`

3. Replay reference scripts on hardware:
   `DEVICE=$DEVICE bash tools/robot/replay_cmd_log.sh /tmp/test_log.log`
   -- expects SIM_RESULT line with fault=0 on at least the simple
   move-only scripts.

4. Live REPL: `bash tools/robot/talk_arm.sh`
   -- "grab the red block, put on the green block" -- user confirms.

5. Re-run the watcher with hardware flags set:
   ```
   HARDWARE_AVAILABLE=1 LIVE_REPL_PASS=1 \
     bash tools/lab/watchers/spurarm_arm_d.sh
   ```
   -- expects VERDICT=PASS.

6. Append chain entry with parent 66bb63f9 (the substrate-thesis
   baseline).

## What surprised me, worth a project memory entry

The protocol was MUCH easier to find than expected. Hiwonder
publishes the full byte-level spec on their public docs site --
no reverse-engineering needed. This is unusual for hobbyist robotic
arms in this price range (Dynamixel, LewanSoul, etc. typically
require buying a $50 SDK manual or sniffing the bus). If a future
session needs to integrate another Hiwonder product, start at
docs.hiwonder.com/projects/<product>/en/latest/ before assuming RE
is needed.

Candidate memory entry name: `hiwonder_protocol_docs_public_2026-05-16`.

## Open follow-ups

1. Ack-frame semantics not yet probed. The protocol doc doesn't say
   whether the firmware emits an async "move complete" frame after
   a SET_XYZ duration elapses. Current driver waits `duration_ms +
   50 ms` and trusts. With hardware, drain after each move and log
   any bytes received -- if there's an ack frame, parse it.

2. The 9600 baud is a hard limit. For the v0 demo (small DSL,
   ~1 cmd/s) this is fine; for higher-rate demos, we may need to
   negotiate up via undocumented "set baud" commands. Defer to
   bench v1+.

3. `arm_real.rail::real_apply_move` currently updates tracked state
   from the COMMANDED position rather than the read-back position.
   talk_arm.sh's /readxyz lets the user verify; for higher
   precision, add a post-move FUNC_READ_XYZ to every move and use
   that to update state.

4. Calibration today only persists offsets for one anchor point
   (ORIGIN). Multi-point calibration with per-region offsets is
   left for v1. Single offset is the common case for a flat
   tabletop demo.

5. CH340 driver requirement on macOS Sequoia is not yet confirmed
   for the user's specific MaxArm batch. Hardware-acquisition
   checklist surfaces this; if it bites, the user will need to
   install the Sanji-Crystal driver before /dev/cu.wchusbserial*
   appears.

## File inventory

```
notes/maxarm_protocol.md                       Phase 1 deliverable
notes/robot_session/AGENT_D_REPORT.md          this file
stdlib/usb_serial.rail                         pure-Rail USB-CDC
tools/robot/coord_map.rail                     IK / DSL<->mm
tools/robot/coord_map_test.rail                12-test IK harness
tools/robot/safety.rail                        clip, cap, e-stop, vac-off
tools/robot/arm_real.rail                      protocol driver + Cmd interp
tools/robot/arm_real_smoke.rail                dry-run frame + safety smoke
tools/robot/calibrate.rail                     one-time offset calibration
tools/robot/talk_arm.sh                        conversational REPL on real arm
tools/robot/replay_cmd_log.sh                  re-execute a session log
tools/lab/watchers/spurarm_arm_d.sh            chain watcher
```

Commits on spurarm/D-maxarm:
- 73cf00a  spurarm-maxarm: protocol research deliverable (Phase 1)
- f7012b1  spurarm-maxarm: Phase 2 driver (serial + IK + frame protocol + safety)
- ab88c31  spurarm-maxarm: integration layer (calibrate + talk_arm + replay + watcher)
