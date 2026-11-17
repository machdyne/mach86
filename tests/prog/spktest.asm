; Mach86 test program: a bootable diskette image that sounds the PC
; speaker, for the bench to measure (make -C sim check-spk): a 1,000 Hz
; tone from timer channel 2, silence, and the BIOS's bell.

        cpu     386
        bits    16
        org     7C00h

start:  xor     ax, ax
        mov     ds, ax
        mov     ss, ax
        mov     sp, 7C00h

        mov     al, 0B6h                ; channel 2, both bytes, square wave
        out     43h, al
        mov     ax, 1193                ; 1,193,182 / 1193 = 1,000.15 Hz
        out     42h, al
        mov     al, ah
        out     42h, al
        in      al, 61h
        or      al, 03h
        out     61h, al
        mov     si, m_on
        call    puts
        call    key

        in      al, 61h
        and     al, 0FCh
        out     61h, al
        mov     si, m_off
        call    puts
        call    key

        ; The timer running but the speaker's own bit off: still silent.
        in      al, 61h
        or      al, 01h
        out     61h, al
        mov     si, m_gate
        call    puts
        call    key

        mov     si, m_bell
        call    puts
        mov     ax, 0E07h               ; the bell
        int     10h
        mov     si, m_done
        call    puts
.halt:  hlt
        jmp     .halt

puts:   lodsb
        test    al, al
        jz      .done
        mov     ah, 0Eh
        mov     bx, 0007h
        int     10h
        jmp     puts
.done:  ret

key:    xor     ah, ah
        int     16h
        ret

m_on:   db      "tone on", 13, 10, 0
m_off:  db      "tone off", 13, 10, 0
m_gate: db      "gate only", 13, 10, 0
m_bell: db      "bell", 13, 10, 0
m_done: db      "speaker test done", 13, 10, 0

        times   510 - ($ - $$) db 0
        dw      0AA55h
        times   720 * 512 - ($ - $$) db 0
