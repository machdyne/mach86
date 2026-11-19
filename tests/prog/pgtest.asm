; Mach86 test program: paging. A bootable diskette image, for
; make -C sim check-pg: on the model, in lockstep with the RTL core,
; and on the simulated SoC.
;
;   1. paging on over an identity map of the first 4 MB; the program
;      goes on running through it;
;   2. two pages at 4 MB mapped to frames that are not neighbours: a
;      doubleword written and read across the boundary lands in both
;      frames, and a read-modify-write there too;
;   3. an instruction that lies across that boundary;
;   4. a page that is not present: the fault's address and error code,
;      the handler maps it, the instruction runs again;
;   5. the accessed and dirty bits;
;   6. a read-only page: level 0 writes it without CR0.WP and faults
;      with it; INVLPG after the handler changes the entry; CMP and
;      TEST with memory there do not fault; ADC and SBB that fault
;      leave the carry alone and give the right sum when run again;
;   7. REP MOVSD into a page that is not present: the fault part of the
;      way, and the rest after the handler maps it;
;   8. paging off, and back to real mode.
;
; It prints from real mode; the last line is "pg test passed".

        cpu     486
        bits    16
        org     7C00h

start:  jmp     short .go
        nop
.go:    xor     ax, ax
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, 7C00h
        mov     ax, 0208h               ; the rest of the program
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

CODE16  equ     08h
DATA16  equ     10h
CODE32  equ     18h
DATA32  equ     20h
PDIR    equ     10000h                  ; the page directory
PT0     equ     11000h                  ; the table of 0 to 4 MB
PT1     equ     12000h                  ; ... and of 4 to 8 MB
LIN     equ     400000h                 ; where the test pages are
FRAME_A equ     20000h                  ; LIN
FRAME_B equ     30000h                  ; LIN + 1000h
FRAME_C equ     40000h                  ; LIN + 2000h, once mapped
FRAME_D equ     50000h                  ; LIN + 3000h
FRAME_E equ     60000h                  ; LIN + 4000h, once mapped

main:   cli
        lgdt    [gdtr]
        sidt    [idt_real]
        lidt    [idtr]
        mov     eax, cr0
        or      al, 1
        mov     cr0, eax
        jmp     dword CODE32:pm32

        bits    32
pm32:   mov     ax, DATA32
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     esp, 90000h

        ; The tables: 0 to 4 MB onto itself; five pages at 4 MB.
        mov     edi, PDIR
        xor     eax, eax
        mov     ecx, 3 * 1024
        rep stosd
        mov     dword [PDIR], PT0 + 7
        mov     dword [PDIR + 4], PT1 + 7
        mov     edi, PT0
        mov     eax, 7
        mov     ecx, 1024
.fill:  stosd
        add     eax, 1000h
        loop    .fill
        mov     dword [PT1], FRAME_A + 7
        mov     dword [PT1 + 4], FRAME_B + 7
        mov     dword [PT1 + 8], FRAME_C + 6        ; not present
        mov     dword [PT1 + 12], FRAME_D + 5       ; read only
        mov     dword [PT1 + 16], FRAME_E + 6       ; not present

        ; 1. Paging on.
        mov     eax, PDIR
        mov     cr3, eax
        mov     eax, cr0
        or      eax, 80000000h
        mov     cr0, eax
        jmp     short .on
