# Agent D — MaxArm protocol driver + integration (worktree-isolated brief)

You are Agent D in a 4-agent parallel build of Spur-arm. The overall
plan is in `notes/railarm4agent/README.md`; the research synthesis is
in `notes/railarm4agent/RESEARCH.md`. Read both before starting. Then
read THIS file end-to-end before writing any code.

You own the physical hardware path. You run **fully parallel** to
Agents A/B/C — none of them depend on you, and you depend on none of
them (the DSL is already frozen). Your output is the hardware demo:
`talk_arm.sh` driving a real Hiwonder MaxArm.

---

## Mission

Build a pure-Rail USB-serial driver for the Hiwonder MaxArm such that:

1. Every Cmd in our DSL (`MoveTo x y z`, `SetGrip GripOpen|Close`,
   `Wait ms`, `Home`) translates to a physical arm action.
2. `talk_arm.sh` is a drop-in replacement for `talk.sh` that operates
   the real arm via the same conversational REPL.
3. The driver is honest about state: queries arm position, reports
   faults, refuses unsafe commands.
4. End-to-end demo: user says "grab the red block and put it on the
   green block," arm does it.

You may start the moment this session begins — you don't need Agents
A/B/C's outputs. (You may want to use the substrate via
`tools/robot/call_substrate.sh` for an early end-to-end demo before
Spur-arm-v1 is trained.)

---

## Required reading before starting

1. `notes/railarm4agent/README.md` — overall plan, hardware specs
2. `tools/robot/arm_sim.rail` — the interface you'll mirror
3. `tools/robot/talk.sh` — the REPL you'll variant
4. `stdlib/robot_arm.rail` — DSL definitions
5. `tools/robot/grader.rail` — state-machine reference
6. Memory: `feedback_no_c_in_rail_work` — pure Rail (or asm
   unavoidable), never C bridges
7. Memory: `feedback_verify_removals` — when removing a safety check,
   write the falsifying smoke test FIRST
8. Memory: `feedback_diagnostics_first` — counters before changing
   anything
9. Memory: `Garmin Phase 1 shipped` (`garmin_phase1`) — example of
   USB-device driver in pure Rail (FIT decoder); pattern to copy

---

## Architecture

```
                              ┌────────────────────────┐
                              │   talk_arm.sh (REPL)   │
                              │                        │
                              │   user types ─────────┐│
                              │                        ↓│
                              │   substrate or Spur-arm│
                              │   emits script         │
                              └────────────┬───────────┘
                                           │ script = [Cmd, ...]
                                           ▼
                              ┌────────────────────────┐
                              │ tools/robot/arm_real   │
                              │   .rail (interpreter)  │
                              │                        │
                              │ for each Cmd:          │
                              │   IK if MoveTo         │
                              │   serial framing       │
                              │   send to ESP32        │
                              │   wait for ack         │
                              │   update tracked state │
                              └────────────┬───────────┘
                                           │ Hiwonder LX-bus or HTTP-like commands over USB-CDC
                                           ▼
                              ┌────────────────────────┐
                              │  /dev/cu.usbserial-*   │
                              │  (MaxArm ESP32)        │
                              └────────────────────────┘
```

---

## Deliverables (every one of these is required)

### Files

```
stdlib/
└── usb_serial.rail            # pure-Rail USB-CDC serial open/read/write/close (if not already exists)

tools/robot/
├── arm_real.rail              # the protocol driver + Cmd interpreter; library, no main
├── arm_real_smoke.rail        # smoke tests (some run dry, some require connected arm)
├── coord_map.rail             # DSL int coords → arm joint targets (4-DOF IK)
├── calibrate.rail             # one-time named-point calibration; persists to ~/.robot/maxarm_calib.txt
├── talk_arm.sh                # variant of talk.sh that uses arm_real.rail instead of arm_sim.rail
├── replay_cmd_log.sh          # replays /tmp/arm_commands.log against real arm
└── safety.rail                # workspace-clip + velocity-cap + e-stop helpers

notes/
└── maxarm_protocol.md         # protocol research findings (deliverable in itself; see Phase 1)
```

---

## Phase 1: protocol research (do this FIRST)

The Hiwonder MaxArm uses a proprietary serial command set. The exact
shape is not in our memory or research reports. Before writing code,
spend 1–3 hours producing `notes/maxarm_protocol.md` containing:

1. **Source identification**: which Hiwonder firmware is on this arm?
   The Amazon listing shows ESP32; Hiwonder's MaxArm typically ships
   with one of:
   - "ROS expansion board" firmware using their JSON protocol
   - The "MasterPi" / hiwonder-common LX bus serial protocol
   - Custom ESP32 firmware with their MicroPython interpreter
2. **Where to find the protocol spec**: Hiwonder's public docs
   (https://www.hiwonder.com/, MaxArm product page),
   their official Python SDK on GitHub (search "Hiwonder MaxArm"),
   community ports (LeRobot, Arduino libraries, etc.), reverse
   engineering via `screen /dev/cu.usbserial-* 115200` and inspecting
   what their official app sends.
3. **Frame format**: byte layout of a single command (header bytes,
   length, command ID, payload, checksum).
4. **Command set table**: at minimum, find:
   - Move joint to angle (J1, J2, J3, optionally rotation J4)
   - Read current joint angles
   - Vacuum on / off (gripper)
   - Read end-effector position (if firmware computes FK)
   - Set move duration / speed
   - Stop / e-stop
5. **Coordinate frame**: where is the origin, which axis is which?
   How does the arm's native joint frame relate to a cartesian
   end-effector frame?
6. **Baud rate, parity, flow control** for serial.

Write this up in `notes/maxarm_protocol.md`. **Stop and ask the user
to confirm** before proceeding to Phase 2 if anything is ambiguous —
guessing protocol bytes wastes hours.

---

## Phase 2: pure-Rail USB-serial driver

### `stdlib/usb_serial.rail`

If a pure-Rail USB-CDC driver doesn't already exist (check
`stdlib/file.rail` and Garmin phase 1 code in `tools/garmin/`),
build one. macOS exposes USB-CDC as a tty device at
`/dev/cu.usbserial-*` — open as a file, but you also need `termios`
to set baud rate / raw mode.

Two options:
- **A**: Use the FFI we have to call `tcsetattr` on the fd, then plain
  `read`/`write` work. ~30 lines of asm in `tools/macos_ffi/` if not
  already linked.
- **B**: Send `stty` commands via `shell` to configure the port before
  Rail opens it. Less elegant but no new FFI. Acceptable if A is
  blocked.

Functions to expose:
```rail
serial_open path baud         -- returns fd
serial_write fd bytes_string  -- returns bytes_written
serial_read fd max_bytes      -- returns bytes_string (may be shorter)
serial_drain fd               -- block until tx buffer empty
serial_close fd
```

### `tools/robot/arm_real.rail`

The interpreter. Same Cmd interface as `arm_sim.rail` so the grader
works unchanged. Required entry points:

```rail
arm_open  -- returns arm handle, opens serial, reads initial state
arm_close arm
arm_run_script arm script  -- thread through each Cmd, return state after
arm_query_state arm  -- returns state in arm_sim.rail's 9-int format
arm_emergency_stop arm  -- e-stop, vacuum off, hold joints

-- Library-compatible aliases so existing arm_sim callers can swap:
run_sim_from_state script ax ay az grip held obx oby obz present
  -- but this version drives the REAL arm; obx/oby/obz/present are now
  -- "where the user TOLD me the ball is" and the arm trusts that
```

Per-Cmd implementation:
- `MoveTo x y z`: convert to joint angles via `coord_map.rail::ik`,
  send move-joint command, wait for ack OR for `serial_read` to return
  a "move complete" message
- `SetGrip GripClose`: send vacuum-on command, wait 200 ms for suction
  to engage
- `SetGrip GripOpen`: send vacuum-off command, wait 200 ms for release
- `Wait ms`: literal sleep (use existing `stdlib/time_us.rail` or
  shell sleep)
- `Home`: send move-joint command to all-zero / safe-rest pose

Each command must update the tracked state (ex, ey, ez, grip, held)
honestly. If the arm reports a fault (out-of-reach joint angle,
collision detect), set the fault code per `arm_sim.rail`'s convention.

### `tools/robot/coord_map.rail` (IK)

4-DOF arms have closed-form inverse kinematics. The MaxArm geometry
(per the Amazon listing dimensions):
- Base rotation joint (J1): yaw, ±120°
- Shoulder pitch (J2): from the 287mm reach diagram
- Elbow pitch (J3): from the same diagram
- End-effector (J4): wrist pitch or vacuum mount (depending on
  variant — protocol research will tell us)

Workspace: 290mm radius × 187mm above + 111mm below base.

