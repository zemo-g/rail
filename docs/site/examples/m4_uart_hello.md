# m4_uart_hello — "Hi!" over UART on Cortex-M4

The hello-world of microcontroller programming: write four bytes (`H`, `i`, `!`, `\n`) to a UART data register. Runs in `qemu-system-arm -M mps2-an386`.

**Source** (`examples/m4_uart_hello.rail`):

```rail
-- examples/m4_uart_hello.rail
-- Rail running on bare-metal Cortex-M4: writes "Hi!\n" to the CMSDK UART.
--
-- Build + run in qemu:
--   tools/garmin/m4_qemu.sh examples/m4_uart_hello.rail
--   (or use the smoke harness's qemu-uart case)
--
-- Compatible with qemu-system-arm -M mps2-an386. The actual Apollo2 chip in
-- the Instinct uses a different UART (Apollo2 IOM peripheral) at a different
-- address; that variant lives elsewhere.

-- CMSDK UART0 register layout (mps2-an386):
--   DATA  = 0x40004000  -- write byte to send
--   STATE = 0x40004004  -- TX/RX status
--   CTRL  = 0x40004008  -- bit 0 = TX enable

write_char c = mmio_write 0x40004000 c
init_uart   = mmio_write 0x40004008 1

main =
  let _ = init_uart in
  let _ = write_char 72 in
  let _ = write_char 105 in
  let _ = write_char 33 in
  let _ = write_char 10 in
  0
```

**Build:**

```bash
./rail_native cortexm examples/m4_uart_hello.rail
```

**Output (compile only):**

```
Compiling examples/m4_uart_hello.rail -> Cortex-M4 (Thumb-2)...
  Assembly: /tmp/rail_m4.s (1084 chars)
  as: OK -> /tmp/rail_m4.o
  startup as: OK
  ld: OK -> /tmp/rail_m4.elf
```

The `1084 chars` of assembly are the entire program — a startup vector, the four MMIO writes, and an infinite-loop epilogue. Run in qemu with `tools/garmin/m4_qemu.sh` to see `Hi!` on the serial console.
