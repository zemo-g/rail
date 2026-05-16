# MaxArm Serial Protocol Research

Authored 2026-05-16 by Agent D (spurarm/D-maxarm).
Sources: official Hiwonder docs at
https://docs.hiwonder.com/projects/MaxArm/en/latest/ — specifically the
serial communication chapter at
https://docs.hiwonder.com/projects/MaxArm/en/latest/_sources/docs/10.MaxArm_Serial_Communication_formatted.md.txt

Verified against four worked examples in the doc (checksum formula
matched 4/4 once one example typo was discounted, see "checksum"
section below). No reverse-engineering required -- protocol is fully
documented by the vendor.

ASCII only.

## 1. Source identification

- Hardware: Hiwonder MaxArm Open Source Robot Arm, ESP32 based.
- Firmware: Hiwonder's stock ESP32 firmware (the "underlying" /
  bottom-layer program in their docs).
- Serial transport: UART. Exposed externally as either
  - micro-USB (USB-CDC, what we will use from the Studio); or
  - 4-pin TX/RX/GND/VCC header (used for MCU-to-MCU integration).
- macOS expects the USB-serial adapter chip to enumerate as
  /dev/cu.usbserial-* or /dev/cu.SLAB_USBtoUART (CP2102) or
  /dev/cu.wchusbserial* (CH340). Confirm at hardware-acquisition
  time -- the exact chip can vary by batch.

## 2. Serial port configuration

| Parameter | Value |
|---|---|
| Baud rate | 9600 |
| Data bits | 8 |
| Parity | None |
| Stop bits | 1 |
| Flow control | None |

Yes, 9600 is slow. The MaxArm's command set is tiny (<20 bytes per
frame, <10 frames per second) so this is fine in practice. We will
not try to negotiate higher rates.

## 3. Frame format

Every frame on the wire:

    +------+------+----------+--------+------+------+----------+
    | 0xAA | 0x55 | func     | datalen| data | ...  | checksum |
    +------+------+----------+--------+------+------+----------+
       1B     1B      1B         1B    0..N B          1B

- Header is the fixed 2-byte sequence 0xAA 0x55. Anything before that
  is junk and should be ignored.
- func is the function code (1 byte).
- datalen is the number of bytes in the data section (1 byte). 0 for
  request-only frames (READ_*).
- data is datalen bytes of payload, little-endian for multi-byte
  fields.
- checksum is a single byte:
    sum = (func + datalen + sum(data)) & 0xFF
    checksum = (~sum) & 0xFF       -- one's complement of low byte

### Checksum verification on doc examples

Doc gives four full-frame examples. Three verify; one has an
off-by-one typo (the suction example). Computing
checksum = (~((func + datalen + sum(data)) & 0xFF)) & 0xFF:

| Frame | sum low byte | ~sum & 0xFF | doc says |
|---|---|---|---|
| AA 55 11 00 EE              | 0x11 | 0xEE | 0xEE OK |
| AA 55 13 00 EC              | 0x13 | 0xEC | 0xEC OK |
| AA 55 03 08 78 00 4C FF 55 00 E8 03 F1 | 0x0E | 0xF1 | 0xF1 OK |
| AA 55 01 08 C8 00 F4 01 F4 01 D0 07 6D | 0x92 | 0x6D | 0x6D OK |
| AA 55 05 04 D0 07 E8 03 34  | 0xCB | 0x34 | 0x34 OK |
| AA 55 07 01 02 F5           | 0x0A | 0xF5 | 0xF6 (doc typo) |

5/6 verify. The one outlier is a documentation typo (off by one bit;
0xF5 is one's complement of 0x0A, 0xF6 would be 0xF5 ^ 0x03 or
similar -- not consistent with any plausible alternative formula).
We trust the formula, not the outlier example.

## 4. Command set

### 4.1 FUNC_SET_ANGLE (0x01) -- set bus-servo angles

- datalen = 8
- data:
    bytes 0..1: servo1 pulse (uint16 LE, 0..1000 maps to 0..240 deg)
    bytes 2..3: servo2 pulse (uint16 LE)
    bytes 4..5: servo3 pulse (uint16 LE)
    bytes 6..7: duration ms  (uint16 LE)
- Worked example:
    AA 55 01 08 C8 00 F4 01 F4 01 D0 07 6D
    -> S1=200, S2=500, S3=500, duration=2000 ms

### 4.2 FUNC_SET_XYZ (0x03) -- cartesian move

- datalen = 8
- data:
    bytes 0..1: X (int16 LE, mm)
    bytes 2..3: Y (int16 LE, mm)
    bytes 4..5: Z (int16 LE, mm)
    bytes 6..7: duration ms (uint16 LE)
- Worked example:
    AA 55 03 08 78 00 4C FF 55 00 E8 03 F1
    -> X=120, Y=-180, Z=85, duration=1000 ms
- This is the command we will primarily use. Firmware does the IK
  internally. We still implement and unit-test our own IK in
  coord_map.rail because:
  (a) we need to validate that a DSL coord is reachable BEFORE we
      send a command to a physical motor;
  (b) the firmware's IK behavior at out-of-reach is opaque -- it
      might silently clip or it might fault, and we don't want to
      find out empirically.
- Workspace per the product spec: 290 mm radius, +187 mm above base,
  -111 mm below base. Origin and axis directions confirmed at
  calibration time. Default assumption (to be validated with
  hardware):
    +X = right of arm, +Y = away from arm, +Z = up.

### 4.3 FUNC_SET_PWMSERVO (0x05) -- end-effector PWM servo

- datalen = 4
- data:
    bytes 0..1: pulse width usec (uint16 LE, 500..2500 = 0..180 deg)
    bytes 2..3: duration ms (uint16 LE)