.on:
        ; 2. Across two pages whose frames are apart.
        mov     dword [LIN + 0FFEh], 11223344h
        cmp     word [FRAME_A + 0FFEh], 3344h
        jne     bad
        cmp     word [FRAME_B], 1122h
        jne     bad
        cmp     dword [LIN + 0FFEh], 11223344h
        jne     bad
        add     dword [LIN + 0FFEh], 0F0F0F0F0h
        cmp     dword [LIN + 0FFEh], 02132434h
        jne     bad
        mov     word [LIN + 0FFFh], 0BEEFh
        cmp     byte [FRAME_A + 0FFFh], 0EFh
        jne     bad
        cmp     byte [FRAME_B], 0BEh
        jne     bad
        mov     eax, [LIN + 0FFEh]
        cmp     eax, 02BEEF34h
        jne     bad

        ; 3. An instruction across the boundary: MOV EAX, imm32 with
        ; its opcode in one frame and the rest in the other.
        mov     byte [FRAME_A + 0FFFh], 0B8h
        mov     dword [FRAME_B], 0CAFEF00Dh
        mov     byte [FRAME_B + 4], 0C3h            ; RET
        xor     eax, eax
        mov     ebx, LIN + 0FFFh
        call    ebx
        cmp     eax, 0CAFEF00Dh
        jne     bad
        ; ... and changed where it lies, through the frame's own address.
        mov     dword [FRAME_B], 12345678h
        call    ebx
        cmp     eax, 12345678h
        jne     bad

        ; 4. Not present.
        mov     dword [FRAME_C + 10h], 0C0FFEE00h
        mov     dword [fix], map_c
        mov     eax, [LIN + 2010h]
        cmp     eax, 0C0FFEE00h
        jne     bad
        cmp     dword [faults], 1
        jne     bad
        cmp     dword [pf_addr], LIN + 2010h
        jne     bad
        cmp     dword [pf_err], 0
        jne     bad

        ; 5. Accessed, not yet dirty; dirty after a write.
        mov     eax, [PT1 + 8]
        and     eax, 67h
        cmp     eax, 27h
        jne     bad
        mov     byte [LIN + 2020h], 1
        mov     eax, [PT1 + 8]
        and     eax, 67h
        cmp     eax, 67h
        jne     bad

        ; 6. Read only. Level 0 writes anyway ...
        mov     byte [LIN + 3000h], 55h
        cmp     byte [FRAME_D], 55h
        jne     bad
        cmp     dword [faults], 1
        jne     bad
        ; ... until CR0.WP says not to.
        mov     eax, cr0
        or      eax, 10000h
        mov     cr0, eax
        mov     dword [fix], unprotect_d
        mov     byte [LIN + 3001h], 66h
        cmp     byte [FRAME_D + 1], 66h
        jne     bad
        cmp     dword [faults], 2
        jne     bad
        cmp     dword [pf_addr], LIN + 3001h
        jne     bad
        cmp     dword [pf_err], 3               ; present, a write
        jne     bad

        ; 6b. Read only again. Reading is allowed, and a comparison
        ; with memory is only a read ...
        mov     dword [LIN + 3010h], 10h
        call    protect_d
        cmp     dword [LIN + 3010h], 10h
        jne     bad
        test    byte [LIN + 3010h], 10h
        jz      bad
        cmp     dword [faults], 2
        jne     bad
        ; ... and an ADC or SBB that faults has not touched the carry:
        ; run again, it gives what it should.
        mov     ebx, 1
        stc
        adc     [LIN + 3010h], ebx              ; 10h + 1 + carry
        cmp     dword [LIN + 3010h], 12h
        jne     bad
        call    protect_d
        stc
        sbb     dword [LIN + 3010h], 1          ; 12h - 1 - carry
        cmp     dword [LIN + 3010h], 10h
        jne     bad
        call    protect_d
        add     dword [LIN + 3010h], 5
        inc     dword [LIN + 3010h]
        cmp     dword [LIN + 3010h], 16h
        jne     bad
        cmp     dword [faults], 5
        jne     bad

        ; 7. A string move that runs into a page not present.
        mov     dword [fix], map_e
        mov     esi, src
        mov     edi, LIN + 4000h - 8
        mov     ecx, 4
        rep movsd
        cmp     dword [faults], 6
        jne     bad
        cmp     dword [pf_addr], LIN + 4000h
        jne     bad
        cmp     dword [pf_err], 2               ; not present, a write
        jne     bad
        cmp     dword [pf_ecx], 2               ; two were done when it faulted
        jne     bad
        test    ecx, ecx
        jnz     bad
        cmp     dword [FRAME_D + 0FF8h], 1
        jne     bad
        cmp     dword [FRAME_E + 4], 0CAFEF00Dh
        jne     bad

        ; 8. Out.
        mov     byte [result], 1
bad:    mov     eax, cr0
        and     eax, 7FFEFFFFh
        mov     cr0, eax
        xor     eax, eax
        mov     cr3, eax
        mov     ax, DATA16
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        jmp     CODE16:pm16

; What the handler does about the fault, by test.
map_c:  or      dword [PT1 + 8], 1
        ret
unprotect_d:
        or      dword [PT1 + 12], 2
        invlpg  [LIN + 3000h]
        ret
protect_d:
        and     dword [PT1 + 12], 0FFFFFFFDh
        invlpg  [LIN + 3000h]
        ret
map_e:  mov     [pf_ecx], ecx
        or      dword [PT1 + 16], 1
        ret

exc14:  push    eax
        mov     eax, cr2
        mov     [pf_addr], eax
        mov     eax, [esp + 4]
        mov     [pf_err], eax
        inc     dword [faults]
        call    dword [fix]
        pop     eax
        add     esp, 4
        iretd

        bits    16
pm16:   mov     eax, cr0
        and     al, 0FEh
        mov     cr0, eax
        jmp     0:real
real:   xor     ax, ax
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, 7C00h
        lidt    [idt_real]
        mov     si, m_ok
        cmp     byte [result], 1
        je      print
        mov     si, m_fail
print:  lodsb
        test    al, al
        jz      .done
        mov     ah, 0Eh
        xor     bx, bx
        int     10h
        jmp     print
.done:  hlt
        jmp     .done

m_ok:   db      "pg test passed", 13, 10, 0
m_fail: db      "pg test FAILED", 13, 10, 0
result: db      0
        align   4
fix:    dd      0
faults: dd      0
pf_addr: dd     0
pf_err: dd      0
pf_ecx: dd      0
src:    dd      1, 2, 3, 0CAFEF00Dh

        align   8
gdt:    dq      0
        dw      0FFFFh, 0, 9A00h, 0000h         ; 08: 16-bit code, 64 KB
        dw      0FFFFh, 0, 9200h, 0000h         ; 10: 16-bit data, 64 KB
        dw      0FFFFh, 0, 9A00h, 00CFh         ; 18: 32-bit code, 4 GB
        dw      0FFFFh, 0, 9200h, 00CFh         ; 20: 32-bit data, 4 GB
GDT_END:
gdtr:   dw      GDT_END - gdt - 1
        dd      gdt

%macro  gate 4                          ; vector, handler, selector, type
        times   (%1) * 8 - ($ - idt) db 0
        dw      ((%2) - $$ + 7C00h) & 0FFFFh
        dw      %3
        dw      %4
        dw      ((%2) - $$ + 7C00h) >> 16
%endmacro
        align   8
idt:
        gate    14, exc14, CODE32, 8E00h
IDT_END:
idtr:   dw      IDT_END - idt - 1
        dd      idt
idt_real: dw    0
        dd      0

        times   1474560 - ($ - $$) db 0
