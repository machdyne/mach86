; Mach86: HDMI.COM, sound on the display's cable. "HDMI ON" makes the
; display output HDMI, with the PC speaker and the AdLib in it;
; "HDMI OFF" makes it plain DVI again; "HDMI" alone says which it is.
; Port 1E1h bit 0 (docs/sound.md). On a board without it the port
; reads back what was written and nothing else happens.

        cpu     386
        bits    16
        org     100h

PORT    equ     1E1h

start:  mov     si, 81h
.skip:  lodsb
        cmp     al, ' '
        je      .skip
        cmp     al, 13
        je      .show
        or      al, 20h
        cmp     al, 'o'
        jne     .usage
        lodsb
        or      al, 20h
        cmp     al, 'n'
        je      .on
        cmp     al, 'f'
        jne     .usage
        xor     al, al
        jmp     .set
.on:    mov     al, 1
.set:   mov     dx, PORT
        out     dx, al
.show:  mov     dx, PORT
        in      al, dx
        mov     dx, m_off
        test    al, 1
        jz      .say
        mov     dx, m_on
.say:   mov     ah, 09h
        int     21h
        mov     ax, 4C00h
        int     21h
.usage: mov     dx, m_use
        mov     ah, 09h
        int     21h
        mov     ax, 4C01h
        int     21h

m_on:   db      'display output: HDMI with sound', 13, 10, '$'
m_off:  db      'display output: DVI, no sound', 13, 10, '$'
m_use:  db      'HDMI ON | OFF', 13, 10, '$'