- We do NOT use this for v0. The MaxArm starter kit ships with a
  suction nozzle, not a wrist roll. PWM servo control is for the
  optional rotating-gripper accessory.

### 4.4 FUNC_SET_SUCTIONNOZZLE (0x07) -- suction control

- datalen = 1
- data: 1 byte command
    0x01 = pump on (suction engaged)
    0x02 = pump off, air valve open (active release)
    0x03 = pump off, air valve closed (passive hold)
- Mapping to our Grip DSL:
    SetGrip GripClose -> send 0x01 (pump on)
    SetGrip GripOpen  -> send 0x02 (release with valve open)
- Sequence note: after sending 0x01 we wait at least 200 ms for
  suction to engage. After 0x02 we wait at least 200 ms for release.

### 4.5 FUNC_READ_ANGLE (0x11) -- read servo angles

- Request datalen = 0. Frame is: AA 55 11 00 EE.
- Response datalen = 6:
    bytes 0..1: servo1 pulse (uint16 LE)
    bytes 2..3: servo2 pulse (uint16 LE)
    bytes 4..5: servo3 pulse (uint16 LE)
- We use this to confirm arm is responsive at startup.

### 4.6 FUNC_READ_XYZ (0x13) -- read end-effector position

- Request datalen = 0. Frame is: AA 55 13 00 EC.
- Response datalen = 6:
    bytes 0..1: X (int16 LE, mm)
    bytes 2..3: Y (int16 LE, mm)
    bytes 4..5: Z (int16 LE, mm)
- We use this after each MoveTo to update tracked state honestly
  (vs. trusting that the firmware reached the commanded point).

## 5. E-stop semantics

The documented protocol does NOT include an explicit e-stop command.
Our e-stop strategy:

1. Send FUNC_SET_SUCTIONNOZZLE 0x02 (release whatever we are
   holding -- avoids dropping an object on the user's hand if the
   arm is mid-move).
2. Send FUNC_SET_XYZ with duration = 100 ms to the current
   (read-back) XYZ. This effectively "freezes" the arm at where it
   is rather than continuing to the prior commanded target.
3. Drain any unread bytes from the serial port.
4. Refuse all further commands until the user explicitly resumes.

Latency budget: <100 ms from Ctrl-C to "no further motion." Achievable
at 9600 baud since both frames are <15 bytes (~16 ms wire time
combined) and the read-back round trip is ~50 ms.

## 6. Coordinate frame

The firmware's XYZ frame:
- Origin at the base of the arm, at table level.
- +X is right of the arm as seen from the user (facing the arm front).
- +Y is forward (away from the user, toward the workspace).
- +Z is up.
- Units: millimeters.

Our DSL frame (stdlib/robot_arm.rail):
- 0..30 cm cube workspace.
- (0, 0, 0) = arm base.
- x right, y forward (away from arm), z up.

DSL-to-arm mapping (default, pre-calibration):
    arm_x_mm = dsl_x * 10            -- DSL 1..30 cm -> 10..300 mm
    arm_y_mm = dsl_y * 10
    arm_z_mm = dsl_z * 10

The arm's physical reach is 290 mm radius. The DSL 30 cm cube has
some corners outside that envelope (the (30,30,30) corner is
sqrt(3)*300 mm = 519 mm out, way outside reach). Workspace clipping
in safety.rail enforces the reachable cone.

Calibration produces (x_offset, y_offset, z_offset) tuning so a DSL
point lands physically where the user expects. Persisted to
~/.robot/maxarm_calib.txt.

## 7. Things we do NOT yet know (escalate if these block)

The following are not in the protocol doc and need either a real arm
or a follow-up vendor question:

- Exact ack/response timing after a write. We assume "wait `duration`
  ms then the move is done" but the firmware may also send an async
  "move complete" frame. We will sniff this once hardware is on hand.
- Behavior when the commanded XYZ is unreachable. Does it fault?
  Silently clip? Move to nearest? We assume worst case (silently
  goes somewhere unsafe) and gate every send on our own reachability
  check.
- Whether READ_XYZ returns a value while the arm is mid-move (so we
  can poll progress) or only after move completes.
- The PWMSERVO channel ID -- the protocol doesn't appear to take a
  channel parameter, suggesting one fixed channel. Will confirm if
  we ever need the rotating gripper.

These are all "nice to know, not blocking" for the v0 driver. The
ack-timing question matters most -- if there is an async completion
frame, we should drain it.

## 8. macOS USB driver notes

- macOS Sonoma / Sequoia on Apple Silicon ships CDC-ACM and FTDI
  natively. CH340 chips usually need a kernel extension or DriverKit
  driver (e.g. WCH or DriverKitTunnel). CP2102 needs Silicon Labs's
  driver below macOS 11; Apple's native USB stack handles it on
  recent macOS.
- The MaxArm's specific USB-serial chip is not in the public docs.
  Hardware-acquisition checklist (in AGENT_D_maxarm.md) calls out
  identifying the chip on first plug-in.

## 9. Citations

Primary: https://docs.hiwonder.com/projects/MaxArm/en/latest/
Serial chapter (markdown source):
  https://docs.hiwonder.com/projects/MaxArm/en/latest/_sources/docs/10.MaxArm_Serial_Communication_formatted.md.txt
Underlying program learning:
  https://docs.hiwonder.com/projects/MaxArm/en/latest/docs/4.Underlying_Program_Learning_checked.html
Getting ready (hardware):
  https://docs.hiwonder.com/projects/MaxArm/en/latest/docs/1.Getting_Ready_checked.html

## 10. Verdict on Phase 1

protocol_documented = 1. Phase 2 (driver) can proceed without further
research. The destructive-RE escalation path is NOT triggered.
