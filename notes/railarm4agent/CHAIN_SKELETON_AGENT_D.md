# Chain entry skeleton -- Agent D (MaxArm driver + integration)

Authored 2026-05-16 BEFORE Agent D swings, per memory
`chain_caught_five_wrong_leverage_swings`: propose chain entry FIRST,
build SECOND.

ASCII only (no em-dashes, no curly quotes).

---

## goal

Pure-Rail USB-CDC driver for Hiwonder MaxArm such that every Cmd in
stdlib/robot_arm.rail (MoveTo / SetGrip / Wait / Home) drives a physical
arm action and talk_arm.sh is a drop-in conversational REPL replacement
for talk.sh on real hardware.

## hypothesis

The MaxArm's ESP32 firmware exposes a documented or reverse-engineerable
serial command set. Pure-Rail termios + serial open/read/write is
sufficient (no C bridge needed) per the Garmin Phase 1 pattern. 4-DOF
closed-form IK plus calibrated named-point offsets land the suction
gripper within the 1 cm tolerance required for pickup.

## kill_target

Protocol research finds an undocumented binary protocol that requires
destructive reverse-engineering of the user's owned hardware (escalate;
do not auto-RE) OR IK unit tests fail to round-trip 12/12 known
positions within +/- 1 cm OR replay_cmd_log.sh on hardware faults on
all 20 reference scripts (suction never engages, joints never reach
named points).

(First two close as FALSIFIED. Third closes as INCONCLUSIVE pending
mechanical / calibration audit.)

## counters

- protocol_documented              -- 0 | 1, must be 1 to leave Phase 1
- ik_unit_test_pass_rate_pct       -- target == 100 (12/12)
- physical_arm_connected           -- 0 | 1
- replay_pass                      -- 0 | 1 (replay_cmd_log.sh over
                                      20 reference scripts on hardware)
- live_repl_pass                   -- 0 | 1 (talk_arm.sh: "grab red,
                                      put on green" succeeds, user-
                                      confirmed)
- estop_latency_ms                 -- target <= 100

## cmd

bash tools/lab/watchers/spurarm_arm_d.sh

(Agent D must author this watcher. Must run dry-mode counters even
without hardware so the INCONCLUSIVE-with-protocol-documented path
can be measured.)

## parent

66bb63f9  -- substrate-thesis robot-arm baseline

## verdict resolution

- PASS         -- protocol documented, IK 12/12, physical arm connected,
                  replay_pass=1, live_repl_pass=1.
- INCONCLUSIVE -- protocol documented + IK 12/12 + driver compiles but
                  hardware has not yet shipped. Reproducer commands
                  named on the chain entry so a follow-up session can
                  close to PASS.
- FALSIFIED    -- undocumented destructive-RE-only protocol (escalate to
                  user before touching hardware) OR IK round-trip
                  fails on paper.

## non-negotiables baked into the swing

- No C bridges. Pure Rail. asm via tools/macos_ffi/ for termios is OK.
- E-stop in talk_arm.sh halts the arm in <= 100 ms (Ctrl-C).
- IK unit tests pass BEFORE any hardware command is sent. A bad IK on
  a real motor breaks plastic.
- Calibration file required on first run. Default IK is for dry-run
  only.
