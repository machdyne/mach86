; Mach86 test program: protected mode, the second part. A bootable
; diskette image, for make -C sim check-pm2: on the model, in lockstep
; with the RTL core, and on the simulated SoC.
;
;   1. 32-bit code and a 32-bit stack: a code segment with the D bit
;      and a stack segment with the B bit, calls, pushes and string
;      moves without prefixes, 16-bit operands with them;
;  1b. code above 2 MB that is overwritten while cached;
;   2. interrupts through an IDT of gates: INT n through a 32-bit
;      interrupt gate (IF goes off), a 32-bit trap gate (IF stays) and
;      a 16-bit gate into a 16-bit code segment, each back with IRET;
;   3. faults: an invalid opcode (no error code), a segment-limit
;      violation (general protection, with an error code), a divide
;      error; the handlers step over the instruction;
;   4. a hardware interrupt, the timer's, taken in 32-bit code;
;   5. the local descriptor table: LLDT, a segment loaded from it,
;      SLDT; LTR and STR;
;   6. back to real mode.
;
; It prints from real mode; the last line is "pm2 test passed".

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
        mov     ax, 0204h               ; the rest of the program
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
STACK32 equ     28h
LDTSEL  equ     30h
TSSSEL  equ     38h
LDATA   equ     0Ch                     ; entry 1 of the local table

main:   cli
        lgdt    [gdtr]
        sidt    [idt_real]
        lidt    [idtr]
        mov     eax, cr0
        or      al, 1
        mov     cr0, eax
        jmp     dword CODE32:pm32

; ---------------------------------------------------------------
        bits    32
