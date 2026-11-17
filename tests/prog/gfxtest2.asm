; Mach86 test program: the video modes with more than 200 lines, which
; need more video memory than the first 64 KB: 640 x 480 (mode 12h)
; and 640 x 350 (mode 10h), 16 colours. A bootable diskette image, or
; with -DDOSCOM a DOS program (GFX2.COM). Draws in each, reads some of
; it back and prints that, and waits for a key.
;
; For make -C sim check-gfx2: the model's picture and the SoC's are
; compared pixel for pixel.

        cpu     386
        bits    16
%ifdef DOSCOM
        org     100h
%else
        org     7C00h
        jmp     short start
        nop
start:  xor     ax, ax
        mov     ds, ax
        mov     ss, ax
        mov     sp, 7C00h
        ; The rest of the program is in the sectors after this one.
        mov     ax, 0207h
        mov     cx, 0002h
        xor     dh, dh                  ; the drive the BIOS booted from
        mov     bx, 7E00h
        push    ds
        pop     es
        int     13h
        jc      .fail
        jmp     main
.fail:  hlt
        jmp     .fail
        times   510 - ($ - $$) db 0
        dw      0AA55h
%endif

main:   mov     ax, 0012h
        mov     bx, 480
        call    picture
        mov     si, m_12
        call    report
        mov     ax, 0010h
        mov     bx, 350
        call    picture
        mov     si, m_10
        call    report
        mov     ax, 0003h
        int     10h
        mov     si, m_done
        call    puts
%ifdef DOSCOM
        mov     ax, 4C00h
        int     21h
%else
.halt:  hlt
        jmp     .halt
%endif

; Set mode AX and draw, on BX lines:
;   - every line a band of colour, 30 lines a colour, by set/reset
;   - a column of single pixels through the BIOS, down the diagonal
;   - a block written with only planes 0 and 2 open (colour 5 over
;     whatever is there), near the bottom
;   - the top 16 lines copied to 16 lines above the bottom through the
;     latches (write mode 1)
;   - a checker of bytes by write mode 2 at the right edge
picture:
        mov     [lines], bx
        int     10h
        mov     ax, 0A000h
        mov     es, ax
        mov     ax, 0F01h               ; set/reset on all planes
        call    gc
        xor     dx, dx                  ; line
.band:  mov     ax, dx
        mov     bl, 30
        div     bl                      ; al = line / 30
        mov     ah, al
        xor     al, al                  ; set/reset = the band's colour
        call    gc
        imul    di, dx, 80
        mov     cx, 80
        mov     al, 0FFh
        rep stosb
        inc     dx
        cmp     dx, [lines]
        jb      .band
        mov     ax, 0001h               ; set/reset off again
        call    gc

        ; The diagonal, by the BIOS: white.
        xor     dx, dx
.diag:  mov     cx, dx
        add     cx, 40
        mov     ax, 0C0Fh
        xor     bh, bh
        int     10h
        inc     dx
        cmp     dx, [lines]
        jb      .diag

        ; Planes 0 and 2 only: FFh into both, 40 bytes wide, 20 lines,
        ; starting 60 lines above the bottom.
        mov     dx, 3C4h
        mov     ax, 0502h
        out     dx, ax
        mov     bx, [lines]
        sub     bx, 60
        mov     dx, 20
.pl:    imul    di, bx, 80
        add     di, 20
        mov     cx, 40
        mov     al, 0FFh
        rep stosb
        inc     bx
        dec     dx
        jnz     .pl
        mov     dx, 3C4h
        mov     ax, 0F02h
        out     dx, ax

        ; The top 16 lines to 16 lines above the bottom, by the latches.
        mov     ax, 0105h
        call    gc
        xor     si, si
        mov     di, [lines]
        sub     di, 16
        imul    di, di, 80
        mov     cx, 16 * 80
        push    ds
        push    es
        pop     ds
        rep movsb
        pop     ds

        ; Write mode 2 at the right edge: the byte is the colour.
        mov     ax, 0205h
        call    gc
        xor     dx, dx
.m2:    imul    di, dx, 80
        add     di, 76
        mov     al, dl
        shr     al, 3
        mov     ah, al
        inc     ah
        stosw                           ; two bytes, two colours
        inc     dx
        cmp     dx, [lines]
        jb      .m2
        mov     ax, 0005h
        call    gc
        ret

; Print the name at SI and what four places read back as: the planes
; of a byte far down the picture (read mode 0), and a pixel there and
; one near the top through the BIOS.
report: xor     bl, bl
        call    puts
        mov     bx, [lines]
        sub     bx, 50                  ; inside the planes-0-and-2 block
        imul    di, bx, 80
        add     di, 30
        xor     cx, cx
.pln:   mov     ah, cl
        mov     al, 04h
        call    gc
        mov     al, [es:di]
        call    hex8
        inc     cl
        cmp     cl, 4
        jb      .pln
        mov     ax, 0004h
        call    gc
        mov     al, ' '
        call    putc
        mov     dx, [lines]
        sub     dx, 50
        mov     cx, 300
        mov     ah, 0Dh
        xor     bh, bh
        int     10h
        call    hex8
        mov     dx, 45
        mov     cx, 85                  ; the diagonal
        mov     ah, 0Dh
        xor     bh, bh
        int     10h
        call    hex8
        mov     dx, 45
        mov     cx, 300
        mov     ah, 0Dh
        xor     bh, bh
        int     10h
        call    hex8
        mov     si, m_ready
        call    puts
        xor     ah, ah
        int     16h
        ret

puts:   lodsb
        test    al, al
        jz      .done
        call    putc
        jmp     puts
.done:  ret

putc:   push    bx
        mov     ah, 0Eh
        mov     bx, 000Fh
        int     10h
        pop     bx
        ret

hex8:   push    ax
        shr     al, 4
        call    .digit
        pop     ax
.digit: and     al, 0Fh
        add     al, '0'
        cmp     al, '9'
        jbe     putc
        add     al, 7
        jmp     putc

gc:     push    dx                      ; al = register, ah = value
        mov     dx, 3CEh
        out     dx, ax
        pop     dx
        ret

lines:   dw     0
m_12:    db     "mode 12h ", 0
m_10:    db     "mode 10h ", 0
m_ready: db     " ready", 13, 10, 0
m_done:  db     "graphics test 2 done", 13, 10, 0

%ifndef DOSCOM
        times   8 * 512 - ($ - $$) db 0
        times   720 * 512 - ($ - $$) db 0
%endif
