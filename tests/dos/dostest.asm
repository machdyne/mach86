; Mach86 test program: a .COM program run as the DOS shell.
;
; It checks that DOS itself works on the machine: console output, the
; DOS version, memory allocation, creating, writing, reading back and
; deleting a file, a directory search, the date, and keyboard input.
; Each test prints its name and "ok"; the last line is
; "dos test passed".
;
; Put on a boot disk as DOSTEST.COM with CONFIG.SYS: SHELL=DOSTEST.COM

        cpu     386
        bits    16
        org     100h

start:  mov     dx, m_hello
        call    print

        ; DOS version
        mov     dx, m_ver
        call    print
        mov     ax, 3000h
        int     21h
        cmp     al, 2
        jb      fail
        call    ok

        ; Allocate and free memory
        mov     dx, m_alloc
        call    print
        mov     ah, 4Ah                 ; shrink our own block first
        mov     bx, 1000h
        int     21h
        jc      fail
        mov     ah, 48h
        mov     bx, 400h                ; 16 KB
        int     21h
        jc      fail
        mov     es, ax
        mov     ah, 49h
        int     21h
        jc      fail
        push    cs
        pop     es
        call    ok

        ; Create a file and write to it
        mov     dx, m_write
        call    print
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, fname
        int     21h
        jc      fail
        mov     [handle], ax
        mov     di, buffer              ; 3000 bytes of a known pattern
        mov     cx, 3000
        xor     ax, ax
.fill:  stosb
        add     al, 7
        loop    .fill
        mov     ah, 40h
        mov     bx, [handle]
        mov     cx, 3000
        mov     dx, buffer
        int     21h
        jc      fail
        cmp     ax, 3000
        jne     fail
        mov     ah, 3Eh
        mov     bx, [handle]
        int     21h
        jc      fail
        call    ok

        ; Read it back
        mov     dx, m_read
        call    print
        mov     di, buffer
        mov     cx, 3000
        xor     al, al
        rep stosb
        mov     ax, 3D00h
        mov     dx, fname
        int     21h
        jc      fail
        mov     [handle], ax
        mov     ah, 3Fh
        mov     bx, [handle]
        mov     cx, 4000
        mov     dx, buffer
        int     21h
        jc      fail
        cmp     ax, 3000
        jne     fail
        mov     ah, 3Eh
        mov     bx, [handle]
        int     21h
        mov     si, buffer
        mov     cx, 3000
        xor     ah, ah
.check: lodsb
        cmp     al, ah
        jne     fail
        add     ah, 7
        loop    .check
        call    ok

        ; Find it in the directory
        mov     dx, m_find
        call    print
        mov     ah, 1Ah                 ; disk transfer area
        mov     dx, buffer
        int     21h
        mov     ah, 4Eh
        xor     cx, cx
        mov     dx, fname
        int     21h
        jc      fail
        cmp     word [buffer+1Ah], 3000 ; its size
        jne     fail
        call    ok

        ; Delete it
        mov     dx, m_del
        call    print
        mov     ah, 41h
        mov     dx, fname
        int     21h
        jc      fail
        mov     ax, 3D00h
        mov     dx, fname
        int     21h
        jnc     fail                    ; it must be gone
        call    ok

        ; Date
        mov     dx, m_date
        call    print
        mov     ah, 2Ah
        int     21h
        cmp     cx, 1980
        jb      fail
        call    ok

        ; Keyboard, through DOS
        mov     dx, m_keys
        call    print
.key:   mov     ah, 08h
        int     21h
        cmp     al, 13
        je      .typed
        mov     dl, al
        mov     ah, 02h
        int     21h
        jmp     .key
.typed: mov     dx, m_crlf
        call    print

        mov     dx, m_pass
        call    print
        ; Back to whoever started us. (As the shell there is nobody:
        ; then DOS's answer is its own business, and we stop.)
        mov     ax, 4C00h
        int     21h
done:   hlt
        jmp     done

print:  mov     ah, 09h
        int     21h
        ret

ok:     mov     dx, m_ok
        jmp     print

fail:   mov     dx, m_fail
        call    print
        mov     ax, 4C01h
        int     21h
        jmp     done

m_hello: db     "Mach86 DOS test", 13, 10, "$"
m_ver:   db     "version $"
m_alloc: db     "memory $"
m_write: db     "file write $"
m_read:  db     "file read $"
m_find:  db     "directory $"
m_del:   db     "delete $"
m_date:  db     "date $"
m_keys:  db     "type something: $"
m_ok:    db     "ok", 13, 10, "$"
m_fail:  db     "FAILED", 13, 10, "$"
m_pass:  db     "dos test passed", 13, 10, "$"
m_crlf:  db     13, 10, "$"
fname:   db     "MACH86.TMP", 0
handle:  dw     0

buffer:
