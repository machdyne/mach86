; Mach86: a look at the mouse. A .COM program. Asks the driver
; (interrupt 33h) whether it is there, shows the cursor, and prints
; the position and buttons whenever they change, until a key is
; pressed; then says how often its event handler was called.

        cpu     386
        bits    16
        org     100h

start:  xor     ax, ax
        int     33h
        cmp     ax, 0FFFFh
        je      .ok
        mov     dx, m_none
        mov     ah, 09h
        int     21h
        mov     ax, 4C01h
        int     21h
.ok:    mov     dx, m_ok
        mov     ah, 09h
        int     21h
        push    cs
        pop     es
        mov     dx, handler
        mov     cx, 7Fh
        mov     ax, 000Ch
        int     33h
        mov     ax, 0001h
        int     33h
        mov     word [lastx], -1

.loop:  mov     ah, 01h
        int     16h
        jnz     .end
        mov     ax, 0003h
        int     33h
        cmp     cx, [lastx]
        jne     .show
        cmp     dx, [lasty]
        jne     .show
        cmp     bx, [lastb]
        je      .loop
.show:  mov     [lastx], cx
        mov     [lasty], dx
        mov     [lastb], bx
        mov     al, 'x'
        call    putc
        mov     al, '='
        call    putc
        mov     ax, [lastx]
        call    putn
        mov     al, ' '
        call    putc
        mov     al, 'y'
        call    putc
        mov     al, '='
        call    putc
        mov     ax, [lasty]
        call    putn
        mov     al, ' '
        call    putc
        mov     al, 'b'
        call    putc
        mov     al, '='
        call    putc
        mov     ax, [lastb]
        call    putn
        mov     al, 13
        call    putc
        mov     al, 10
        call    putc
        jmp     .loop

.end:   xor     ah, ah
        int     16h
        mov     ax, 0002h
        int     33h
        xor     cx, cx                  ; no more events
        mov     ax, 000Ch
        int     33h
        mov     dx, m_events
        mov     ah, 09h
        int     21h
        mov     ax, [events]
        call    putn
        mov     al, 13
        call    putc
        mov     al, 10
        call    putc
        mov     ax, 4C00h
        int     21h

; Called by the driver, far, with its own registers.
handler:
        inc     word [cs:events]
        retf

putc:   push    dx
        mov     dl, al
        mov     ah, 02h
        int     21h
        pop     dx
        ret

; AX in decimal.
putn:   push    bx
        push    cx
        push    dx
        xor     cx, cx
        mov     bx, 10
.div:   xor     dx, dx
        div     bx
        push    dx
        inc     cx
        test    ax, ax
        jnz     .div
.out:   pop     ax
        add     al, '0'
        call    putc
        loop    .out
        pop     dx
        pop     cx
        pop     bx
        ret

lastx:  dw      0
lasty:  dw      0
lastb:  dw      0
events: dw      0
m_none:   db    "no mouse driver: run MOUSE first", 13, 10, "$"
m_ok:     db    "mouse driver ok; move the mouse, a key ends", 13, 10, "$"
m_events: db    "events=$"
