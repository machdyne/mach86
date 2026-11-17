; Mach86 test program: a bootable diskette image that listens to the
; mouse port (E3h, interrupt 12) and prints what each report reads as:
; "m" and the three bytes in hex. For make -C sim check-mouse, on the
; model and on the SoC.

        cpu     386
        bits    16
        org     7C00h

start:  xor     ax, ax
        mov     ds, ax
        mov     ss, ax
        mov     sp, 7C00h
        cli
        mov     word [74h * 4], irq12
        mov     [74h * 4 + 2], ax
        out     0E3h, al
        in      al, 0A1h
        and     al, 0EFh
        out     0A1h, al
        in      al, 21h
        and     al, 0FBh
        out     21h, al
        sti
        mov     si, m_ready
        call    puts
.idle:  hlt
        jmp     .idle

irq12:  pusha
.more:  mov     al, 'm'
        call    putc
        in      al, 0E3h
        mov     ch, al
        call    hex
        in      al, 0E3h
        call    hex
        in      al, 0E3h
        call    hex
        mov     al, 13
        call    putc
        mov     al, 10
        call    putc
        test    ch, 40h
        jnz     .more
        mov     al, 20h
        out     0A0h, al
        out     20h, al
        popa
        iret

hex:    push    ax
        mov     al, ' '
        call    putc
        pop     ax
        push    ax
        shr     al, 4
        call    .nib
        pop     ax
.nib:   and     al, 0Fh
        add     al, '0'
        cmp     al, '9'
        jbe     putc
        add     al, 7
putc:   mov     ah, 0Eh
        mov     bx, 0007h
        int     10h
        ret

puts:   lodsb
        test    al, al
        jz      .done
        call    putc
        jmp     puts
.done:  ret

m_ready: db     "mouse ready", 13, 10, 0

        times   510 - ($ - $$) db 0
        dw      0AA55h
        times   720 * 512 - ($ - $$) db 0
