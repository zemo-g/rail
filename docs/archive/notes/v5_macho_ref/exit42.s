.text
.global _main
.align 2
_main:
    mov x16, #1       // SYS_exit
    mov x0,  #42      // status
    svc  #0x80
    ret
