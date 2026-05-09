@ tools/cortexm_rt/startup.s — Cortex-M4 bare-metal startup.
@ Targets Apollo2 (Instinct gen-1). Minimal: vector table + Reset_Handler.
@ All non-Reset vectors point at a default trap that loops forever.

    .syntax unified
    .thumb
    .cpu cortex-m4

    .section .vectors, "ax"
    .align 2
    .global _vectors
_vectors:
    .word _stack_top              @ 0x00: initial SP (set by linker)
    .word Reset_Handler           @ 0x04: reset (lld auto-sets Thumb LSB for .thumb_func)
    .word Default_Handler     @ 0x08: NMI
    .word Default_Handler     @ 0x0c: HardFault
    .word Default_Handler     @ 0x10: MemManage
    .word Default_Handler     @ 0x14: BusFault
    .word Default_Handler     @ 0x18: UsageFault
    .word 0                       @ 0x1c: reserved
    .word 0                       @ 0x20: reserved
    .word 0                       @ 0x24: reserved
    .word 0                       @ 0x28: reserved
    .word Default_Handler     @ 0x2c: SVCall
    .word Default_Handler     @ 0x30: DebugMon
    .word 0                       @ 0x34: reserved
    .word Default_Handler     @ 0x38: PendSV
    .word _rail_SysTick_Handler @ 0x3c: SysTick (Rail-overridable; weak default below)

    .text
    .align 2

    .global Reset_Handler
    .type Reset_Handler, %function
    .thumb_func
Reset_Handler:
    @ Stack is loaded automatically from vector[0] at reset.
    @ Zero .bss.
    ldr r0, =_bss_start
    ldr r1, =_bss_end
    movs r2, #0
.Lzero_bss:
    cmp r0, r1
    bge .Lbss_done
    str r2, [r0]
    adds r0, r0, #4
    b .Lzero_bss
.Lbss_done:

    @ Copy .data from flash to SRAM.
    ldr r0, =_data_load           @ source in flash
    ldr r1, =_data_start          @ dest in SRAM
    ldr r2, =_data_end
.Lcopy_data:
    cmp r1, r2
    bge .Ldata_done
    ldr r3, [r0]
    str r3, [r1]
    adds r0, r0, #4
    adds r1, r1, #4
    b .Lcopy_data
.Ldata_done:

    @ Call user main. r0 holds main's return value on return.
    bl _main

    @ Exit via ARM semihosting SYS_EXIT_EXTENDED so QEMU exits with main's
    @ return value as its exit code. Build the {reason, code} struct on
    @ the stack: bottom word = ADP_Stopped_ApplicationExit (0x20026),
    @ top word = exit code (main's return value already in r0).
    push {r0}                     @ stack[+4] = exit code
    movw r2, #0x0026
    movt r2, #0x0002              @ r2 = 0x20026
    push {r2}                     @ stack[+0] = reason
    mov r1, sp                    @ r1 -> {reason, code}
    movs r0, #0x20                @ SYS_EXIT_EXTENDED
    bkpt 0xab                     @ semihosting trap

    @ If qemu somehow returns (e.g., no semihosting), spin.
.Lspin:
    b .Lspin

    .global Default_Handler
    .type Default_Handler, %function
    .thumb_func
Default_Handler:
    b Default_Handler

    @ Weak default for the SysTick handler. If a Rail program defines
    @ _rail_SysTick_Handler (i.e. a Rail function named SysTick_Handler),
    @ its strong global definition wins; otherwise this stub returns
    @ from interrupt cleanly. Useful when SysTick is never enabled.
    .weak _rail_SysTick_Handler
    .type _rail_SysTick_Handler, %function
    .thumb_func
_rail_SysTick_Handler:
    bx lr