For Spur-arm v0 DSL coords (0–30 cm cube):
- Map (x, y, z) DSL coords to (X, Y, Z) world mm: `X = (x - 15) * 10`,
  `Y = y * 10`, `Z = z * 10` (placing the workspace center 15 cm to
  the right of the arm base; tune in calibration)
- Compute IK to (J1, J2, J3, J4) joint angles
- Reject if any joint exceeds physical limits or if the position is
  outside reachable workspace — return fault code 1 (out-of-bounds)

Use a tested IK library reference (e.g., a paper or textbook 4-DOF
arm IK derivation) and unit-test against known positions before
running on hardware. Don't ship un-validated IK to a physical motor.

### `tools/robot/calibrate.rail`

One-time interactive routine:

1. User says "OK arm at named point A"
2. Driver records the current joint angles as A's calibration
3. Repeat for B, C, D, ORIGIN
4. Persist to `~/.robot/maxarm_calib.txt`

On startup of `talk_arm.sh`, if the calibration file is missing or
stale (>30 days old), prompt the user to recalibrate.

Without calibration, the IK uses the default mapping. With
calibration, the IK uses calibrated offsets — robustness against
mounting variation.

### `tools/robot/safety.rail`

- Workspace clip: any (X, Y, Z) outside the physical reachable cone
  is clipped to the nearest valid point AND a warning is emitted.
- Velocity cap: `move duration ≥ 500 ms` (no jerky movements).
- E-stop on fault: if 2 consecutive commands fault, halt and require
  user confirmation to resume.
- Vacuum auto-off: if grip stays closed for >30 sec with `held=0`
  (vacuum on, nothing held = leak / motor strain), auto-release.

---

## Phase 3: `talk_arm.sh` integration

Variant of `talk.sh` with these changes:
- Import `arm_real.rail` instead of `arm_sim.rail` in the candidate template
- Open the arm on startup, e-stop on Ctrl-C
- After each script execution, query the real arm's state via
  `arm_query_state` and update the world file
- Add slash command `/calibrate` to enter calibration mode
- Add slash command `/estop` for immediate halt
- Add slash command `/home` to send the arm to safe-rest pose

The conversational engine can be EITHER:
- Substrate (`call_substrate.sh`) — works today, lets you demo before
  Spur-arm-v1 is trained
- Spur-arm-v1 inference (after Agent C integration) — drop-in via
  flag `SPURARM_ENDPOINT=local:1234` to a local Rail HTTP server

For Agent D's acceptance test, EITHER engine is fine. The integration
session swaps in Spur-arm.

---

## Phase 4: replay_cmd_log

```bash
sh tools/robot/replay_cmd_log.sh /tmp/arm_commands.log
```

Reads each `[CMDS]` line from the log file produced by `talk.sh` /
`talk_arm.sh` and re-executes it on the connected arm. Smoke test
mode (`--dry-run` flag) prints each Cmd without sending.

This is the smoke test the user can run independently to verify the
arm behaves as expected.

---

## Acceptance test

### Without physical arm (Phase 1-2 done, no MaxArm connected yet)

```bash
# Protocol doc written
test -s notes/maxarm_protocol.md
# Driver compiles
./rail_native tools/robot/arm_real.rail 2>&1 | grep -E "OK|warning"
# Smoke harness in dry-run mode
./rail_native run tools/robot/arm_real_smoke.rail --dry-run
# IK unit tests pass
./rail_native run tools/robot/coord_map.rail --test
# expects: 12/12 known-position round-trips pass (DSL coord → joints → forward kinematics → DSL coord within ±1 cm)
```

**INCONCLUSIVE PASS** for the without-arm case.

### With physical arm connected

```bash
# Arm enumerates as a serial device
ls /dev/cu.usbserial-* 2>&1
# Driver opens and reads initial state
./rail_native run tools/robot/arm_real_smoke.rail --connect
# expects: "arm connected fd=... initial_state=..."

# Calibration
./rail_native run tools/robot/calibrate.rail
# walk through A/B/C/D/ORIGIN; persists calibration file

# Replay the prior session's log against the arm
sh tools/robot/replay_cmd_log.sh /tmp/arm_commands.log
# expects: arm physically executes prior session's "grab the ball" sequence

# Conversational REPL on real arm
bash tools/robot/talk_arm.sh
> grab the red block
# expects: arm moves to the block, vacuum engages, block lifts
> put it on the green block
# expects: arm stacks
> /quit
```

**PASS** if all three with-arm operations work.

