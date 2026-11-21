; Mach86 test program: the floating-point unit (docs/fpu.md). A
; bootable diskette image, for make -C sim check-fpu: on the model with
; its FPU (m86pc -fpu). It checks what has one right answer -- exact
; results, rounding, the status word's bits, the saved state's layout,
; the two ways an exception that is not masked reaches a handler -- and
; that the transcendental functions are where they should be to within
; a few units in the last place. A failure prints the number of the
; step that failed.
;
; The last line it prints is "fpu test passed".

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

%macro  STEP 1
        mov     byte [step], %1
%endmacro
; The double at [res] is the 64 bits given.
%macro  CHKQ 2                  ; high, low
        cmp     dword [res+4], %1
        jne     fail
        cmp     dword [res], %2
        jne     fail
%endmacro
; The status word's condition bits (C3 C2 C1 C0 = 4000h 0400h 0200h 0100h).
%macro  CHKCC 2                 ; mask, value
        fnstsw  ax
        and     ax, %1
        cmp     ax, %2
        jne     fail
%endmacro

main:
; ---- 1: the BIOS found it ----
        STEP    1
        int     11h
        test    al, 2
        jz      fail
        fninit
        fnstcw  [res]
        cmp     word [res], 037Fh
        jne     fail
        fnstsw  ax
        test    ax, ax
        jnz     fail

; ---- 2: exact arithmetic and rounding to double ----
        STEP    2
        fld1
        fld1
        faddp   st1, st0                ; 2
        fld     st0
        fsqrt
        fstp    qword [res]
        CHKQ    3FF6A09Eh, 667F3BCDh
        fsqrt
        fstp    tword [res]             ; and to 64 bits
        cmp     dword [res], 0F9DE6484h
        jne     fail
        cmp     dword [res+4], 0B504F333h
        jne     fail
        cmp     word [res+8], 3FFFh
        jne     fail
        fild    word [n10]
        fidiv   word [n3]
        fstp    qword [res]
        CHKQ    400AAAAAh, 0AAAAAAABh
        fld     dword [f0_1]            ; 0.1 as a single, times ten, less one:
        fimul   word [n10]              ; what is left of the single's error
        fld1
        fsubp   st1, st0
        fstp    qword [res]
        CHKQ    3E500000h, 00000000h
        fldpi
        fstp    tword [res]
        cmp     dword [res], 2168C235h
        jne     fail
        cmp     dword [res+4], 0C90FDAA2h
        jne     fail
        fld     qword [d_big]           ; overflow of a single: infinity, and the flags say so
        fstp    dword [res]
        cmp     dword [res], 7F800000h
        jne     fail
        fnstsw  ax
        and     al, 3Fh
        cmp     al, 28h                 ; overflow and precision
        jne     fail
        fnclex

; ---- 3: rounding control and integers ----
        STEP    3
        fld     dword [f2_5]
        fist    word [res]              ; to nearest: the even one
        cmp     word [res], 2
        jne     fail
        mov     word [cw], 0B7Fh        ; up
        fldcw   [cw]
        fist    word [res]
        cmp     word [res], 3
        jne     fail
        fchs
        mov     word [cw], 0F7Fh        ; toward zero
        fldcw   [cw]
        fist    dword [res]
        cmp     dword [res], -2
        jne     fail
        mov     word [cw], 077Fh        ; down
        fldcw   [cw]
        fistp   qword [res]
        cmp     dword [res], -3
        jne     fail
        cmp     dword [res+4], -1
        jne     fail
        mov     word [cw], 037Fh
        fldcw   [cw]
        fild    dword [k_big]           ; 123456789 * 1000 as an integer of 64 bits
        fimul   word [n1000]
        fistp   qword [res]
        cmp     dword [res], 0BE991A08h ; 123456789000 = 1C_BE991A08h
        jne     fail
        cmp     dword [res+4], 1Ch
        jne     fail
        fld     qword [d_big]           ; does not fit: the indefinite integer, invalid
        fistp   word [res]
        cmp     word [res], 8000h
        jne     fail
        fnstsw  ax
        test    al, 01h
        jz      fail
        fnclex
        mov     word [cw], 027Fh        ; 53 bits: 1 + 2^-60 is 1
        fldcw   [cw]
        fld1
        fld     tword [t_tiny]
        faddp   st1, st0
        fld1
        fcompp
        CHKCC   4500h, 4000h            ; equal
        mov     word [cw], 037Fh        ; 64 bits: it is not
        fldcw   [cw]
        fld1
        fld     tword [t_tiny]
        faddp   st1, st0
        fld1
        fcompp
        CHKCC   4500h, 0100h            ; 1 is below

