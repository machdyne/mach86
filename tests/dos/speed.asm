; Mach86: how fast is this machine? A .COM program.
;
; Runs a fixed mix of ordinary instructions -- moves, arithmetic, a
; memory variable, stack traffic, a call and return, a conditional
; jump -- for 18 timer ticks, just under a second, and prints how many
; instructions that was. The mix is 20 instructions a round, counted
; by hand below. It is not a benchmark of anything but itself: it is
; here so that the same number can be read off the simulator and off
; the board.

        cpu     386
        bits    16
        org     100h

ROUND   equ     20                      ; instructions in one round

start:  mov     dx, m_title
        mov     ah, 09h
        int     21h

        ; Wait for a tick to begin, then run until 18 more have passed.
        xor     ax, ax
        mov     es, ax
        mov     bx, [es:046Ch]
.edge:  cmp     bx, [es:046Ch]
        je      .edge
        mov     bx, [es:046Ch]
        add     bx, 18
        xor     esi, esi                ; rounds done

.round: mov     ax, [var]               ;  1
        add     ax, si                  ;  2
        mov     [var], ax               ;  3
        push    ax                      ;  4
        push    bx                      ;  5
        mov     cx, ax                  ;  6
        and     cx, 0Fh                 ;  7
        shl     ax, 1                   ;  8
        xor     ax, cx                  ;  9
        call    leaf                    ; 10 (and 11, 12, 13 inside)
        pop     bx                      ; 14
        pop     ax                      ; 15
        inc     word [count]            ; 16
        inc     esi                     ; 17
        mov     di, [es:046Ch]          ; 18
        cmp     di, bx                  ; 19
        jne     .round                  ; 20

        ; esi rounds in 18 ticks of 1/18.2065 s: instructions a second
        ; = esi * ROUND * 18.2065 / 18. Printed in thousands.
        mov     eax, esi
        mov     ecx, ROUND * 182065 / 18 ; times ten thousand
        mul     ecx                     ; edx:eax
        mov     ecx, 10000 * 1000
        div     ecx                     ; eax = thousands of instructions a second
        mov     ebx, eax

        mov     dx, m_rounds
        mov     ah, 09h
        int     21h
        mov     eax, esi
        call    decimal
        mov     dx, m_speed
        mov     ah, 09h
        int     21h
        mov     eax, ebx
        call    decimal
        mov     dx, m_unit
        mov     ah, 09h
        int     21h
        mov     ax, 4C00h
        int     21h

leaf:   add     ax, 3                   ; 11
        sub     cx, ax                  ; 12
        ret                             ; 13

; Print eax in decimal.
decimal:
        mov     di, digits + 10
        mov     ecx, 10
.digit: xor     edx, edx
        div     ecx
        add     dl, '0'
        dec     di
        mov     [di], dl
        test    eax, eax
        jnz     .digit
        mov     dx, di
        mov     ah, 09h
        int     21h
        ret

m_title:  db    "Mach86 speed: a second of ordinary instructions", 13, 10, "$"
m_rounds: db    "rounds: $"
m_speed:  db    13, 10, "thousand instructions a second: $"
m_unit:   db    13, 10, "$"
digits:   times 10 db 0
          db    "$"
var:      dw    0
count:    dw    0
