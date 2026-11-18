; SBTEST.COM: the Sound Blaster (docs/sound.md). It resets the DSP,
; asks its version, has it raise its interrupt, plays a block of a
; triangle wave through DMA channel 1, then three blocks in a row
; with automatic restart, and looks at the DMA controller's counters
; along the way. The last line is "SB test passed". You should hear
; a short tone, twice.

        cpu     386
        org     100h
BASE    equ     220h
IRQ     equ     7
BLOCK   equ     2000

start:  mov     dx, m_hello
        call    print

        ; The DSP: reset, and the byte that says it is there.
        mov     dx, BASE + 6
        mov     al, 1
        out     dx, al
        mov     cx, 200
.d:     in      al, 61h
        loop    .d
        xor     al, al
        out     dx, al
        call    dsp_get
        cmp     al, 0AAh
        jne     fail

        ; Its version.
        mov     al, 0E1h
        call    dsp_put
        call    dsp_get
        mov     bh, al
        call    dsp_get
        mov     bl, al
        cmp     bh, 2
        jb      fail

        ; Its interrupt.
        mov     ax, 3500h + 8 + IRQ
        int     21h
        mov     [old_off], bx
        mov     [old_seg], es
        mov     ax, 2500h + 8 + IRQ
        mov     dx, isr
        int     21h
        in      al, 21h
        mov     [old_mask], al
        and     al, ~(1 << IRQ)
        out     21h, al
        mov     al, 0F2h
        call    dsp_put
        mov     cx, 1
        call    wait_irqs
        jc      fail_r

        ; A wave: a triangle, 32 samples a period.
        push    ds
        pop     es
        mov     di, buffer
        mov     cx, BLOCK
        xor     bx, bx
.w:     mov     al, bl
        and     al, 31
        cmp     al, 16
        jb      .up
        neg     al
        add     al, 32
.up:    shl     al, 3
        add     al, 64
        stosb
        inc     bx
        loop    .w

        ; Where it is in memory. (A DMA block may not cross 64 KB:
        ; this program is small enough to be moved back if it would.)
        mov     ax, ds
        mov     dx, ax
        shr     dx, 12                  ; the page
        shl     ax, 4
        add     ax, buffer
        adc     dl, 0
        mov     [addr], ax
        mov     [page], dl
        add     ax, BLOCK - 1
        jc      fail_r

        mov     al, 0D1h                ; speaker on
        call    dsp_put
        mov     al, 40h                 ; 22 kHz
        call    dsp_put
        mov     al, 0D3h
        call    dsp_put

        ; One block.
        mov     byte [irqs], 0
        mov     bl, 49h                 ; single transfers, from memory, channel 1
        mov     cx, BLOCK - 1
        call    dma_setup
        mov     al, 14h
        call    dsp_put
        mov     al, (BLOCK - 1) & 255
        call    dsp_put
        mov     al, (BLOCK - 1) >> 8
        call    dsp_put
        mov     cx, 1
        call    wait_irqs
        jc      fail_r
        in      al, 08h                 ; the channel reached its count
        test    al, 2
        jz      fail_r
        out     0Ch, al
        in      al, 03h
        mov     ah, al
        in      al, 03h
        cmp     ax, 0FFFFh              ; (both bytes FFh)
        jne     fail_r

        ; Three blocks of 500 with automatic restart, over and over
        ; the same 1,000 bytes.
        mov     byte [irqs], 0
        mov     bl, 59h                 ; ... and the channel starts again by itself
        mov     cx, 1000 - 1
        call    dma_setup
        mov     al, 48h
        call    dsp_put
        mov     al, (500 - 1) & 255
        call    dsp_put
        mov     al, (500 - 1) >> 8
        call    dsp_put
        mov     al, 1Ch
        call    dsp_put
        mov     cx, 3
        call    wait_irqs
        jc      fail_r
        out     0Ch, al                 ; the address is inside the block
        in      al, 02h
        mov     ah, al
        in      al, 02h
        xchg    al, ah
        sub     ax, [addr]
        cmp     ax, 1000
        jae     fail_r
        mov     al, 0DAh                ; stop after this block
        call    dsp_put
        mov     cx, 4
        call    wait_irqs
        jc      fail_r
        mov     cx, 5                   ; and no fifth
        call    wait_irqs
        jnc     fail_r
        mov     al, 0D3h
        call    dsp_put

        ; The AdLib at the Sound Blaster's ports, found the way Apogee's
        ; sound library looks for it: timer 1 is started and the status
        ; read a hundred times "to wait"; the timer must have run out.
        mov     ax, 6004h
        call    opl
        mov     ax, 8004h
        call    opl
        mov     dx, BASE + 8
        in      al, dx
        test    al, 0E0h
        jnz     fail_r
        mov     ax, 0FF02h
        call    opl
        mov     ax, 2104h
        call    opl
        mov     dx, BASE + 8
        mov     cx, 100