; ---- 4: comparisons, examination, remainder ----
        STEP    4
        fldz
        fld1
        fcom    st1
        CHKCC   4500h, 0000h            ; 1 > 0
        fxch
        fcom    st1
        CHKCC   4500h, 0100h            ; 0 < 1
        fnstsw  ax
        sahf
        jnb     fail
        ftst
        CHKCC   4500h, 4000h
        fxam
        CHKCC   4700h, 4000h            ; zero, positive
        fchs
        fxam
        CHKCC   4700h, 4200h            ; zero, negative
        fstp    st0
        fxam
        CHKCC   4700h, 0400h            ; a normal number
        fstp    st0
        fxam
        CHKCC   4500h, 4100h            ; empty
        fld     dword [f_nan]
        fld1
        fucom   st1
        CHKCC   4500h, 4500h            ; unordered
        fnstsw  ax
        test    al, 01h
        jnz     fail                    ; and quietly
        fcompp
        fnstsw  ax
        test    al, 01h
        jz      fail                    ; FCOM minds
        fnclex
        fild    word [n3]
        fild    word [n10]
        fprem                           ; 10 mod 3 = 1, quotient 3
        CHKCC   4700h, 4200h
        fld1
        fcompp
        CHKCC   4500h, 4000h
        fstp    st0
        fild    word [n3]
        fild    word [n11]
        fprem1                          ; 11 to the nearest multiple: -1, quotient 4
        CHKCC   4700h, 0100h
        fld1
        fchs
        fcompp
        CHKCC   4500h, 4000h
        fstp    st0
        fild    word [n3]
        fld1
        fscale                          ; 8
        fxtract                         ; exponent 3, significand 1
        fld1
        fcompp
        CHKCC   4500h, 4000h
        fistp   word [res]
        cmp     word [res], 3
        jne     fail
        fstp    st0

; ---- 5: packed decimal ----
        STEP    5
        fild    dword [k_odd]           ; 1234567, and a half: to the even 1234568
        fld     dword [f0_5]
        faddp   st1, st0
        fchs
        fbstp   [res]
        cmp     dword [res], 01234568h
        jne     fail
        cmp     dword [res+4], 0
        jne     fail
        cmp     word [res+8], 8000h
        jne     fail
        fbld    [bcd]
        fistp   dword [res]
        cmp     dword [res], 98765432
        jne     fail

; ---- 6: the transcendental functions, roughly ----
        STEP    6
        fldpi                           ; 2 sin(pi/6) = 1
        fidiv   word [n6]
        fsin
        fadd    st0, st0
        call    near_one
        fldpi                           ; cos(pi/3) * 2 = 1
        fidiv   word [n3]
        fcos
        fadd    st0, st0
        call    near_one
        fld1                            ; 4 atan(1) / pi = 1
        fld1
        fpatan
        fimul   word [n4]
        fldpi
        fdivp   st1, st0
        call    near_one
        fldpi                           ; tan(pi/4) = 1, and FPTAN's 1
        fidiv   word [n4]
        fptan
        fld1
        fcompp
        CHKCC   4500h, 4000h
        call    near_one
        fld1                            ; log2(8) / 3 = 1
        fild    word [n8]
        fyl2x
        fidiv   word [n3]
        call    near_one
        fld     dword [f0_5]            ; (2^0.5 - 1 + 1)^2 / 2 = 1
        f2xm1
        fld1
        faddp   st1, st0
        fmul    st0, st0
        fidiv   word [n2]
        call    near_one
        fld1                            ; log2(1 + 0.25) - log2(1.25) + 1 = 1
        fld     dword [f0_25]
        fyl2xp1
        fld1
        fld     dword [f1_25]
        fyl2x
        fsubp   st1, st0
        fld1
        faddp   st1, st0
        call    near_one
        fldpi                           ; sin and cos together: squares add to 1
        fidiv   word [n7]
        fsincos
        fmul    st0, st0
        fxch
        fmul    st0, st0
        faddp   st1, st0
        call    near_one
        fld     tword [t_huge]          ; too large: C2, and nothing done
        fsin
        CHKCC   0400h, 0400h
        fstp    st0
        fnstsw  ax                      ; the stack is empty again
        and     ax, 3800h
        jnz     fail

; ---- 7: the stack's faults ----
        STEP    7
        fninit
        fstp    st0                     ; from an empty register
        fnstsw  ax
        and     ax, 0241h
        cmp     ax, 0041h               ; invalid, stack fault, C1 clear: under
        jne     fail
        fninit
        mov     cx, 9
.push:  fld1
        loop    .push                   ; the ninth does not fit
        fnstsw  ax
        and     ax, 0241h
        cmp     ax, 0241h               ; C1 set: over
        jne     fail
        fxam                            ; and what is there is the indefinite NaN
        CHKCC   4500h, 0100h

