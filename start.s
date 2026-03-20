.section .text
.globl _start

_start:
    li t0, 1            # 10000      
    li t1, 20           # 10004

loop:
    addi t0, t0, 1      # 10008
    blt t0, t1, loop    # 1000c
    
end:
    li t2, 0x2fffc      
    sw zero, 0(t2)    
