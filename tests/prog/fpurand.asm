; Mach86 test program: the floating-point unit at random (docs/fpu.md).
; A bootable diskette image, for make -C sim check-fpu-rtl. It checks
; nothing itself: it is run in lockstep, design C with its FPU against
; the model, and the two are compared after every instruction,
; registers, status word and tags.
;
; Each round: a control word with a rounding and a precision at random
; (all exceptions masked), two operands at random (of ordinary size
; mostly; sometimes of any size, or a zero, an infinity, a NaN or a
; denormal), one instruction out of a table, and the results stored in
; every format.
;
; The last line it prints is "fpu random test done".

        cpu     486
        bits    16
        org     7C00h

ROUNDS  equ     6000

start:  jmp     short .go
        nop
.go:    xor     ax, ax
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, 7C00h
        mov     ax, 0208h
        mov     cx, 0002h
        xor     dh, dh
        mov     bx, 7E00h
        int     13h
        jc      .bad
        jmp     main
.bad:   hlt
        jmp     .bad
        times   510 - ($ - $$) db 0
        dw      0AA55h

; EAX = the next random number (xorshift).
rnd:    mov     eax, [seed]
        mov     ebx, eax
        shl     ebx, 13
        xor     eax, ebx
        mov     ebx, eax
        shr     ebx, 17
        xor     eax, ebx
        mov     ebx, eax
        shl     ebx, 5
        xor     eax, ebx
        mov     [seed], eax
        ret

; An operand at DI: ten bytes.
operand:
        call    rnd
        mov     [di], eax
        call    rnd
        or      eax, 80000000h
        mov     [di+4], eax
        call    rnd
        mov     edx, eax
        mov     cx, ax
        and     cx, 8000h               ; the sign
        shr     eax, 16
        test    al, 0Fh
        jz      .odd
        ; Of ordinary size: an exponent within 24 of one's.
        shr     ax, 4
        and     ax, 31
        add     ax, 3FFFh - 16
        or      ax, cx
        mov     [di+8], ax
        test    dh, 3                   ; one in four with few bits
        jnz     .done
        mov     dword [di], 0
        and     dword [di+4], 0FFF00000h
.done:  ret
.odd:   shr     ax, 4
        and     ax, 7
        cmp     al, 0
        je      .zero
        cmp     al, 1
        je      .inf
        cmp     al, 2
        je      .nan
        cmp     al, 3
        je      .den
        cmp     al, 4
        je      .int
        ; Of any size.
        mov     ax, dx
        shr     ax, 1
        or      ax, cx
        mov     [di+8], ax
        test    ax, 7FFFh
        jnz     .done
.zero:  mov     dword [di], 0
        mov     dword [di+4], 0
        mov     [di+8], cx
        ret
.inf:   mov     dword [di], 0
        mov     dword [di+4], 80000000h
        or      cx, 7FFFh
        mov     [di+8], cx
        ret
.nan:   or      cx, 7FFFh
        mov     [di+8], cx
        ret
.den:   and     dword [di+4], 7FFFFFFFh
        mov     [di+8], cx
        ret
.int:   ; A small whole number.
        mov     dword [di], 0
        mov     eax, edx
        and     eax, 0F8000000h
        or      eax, 80000000h
        mov     [di+4], eax
        mov     ax, 3FFFh + 4
        or      ax, cx
        mov     [di+8], ax
        ret

main:   mov     word [count], ROUNDS
round:  fninit
        call    rnd
        and     ax, 0F00h               ; rounding and precision
        or      ax, 007Fh
        mov     [cw], ax
        fldcw   [cw]
        mov     di, opa
        call    operand
        mov     di, opb
        call    operand
        fld     tword [opb]
        fld     tword [opa]
        call    rnd
        xor     dx, dx
        shr     eax, 8
        and     eax, 0FFFFh
        mov     bx, NOPS
        div     bx
        mov     bx, dx
        shl     bx, 1
        call    [optab+bx]
        ; What is there now, in every format (the stack may hold
        ; one, two or three numbers; storing from an empty register is
        ; part of the test).
        fxam
        fst     dword [res]
        fst     qword [res]
        fist    word [res]
        fist    dword [res]
        fld     st0
        fbstp   [res]
        fstp    tword [res]
        fxam
        fstp    qword [res]
        fistp   qword [res]
        dec     word [count]
        jnz     round

        mov     si, m_done
print:  lodsb
        test    al, al
        jz      .done
        mov     ah, 0Eh
        xor     bx, bx
        int     10h
        jmp     print
.done:  hlt
        jmp     .done

o_add:  fadd    st0, st1
        ret
o_sub:  fsubp   st1, st0
        ret
o_subr: fsubr   st0, st1
        ret
o_mul:  fmul    st1, st0
        ret
o_div:  fdivp   st1, st0
        ret
o_divr: fdivr   st0, st1
        ret
o_sqrt: fabs
        fsqrt
        ret
o_sqrn: fsqrt
        ret
o_rnd:  frndint
        ret
o_com:  fcom    st1
        ret
o_ucom: fucompp
        ret
o_tst:  ftst
        ret
o_prem: fprem
        ret
o_prm1: fprem1
        ret
o_scal: fscale
        ret
o_xtr:  fxtract
        ret
o_sin:  fsin
        ret
o_cos:  fcos
        ret
o_sc:   fsincos
        ret
o_tan:  fptan
        ret
o_atan: fpatan
        ret
o_2xm1: f2xm1
        ret
o_yl2x: fabs
        fyl2x
        ret
o_yl2n: fyl2x
        ret
o_ylp1: fyl2xp1
        ret
o_m32:  fstp    dword [res]
        fadd    dword [res]
        ret
o_m64:  fstp    qword [res]
        fmul    qword [res]
        ret
o_i16:  fistp   word [res]
        fidiv   word [res]
        ret
o_i32:  fistp   dword [res]
        fisub   dword [res]
        ret
o_ild:  fistp   qword [res]
        fild    qword [res]
        ret
o_bcd:  fbstp   [res]
        fbld    [res]
        ret
o_env:  fnstenv [env]
        fxch
        fldenv  [env]
        ret
o_save: fnsave  [env]
        frstor  [env]
        ret
o_misc: fchs
        fxch    st1
        fld1
        faddp   st2, st0
        fldpi
        fdecstp
        fincstp
        fcomp   st2
        ret
optab:  dw      o_add, o_sub, o_subr, o_mul, o_div, o_divr, o_sqrt, o_sqrn, o_rnd, o_com
        dw      o_ucom, o_tst, o_prem, o_prm1, o_scal, o_xtr, o_sin, o_cos, o_sc, o_tan
        dw      o_atan, o_2xm1, o_yl2x, o_yl2n, o_ylp1, o_m32, o_m64, o_i16, o_i32, o_ild
        dw      o_bcd, o_env, o_save, o_misc
NOPS    equ     ($ - optab) / 2

m_done: db      "fpu random test done", 13, 10, 0
seed:   dd      2463534242
count:  dw      0
cw:     dw      0
opa:    times 10 db 0
opb:    times 10 db 0
res:    times 12 db 0
env:    times 128 db 0

        times   512*9 - ($ - $$) db 0
