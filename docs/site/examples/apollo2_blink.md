# apollo2_blink — GPIO toggle on a real chip

Apollo2 (the MCU inside a Garmin Instinct gen-1) is a Cortex-M4. This Rail program drives a GPIO pin through Ambiq's PADKEY/CFGA/WTSA/WTCA register sequence using a SysTick interrupt for timing. Real microcontroller code, no C, no libc.

**Source excerpt** (`examples/apollo2_blink.rail`):

```rail
-- examples/apollo2_blink.rail
-- First Apollo2 (Instinct gen-1 main MCU) bring-up: GPIO toggle via SysTick.
--
-- Build:  ./rail_native cortexm examples/apollo2_blink.rail  -> /tmp/rail_m4.elf

-- ---------- Apollo2 GPIO register addresses ----------

GPIO_PADKEY  = 0x40010060
GPIO_CFGA    = 0x40010040
GPIO_WTSA    = 0x40010090
GPIO_WTCA    = 0x40010098
GPIO_ENSA    = 0x400100A8

PADKEY_VALUE = 0x73

-- SysTick (ARM Cortex-M4 standard, same address on Apollo2 and any M4)
SYSTICK_CTRL = 0xE000E010
-- ... (107 lines total — read the full file in the repo)
```

The full program is 107 lines and configures: PADKEY unlock, output mode for `BLINK_PIN`, output enable, then a SysTick-driven main loop that toggles the pin via `GPIO_WTSA`/`GPIO_WTCA`.

**Build:**

```bash
./rail_native cortexm examples/apollo2_blink.rail
```

**Output:**

```
Compiling examples/apollo2_blink.rail -> Cortex-M4 (Thumb-2)...
  Assembly: /tmp/rail_m4.s (7543 chars)
  as: OK -> /tmp/rail_m4.o
  startup as: OK
  ld: OK -> /tmp/rail_m4.elf
```

The result is a 7.5 KB Thumb-2 ELF ready to flash. Note that Apollo2 isn't a qemu machine — verification means SWD-flashing it onto real hardware. The file has annotated assumptions about the chip's reset-default pad config.
