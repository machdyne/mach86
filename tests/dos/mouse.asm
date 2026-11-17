; Mach86: MOUSE.COM, the mouse driver. Stays in memory and gives
; programs interrupt 33h, the interface every DOS program uses for a
; mouse, from Mach86's own mouse port (rtl/soc/m86_usbmouse.v: port
; E3h, interrupt 12), which a USB mouse feeds. docs/mouse.md lists the
; functions.
;
; Written from the interface as programs use it (the Microsoft Mouse
; Programmer's Reference's function list); no other driver was read.
;
; Positions are in the usual virtual screen: 640 across, and down as
; many lines as the mode has (200, 350, 480). It draws a cursor in
; text modes only (the cell's colours inverted); in graphics modes
; programs that want one draw their own, as games do.

        cpu     386
        bits    16
        org     100h

MPORT   equ     0E3h

        jmp     install

; ---- what stays ----
state:
x:      dw      320
y:      dw      100
minx:   dw      0
maxx:   dw      639
miny:   dw      0
maxy:   dw      199
btn:    dw      0
hide:   dw      -1                      ; 0: shown; below: hidden that many times
umask:  dw      0
uhand:  dd      0
mickx:  dw      0
micky:  dw      0
yrem:   dw      0
press:  times 3 * 3 dw 0                ; count, x, y for each button
relse:  times 3 * 3 dw 0
STATE_SIZE equ $ - state
drawn:  db      0
busy:   db      0
drawat: dw      0

; ---- interrupt 33h ----
int33:  push    ds
        push    bp
        push    cs
        pop     ds
        cld
        cmp     ax, 24h
        ja      .done
        mov     bp, ax
        shl     bp, 1
        call    [cs:table + bp]
.done:  pop     bp
        pop     ds
        iret

table:  dw      f_reset, f_show, f_hide, f_get, f_set, f_press, f_release
        dw      f_xrange, f_yrange, f_none, f_none, f_mick, f_handler
        dw      f_none, f_none, f_none, f_none, f_none, f_none, f_none
        dw      f_swap, f_size, f_save, f_load, f_none, f_none
        dw      f_none, f_sens, f_none, f_none, f_none, f_none, f_none
        dw      f_reset, f_none, f_none, f_ver

f_none: ret

f_reset:
        call    erase
        push    es
        push    di
        push    cx
        push    cs
        pop     es
        mov     di, state
        mov     cx, STATE_SIZE / 2
        xor     ax, ax
        rep stosw
        pop     cx
        pop     di
        xor     ax, ax
        mov     es, ax
        mov     al, [es:0449h]          ; the video mode
        pop     es
        mov     bx, 199
        cmp     al, 0Fh
        jb      .set
        mov     bx, 349
        cmp     al, 10h
        jbe     .set
        mov     bx, 479
        cmp     al, 12h
        jbe     .set
        mov     bx, 199
.set:   mov     [maxy], bx
        shr     bx, 1
        mov     [y], bx
        mov     word [maxx], 639
        mov     word [x], 320
        mov     word [hide], -1
        mov     ax, 0FFFFh
        mov     bx, 3
        ret

f_show: cmp     word [hide], 0
        jge     .ret
        inc     word [hide]
        call    draw
.ret:   ret

f_hide: call    erase
        dec     word [hide]
        ret

f_get:  mov     bx, [btn]
        mov     cx, [x]
        mov     dx, [y]
        ret

f_set:  call    erase
        mov     [x], cx
        mov     [y], dx
        call    clamp
        call    draw
        ret

; 05h, 06h: BX = button. AX = buttons now, BX = times since last asked,
; CX, DX = where the last one was.
f_press:
        mov     bp, press
        jmp     short counts
f_release:
        mov     bp, relse
counts: cmp     bx, 2
        ja      .none
        push    si
        mov     si, bx
        shl     si, 1
        add     si, bx
        shl     si, 1                   ; six bytes a button
        add     si, bp
        mov     bx, [si]
        mov     word [si], 0
        mov     cx, [si + 2]
        mov     dx, [si + 4]
        pop     si
        mov     ax, [btn]
        ret
.none:  mov     ax, [btn]
        xor     bx, bx
        ret

f_xrange:
        cmp     cx, dx
        jle     .ok
        xchg    cx, dx
.ok:    mov     [minx], cx
        mov     [maxx], dx
        jmp     short reclamp
f_yrange:
        cmp     cx, dx
        jle     .ok
        xchg    cx, dx
.ok:    mov     [miny], cx
        mov     [maxy], dx
reclamp:
        call    erase
        call    clamp
        call    draw
        ret

f_mick: xor     cx, cx
        xor     dx, dx
        xchg    cx, [mickx]
        xchg    dx, [micky]
        ret

f_handler:
        mov     [umask], cx
        mov     [uhand], dx
        mov     [uhand + 2], es
        ret

f_swap: xchg    cx, [umask]
        xchg    dx, [uhand]
        push    ax
        mov     ax, es
        xchg    ax, [uhand + 2]
        mov     es, ax
        pop     ax
        ret

f_size: mov     bx, STATE_SIZE
        ret

f_save: push    si
        push    di
        push    cx
        mov     si, state
        mov     di, dx
        mov     cx, STATE_SIZE
        rep movsb
        pop     cx
        pop     di
        pop     si
        ret

f_load: call    erase
        push    si
        push    di
        push    cx
        push    ds
        push    es
        push    es
        push    ds
        pop     es
        pop     ds
        mov     si, dx
        mov     di, state
        mov     cx, STATE_SIZE
        rep movsb
        pop     es
        pop     ds
        pop     cx
        pop     di
        pop     si
        call    draw
        ret

f_sens: mov     bx, 50
        mov     cx, 50
        mov     dx, 50
        ret

f_ver:  mov     bx, 0626h
        mov     cx, 0400h
        ret

; Keep the position inside its range.
clamp:  push    ax
        mov     ax, [x]
        cmp     ax, [minx]
        jge     .x1
        mov     ax, [minx]
.x1:    cmp     ax, [maxx]
        jle     .x2
        mov     ax, [maxx]
.x2:    mov     [x], ax
        mov     ax, [y]
        cmp     ax, [miny]
        jge     .y1
        mov     ax, [miny]
.y1:    cmp     ax, [maxy]
        jle     .y2
        mov     ax, [maxy]
.y2:    mov     [y], ax
        pop     ax
        ret

; The text cursor: the colours of the cell under the mouse, inverted.
draw:   cmp     word [hide], 0
        jne     .ret
        cmp     byte [drawn], 0
        jne     .ret
        push    ax
        push    bx
        push    es
        xor     ax, ax
        mov     es, ax
        mov     al, [es:0449h]
        cmp     al, 3
        ja      .no                     ; not a text mode
        mov     ax, [y]
        shr     ax, 3
        imul    ax, ax, 160
        mov     bx, [x]
        shr     bx, 3
        shl     bx, 1
        add     bx, ax
        inc     bx
        mov     ax, 0B800h
        mov     es, ax
        xor     byte [es:bx], 77h
        mov     [drawat], bx
        mov     byte [drawn], 1
.no:    pop     es
        pop     bx
        pop     ax
.ret:   ret

erase:  cmp     byte [drawn], 0
        je      .ret
        push    ax
        push    bx
        push    es
        mov     ax, 0B800h
        mov     es, ax
        mov     bx, [drawat]
        xor     byte [es:bx], 77h
        mov     byte [drawn], 0
        pop     es
        pop     bx
        pop     ax
.ret:   ret

; ---- interrupt 12: the mouse has something ----
irq12:  pusha
        push    ds
        push    es
        push    cs
        pop     ds
        cld
        xor     bp, bp                  ; what happened, for the program's handler
.more:  in      al, MPORT               ; buttons, and whether there is more
        mov     bl, al
        in      al, MPORT
        cbw
        mov     si, ax                  ; right
        in      al, MPORT
        cbw
        mov     di, ax                  ; down
        mov     ax, si
        or      ax, di
        jz      .still
        or      bp, 1
        call    erase
        add     [mickx], si
        add     [micky], di
        add     [x], si
        add     di, [yrem]              ; two mickeys a line
        mov     ax, di
        and     ax, 1
        mov     [yrem], ax
        sar     di, 1
        add     [y], di
        call    clamp
        call    draw
.still: test    bl, 40h
        jnz     .more
        mov     al, 20h
        out     0A0h, al
        out     20h, al

        ; The buttons that changed.
        and     bx, 7
        mov     dx, bx
        xor     dx, [btn]               ; changed
        mov     [btn], bx
        mov     cx, 2                   ; the event bit of button 0's press
        mov     si, press               ; its counts; the release's are 18 on
.btn:   test    dl, 1
        jz      .next
        mov     di, si
        mov     ax, cx
        test    bl, 1
        jnz     .rec
        shl     ax, 1                   ; released: the next event bit
        add     di, relse - press
.rec:   or      bp, ax
        inc     word [di]
        mov     ax, [x]
        mov     [di + 2], ax
        mov     ax, [y]
        mov     [di + 4], ax
.next:  shr     dl, 1
        shr     bl, 1
        shl     cx, 2
        add     si, 6
        cmp     cx, 80h
        jb      .btn

        ; The program's handler, if it asked for any of this.
        test    bp, [umask]
        jz      .out
        cmp     byte [busy], 0
        jne     .out
        mov     byte [busy], 1
        mov     ax, bp
        mov     bx, [btn]
        mov     cx, [x]
        mov     dx, [y]
        mov     si, [mickx]
        mov     di, [micky]
        call    far [uhand]
        push    cs
        pop     ds
        mov     byte [busy], 0
.out:   pop     es
        pop     ds
        popa
        iret

resident_end:

; ---- install ----
install:
        mov     dx, m_title
        mov     ah, 09h
        int     21h
        mov     ax, 3533h               ; is there a driver already?
        int     21h
        mov     ax, es
        or      ax, bx
        jz      .go
        cmp     byte [es:bx], 0CFh      ; a bare IRET is not one
        je      .go
        xor     ax, ax
        int     33h
        cmp     ax, 0FFFFh
        jne     .go
        mov     dx, m_already
        mov     ah, 09h
        int     21h
        mov     ax, 4C00h
        int     21h
.go:    out     MPORT, al               ; start the port's three bytes afresh
        mov     dx, int33
        mov     ax, 2533h
        int     21h
        mov     dx, irq12
        mov     ax, 2574h
        int     21h
        in      al, 0A1h                ; let interrupt 12 through, and the
        and     al, 0EFh                ; second controller's line on the first
        out     0A1h, al
        in      al, 21h
        and     al, 0FBh
        out     21h, al
        in      al, MPORT
        mov     bl, al
        in      al, MPORT
        in      al, MPORT
        mov     dx, m_seen
        test    bl, 80h
        jnz     .say
        mov     dx, m_wait
.say:   mov     ah, 09h
        int     21h
        mov     es, [2Ch]               ; the environment is not needed
        mov     ah, 49h
        int     21h
        mov     dx, resident_end + 15
        shr     dx, 4
        mov     ax, 3100h
        int     21h

m_title:   db   "Mach86 mouse driver", 13, 10, "$"
m_already: db   "already loaded", 13, 10, "$"
m_seen:    db   "mouse found", 13, 10, "$"
m_wait:    db   "no mouse seen yet; it will work when one is plugged in", 13, 10, "$"
