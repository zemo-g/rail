.text
.global _main
_main:
    mov  x0,  #2
    mov  x1,  #21
    mul  x0,  x0, x1
    mov  x16, #1
    svc  #0x80
    ret
