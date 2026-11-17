; Mach86: is there an AdLib, and does it play? A .COM program. Looks
; for the card the way programs do (its two timers), then plays a
; scale on one voice with a plain organ-like sound, and three notes
; together.

        cpu     386
        bits    16
        org     100h

start:  mov     dx, m_title
        mov     ah, 09h
        int     21h

        ; The usual test: stop and clear the timers, read the status;
        ; start timer 1 at FFh, wait, read it again.
        mov     ax, 6004h
        call    opl
        mov     ax, 8004h
        call    opl
        mov     dx, 388h
        in      al, dx
        and     al, 0E0h
        mov     bl, al
        mov     ax, 0FF02h
        call    opl
        mov     ax, 2104h
        call    opl
        mov     cx, 2                   ; two timer ticks: far more than 80 us
        call    pause
        mov     dx, 388h
        in      al, dx
        and     al, 0E0h
        mov     bh, al
        mov     ax, 6004h
        call    opl
        mov     ax, 8004h
        call    opl
        cmp     bx, 0C000h
        je      .found
        mov     dx, m_none
        mov     ah, 09h
        int     21h
        mov     ax, 4C01h
        int     21h

.found: mov     dx, m_found
        mov     ah, 09h
        int     21h

        ; Clear every register, then the sound: voices 0 to 2 alike.
        xor     bx, bx
.clr:   mov     al, bl
        xor     ah, ah
        inc     bl
        call    opl
        cmp     bl, 0F6h
        jb      .clr
        mov     si, patch
.set:   lodsw
        test    al, al
        jz      .play
        call    opl
        jmp     .set

.play:  mov     si, notes
.note:  lodsw                           ; the F-number, the block, key on
        test    ax, ax
        jz      .chord
        push    ax
        mov     ah, al
        mov     al, 0A0h
        call    opl
        pop     ax
        mov     al, 0B0h
        call    opl
        lodsb
        mov     dl, al
        mov     ah, 02h
        int     21h
        mov     dl, ' '
        int     21h
        mov     cx, 4
        call    pause
        mov     ax, 00B0h               ; key off
        call    opl
        mov     cx, 1
        call    pause
        jmp     .note

.chord: mov     dx, m_chord
        mov     ah, 09h
        int     21h
        mov     ax, 59A0h               ; C
        call    opl
        mov     ax, 31B0h
        call    opl
        mov     ax, 0B3A1h              ; E
        call    opl
        mov     ax, 31B1h
        call    opl
        mov     ax, 05A2h               ; G
        call    opl
        mov     ax, 32B2h
        call    opl
        mov     cx, 18
        call    pause
        mov     ax, 00B0h
        call    opl
        mov     ax, 00B1h
        call    opl
        mov     ax, 00B2h
        call    opl
        mov     dx, m_done
        mov     ah, 09h
        int     21h
        mov     ax, 4C00h
        int     21h

; Write AH to register AL.
opl:    push    dx
        push    ax
        mov     dx, 388h
        out     dx, al
        in      al, dx                  ; (the card wants a little time)
        in      al, dx
        inc     dx
        mov     al, ah
        out     dx, al
        dec     dx
        in      al, dx
        in      al, dx
        pop     ax
        pop     dx
        ret

; Wait cx timer ticks.
pause:  push    es
        push    ax
        xor     ax, ax
        mov     es, ax
.tick:  mov     ax, [es:046Ch]
.same:  hlt
        cmp     ax, [es:046Ch]
        je      .same
        loop    .tick
        pop     ax
        pop     es
        ret

; Register, value. Voice 0's operators are at 0 and 3, voice 1's at
; 1 and 4, voice 2's at 2 and 5.
patch:  db      01h, 20h                ; waveforms allowed
%assign v 0
%rep 3
        db      20h + v, 21h            ; modulator: sustained, multiple 1
        db      40h + v, 1Ah            ;   fairly quiet
        db      60h + v, 0F2h           ;   fast attack, slow decay
        db      80h + v, 73h
        db      23h + v, 21h            ; carrier
        db      43h + v, 04h
        db      63h + v, 0F3h
        db      83h + v, 75h
        db      0C0h + v, 06h           ; some feedback, modulate
%assign v v + 1
%endrep
        db      0, 0

; A0h value, B0h value (key on, block 4, the F-number's top bits),
; name. F-number = frequency * 2^16 / 49,716 in block 4.
notes:  db      059h, 31h, 'C'          ; 262 Hz: 345
        db      083h, 31h, 'D'
        db      0B3h, 31h, 'E'
        db      0CCh, 31h, 'F'
        db      005h, 32h, 'G'
        db      044h, 32h, 'A'
        db      08Bh, 32h, 'B'
        db      0B2h, 32h, 'C'
        dw      0

m_title: db     "Mach86 AdLib test", 13, 10, "$"
m_none:  db     "no AdLib found", 13, 10, "$"
m_found: db     "AdLib found", 13, 10, "$"
m_chord: db     13, 10, "chord", 13, 10, "$"
m_done:  db     "done", 13, 10, "$"
