/* tools/cortexm_rt/rv_virt.ld
 * Linker script for qemu-system-riscv32 -M virt.
 * Memory map: RAM at 0x80000000, sifive_test at 0x100000. */

ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 128M
}

_stack_top = ORIGIN(RAM) + LENGTH(RAM);

SECTIONS
{
    .text : ALIGN(4)
    {
        KEEP(*(.text.init))
        *(.text)
        *(.text.*)
        *(.rodata)
        *(.rodata.*)
        . = ALIGN(4);
    } > RAM

    .data : ALIGN(4)
    {
        _data_start = .;
        *(.data)
        *(.data.*)
        . = ALIGN(4);
        _data_end = .;
    } > RAM

    .bss (NOLOAD) : ALIGN(4)
    {
        _bss_start = .;
        *(.bss)
        *(.bss.*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > RAM

    /DISCARD/ :
    {
        *(.eh_frame)
        *(.eh_frame.*)
        *(.riscv.attributes)
    }
}
