; Mach86: is extended memory usable? A .COM program. Asks for an XMS
; driver (HIMEM and its kin; interrupt 2Fh), says how much memory it
; offers, takes 1 MB of it, copies a pattern up into its far end and
; back down, compares, and gives the memory back.

        cpu     386
        bits    16
        org     100h

start:  mov     ax, 4300h
        int     2Fh
        cmp     al, 80h
        je      .have
        mov     dx, m_none
        jmp     quit1
.have:  mov     ax, 4310h
        int     2Fh
        mov     [xms], bx
        mov     [xms + 2], es

        mov     ah, 08h                 ; free extended memory
        call    far [xms]
        push    dx
        mov     dx, m_free
        mov     ah, 09h
        int     21h
        pop     ax                      ; total free, KB
        call    putn
        mov     dx, m_kb
        mov     ah, 09h
        int     21h

        mov     ah, 09h                 ; allocate 1,024 KB
        mov     dx, 1024
        call    far [xms]
        cmp     ax, 1
        jne     fail
        mov     [handle], dx

        ; Down here to 1,020 KB into the block ...
        mov     dword [m_len], 256
        mov     word [m_sh], 0
        mov     word [m_so], pattern
        mov     [m_so + 2], cs
        mov     [m_dh], dx
        mov     dword [m_do], 1020 * 1024
        call    move
        ; ... and back down to another place.
        mov     ax, [handle]
        mov     [m_sh], ax
        mov     dword [m_so], 1020 * 1024
        mov     word [m_dh], 0
        mov     word [m_do], copy
        mov     [m_do + 2], cs
        call    move
        mov     si, pattern
        mov     di, copy
        mov     cx, 128
        push    cs
        pop     es
        cld
        repe cmpsw
        jne     fail

        mov     ah, 0Ah                 ; free it
        mov     dx, [handle]
        call    far [xms]
        cmp     ax, 1
        jne     fail
        mov     dx, m_ok
        mov     ah, 09h
        int     21h
        mov     ax, 4C00h
        int     21h

fail:   mov     dx, m_fail
quit1:  mov     ah, 09h
        int     21h
        mov     ax, 4C01h
        int     21h

move:   mov     ah, 0Bh
        mov     si, m_len
        call    far [xms]
        cmp     ax, 1
        jne     fail
        ret

; AX in decimal.
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

xms:    dd      0
handle: dw      0
; The move structure: length, source handle and offset, destination
; handle and offset. Handle 0 means a real-mode segment:offset.
m_len:  dd      0
m_sh:   dw      0
m_so:   dd      0
m_dh:   dw      0
m_do:   dd      0

m_none: db      "no XMS driver (DEVICE=HIMEMX.EXE in CONFIG.SYS)", 13, 10, "$"
m_free: db      "XMS: $"
m_kb:   db      " KB free", 13, 10, "$"
m_ok:   db      "XMS test passed", 13, 10, "$"
m_fail: db      "XMS test FAILED", 13, 10, "$"

pattern:
%assign i 0
%rep 128
        dw      (0A500h + i * 257) & 0FFFFh
%assign i i + 1
%endrep
copy:   times 256 db 0