pm32:   mov     ax, DATA32
        mov     ds, ax
        mov     es, ax
        mov     ax, STACK32
        mov     ss, ax
        mov     esp, 90000h             ; above 64 KB: the pointer is ESP

        ; 1. 32-bit defaults.
        mov     eax, 12345678h
        push    eax
        push    word 0ABCDh             ; a 16-bit push, by prefix
        pop     bx
        pop     ecx
        cmp     ecx, eax
        jne     bad
        cmp     bx, 0ABCDh
        jne     bad
        cmp     esp, 90000h
        jne     bad
        call    sub32
        cmp     eax, 12345679h
        jne     bad
        mov     esi, src
        mov     edi, 0A0000h - 16       ; (plain memory in this machine's model: below the screen)
        mov     edi, 80000h
        mov     ecx, 4
        cld
        rep movsd
        cmp     dword [80000h + 12], 0CAFEF00Dh
        jne     bad
        enter   8, 0
        mov     dword [ebp - 4], 55AA55AAh
        leave
        pushad
        popad
        pushfd
        popfd
        mov     ebx, 80000h
        lea     edx, [ebx + ecx*4 + 12]
        cmp     dword [edx], 0CAFEF00Dh
        jne     bad
        mov     ax, [ebx + 12]          ; a 16-bit operand, by prefix
        cmp     ax, 0F00Dh
        jne     bad
        mov     si, 12                  ; a 16-bit address, by prefix
        mov     al, [si + 0]
        jmp     .far
.far:   jmp     CODE32:.there           ; a far jump within 32-bit code
.there:

        ; 1b. Code above 2 MB, changed while it is in use: a routine
        ; copied to 3 MB, called, its constant overwritten, called
        ; again; data stored beside it in between.
        mov     esi, hicode
        mov     edi, 300000h
        mov     ecx, hicode_end - hicode
        rep movsb
        mov     ebx, 300000h
        call    ebx
        cmp     eax, 11111111h
        jne     bad
        mov     dword [300000h + 100h], 5   ; the same page, not the code
        call    ebx
        cmp     eax, 11111111h
        jne     bad
        mov     dword [300000h + 1], 22222222h   ; the MOV's constant
        call    ebx
        cmp     eax, 22222222h
        jne     bad
        mov     byte [300000h + 4], 33h          ; one byte of it
        call    ebx
        cmp     eax, 33222222h
        jne     bad

        ; 2. Interrupts through gates.
        xor     edx, edx
        pushfd
        or      dword [esp], 200h       ; IF on (the PIC's lines are masked)
        popfd
        int     40h                     ; a 32-bit interrupt gate
        cmp     edx, 1
        jne     bad
        int     41h                     ; a 32-bit trap gate
        cmp     edx, 3
        jne     bad
        int     42h                     ; a 16-bit gate, 16-bit code
        cmp     edx, 7
        jne     bad
        cli

        ; 3. Faults.
        ud2                             ; invalid opcode: the handler steps over it
        cmp     edx, 15
        jne     bad
        mov     ax, DATA16              ; a 64 KB segment
        mov     fs, ax
        mov     al, [fs:12345h]         ; outside it: general protection
        nop                             ; (the handler steps over four bytes ... see it)
        cmp     edx, 31
        jne     bad
        xor     ecx, ecx
        mov     eax, 1
        div     ecx                     ; divide error: two bytes
        cmp     edx, 63
        jne     bad

        ; 4. The timer's interrupt (vector 8), in 32-bit code.
        mov     al, 0FEh
        out     21h, al                 ; only line 0
        sti
.wait:  cmp     byte [ticked], 0
        je      .wait
        cli
        mov     al, 0FFh
        out     21h, al

        ; 5. The local table, and the task register.
        mov     ax, LDTSEL
        lldt    ax
        sldt    bx
        cmp     bx, LDTSEL
        jne     bad
        sldt    word [80020h]
        cmp     word [80020h], LDTSEL
        jne     bad
        mov     ax, LDATA
        mov     gs, ax                  ; base 80000h, from the local table
        cmp     dword [gs:12], 0CAFEF00Dh
        jne     bad
        mov     ax, TSSSEL
        mov     [80024h], ax
        ltr     word [80024h]
        str     cx
        cmp     cx, TSSSEL
        jne     bad
        xor     ax, ax
        lldt    ax

        ; 6. Out: 16-bit segments first, then PE off.
        mov     byte [result], 1
bad:    mov     ax, DATA16
        mov     ds, ax
        mov     es, ax
        mov     fs, ax
        mov     gs, ax
        mov     ss, ax
        jmp     CODE16:pm16

sub32:  inc     eax
        ret
hicode: mov     eax, 11111111h
        ret
hicode_end:

; The handlers. EDX collects a bit from each, so the order shows.
int40:  pushfd
        pop     eax
        test    eax, 200h               ; an interrupt gate: IF is off
        jnz     .bad
        lea     edx, [edx*2 + 1]
.bad:   iretd
int41:  pushfd
        pop     eax
        test    eax, 200h               ; a trap gate: IF is still on
        jz      .bad
        lea     edx, [edx*2 + 1]
.bad:   iretd
exc6:   lea     edx, [edx*2 + 1]
        add     dword [esp], 2          ; over UD2
        iretd
exc13:  lea     edx, [edx*2 + 1]
        cmp     dword [esp], 0          ; the error code
        jne     .bad
        add     esp, 4
        add     dword [esp], 7          ; over the load (prefix, opcode, ModRM, disp32)
        iretd
.bad:   add     esp, 4
        iretd
exc0:   lea     edx, [edx*2 + 1]
        add     dword [esp], 2          ; over DIV ECX
        iretd
irq0:   push    eax
        mov     byte [ticked], 1
        mov     al, 20h
        out     20h, al
        pop     eax
        iretd

        bits    16
; (In the 16-bit code segment, base 0, on the 32-bit stack.)
int42:  lea     edx, [edx*2 + 1]
        iret

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

m_ok:   db      "pm2 test passed", 13, 10, 0
m_fail: db      "pm2 test FAILED", 13, 10, 0
result: db      0
ticked: db      0

        align   4
src:    dd      1, 2, 3, 0CAFEF00Dh

        align   8
gdt:    dq      0
        dw      0FFFFh, 0, 9A00h, 0000h         ; 08: 16-bit code, 64 KB
        dw      0FFFFh, 0, 9200h, 0000h         ; 10: 16-bit data, 64 KB
        dw      0FFFFh, 0, 9A00h, 00CFh         ; 18: 32-bit code, 4 GB
        dw      0FFFFh, 0, 9200h, 00CFh         ; 20: 32-bit data, 4 GB
        dw      0FFFFh, 0, 9200h, 00CFh         ; 28: 32-bit stack
        dw      15, ldt, 8200h, 0               ; 30: the local table
        dw      103, 0, 8908h, 0                ; 38: a task state segment at 80000h
GDT_END:
gdtr:   dw      GDT_END - gdt - 1
        dd      gdt

        align   8
ldt:    dq      0
        dw      0FFFFh, 0, 9208h, 0040h         ; 0C: data, base 80000h

; The IDT: 8 bytes a gate. Only the ones used are filled in.
%macro  gate 4                          ; vector, handler, selector, type
        times   (%1) * 8 - ($ - idt) db 0
        dw      ((%2) - $$ + 7C00h) & 0FFFFh
        dw      %3
        dw      %4
        dw      ((%2) - $$ + 7C00h) >> 16
%endmacro
        align   8
idt:
        gate    0, exc0, CODE32, 8E00h
        gate    6, exc6, CODE32, 8E00h
        gate    8, irq0, CODE32, 8E00h
        gate    13, exc13, CODE32, 8E00h
        gate    40h, int40, CODE32, 8E00h
        gate    41h, int41, CODE32, 8F00h
        gate    42h, int42, CODE16, 8600h
IDT_END:
idtr:   dw      IDT_END - idt - 1
        dd      idt
idt_real: dw    0
        dd      0

        times   1474560 - ($ - $$) db 0