; ---- 8: saving and restoring ----
        STEP    8
        fninit
        fldpi
        fldz
        fld1
        fnstenv [env]
        cmp     word [env+4], 13FFh     ; tags: 5 valid, 6 zero, 7 valid, the rest empty
        jne     fail
        mov     ax, [env+2]
        and     ax, 3800h
        cmp     ax, 2800h               ; top is 5
        jne     fail
        fnstcw  [res]                   ; FNSTENV masks everything
        cmp     word [res], 037Fh
        jne     fail
        fnsave  [env]
        fnstsw  ax                      ; and FNSAVE leaves it as FNINIT does
        test    ax, ax
        jnz     fail
        cmp     dword [env+14+20+4], 0C90FDAA2h ; ST(2) is pi
        jne     fail
        cmp     word [env+14+8], 3FFFh  ; ST(0) is one
        jne     fail
        frstor  [env]
        fnstsw  ax
        and     ax, 3800h
        cmp     ax, 2800h
        jne     fail
        fld1
        fcompp                          ; ST(0) was one
        CHKCC   4500h, 4000h
        ftst                            ; then zero
        CHKCC   4500h, 4000h
        o32 fnstenv [env]               ; the 32-bit layout
        cmp     word [env+8], 1FFFh     ; tags: 6 zero, 7 valid, the rest empty
        jne     fail
        fninit

; ---- 9: an exception that is not masked, the PC's way ----
        STEP    9
        mov     word [2*4], nmi         ; the BIOS passes interrupt 13 on to here
        mov     [2*4+2], cs
        mov     word [cw], 037Bh        ; division by zero is not masked
        fldcw   [cw]
        fld1
        fldz
        cli
        fdivp   st1, st0                ; the division is not done,
        cmp     byte [seen], 0
        jne     fail
        fnstsw  ax
        and     ax, 8084h
        cmp     ax, 8084h               ; the status word says why,
        jne     fail
        sti                             ; and interrupt 13 is waiting
        nop
        cmp     byte [seen], 1
        jne     fail
        fld1                            ; (nothing is in the next instruction's way now)
        fnstsw  ax                      ; (the handler cleared it; the operands are still there)
        test    al, 0BFh
        jnz     fail
        fstp    st0
        fcompp                          ; zero and one
        CHKCC   4500h, 0100h
        fninit

; ---- 10: and the processor's own way (CR0's NE), and with no FPU allowed ----
        STEP    10
        mov     eax, [16*4]             ; (exception 16 is also the BIOS's INT 10h)
        mov     [old10], eax
        mov     word [16*4], mf
        mov     [16*4+2], cs
        mov     word [7*4], nm
        mov     [7*4+2], cs
        mov     eax, cr0
        test    al, 10h                 ; (ET reads as one)
        jz      fail
        or      al, 20h                 ; NE
        mov     cr0, eax
        in      al, 0A1h                ; (and interrupt 13 is masked, as a system using NE does)
        or      al, 20h
        out     0A1h, al
        mov     byte [seen], 0
        mov     word [cw], 037Eh        ; invalid is not masked
        fldcw   [cw]
        fldz
        fsqrt                           ; fine
        fchs
        fld1
        fchs
        fsqrt                           ; invalid: waits
        cmp     byte [seen], 0
        jne     fail
        fwait                           ; exception 16
        mov     eax, [old10]
        mov     [16*4], eax
        cmp     byte [seen], 2
        jne     fail
        fninit
        mov     eax, cr0
        and     al, ~20h
        or      al, 04h                 ; EM: every FPU instruction is exception 7
        mov     cr0, eax
        mov     byte [seen], 0
        fld1
        cmp     byte [seen], 3
        jne     fail
        fnstsw  ax                      ; (the handler cleared EM, and FLD1 was done again)
        and     ax, 3800h
        cmp     ax, 3800h
        jne     fail

        mov     si, m_ok
        jmp     print

; ST is within about 2^-60 of one; popped.
near_one:
        fld1
        fsubp   st1, st0
        fabs
        fld     tword [t_tiny]
        fcompp                          ; 2^-60 against the error
        fnstsw  ax
        sahf
        jb      fail
        ret

nmi:    push    ax
        fnclex
        mov     byte [seen], 1
        pop     ax
        iret

mf:     fnclex
        mov     byte [seen], 2
        iret

nm:     push    eax
        mov     eax, cr0
        and     al, ~04h
        mov     cr0, eax
        mov     byte [seen], 3
        pop     eax
        iret

fail:   mov     eax, [old10]
        test    eax, eax
        jz      .f
        mov     [16*4], eax
.f:     mov     al, [step]
        aam
        add     ax, 3030h
        mov     [m_step], ah
        mov     [m_step+1], al
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

m_ok:   db      "fpu test passed", 13, 10, 0
m_fail: db      "fpu test FAILED at step "
m_step: db      "00", 13, 10, 0

n2:     dw      2
n3:     dw      3
n4:     dw      4
n6:     dw      6
n7:     dw      7
n8:     dw      8
n10:    dw      10
n11:    dw      11
n1000:  dw      1000
k_big:  dd      123456789
k_odd:  dd      1234567
f0_1:   dd      0.1
f0_25:  dd      0.25
f0_5:   dd      0.5
f1_25:  dd      1.25
f2_5:   dd      2.5
f_nan:  dd      7FC00000h
d_big:  dq      1.0e300
t_tiny: dt      0x1p-60
t_huge: dt      0x1p70
bcd:    dt      98765432p
step:   db      0
old10:  dd      0
seen:   db      0
cw:     dw      0
res:    times 12 db 0
env:    times 128 db 0

        times   512*9 - ($ - $$) db 0
