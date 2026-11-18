; Mach86 test program: protected mode, the third part: privilege
; levels. A bootable diskette image, for make -C sim check-pm3: on the
; model, in lockstep with the RTL core, and on the simulated SoC.
;
;   1. down to level 3 with IRETD (a stack switch outward; the level-0
;      data segment left in DS is emptied on the way);
;   2. what level 3 may not do, each a general-protection fault with
;      its error code, taken at level 0 on the stack the task state
;      segment names: CLI, HLT, MOV from CR0, IN, loading a level-0
;      data segment, INT through a level-0 gate, a far call to level-0
;      code, a write to a read-only segment, a read through a null
;      selector; and a segment that is not present (fault 11);
;   3. POPFD at level 3 changes neither IF nor the I/O privilege level;
;   4. INT through a level-3 gate: in at level 0 on the inner stack,
;      the outer stack pointer in the frame, back with IRETD;
;   5. a call gate to level 0 and RETF back out (a level-0 segment
;      loaded there is emptied on the way);
;   6. a far call to conforming code: the level stays 3;
;   7. ARPL, and LAR, LSL and VERR on segments level 3 may not see;
;  7b. a 286's task state segment and a 16-bit gate: in on the stack
;      it names, 16-bit frame, back with a 16-bit IRET;
;   8. the timer's interrupt, taken while at level 3 (through a 32-bit
;      gate, onto the 16-bit stack);
;   9. back to level 0 through a gate, and to real mode.
;
; It prints from real mode; the last line is "pm3 test passed".

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
CODE0   equ     18h
DATA0   equ     20h
STACK0  equ     28h
TSSSEL  equ     30h
CODE3   equ     38h + 3
DATA3   equ     40h + 3
CGATE   equ     48h + 3
CONF    equ     50h + 3
RODATA  equ     58h + 3
ABSENT  equ     60h + 3
TSS16SEL equ    68h
TSS     equ     80000h

main:   cli
        lgdt    [gdtr]
        sidt    [idt_real]
        lidt    [idtr]
        mov     eax, cr0
        or      al, 1
        mov     cr0, eax
        jmp     dword CODE0:pm32

; ---------------------------------------------------------------
        bits    32
pm32:   mov     ax, DATA0
        mov     ds, ax
        mov     es, ax
        mov     ax, STACK0
        mov     ss, ax
        mov     esp, 90000h

        ; The task state segment: only the level-0 stack matters.
        mov     edi, TSS
        xor     eax, eax
        mov     ecx, 26
        rep stosd
        mov     dword [TSS + 4], 90000h
        mov     dword [TSS + 8], STACK0
        mov     word [TSS + 66h], 104   ; no I/O permission bitmap
        mov     ax, TSSSEL
        ltr     ax
        mov     al, 0FFh
        out     21h, al                 ; no hardware interrupts yet
        xor     edx, edx

        ; 1. Down to level 3.
        push    dword DATA3
        push    dword 70000h
        push    dword 0202h             ; IF on, I/O privilege level 0
        push    dword CODE3
        push    dword user
        iretd

; ---- level 3 ---------------------------------------------------
user:   mov     ax, ds                  ; the level-0 segment is gone
        test    ax, ax
        jnz     ubad
        mov     ax, cs
        and     ax, 3
        cmp     ax, 3
        jne     ubad
        mov     ax, DATA3
        mov     ds, ax
        mov     es, ax

        ; 2. Faults. `fault code, instruction`: the handler checks the
        ; error code and goes on at the label after.
%macro  fault 2+
        mov     dword [experr], %1
        mov     dword [resume], %%next
        %2
        jmp     ubad
