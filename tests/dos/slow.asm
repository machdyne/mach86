; Mach86: SLOW.COM, the speed control. "SLOW n" makes the CPU wait n
; cycles (0 to 255) after every instruction; "SLOW 0" or "SLOW OFF" is
; full speed; "SLOW" alone says what is set. docs/speed.md has a table
; of what n is like which PC.

        cpu     386
        bits    16
        org     100h

PORT    equ     1E0h

start:  mov     si, 81h
.skip:  lodsb
        cmp     al, ' '
        je      .skip
        cmp     al, 13
        je      .show
        or      al, 20h
        cmp     al, 'o'                 ; OFF (or ON: full speed too)
        je      .off
        dec     si
        xor     bx, bx
.digit: lodsb
        cmp     al, '0'
        jb      .set
        cmp     al, '9'
        ja      .set
        sub     al, '0'
        xor     ah, ah
        imul    bx, bx, 10
        add     bx, ax
        jmp     .digit
.off:   xor     bx, bx
.set:   cmp     bx, 255
        jbe     .ok
        mov     bx, 255
.ok:    mov     al, bl
        mov     dx, PORT
        out     dx, al
.show:  mov     dx, m_is
        mov     ah, 09h
        int     21h
        mov     dx, PORT
        in      al, dx
        xor     ah, ah
        call    putn
        mov     dx, m_end
        mov     ah, 09h
        int     21h
        mov     ax, 4C00h
        int     21h

putn:   xor     cx, cx
        mov     bx, 10
.div:   xor     dx, dx
        div     bx
        push    dx
        inc     cx
        test    ax, ax
        jnz     .div
.out:   pop     dx
        add     dl, '0'
        mov     ah, 02h
        int     21h
        loop    .out
        ret

m_is:   db      "speed control: $"
m_end:  db      " cycles' wait after each instruction (0: full speed)", 13, 10, "$"