.wt:    in      al, dx
        loop    .wt
        in      al, dx
        and     al, 0E0h
        cmp     al, 0C0h
        jne     fail_r
        mov     ax, 6004h
        call    opl
        mov     ax, 8004h
        call    opl

        call    restore
        mov     dx, m_ok
        call    print
        mov     ax, 4C00h
        int     21h

fail_r: call    restore
fail:   mov     dx, m_fail
        call    print
        mov     ax, 4C01h
        int     21h

restore:
        mov     al, 5                   ; the channel off
        out     0Ah, al
        mov     al, [old_mask]
        out     21h, al
        push    ds
        mov     dx, [old_off]
        mov     ds, [old_seg]
        mov     ax, 2500h + 8 + IRQ
        int     21h
        pop     ds
        ret

; Program channel 1: mode BL, count CX, the buffer's address.
dma_setup:
        mov     al, 5
        out     0Ah, al
        out     0Ch, al
        mov     al, bl
        out     0Bh, al
        mov     ax, [addr]
        out     02h, al
        mov     al, ah
        out     02h, al
        mov     al, cl
        out     03h, al
        mov     al, ch
        out     03h, al
        mov     al, [page]
        out     83h, al
        mov     al, 1
        out     0Ah, al
        ret

; Wait until CX interrupts have come; carry if a second passes first.
wait_irqs:
        push    es
        xor     ax, ax
        mov     es, ax
        mov     bx, [es:46Ch]
        add     bx, 19
.l:     cmp     [irqs], cl
        jae     .ok
        cmp     [es:46Ch], bx
        jne     .l
        pop     es
        stc
        ret
.ok:    pop     es
        clc
        ret

isr:    push    ax
        push    dx
        push    ds
        push    cs
        pop     ds
        inc     byte [irqs]
        mov     dx, BASE + 0Eh          ; tell the DSP it was seen
        in      al, dx
        mov     al, 20h
        out     20h, al
        pop     ds
        pop     dx
        pop     ax
        iret

; AdLib register AL = AH, through 228h and 229h.
opl:    mov     dx, BASE + 8
        out     dx, al
        inc     dx
        mov     al, ah
        out     dx, al
        ret

dsp_put:
        push    ax
        mov     dx, BASE + 0Ch
.b:     in      al, dx
        test    al, 80h
        jnz     .b
        pop     ax
        out     dx, al
        ret

dsp_get:
        mov     dx, BASE + 0Eh
        mov     cx, 0FFFFh
.b:     in      al, dx
        test    al, 80h
        loopz   .b
        mov     dx, BASE + 0Ah
        in      al, dx
        ret

print:  mov     ah, 9
        int     21h
        ret

m_hello: db     "Sound Blaster at 220h, interrupt 7, DMA 1", 13, 10, "$"
m_ok:   db      "SB test passed", 13, 10, "$"
m_fail: db      "SB test FAILED", 13, 10, "$"
irqs:   db      0
old_mask: db    0
page:   db      0
addr:   dw      0
old_off: dw     0
old_seg: dw     0
buffer:
