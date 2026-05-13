/* tools/cortexm_rt/apollo2.ld
 * Linker script for Ambiq Apollo2 (Cortex-M4F) — Instinct gen-1 main MCU.
 * Memory: 1 MB flash @ 0x00000000, 384 KB SRAM @ 0x10000000.
 * Vector table goes first in flash; .text follows; .data RAM-init via copy. */

ENTRY(Reset_Handler)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x00000000, LENGTH = 1024K
    SRAM  (rwx) : ORIGIN = 0x10000000, LENGTH = 384K
}

_stack_top = ORIGIN(SRAM) + LENGTH(SRAM);  /* full descending */

SECTIONS
{
    .vectors : ALIGN(4)
    {
        KEEP(*(.vectors))
    } > FLASH

    .text : ALIGN(4)
    {
        *(.text)
        *(.text.*)
        *(.rodata)
        *(.rodata.*)
        . = ALIGN(4);
        _data_load = .;
    } > FLASH

    .data : ALIGN(4)
    {
        _data_start = .;
        *(.data)
        *(.data.*)
        . = ALIGN(4);
        _data_end = .;
    } > SRAM AT > FLASH

    .bss (NOLOAD) : ALIGN(4)
    {
        _bss_start = .;
        *(.bss)
        *(.bss.*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > SRAM

    /DISCARD/ :
    {
        *(.ARM.exidx)
        *(.ARM.exidx.*)
        *(.ARM.extab.*)
    }
}
