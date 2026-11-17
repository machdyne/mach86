; Mach86 test program for CPU design B: a loop of the instructions that
; have microcode so far, to check the result and count cycles.
;
; A 64 KB ROM image, as for sim/m86run. Expected at HLT: AX = A314h
; (the low word of 1 + 2 + ... + 1000), DX = 1000, and 8006
; instructions executed.

        cpu     386
        bits    16
        org     0

start:  mov     sp, 1000h
        mov     ax, 0
        mov     cx, 1000
        mov     dx, 0
.loop:  add     ax, cx
        push    ax
        pop     bx
        call    bump
        dec     cx
        jnz     .loop
        hlt

bump:   add     dx, 1
        ret

        times   0FFF0h - ($ - $$) db 0FFh
reset:  jmp     start
        times   10000h - ($ - $$) db 0FFh