**INCONCLUSIVE** if hardware hasn't shipped yet but everything except
the physical operations passes — chain entry notes "real-arm
acceptance pending" with reproducer commands.

**FAIL** if the protocol turns out to be undocumented and a bus-sniff
session is needed — escalate to user.

---

## Chain entry

On completion, append chain entry with parent `66bb63f9`. cmd points
to `tools/lab/watchers/spurarm_arm_d.sh`:

```
===RAIL_LAB_COUNTERS===
{"counter": "protocol_documented", "value": <0|1>}
{"counter": "ik_unit_test_pass_rate_pct", "value": <0..100>}
{"counter": "physical_arm_connected", "value": <0|1>}
{"counter": "replay_pass", "value": <0|1>}
{"counter": "live_repl_pass", "value": <0|1>}
===END===
===VERDICT=== <PASS|INCONCLUSIVE|FALSIFIED>
```

---

## Out of scope for Agent D

- Tokenizer / model / RL (Agents A/B/C)
- Bench v1+ prompts (separate arc)
- Multi-arm coordination (this is a single-arm demo)
- Vision (the model reads world state from REPL, not pixels)
- ROS / MoveIt integration (overkill; we own the protocol layer)
- Voice STT (separate arc)
- If you can't find the protocol, DO NOT reverse-engineer it
  destructively — escalate to user. The arm is the user's; don't
  risk bricking it.

---

## Discipline reminders

- **Phase 1 BEFORE Phase 2**: don't write protocol bytes from
  imagination. Document first, code second.
- **Per `feedback_no_c_in_rail_work`**: pure Rail (or asm where
  unavoidable), no C bridges. macOS termios via FFI shim is asm-class.
- **Per `feedback_verify_removals`**: before removing any safety check
  (workspace clip, velocity cap, e-stop), write the falsifying smoke
  test FIRST. Born from float-TCO 17-day silent corruption.
- **Per `feedback_diagnostics_first`**: counters for joint
  positions, command latency, fault rate before tuning.
- **IK unit tests**: 12 round-trip tests on paper-known coords BEFORE
  any hardware run. A bad IK on a real motor breaks plastic.
- **E-stop is non-negotiable**: every motion must be cancellable.
  Ctrl-C in `talk_arm.sh` halts the arm in <100 ms.
- **`incremental_testing`**: dry-run → loopback (USB connected but
  arm powered OFF) → arm powered ON with manual position-hold → full
  motion. Don't skip stages.
- **macOS USB device permissions**: the user may need to grant terminal
  access to USB devices in System Preferences. Document this in the
  README.
- **No mutations to existing files** except adding entries to
  `tools/lab/watchers/`. The DSL (`stdlib/robot_arm.rail`), sim
  (`tools/robot/arm_sim.rail`), grader (`tools/robot/grader.rail`),
  and talk.sh are FROZEN.
- **No commits to main**: stage on `spurarm/D-maxarm` branch.

---

## Estimated effort

6–10 hours. Bottlenecks (in likely order):
- Protocol research (1–3 h, possibly longer if undocumented)
- USB-serial open/read/write in pure Rail with termios (1–2 h)
- IK derivation + unit tests (1–2 h)
- Command-set implementation + ack handling (1–2 h)
- Calibration + safety + talk_arm.sh (1 h)
- Acceptance test with physical arm (0.5–1 h, dependent on hardware)

If you exceed 15 hours and protocol is still uncracked, escalate.
The user has authority to decide whether to invest more time, switch
arms, or descope to a vendor-SDK-bridged approach (which would
violate the "pure Rail" goal but is a valid emergency exit).

---

## Hardware-acquisition checklist (for the user)

These are not Agent D tasks but the user needs them done before the
physical-arm acceptance test runs:

- [ ] MaxArm physically delivered + assembled
- [ ] USB cable connecting MaxArm to Studio (or Mini)
- [ ] 12V 5A power supply plugged in
- [ ] First boot: confirm the arm wakes, observe default pose
- [ ] Identify which `/dev/cu.usbserial-*` device the arm enumerates as
- [ ] Test connection with vendor's app or Python SDK to confirm
      protocol is intact and arm responds
- [ ] If using Studio with Apple Silicon: verify macOS USB driver
      support for the specific ESP32 chip (CH340, CP2102, or
      Apple-native CDC) — most likely CH340 needing a Mac driver
- [ ] Workspace clear of obstacles
- [ ] 3 cm blocks placed at named points A, B, C, D for the demo

Once these are done, Agent D's physical-arm acceptance test can run.
