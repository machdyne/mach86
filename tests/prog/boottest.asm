; Mach86 test program: a bootable 360 KB diskette image that exercises
; the BIOS services DOS depends on, and says so on the screen.
;
; Run by `make -C sim check` with scripted keys. Each test prints its
; name and "ok"; the last line is "boot test passed".

        cpu     386
        bits    16
        org     7C00h

SECTORS equ     720

boot:   jmp     short start
        nop
        db      "MACH86  "              ; a diskette-style parameter block,
        dw      512                     ; which is how the BIOS recognises
        db      2                       ; the image as drive A:
        dw      1
        db      2
        dw      112
        dw      SECTORS
        db      0FDh
        dw      2
        dw      9                       ; sectors per track
        dw      2                       ; heads
        dw      0

start:  xor     ax, ax
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, 7C00h
        mov     [drive], dl

        ; The rest of this program is in sectors 2 to 5.
        mov     ax, 0204h
        mov     bx, 7E00h
        mov     cx, 0002h
        xor     dh, dh
        int     13h
        jc      .fail
        jmp     main
.fail:  mov     si, m_load
        call    puts
        hlt

puts:   lodsb
        test    al, al
        jz      .done
        mov     ah, 0Eh
        mov     bx, 7
        int     10h
        jmp     puts
.done:  ret

drive:  db      0
m_load: db      "cannot load", 13, 10, 0

        times   510 - ($ - $$) db 0
        dw      0AA55h

; ---- sector 2 onwards ----------------------------------------------

main:   mov     si, m_hello
        call    puts

        ; Memory size.
        mov     si, m_mem
        call    puts
        int     12h                     ; 639 with 640 KB; a board with
        cmp     ax, 639                 ; block RAM only has less
        ja      fail
        cmp     ax, 127
        jb      fail
        and     al, 0Fh                 ; a multiple of 16 KB, less one
        cmp     al, 0Fh
        jne     fail
        call    ok

        ; Equipment: one diskette drive, colour text.
        mov     si, m_equip
        call    puts
        int     11h
        and     ax, 0031h
        cmp     ax, 0021h
        jne     fail
        call    ok

        ; Disk parameters.
        mov     si, m_parm
        call    puts
        push    es                      ; the call returns a pointer in es:di
        mov     ah, 08h
        mov     dl, [drive]
        int     13h
        pop     es
        jc      fail
        cmp     cx, 2709h               ; 40 cylinders, 9 sectors
        jne     fail
        cmp     dh, 1
        jne     fail
        call    ok

        ; Read the last sector of the disk and check its marker.
        mov     si, m_read
        call    puts
        mov     ax, 0201h
        mov     bx, buffer
        mov     cx, 2709h               ; cylinder 39, sector 9
        mov     dh, 1
        mov     dl, [drive]
        int     13h
        jc      fail
        cmp     dword [buffer], 'LAST'
        jne     fail
        call    ok

        ; Write a sector, read it back, restore it.
        mov     si, m_write
        call    puts
        mov     di, buffer
        mov     cx, 256
        mov     ax, 5AA5h
        rep stosw
        mov     ax, 0301h
        mov     bx, buffer
        mov     cx, 2708h               ; cylinder 39, sector 8
        mov     dh, 1
        mov     dl, [drive]
        int     13h
        jc      fail
        mov     di, buffer
        mov     cx, 256
        xor     ax, ax
        rep stosw
        mov     ax, 0201h
        mov     bx, buffer
        mov     cx, 2708h
        mov     dh, 1
        mov     dl, [drive]
        int     13h
        jc      fail
        cmp     word [buffer+510], 5AA5h
        jne     fail
        call    ok

        ; A request past the end must fail.
        mov     si, m_range
        call    puts
        mov     ax, 0201h
        mov     bx, buffer
        mov     cx, 280Ah               ; sector 10 of 9
        mov     dh, 0
        mov     dl, [drive]
        int     13h
        jnc     fail
        call    ok

        ; The timer: wait for the tick count to move.
        mov     si, m_timer
        call    puts
        xor     ah, ah
        int     1Ah
        mov     bx, dx
        mov     cx, 40
.tick:  hlt
        push    cx
        xor     ah, ah
        int     1Ah
        pop     cx
        cmp     dx, bx
        jne     .moved
        loop    .tick
        jmp     fail
.moved: call    ok

        ; The clock.
        mov     si, m_clock
        call    puts
        mov     ah, 04h
        int     1Ah
        jc      fail
        cmp     cx, 1990h
        jne     fail
        call    ok

        ; Screen: write at a position and read it back.
        mov     si, m_screen
        call    puts
        mov     ah, 03h
        xor     bh, bh
        int     10h
        push    dx
        mov     ah, 02h
        mov     dx, 1040h               ; row 16, column 64
        int     10h
        mov     ax, 0941h               ; 'A', attribute 1Eh
        mov     bx, 001Eh
        mov     cx, 1
        int     10h
        mov     ah, 08h
        int     10h
        mov     cx, ax
        pop     dx
        mov     ah, 02h
        xor     bh, bh
        int     10h
        cmp     cx, 1E41h
        jne     fail
        call    ok

        ; Keyboard: echo keys until Enter.
        mov     si, m_keys
        call    puts
.key:   xor     ah, ah
        int     16h
        cmp     al, 13
        je      .typed
        mov     ah, 0Eh
        mov     bx, 7
        int     10h
        jmp     .key
.typed: mov     si, m_crlf
        call    puts

        mov     si, m_pass
        call    puts
done:   hlt
        jmp     done

ok:     mov     si, m_ok
        jmp     puts

fail:   mov     si, m_fail
        call    puts
        jmp     done

m_hello:  db    "Mach86 boot test", 13, 10, 0
m_mem:    db    "memory size ", 0
m_equip:  db    "equipment ", 0
m_parm:   db    "disk parameters ", 0
m_read:   db    "disk read ", 0
m_write:  db    "disk write ", 0
m_range:  db    "disk range ", 0
m_timer:  db    "timer ", 0
m_clock:  db    "clock ", 0
m_screen: db    "screen ", 0
m_keys:   db    "type something: ", 0
m_ok:     db    "ok", 13, 10, 0
m_fail:   db    "FAILED", 13, 10, 0
m_pass:   db    "boot test passed", 13, 10, 0
m_crlf:   db    13, 10, 0

buffer  equ     9000h

        times   5 * 512 - ($ - $$) db 0

; ---- the rest of the disk -------------------------------------------

        times   (SECTORS - 1) * 512 - ($ - $$) db 0
        db      "LAST"
        times   SECTORS * 512 - ($ - $$) db 0
