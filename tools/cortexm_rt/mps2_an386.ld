/* tools/cortexm_rt/mps2_an386.ld
 * QEMU MPS2-AN386 (Cortex-M4) memory map for execution-verification tests.
 * Differs from apollo2.ld only in the SRAM region: qemu's mps2-an386 puts
 * RAM at 0x20000000 (typical ARM reference), Apollo2 puts it at 0x10000000.
 * Use this script when running rail_m4.elf in qemu-system-arm; use apollo2.ld
 * when targeting the actual Instinct hardware. */

ENTRY(Reset_Handler)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x00000000, LENGTH = 4096K
    SRAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 4096K
}

_stack_top = ORIGIN(SRAM) + LENGTH(SRAM);

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
