; Mach86: is there sound? A .COM program. Plays a scale on the PC
; speaker, a note every four timer ticks, then the BIOS's bell, and
; says what it is doing.

        cpu     386
        bits    16
        org     100h

start:  mov     dx, m_title
        mov     ah, 09h
        int     21h
        mov     si, notes
.note:  lodsw                           ; the timer's divisor
        test    ax, ax
        jz      .end
        push    ax
        mov     al, 0B6h
        out     43h, al
        pop     ax
        out     42h, al
        mov     al, ah
        out     42h, al
        in      al, 61h
        or      al, 03h
        out     61h, al
        lodsb                           ; its name
        mov     dl, al
        mov     ah, 02h
        int     21h
        mov     dl, ' '
        int     21h
        mov     cx, 4
        call    pause
        jmp     .note
.end:   in      al, 61h
        and     al, 0FCh
        out     61h, al
        mov     cx, 4
        call    pause
        mov     dx, m_bell
        mov     ah, 09h
        int     21h
        mov     ax, 0E07h
        int     10h
        mov     dx, m_done
        mov     ah, 09h
        int     21h
        mov     ax, 4C00h
        int     21h

; Wait cx timer ticks.
pause:  push    es
        xor     ax, ax
        mov     es, ax
.tick:  mov     ax, [es:046Ch]
.same:  hlt
        cmp     ax, [es:046Ch]
        je      .same
        loop    .tick
        pop     es
        ret

; C major from middle C: 1,193,182 / frequency.
notes:  dw      4561
        db      'C'
        dw      4063
        db      'D'
        dw      3620
        db      'E'
        dw      3417
        db      'F'
        dw      3044
        db      'G'
        dw      2712
        db      'A'
        dw      2416
        db      'B'
        dw      2280
        db      'C'
        dw      0

m_title: db     "Mach86 speaker test: a scale, then the bell", 13, 10, "$"
m_bell:  db     13, 10, "bell", 13, 10, "$"
m_done:  db     "done", 13, 10, "$"
