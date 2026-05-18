# MaxArm Serial Protocol -- Factory Firmware

**Status (2026-05-18): verified live on hardware.** Prior version of this
note described the `AA 55 func datalen data cksum` binary protocol from
Hiwonder's docs. That protocol exists -- but only on a different firmware
variant. **The factory-shipped firmware on the unit in hand exposes a
MicroPython REPL over USB-CDC instead.**

Decisive evidence: decompiling the official MaxArm.app (PyInstaller bundle,
PyQt5 + pyserial) showed it sends Python expressions as `\r\n`-terminated
text and parses tuple-formatted responses. No frame headers. No checksums.

ASCII only.

## 1. Hardware

- Hiwonder MaxArm, ESP32-based controller.
- USB enumerates as `/dev/cu.usbserial-110` on macOS Sequoia. The CH340
  USB-UART chip (vendor 0x1A86) bridges to the ESP32's UART. macOS
  Sonoma+ ships the driver natively -- no kext install required.
- The controller's blue LED flashes whenever the factory Bluetooth
  Wonderbot listener is advertising (it is, by default, on every power
  cycle).

## 2. Serial port configuration

| Parameter | Value |
|---|---|
| Baud rate | **115200** (the Hiwonder docs say 9600 -- wrong for this firmware) |
| Data bits | 8 |
| Parity | None |
| Stop bits | 1 |
| Flow control | None |
| DTR/RTS | irrelevant; CH340 board does NOT toggle ESP32 reset on DTR |

## 3. Protocol

There is no frame format. The wire carries plain UTF-8 text in both
directions.

Bring-up sequence on every fresh connect:

1. Open the port at 115200 8N1.
2. Write a single `0x03` byte (Ctrl-C) to interrupt the running
   `main.py`. Read the response -- you will see `\r\n>>> ` indicating
   the REPL is live.
3. Optional first thing to send: `arm.teaching_mode()\r\n`. This
   unloads all three bus servos so they stop holding against gravity
   and don't heat up during iteration.

From then on, send any MicroPython expression terminated by `\r\n`.
The REPL echoes the command, then prints the result, then prints a
new `>>> ` prompt. Read until `>>> ` to see one full response.

## 4. Verified command vocabulary

(All commands extracted from the official MaxArm.app's `writeComData`
call sites, and the on-device modules at
`tools/MaxArm-repo/Python/ps2_gamepad_control/{espmax,BusServo}.py`.)

| Action | Wire text |
|---|---|
| Interrupt running script | `\x03` (raw byte, no newline) |
| **Relax servos** | `arm.teaching_mode()` |
| Read current position | `arm.read_position()` |
| Move to absolute (x,y,z) | `arm.set_position((x,y,z), duration_ms)` |
| Go to ORIGIN | `arm.go_home(duration_ms)` |
| Read ORIGIN constant | `arm.ORIGIN` |
| Suction on | `nozzle.on()` |
| Suction off | `nozzle.off()` |
| Wrist angle | `nozzle.set_angle(angle, time_ms)` |
| Stop action group | `robot.stopActionGroup()` |
| Run named action group | `robot.runActionGroup(name, count)` |
| Read bus-servo offsets | `bus_servo.get_offset()` |
| Unload single servo | `bus_servo.unload(servo_id)` |
| Read single servo pos | `bus_servo.get_position(servo_id)` |

Coordinates are signed millimeters. ORIGIN is `(0, -163.0, 212.0)` mm
on this unit (firmware will print this if asked). The firmware refuses
any target with `sqrt(x*x+y*y) < 50` (too close) and clips z to 225.

## 5. Response format

Each command's response is one of:

- Empty -- command executed without return value (e.g. `arm.go_home(1500)`).
  REPL prints just a new `>>> `.
- A Python repr of the return value, on its own line, before the next
  `>>> `. Examples seen live:
  - `arm.read_position()` -> `(2, -158, 168)`
  - `arm.ORIGIN`         -> `(0, -163.0, 212.0)`
  - `arm.set_position((80,-150,200), 600)` -> `True`
- A Python traceback if the command raised. Multi-line, ends with the
  next `>>> `.

The official app parses the position tuple by string scanning for `(`
through `)` and splitting on `,`. Same approach works for our driver.

## 6. Servo heat

Servos hold against gravity when idle and warm within a few minutes if
left engaged. Two consequences for protocol design:

1. Default bring-up should send `arm.teaching_mode()` immediately
   after the Ctrl-C handshake. The arm is then limp until a
   set_position re-engages it.
2. Between motion sessions, send `arm.teaching_mode()` again. This
   includes graceful-shutdown of the Rail driver (`arm_close`).
3. If you're going to move soon, `arm.go_home(2000)` with a long
   duration is a gentle way to re-engage from a relaxed pose -- avoids
   a snap if gravity has dragged the arm down.

## 7. E-stop semantics

There is no documented e-stop. Our strategy:

1. Send `\x03` (Ctrl-C) to interrupt any in-flight long-duration move.
   This actually stops the arm where it is, because the MicroPython
   side issues a series of `bus_servo.run(id, pulse, duration)` calls
   and a Ctrl-C between calls prevents further sends. The current
   command will run to its duration but no NEW command will be issued.
2. Send `nozzle.off()` to drop anything held.
3. Send `arm.teaching_mode()` to relax.

Latency is well under 100 ms at 115200 baud.

## 8. The other (binary AA 55) protocol

The Hiwonder docs at
https://docs.hiwonder.com/projects/MaxArm/en/latest/docs/10.MaxArm_Serial_Communication_formatted.html
describe a binary `AA 55 func datalen data cksum` protocol with funcs
0x01..0x13. That protocol exists -- it is what the "underlying program"
firmware exposes -- but it is not what ships from the factory. Flashing
the underlying program is reversible (via the Hiwonder PC tool) but for
our purposes, the factory REPL is strictly more powerful (any Python
expression is callable, not just the 6 enumerated funcs) so we keep it.

If a future MaxArm ships with the binary firmware preloaded, swap to it
by re-implementing this driver layer per the docs above.

## 9. Tooling on disk

- Bring-up smoke: `/tmp/maxarm_smoke.py` -- ping, relax, read position.
- Wave demo: `/tmp/maxarm_wave.py` -- gentle home, 3x L/R wave, relax.
- MaxArm.app (extracted): `/private/tmp/MaxArm_extracted/` (PyInstaller
  unpack, used for protocol reference -- DO NOT redistribute).
- On-device firmware reference: `/tmp/MaxArm-repo/Python/...` (Hiwonder
  GitHub mirror of example code; the BusServo and ESPMax classes match
  what is running on the arm).

## 10. Citations

- Hiwonder MaxArm docs (binary protocol, wrong for our firmware):
  https://docs.hiwonder.com/projects/MaxArm/en/latest/
- Hiwonder MaxArm GitHub (on-arm Python examples):
  https://github.com/Hiwonder/MaxArm
- MaxArm Mac debugging app (the one we decompiled):
  https://net.hiwonder.com.cn/uploads/20250708/lvhicYOMYHeAqc1xQR88Ay4Lx42X/MaxArm.zip

## 11. Verdict on Phase 1

`protocol_documented = 1`. Phase 2 driver path is: `usb_serial.rail`
already exists and works; `arm_real.rail` rewrites the binary framing
layer as a thin text REPL helper.
