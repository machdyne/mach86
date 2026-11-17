; Mach86 test program: the first part of protected mode. A bootable
; diskette image. For make -C sim check-pm: on the model, in lockstep
; with the RTL core, and on the simulated SoC with memory above 1 MB.
;
;   1. the table registers and the machine status word, stored and
;      read back;
;   2. into protected mode, segments loaded from a GDT (one with a
;      base of 1 MB), a far jump through a code descriptor, memory
;      written through them, and out again;
;   3. "unreal mode": back in real mode the limits are still 4 GB, and
;      memory at 2 MB is written, copied with REP MOVSD and compared;
;   4. the BIOS: how much memory is above 1 MB (INT 15h, 88h) and a
;      block move up there and back (INT 15h, 87h), after which the
;      limits are 64 KB again.
;
; It prints what it finds; the last line is "pm test passed".

        cpu     386
        bits    16
        org     7C00h

start:  jmp     short .go
        nop
.go:    xor     ax, ax
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, 7C00h
        mov     ax, 0203h               ; the rest of the program
        mov     cx, 0002h
        xor     dh, dh
        mov     bx, 7E00h
        int     13h
        jc      fail0
        jmp     main
fail0:  hlt
        jmp     fail0
        times   510 - ($ - $$) db 0
        dw      0AA55h

main:   mov     si, m_start
        call    puts

        ; 1. The table registers.
        lgdt    [gdtr]
        sgdt    [buf]
        mov     ax, [buf]
        cmp     ax, GDT_END - gdt - 1
        jne     fail
        mov     eax, [buf + 2]
        cmp     eax, gdt
        jne     fail
        sidt    [buf]
        mov     ax, [buf]
        call    hex16                   ; the IDT's limit: FFFF
        smsw    ax
        test    al, 1
        jnz     fail
        mov     si, m_tables
        call    puts

        ; 2. Protected mode.
        cli
        in      al, 92h
        or      al, 02h                 ; address line 20 on
        out     92h, al
        mov     eax, cr0
        or      al, 1
        mov     cr0, eax
        jmp     08h:.pm                 ; CS from the code descriptor
.pm:    mov     ax, 10h
        mov     ds, ax
        mov     es, ax
        mov     ax, 18h
        mov     fs, ax                  ; base 1 MB
        mov     dword [fs:0], 0CAFE1234h
        mov     ebx, 00100000h
        mov     eax, [ebx]              ; the same place through DS
        mov     edx, eax
        smsw    cx                      ; with PE set
        mov     eax, cr0
        and     al, 0FEh
        mov     cr0, eax
        jmp     0000h:.real
.real:  xor     ax, ax
        mov     ds, ax
        mov     es, ax
        mov     fs, ax
        sti
        cmp     edx, 0CAFE1234h
        jne     fail
        test    cl, 1
        jz      fail
        mov     si, m_pm
        call    puts

        ; 3. Unreal mode: 2 MB and up, from real mode.
        mov     edi, 00200000h
        mov     dword [edi], 11223344h
        mov     dword [edi + 4], 55667788h
        cmp     dword [edi], 11223344h
        jne     fail
        mov     esi, 00200000h
        mov     edi, 00300000h
        mov     ecx, 2
        cld
        a32 rep movsd
        mov     ebx, 00300000h
        cmp     dword [ebx + 4], 55667788h
        jne     fail
        ; ... and it is not the first megabyte seen again.
        mov     dword [ebx], 0A5A5A5A5h
        cmp     dword [0], 0A5A5A5A5h
        je      fail
        mov     si, m_unreal
        call    puts

        ; 4. The BIOS.
        mov     ah, 88h
        int     15h
        jc      fail
        push    ax
        call    hex16
        mov     si, m_kb
        call    puts
        pop     ax
        test    ax, ax
        jz      fail
        ; 16 words from `pattern` to 110000h, then from there to `buf`.
        mov     dword [bm_src], pattern
        mov     dword [bm_dst], 00110000h
        call    block_move
        mov     dword [bm_src], 00110000h
        mov     dword [bm_dst], buf
        call    block_move
        mov     si, pattern
        mov     di, buf
        mov     cx, 16
        repe cmpsw
        jne     fail
        mov     si, m_bios
        call    puts

        mov     si, m_pass
        call    puts
halt:   hlt
        jmp     halt

fail:   mov     si, m_fail
        call    puts
        jmp     halt

; Move 16 words from linear [bm_src] to linear [bm_dst] by the BIOS.
block_move:
        mov     eax, [bm_src]
        mov     [bm_tab + 12h], ax
        shr     eax, 16
        mov     [bm_tab + 14h], al
        mov     [bm_tab + 17h], ah
        mov     eax, [bm_dst]
        mov     [bm_tab + 1Ah], ax
        shr     eax, 16
        mov     [bm_tab + 1Ch], al
        mov     [bm_tab + 1Fh], ah
        push    ds
        pop     es
        mov     si, bm_tab
        mov     cx, 16
        mov     ah, 87h
        int     15h
        jc      fail
        ret

puts:   lodsb
        test    al, al
        jz      .done
        call    putc
        jmp     puts
.done:  ret

putc:   push    bx
        mov     ah, 0Eh
        mov     bx, 0007h
        int     10h
        pop     bx
        ret

hex16:  push    ax
        mov     al, ah
        call    hex8
        pop     ax
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

        align   8
gdt:    dq      0
        dw      0FFFFh, 0               ; 08h: code, 16-bit, base 0, 64 KB
        db      0, 9Ah, 00h, 0
        dw      0FFFFh, 0               ; 10h: data, base 0, 4 GB
        db      0, 92h, 8Fh, 0
        dw      0FFFFh, 0               ; 18h: data, base 1 MB, 64 KB
        db      10h, 92h, 00h, 0
GDT_END:
gdtr:   dw      GDT_END - gdt - 1
        dd      gdt

bm_src: dd      0
bm_dst: dd      0
bm_tab: times 30h db 0
        ; (limits and access bytes of the two the BIOS reads)
pattern: dw     0102h, 0304h, 0506h, 0708h, 1112h, 1314h, 1516h, 1718h
         dw     2122h, 2324h, 2526h, 2728h, 3132h, 3334h, 3536h, 0AA55h
buf:    times 32 db 0

m_start:  db    "pm test", 13, 10, 0
m_tables: db    " tables ok", 13, 10, 0
m_pm:     db    "protected mode ok", 13, 10, 0
m_unreal: db    "unreal mode ok", 13, 10, 0
m_kb:     db    " KB above 1 MB", 13, 10, 0
m_bios:   db    "block move ok", 13, 10, 0
m_pass:   db    "pm test passed", 13, 10, 0
m_fail:   db    "pm test FAILED", 13, 10, 0

        times   4 * 512 - ($ - $$) db 0
        times   720 * 512 - ($ - $$) db 0
