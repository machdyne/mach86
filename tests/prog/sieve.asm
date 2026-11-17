; Mach86 test program: primes below 1000.
;
; A 64 KB ROM image for sim/m86run. It exercises 16-bit code, 32-bit
; registers in real mode, a string instruction, multiply, divide, calls
; and the debug console, and prints a result that is easy to check.
;
; Expected output: tests/prog/sieve.expect

        cpu     386
        bits    16
        org     0               ; the image is F000:0000 to F000:FFFF

LIMIT   equ     1000
DEBUG   equ     0E0h            ; debug console port (docs/hwmap.md)

start:  cli
        xor     ax, ax
        mov     ss, ax
        mov     sp, 7C00h
        mov     ax, 1000h
        mov     ds, ax
        mov     es, ax
        cld

        ; flags[i] = 1 for all i, then strike out 0 and 1
        xor     di, di
        mov     cx, LIMIT
        mov     al, 1
        rep stosb
        mov     byte [0], 0
        mov     byte [1], 0

        mov     bx, 2
.outer: mov     ax, bx
        mul     bx              ; dx:ax = bx * bx
        or      dx, dx
        jnz     .sieved
        cmp     ax, LIMIT
        jae     .sieved
        cmp     byte [bx], 0
        je      .next
        mov     si, ax
.strike:
        mov     byte [si], 0
        add     si, bx
        cmp     si, LIMIT
        jb      .strike
.next:  inc     bx
        jmp     .outer

.sieved:
        xor     ecx, ecx        ; how many
        xor     edx, edx        ; their sum
        xor     si, si
.count: cmp     byte [si], 0
        je      .skip
        inc     ecx
        movzx   eax, si
        add     edx, eax
.skip:  inc     si
        cmp     si, LIMIT
        jb      .count

        push    edx
        push    ecx
        mov     si, msg_count
        call    puts
        pop     eax
        call    putdec
        mov     si, msg_sum
        call    puts
        pop     eax
        call    putdec
        mov     al, 10
        out     DEBUG, al
        hlt

; print the zero-terminated string at cs:si
puts:   cs lodsb
        test    al, al
        jz      .done
        out     DEBUG, al
        jmp     puts
.done:  ret

; print eax in decimal
putdec: mov     ebx, 10
        xor     cx, cx
.digit: xor     edx, edx
        div     ebx
        push    dx
        inc     cx
        test    eax, eax
        jnz     .digit
.print: pop     ax
        add     al, '0'
        out     DEBUG, al
        loop    .print
        ret

msg_count: db   "primes below 1000: ", 0
msg_sum:   db   10, "their sum: ", 0

        times   0FFF0h - ($ - $$) db 0FFh
reset:  jmp     0F000h:start
        times   10000h - ($ - $$) db 0FFh
