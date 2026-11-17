; Mach86 test program: the double shifts, the bit instructions and
; what a 486 has that a 386 has not. A bootable diskette image, for
; make -C sim check-486: on the model, and in lockstep with the RTL
; core, where every instruction's registers, flags and memory writes
; are compared -- so most of what is here is simply run, in many
; variations, and a little is checked by the program itself:
;
;   - SHLD and SHRD, 16 and 32 bits, counts 0 to 31, register and memory;
;   - BT, BTS, BTR, BTC with register and immediate bit numbers, on
;     registers and on memory, the number reaching outside the operand
;     both ways;
;   - BSWAP, XADD, CMPXCHG (taken and not), INVD, WBINVD;
;   - the AC flag can be set and cleared (which is how software tells
;     a 486 from a 386).
;
; The last line it prints is "486 test passed".

        cpu     pentium                 ; (nasm files CMPXCHG's 486 form under this)
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

main:
; ---- the AC flag ----
        pushfd
        pop     eax
        mov     ebx, eax
        xor     eax, 40000h
        push    eax
        popfd
        pushfd
        pop     eax
        xor     eax, ebx
        test    eax, 40000h
        jz      fail                    ; a 386: the bit does not change
        push    ebx
        popfd
        ; a 16-bit POPF leaves it alone
        or      ebx, 40000h
        push    ebx
        popfd
        pushf
        popf
        pushfd
        pop     eax
        test    eax, 40000h
        jz      fail
        and     ebx, ~40000h
        push    ebx
        popfd

; ---- BSWAP ----
        mov     eax, 11223344h
        bswap   eax
        cmp     eax, 44332211h
        jne     fail
        mov     esi, 0A1B2C3D4h
        bswap   esi
        cmp     esi, 0D4C3B2A1h
        jne     fail
        mov     ebp, esp
        bswap   ebp
        bswap   ebp
        cmp     ebp, esp
        jne     fail

; ---- double shifts: every count, both sizes, register and memory ----
        xor     cx, cx
.sh:    mov     eax, 0C3A59687h
        mov     ebx, 5A0FF0E1h
        mov     edx, eax
        shld    eax, ebx, cl
        mov     eax, edx
        shrd    eax, ebx, cl
        mov     ax, dx
        shld    ax, bx, cl
        mov     ax, dx
        shrd    ax, bx, cl
        mov     [buf], edx
        shld    [buf], ebx, cl
        mov     [buf], edx
        shrd    [buf], ebx, cl
        mov     [buf], edx
        shld    word [buf], bx, cl
        mov     [buf], edx
        shrd    word [buf + 2], bx, cl
        stc
        shld    edx, ebx, 0             ; nothing, not even the flags
        jnc     fail
        inc     cx
        cmp     cx, 40
        jb      .sh
        mov     eax, 80000001h
        mov     ebx, 0FFFFFFFFh
        shld    eax, ebx, 1
        shrd    eax, ebx, 1
        shld    ax, bx, 17
        shrd    ax, bx, 31
        shld    eax, ebx, 31
        shrd    dword [buf], eax, 12
        shld    word [buf], ax, 5
        cmp     dword [buf], 0
        je      fail

; ---- the bit instructions ----
        mov     dword [buf], 0
        mov     dword [buf + 4], 0
        mov     dword [buf - 4], 0
        xor     cx, cx
.bt:    mov     eax, 0F0F01234h
        mov     ebx, ecx
        bt      eax, ebx
        bts     eax, ebx
        btr     eax, ebx
        btc     eax, ebx
        bt      ax, bx
        bts     ax, bx
        btr     ax, bx
        btc     ax, bx
        bts     [buf], ebx
        bt      [buf], ebx
        btc     [buf], bx
        btc     [buf], bx
        add     cx, 7
        cmp     cx, 70
        jb      .bt
        mov     ebx, -1                 ; the bit before the operand
        bts     [buf], ebx
        jc      fail
        bt      dword [buf - 4], 31
        jnc     fail
        mov     bx, -9
        bts     [buf], bx               ; bit 7 of the byte two before
        test    byte [buf - 2], 80h
        jz      fail
        btr     [buf], bx
        jnc     fail
        mov     ebx, 37                 ; and after it
        btc     [buf], ebx
        bt      dword [buf + 4], 5
        jnc     fail
        mov     edi, buf
        mov     ecx, -64
        bts     [edi], ecx
        bt      [edi + 4], cx
        bt      dword [buf], 3
        bts     dword [buf], 35         ; an immediate number is taken modulo the size
        btr     word [buf], 19
        btc     dword [buf], 31
        bt      ax, 20
        bts     eax, 31
        btr     cx, 0
        btc     edx, 17
        lock bts dword [buf], 1
        lock btr word [buf], 1

; ---- XADD ----
        mov     eax, 7FFFFFFFh
        mov     ebx, 1
        xadd    eax, ebx
        jno     fail
        cmp     ebx, 7FFFFFFFh
        jne     fail
        mov     ecx, 5
        xadd    ecx, ecx                ; both the same: the sum stays
        cmp     ecx, 10
        jne     fail
        mov     dx, 0FFFFh
        mov     word [buf], 1
        xadd    [buf], dx
        jnc     fail
        cmp     dx, 1
        jne     fail
        mov     al, 0F0h
        mov     ah, 20h
        xadd    al, ah
        xadd    [buf + 1], ah
        lock xadd [buf], eax

; ---- CMPXCHG ----
        mov     eax, 1234h
        mov     ebx, 1234h
        mov     ecx, 5678h
        cmpxchg ebx, ecx                ; equal: EBX takes ECX
        jnz     fail
        cmp     ebx, 5678h
        jne     fail
        cmpxchg ebx, ecx                ; not: EAX takes EBX
        jz      fail
        cmp     eax, 5678h
        jne     fail
        mov     dword [buf], 5678h
        mov     edx, 0AAAA5555h
        cmpxchg [buf], edx
        jnz     fail
        cmp     dword [buf], 0AAAA5555h
        jne     fail
        mov     ax, 1
        cmpxchg [buf], dx
        jz      fail
        cmp     ax, 5555h
        jne     fail
        mov     al, 55h
        mov     cl, 99h
        cmpxchg [buf], cl
        cmpxchg cl, ch
        cmpxchg ah, bl
        lock cmpxchg [buf], ebx

        invd
        wbinvd

        mov     si, m_ok
        jmp     short print
fail:   mov     si, m_fail
print:  lodsb
        test    al, al
        jz      .done
        mov     ah, 0Eh
        xor     bx, bx
        int     10h
        jmp     print
.done:  hlt
        jmp     .done

m_ok:   db      "486 test passed", 13, 10, 0
m_fail: db      "486 test FAILED", 13, 10, 0

        dd      0, 0
buf:    dd      0, 0, 0
        times   1474560 - ($ - $$) db 0
