; Mach86 test program: a bootable diskette image that draws in each
; graphics mode, by the BIOS and straight into the video memory, the
; ways programs do: bytes, words and double words in the 256-colour
; mode; the graphics controller's write modes, logical functions, bit
; mask, set/reset and both read modes in the 16-colour mode; the two
; CGA modes. After each picture it prints a line and waits for a key,
; so that the bench can take the picture and compare it (the model's
; with the display's, pixel for pixel).
;
; Run by `make -C sim check-gfx`.

        cpu     386
        bits    16

; Assembled with -DDOSCOM it is a DOS program, GFX.COM on the boot
; disk, for looking at the same pictures on a board: a key for the
; next one.
%ifdef DOSCOM
        org     100h
        jmp     main
%else
        org     7C00h

SECTORS equ     720

boot:   jmp     short start
        nop
        db      "MACH86  "
        dw      512
        db      2
        dw      1
        db      2
        dw      112
        dw      SECTORS
        db      0FDh
        dw      2
        dw      9
        dw      2
        dw      0

start:  xor     ax, ax
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, 7C00h
        mov     ax, 0207h               ; the rest: sectors 2 to 8
        mov     bx, 7E00h
        mov     cx, 0002h
        xor     dh, dh
        int     13h
        jc      .fail
        jmp     main
.fail:  hlt
        jmp     .fail

        times   510 - ($ - $$) db 0
        dw      0AA55h

%endif

; ---- helpers -----------------------------------------------------------

puts:   lodsb                           ; ds:si, colour in bl
        test    al, al
        jz      .done
        mov     ah, 0Eh
        int     10h
        jmp     puts
.done:  ret

hex8:   push    ax                      ; al as two digits
        shr     al, 4
        call    .digit
        pop     ax
.digit: and     al, 0Fh
        add     al, '0'
        cmp     al, '9'
        jbe     .put
        add     al, 7
.put:   mov     ah, 0Eh
        int     10h
        ret

key:    xor     ah, ah
        int     16h
        ret

gc:     push    dx                      ; al = register, ah = value
        mov     dx, 3CEh
        out     dx, ax
        pop     dx
        ret

; ---- the pictures --------------------------------------------------------

main:
; 256 colours.
        mov     ax, 0013h
        int     10h
        mov     ax, 0A000h
        mov     es, ax
        xor     di, di
        xor     dx, dx                  ; row
.row13: xor     cx, cx                  ; column
.col13: mov     al, cl
        xor     al, dl
        stosb
        inc     cx
        cmp     cx, 320
        jb      .col13
        inc     dx
        cmp     dx, 200
        jb      .row13
        ; A block, written as double words at an odd address.
        mov     di, 80 * 320 + 101
        mov     bx, 20
.blk:   mov     eax, 2C2B2A29h
        mov     cx, 25
        rep stosd
        add     di, 320 - 100
        dec     bx
        jnz     .blk
        ; A row copied as words.
        push    ds
        push    es
        pop     ds
        mov     si, 10 * 320
        mov     di, 190 * 320
        mov     cx, 160
        rep movsw
        pop     ds
        ; A diagonal by the BIOS, and one colour changed.
        xor     cx, cx
.diag:  mov     dx, cx
        mov     ax, 0C0Fh
        xor     bh, bh
        int     10h
        inc     cx
        cmp     cx, 200
        jb      .diag
        mov     ax, 1010h
        mov     bx, 002Ah
        mov     dh, 63
        mov     ch, 32
        mov     cl, 0
        int     10h
        mov     ax, 0D00h               ; read a pixel back: 5 xor 7
        mov     cx, 5
        mov     dx, 7
        int     10h
        push    ax
        mov     ah, 02h                 ; text, at row 3
        xor     bh, bh
        mov     dx, 0300h
        int     10h
        mov     bl, 14
        mov     si, m_13
        call    puts
        pop     ax
        call    hex8
        mov     si, m_ready
        call    puts
        call    key

; Sixteen colours in planes.
        mov     ax, 000Dh
        int     10h
        mov     ax, 0A000h
        mov     es, ax
        ; Rows 0-49: sixteen bars by set/reset.
        mov     ax, 0F01h               ; enable set/reset on all planes
        call    gc
        xor     dx, dx
.bars:  xor     bx, bx                  ; byte column
.bar:   mov     ah, bl
        shr     ah, 1
        and     ah, 0Fh
        add     ah, dl
        and     ah, 0Fh
        xor     al, al
        call    gc                      ; set/reset = the colour
        imul    di, dx, 40
        add     di, bx
        mov     byte [es:di], 0
        inc     bx
        cmp     bx, 40
        jb      .bar
        inc     dx
        cmp     dx, 50
        jb      .bars
        mov     ax, 0001h
        call    gc
        ; Rows 50-99: write mode 2 through two masks.
        mov     ax, 0205h
        call    gc
        mov     dx, 50
.m2row: xor     bx, bx
.m2:    imul    di, dx, 40
        add     di, bx
        mov     ax, 0F008h
        call    gc
        mov     al, [es:di]             ; (loads the latches)
        mov     al, bl
        mov     [es:di], al
        mov     ax, 0F08h
        call    gc
        mov     al, [es:di]
        mov     al, bl
        not     al
        mov     [es:di], al
        inc     bx
        cmp     bx, 40
        jb      .m2
        inc     dx
        cmp     dx, 100
        jb      .m2row
        mov     ax, 0FF08h
        call    gc
        ; Rows 60-69: exclusive-or white over what is there.
        mov     ax, 1803h
        call    gc
        mov     di, 60 * 40
        mov     cx, 10 * 40
.xor:   mov     al, [es:di]
        mov     byte [es:di], 0Fh       ; write mode 2: colour 15
        inc     di
        loop    .xor
        mov     ax, 0003h
        call    gc
        ; Rows 100-119: write mode 3, colour 12 through a pattern,
        ; rotated by one.
        mov     ax, 0305h
        call    gc
        mov     ax, 0C00h
        call    gc
        mov     ax, 0103h
        call    gc
        mov     di, 100 * 40
        mov     cx, 20 * 40
.m3:    mov     al, [es:di]
        mov     byte [es:di], 0CCh
        inc     di
        loop    .m3
        mov     ax, 0003h
        call    gc
        mov     ax, 0000h
        call    gc
        ; Rows 150-199: rows 0-49 copied through the latches.
        mov     ax, 0105h
        call    gc
        push    ds
        push    es
        pop     ds
        xor     si, si
        mov     di, 150 * 40
        mov     cx, 50 * 40
        rep movsb
        pop     ds
        mov     ax, 0005h
        call    gc
        ; Rows 120-139: plain bytes to planes 0 and 2 only.
        mov     dx, 3C4h
        mov     ax, 0502h
        out     dx, ax
        mov     di, 120 * 40
        mov     cx, 20 * 40
        mov     al, 0F0h
        rep stosb
        mov     ax, 0F02h
        out     dx, ax
        ; What the read modes say of byte 55 * 40 + 3 (colours 3 and 12).
        mov     ah, 02h
        xor     bh, bh
        mov     dx, 1200h               ; row 18
        int     10h
        mov     bl, 15
        mov     si, m_0d
        call    puts
        mov     di, 55 * 40 + 3
        xor     cx, cx
.rm0:   mov     ah, cl
        mov     al, 04h
        call    gc
        mov     al, [es:di]
        call    hex8
        inc     cx
        cmp     cx, 4
        jb      .rm0
        mov     ax, 0004h
        call    gc
        mov     ax, 0805h               ; read mode 1: where is colour 3?
        call    gc
        mov     ax, 0302h
        call    gc
        mov     al, [es:di]
        call    hex8
        mov     ax, 0005h
        call    gc
        mov     ax, 0C00h               ; a pixel by the BIOS, and back
        mov     al, 9
        mov     cx, 300
        mov     dx, 140
        xor     bh, bh
        int     10h
        mov     ah, 0Dh
        int     10h
        call    hex8
        mov     si, m_ready
        call    puts
        call    key

; Four colours, the CGA way.
        mov     ax, 0004h
        int     10h
        mov     ax, 0B800h
        mov     es, ax
        xor     di, di                  ; even lines: bands of the four
        mov     cx, 100 * 80
.c4e:   mov     ax, di
        shr     ax, 9
        and     al, 3
        imul    ax, ax, 55h
        stosb
        loop    .c4e
        mov     di, 2000h               ; odd lines: a pattern of words
        mov     cx, 100 * 40
        mov     ax, 0E41Bh
        rep stosw
        mov     cx, 20                  ; a line by the BIOS
.c4p:   mov     dx, 150
        mov     ax, 0C02h
        xor     bh, bh
        push    cx
        add     cx, 100
        int     10h
        pop     cx
        loop    .c4p
        mov     ax, 0B00h               ; a blue background
        mov     bx, 0001h
        int     10h
        mov     ah, 02h
        xor     bh, bh
        mov     dx, 0A00h
        int     10h
        mov     bl, 3
        mov     si, m_04
        call    puts
        mov     si, m_ready
        call    puts
        call    key

; Two colours.
        mov     ax, 0006h
        int     10h
        mov     ax, 0B800h
        mov     es, ax
        xor     di, di
        mov     cx, 2000h / 2
        mov     ax, 0AA55h
        rep stosw
        mov     di, 2000h
        mov     cx, 2000h / 4
        mov     eax, 0FF00F00Fh
        rep stosd
        mov     ah, 02h
        xor     bh, bh
        mov     dx, 0C10h
        int     10h
        mov     bl, 1
        mov     si, m_06
        call    puts
        mov     si, m_ready
        call    puts
        call    key

; And text again.
        mov     ax, 0003h
        int     10h
        mov     bl, 7
        mov     si, m_done
        call    puts
%ifdef DOSCOM
        mov     ax, 4C00h
        int     21h
%else
.halt:  hlt
        jmp     .halt
%endif

m_13:    db     "mode 13h ", 0
m_0d:    db     "mode 0Dh ", 0
m_04:    db     "mode 04h", 0
m_06:    db     "mode 06h", 0
m_ready: db     " ready", 13, 10, 0
m_done:  db     "graphics test done", 13, 10, 0

%ifndef DOSCOM
        times   8 * 512 - ($ - $$) db 0
        times   SECTORS * 512 - ($ - $$) db 0
%endif
