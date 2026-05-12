# m4_fib_print — bare-metal Cortex-M4

Same Rail compiler, different backend: `./rail_native cortexm` produces a Thumb-2 ELF for ARMv7E-M (Cortex-M3/M4/M7). This program computes `fib(0..10)` and prints each result to the memory-mapped UART at `0x40004000`.

**Source** (`examples/m4_fib_print.rail`):

```rail
-- examples/m4_fib_print.rail
-- Bare-metal Cortex-M4: compute fib(0..10) and print each result to UART.
-- Demonstrates real computation + decimal output without any runtime support.
--
-- Run:  tools/garmin/m4_qemu.sh examples/m4_fib_print.rail
-- Expected output (one per line):
--   0 1 1 2 3 5 8 13 21 34 55

write_char c = mmio_write 0x40004000 c
init_uart    = mmio_write 0x40004008 1
newline      = write_char 10

print_digit d = write_char (48 + d)

print_int n =
  if n < 10 then print_digit n
  else
    let n10 = n / 10 in
    let _ = print_int n10 in
    print_digit (n - n10 * 10)

fib n = if n < 2 then n else fib (n - 1) + fib (n - 2)

print_fib_loop i hi =
  if i > hi then 0
  else
    let _ = print_int (fib i) in
    let _ = newline in
    print_fib_loop (i + 1) hi

main =
  let _ = init_uart in
  print_fib_loop 0 10
```

**Build (compile-only — produces a flashable ELF):**

```bash
./rail_native cortexm examples/m4_fib_print.rail
```

**Output (from the compile driver):**

```
Compiling examples/m4_fib_print.rail -> Cortex-M4 (Thumb-2)...
  Assembly: /tmp/rail_m4.s (3553 chars)
  as: OK -> /tmp/rail_m4.o
  startup as: OK
  ld: OK -> /tmp/rail_m4.elf
```

`/tmp/rail_m4.elf` is a flashable image. To run it in qemu (which provides an MPS2-AN386 board with a working UART), use `tools/garmin/m4_qemu.sh`. Expected output: `0 1 1 2 3 5 8 13 21 34 55`, one per line.

Note the `mmio_write` builtin — that's Rail's intrinsic for `str rX, [addr]` on the Cortex-M backend. No runtime, no libc.
