; Mach86: a 64 KB ROM image that runs a flat 16-bit C program.
;
; The program (PROG, linked at 0100h) is copied to segment 1000h,
; where code, data and stack share one segment, and is called there.
; It returns here to halt.

        cpu     386
        bits    16
        org     0

prog:   incbin  PROG
prog_end:

        times   0F000h - ($ - $$) db 0
start:  mov     ax, 1000h
        mov     es, ax
        mov     ss, ax
        mov     esp, 0FFF0h
        xor     si, si
        mov     di, 100h
        mov     cx, (prog_end - prog + 1) / 2
.copy:  mov     ax, [cs:si]
        mov     [es:di], ax
        add     si, 2
        add     di, 2
        dec     cx
        jnz     .copy
        mov     ax, es
        mov     ds, ax
        xor     eax, eax
        xor     ebx, ebx
        xor     ecx, ecx
        xor     edx, edx
        xor     esi, esi
        xor     edi, edi
        xor     ebp, ebp
        call    1000h:0100h
        hlt

        times   0FFF0h - ($ - $$) db 0
        jmp     0F000h:start
        times   10000h - ($ - $$) db 0