%%next:
%endmacro
        mov     byte [expvec], 13
        fault   0, cli
        fault   0, hlt
        fault   0, mov eax, cr0
        fault   0, in al, 60h
        mov     ax, DATA0
        fault   DATA0, mov fs, ax
        fault   41h * 8 + 2, int 41h
        fault   CODE0, call CODE0:0
        mov     ax, RODATA
        mov     fs, ax
        mov     al, [fs:result]         ; reading it is fine
        fault   0, mov [fs:result], al
        xor     ax, ax
        mov     gs, ax                  ; a null selector loads ...
        fault   0, mov al, [gs:result]  ; ... and cannot be used
        mov     byte [expvec], 11
        mov     ax, ABSENT
        fault   ABSENT & 0FFFCh, mov fs, ax
        cmp     dword [faults], 10
        jne     ubad

        ; 3. POPFD here leaves IF and the I/O privilege level alone.
        pushfd
        pop     eax
        or      eax, 3000h
        and     eax, ~200h
        xor     eax, 1                  ; (but the carry flag changes)
        push    eax
        popfd
        pushfd
        pop     ebx
        and     ebx, 3201h
        cmp     ebx, 0201h
        jne     ubad
        clc

        ; 4. A gate level 3 may use.
        mov     esi, esp
        int     40h
        cmp     edx, 1
        jne     ubad
        cmp     esi, esp
        jne     ubad

        ; 5. A call gate, and back.
        call    CGATE:0
        cmp     edx, 3
        jne     ubad
        mov     ax, gs                  ; what level 0 left there is gone
        test    ax, ax
        jnz     ubad
        cmp     esi, esp
        jne     ubad

        ; 6. Conforming code runs at the caller's level.
        call    CONF:conf
        cmp     edx, 7
        jne     ubad

        ; 7. ARPL; LAR, LSL and VERR.
        mov     ax, 08h
        mov     bx, 13h
        arpl    ax, bx
        jnz     ubad
        cmp     ax, 0Bh
        jne     ubad
        arpl    ax, bx
        jz      ubad
        mov     word [scratch], 20h
        mov     bx, 22h
        arpl    [scratch], bx
        jnz     ubad
        cmp     word [scratch], 22h
        jne     ubad
        mov     ax, DATA0
        lar     ebx, ax                 ; not visible from here
        jz      ubad
        lsl     ebx, ax
        jz      ubad
        verr    ax
        jz      ubad
        mov     ax, DATA3
        lar     ebx, ax
        jnz     ubad
        cmp     ebx, 00C0F300h          ; (accessed by now)
        jne     ubad
        lsl     ebx, ax
        jnz     ubad
        cmp     ebx, 0FFFFFFFFh
        jne     ubad
        verw    ax
        jnz     ubad
        mov     ax, RODATA
        verw    ax
        jz      ubad
        mov     ax, CONF                ; conforming code: any level may look
        lar     ebx, ax
        jnz     ubad
        mov     ax, TSSSEL
        lar     ebx, ax                 ; a level-0 system segment
        jz      ubad

        ; 7b. A 286 task state segment, a 16-bit gate.
        int     45h                     ; (level 0 changes the task register)
        mov     esp, 6800h              ; a 16-bit frame holds only SP
        int     44h
        cmp     esp, 6800h
        jne     ubad
        mov     esp, esi
        cmp     edx, 15
        jne     ubad

        ; 8. The timer's interrupt while at level 3.
        int     43h                     ; (level 0 opens the line)
.wait:  cmp     byte [ticked], 0
        je      .wait

        ; 9. Out.
        mov     byte [result], 1
ubad:   int     42h
        jmp     ubad

; ---- level 0 ---------------------------------------------------
conf:   mov     ax, cs                  ; conforming, level 0, called from 3
        and     ax, 3
        cmp     ax, 3
        jne     .bad
        lea     edx, [edx*2 + 1]
.bad:   retf

cgate0: mov     ax, cs
        test    ax, 3
        jnz     .bad
        cmp     dword [esp + 4], CODE3  ; the caller, and its stack
        jne     .bad
        cmp     dword [esp + 8], esi
        jne     .bad
        cmp     dword [esp + 12], DATA3
        jne     .bad
        mov     ax, ss
        cmp     ax, STACK0
        jne     .bad
        mov     ax, DATA0
        mov     gs, ax
        lea     edx, [edx*2 + 1]
.bad:   retf

int40:  mov     ax, cs
        test    ax, 3
        jnz     .bad
        pushfd
        pop     eax
        test    eax, 200h               ; an interrupt gate: IF is off
        jnz     .bad
        cmp     dword [esp + 4], CODE3
        jne     .bad
        test    dword [esp + 8], 200h   ; ... and was on outside
        jz      .bad
        cmp     dword [esp + 12], esi
        jne     .bad
        cmp     dword [esp + 16], DATA3
        jne     .bad
        lea     eax, [esp + 20]         ; the inner stack was empty
        cmp     eax, 90000h
        jne     .bad
        lea     edx, [edx*2 + 1]
.bad:   iretd

int45:  push    eax
        push    edi
        push    ecx
        push    es
        mov     ax, DATA0
        mov     es, ax
        mov     edi, TSS + 100h
        xor     eax, eax
        mov     ecx, 11
        rep stosd
        mov     word [es:TSS + 102h], 6000h     ; SP0
        mov     word [es:TSS + 104h], DATA16    ; SS0
        mov     ax, TSS16SEL
        ltr     ax
        pop     es
        pop     ecx
        pop     edi
        pop     eax
        iretd

int43:  mov     al, 0FEh                ; only line 0
        out     21h, al
        iretd

; General protection and not present: the error code is checked and
; the program goes on where it said.
exc11:  cmp     byte [expvec], 11
        jne     excbad
        jmp     short exc
exc13:  cmp     byte [expvec], 13
        jne     excbad
exc:    mov     eax, [esp]
        cmp     eax, [experr]
        jne     excbad
        mov     ax, cs
        test    ax, 3
        jnz     excbad
        cmp     dword [esp + 8], CODE3
        jne     excbad
        inc     dword [faults]
        mov     eax, [resume]
        mov     [esp + 4], eax
        add     esp, 4
        iretd
excbad: mov     byte [result], 0
        jmp     short out0

irq0:   push    eax
        push    ds
        mov     ax, DATA0
        mov     ds, ax
        mov     byte [ticked], 1
        mov     al, 0FFh
        out     21h, al
        mov     al, 20h
        out     20h, al
        pop     ds
        pop     eax
        iretd

; INT 42h: the way out. 16-bit segments first, then PE off.
out0:
int42:  cli
        mov     ax, DATA16
        mov     ds, ax
        mov     es, ax
        mov     fs, ax
        mov     gs, ax
        mov     ss, ax
        jmp     CODE16:pm16

        bits    16
; (In the 16-bit code segment, base 0, on the stack of the 286 TSS.)
int44:  mov     bp, sp
        mov     ax, cs
        cmp     ax, CODE16
        jne     .bad
        mov     ax, ss
        cmp     ax, DATA16
        jne     .bad
        cmp     sp, 6000h - 10          ; five words
        jne     .bad
        cmp     word [bp + 2], CODE3
        jne     .bad
        cmp     word [bp + 6], 6800h
        jne     .bad
        cmp     word [bp + 8], DATA3
        jne     .bad
        lea     edx, [edx*2 + 1]
.bad:   iret

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

m_ok:   db      "pm3 test passed", 13, 10, 0
m_fail: db      "pm3 test FAILED", 13, 10, 0
result: db      0
ticked: db      0
expvec: db      0
        align   4
experr: dd      0
resume: dd      0
faults: dd      0
scratch: dd     0

        align   8
gdt:    dq      0
        dw      0FFFFh, 0, 9A00h, 0000h         ; 08: 16-bit code, 64 KB
        dw      0FFFFh, 0, 9200h, 0000h         ; 10: 16-bit data, 64 KB
        dw      0FFFFh, 0, 9A00h, 00CFh         ; 18: level-0 code
        dw      0FFFFh, 0, 9200h, 00CFh         ; 20: level-0 data
        dw      0FFFFh, 0, 9200h, 00CFh         ; 28: level-0 stack
        dw      103, 0, 8908h, 0                ; 30: the task state segment, at 80000h
        dw      0FFFFh, 0, 0FA00h, 00CFh        ; 38: level-3 code
        dw      0FFFFh, 0, 0F200h, 00CFh        ; 40: level-3 data
        dw      (cgate0 - $$ + 7C00h) & 0FFFFh, CODE0, 0EC00h, (cgate0 - $$ + 7C00h) >> 16
                                                ; 48: a call gate level 3 may use
        dw      0FFFFh, 0, 9E00h, 00CFh         ; 50: conforming code, level 0
        dw      0FFFFh, 0, 0F000h, 00CFh        ; 58: level-3 data, read only
        dw      0FFFFh, 0, 7200h, 00CFh         ; 60: level-3 data, not present
        dw      43, 0100h, 8108h, 0             ; 68: a 286 task state segment, at 80100h
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
        gate    8, irq0, CODE0, 8E00h
        gate    11, exc11, CODE0, 8E00h
        gate    13, exc13, CODE0, 8E00h
        gate    40h, int40, CODE0, 0EE00h
        gate    41h, int40, CODE0, 8E00h
        gate    42h, int42, CODE0, 0EE00h
        gate    43h, int43, CODE0, 0EE00h
        gate    44h, int44, CODE16, 0E600h
        gate    45h, int45, CODE0, 0EE00h
IDT_END:
idtr:   dw      IDT_END - idt - 1
        dd      idt
idt_real: dw    0
        dd      0

        times   1474560 - ($ - $$) db 0
