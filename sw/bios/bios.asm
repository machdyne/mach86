; Mach86 BIOS.
;
; Sources: BIOS-IF (the PC BIOS interrupt interface and data area, as
; publicly described), I8259, I8254, I8042, MC146818, SD-PHY, and
; docs/hwmap.md for the machine's own ports. No BIOS listing or
; disassembly was consulted (docs/cleanroom.md).
;
; A 64 KB image for F000:0000. What it provides so far is listed in
; docs/bios.md. Text mode only; one disk, the SD card, through the BIOS
; disk service.

        cpu     386
        bits    16
        org     0

; ---- machine ------------------------------------------------------

PIC1_CMD        equ 20h
PIC1_DATA       equ 21h
PIC2_CMD        equ 0A0h
PIC2_DATA       equ 0A1h
PIT_CH0         equ 40h
PIT_CTRL        equ 43h
KBD_DATA        equ 60h
KBD_CMD         equ 64h
CMOS_INDEX      equ 70h
CMOS_DATA       equ 71h
DEBUG_PORT      equ 0E0h        ; debug console; bit 7 (read): no room
MEM_CMD         equ 0E4h        ; the memory port (docs/hwmap.md)
SPI_DATA        equ 0E1h        ; write: send a byte; read: byte received
SPI_CTRL        equ 0E2h        ; bit 0: card selected; bit 7 (read): busy
SPI_SLOW        equ 04h         ; written to SPI_CTRL: bit 2 says "set the
SPI_FAST        equ 06h         ; speed", and bit 1 is the speed (1 = fast)
CRTC_INDEX      equ 3D4h

VIDEO_SEG       equ 0B800h
BDA_SEG         equ 40h
BOOT_OFF        equ 7C00h

COLS            equ 80
ROWS            equ 25

; ---- BIOS data area (segment 40h) ---------------------------------

BDA_EBDA        equ 0Eh
BDA_EQUIP       equ 10h
BDA_MEMSIZE     equ 13h
BDA_KBFLAGS     equ 17h
BDA_KBHEAD      equ 1Ah
BDA_KBTAIL      equ 1Ch
BDA_KBBUF       equ 1Eh
BDA_VMODE       equ 49h
BDA_VCOLS       equ 4Ah
BDA_VPAGESIZE   equ 4Ch
BDA_VPAGEOFF    equ 4Eh
BDA_CURSOR      equ 50h         ; eight pages, column then row
BDA_CURSHAPE    equ 60h
BDA_VPAGE       equ 62h
BDA_CRTC        equ 63h
BDA_TICKS       equ 6Ch
BDA_MIDNIGHT    equ 70h
BDA_HDCOUNT     equ 75h
BDA_KBSTART     equ 80h
BDA_KBEND       equ 82h
BDA_VROWS       equ 84h
BDA_VKIND       equ 0B0h        ; ours: the kind of video mode (video.inc)
BDA_KBSTATE     equ 96h         ; bit 1: the last scancode was E0h
BDA_VCHARH      equ 85h

; ---- our own data (in the EBDA) -----------------------------------

E_SIZE          equ 00h         ; size of the EBDA in KB
E_KIND          equ 10h         ; 0 no disk, 1 floppy image, 2 hard disk
E_STATUS        equ 11h         ; status of the last disk operation
E_FD            equ 12h         ; geometry: sectors/track, heads, cylinders
E_HD            equ 16h
E_TOTAL         equ 1Ah         ; sectors on the card (dword)
E_SDSTEP        equ 1Eh         ; how far bringing the card up got
E_SDANS         equ 1Fh         ; the card's last answer to a command

G_SPT           equ 0
G_HEADS         equ 1
G_CYLS          equ 2

; ---- service frame --------------------------------------------------
;
; Every service saves the caller's registers the same way and reaches
; them through BP, so results are written straight into the frame.

%macro  SVC_ENTER 0
        push    ds
        push    es
        pusha
        mov     bp, sp
        cld
%endmacro

%define F_DI    word [bp+0]
%define F_SI    word [bp+2]
%define F_BP    word [bp+4]
%define F_BX    word [bp+8]
%define F_BL    byte [bp+8]
%define F_BH    byte [bp+9]
%define F_DX    word [bp+10]
%define F_DL    byte [bp+10]
%define F_DH    byte [bp+11]
%define F_CX    word [bp+12]
%define F_CL    byte [bp+12]
%define F_CH    byte [bp+13]
%define F_AX    word [bp+14]
%define F_AL    byte [bp+14]
%define F_AH    byte [bp+15]
%define F_ES    word [bp+16]
%define F_DS    word [bp+18]
%define F_FLAGS byte [bp+24]

svc_leave:
        popa
        pop     es
        pop     ds
        iret

svc_carry:
        or      F_FLAGS, 1
        jmp     svc_leave

svc_nocarry:
        and     F_FLAGS, 0FEh
        jmp     svc_leave

; ====================================================================
; Power-on
; ====================================================================

post:   cli
        cld
        ; A main memory that needs training (DDR3) is not usable yet,
        ; and there is no other RAM -- except the text screen's 4 KB.
        ; The trainer (sw/train) is copied there and run there, with
        ; its stack at the top; it reports on the debug console.
        in      al, MEM_CMD
        test    al, 02h
        jz      .ram
        mov     ax, 0B800h
        mov     ss, ax
        mov     esp, 1000h
        mov     ds, ax
        mov     es, ax
        xor     di, di
        mov     cx, 1000h - 100h        ; all but some stack, so that
        xor     al, al                  ; its variables start as zero
        rep stosb
        mov     si, train_blob
        xor     di, di
        mov     cx, train_end - train_blob
        cs rep movsb
        call    0B800h:0000h
        test    ax, ax
        jnz     .ram
        mov     si, msg_nomem
.nomem: cs lodsb
        test    al, al
        jz      .stop
        mov     ah, al
.room:  in      al, DEBUG_PORT
        test    al, 80h
        jnz     .room
        mov     al, ah
        out     DEBUG_PORT, al
        jmp     .nomem
.stop:  hlt
        jmp     .stop
.ram:   xor     ax, ax
        mov     ss, ax
        mov     sp, BOOT_OFF
        mov     ds, ax
        mov     es, ax

        ; Clear the vector table and the BIOS data area.
        xor     di, di
        mov     cx, 500h / 2
        rep stosw

        ; Every vector gets a handler that just returns ...
        xor     di, di
        mov     cx, 256
.fill:  mov     ax, int_dummy
        stosw
        mov     ax, cs
        stosw
        loop    .fill

        ; ... then the ones we implement.
        mov     si, vector_table
.vec:   cs lodsb
        cmp     al, 0FFh
        je      .vdone
        movzx   di, al
        shl     di, 2
        cs lodsw
        stosw
        mov     ax, cs
        stosw
        jmp     .vec
.vdone:
        mov     word [1Eh*4], diskette_table
        mov     word [1Eh*4+2], cs
        ; Second interrupt controller: vectors 70h-77h.
        mov     di, 70h*4
        mov     cx, 8
.vec2:  mov     ax, irq_slave
        stosw
        mov     ax, cs
        stosw
        loop    .vec2

        ; Interrupt controllers: edge-triggered, bases 08h and 70h,
        ; second one cascaded on line 2.
        mov     al, 11h
        out     PIC1_CMD, al
        out     PIC2_CMD, al
        mov     al, 08h
        out     PIC1_DATA, al
        mov     al, 70h
        out     PIC2_DATA, al
        mov     al, 04h
        out     PIC1_DATA, al
        mov     al, 02h
        out     PIC2_DATA, al
        mov     al, 01h
        out     PIC1_DATA, al
        out     PIC2_DATA, al
        mov     al, 0F8h                ; timer, keyboard and cascade on
        out     PIC1_DATA, al
        mov     al, 0FFh
        out     PIC2_DATA, al

        ; Timer channel 0: square wave, full count: 18.2 ticks a second.
        mov     al, 36h
        out     PIT_CTRL, al
        xor     al, al
        out     PIT_CH0, al
        out     PIT_CH0, al

        ; BIOS data area.
        mov     ax, BDA_SEG
        mov     ds, ax
        ; Conventional memory: look for RAM downwards from 640 KB in
        ; 16 KB steps. Our own data takes the last kilobyte of it.
        mov     bx, 640
.probe: mov     ax, bx
        dec     ax
        shl     ax, 6                   ; the segment of the last kilobyte
        mov     es, ax
        mov     word [es:0], 55AAh
        cmp     word [es:0], 55AAh
        jne     .less
        mov     word [es:0], 0AA55h
        cmp     word [es:0], 0AA55h
        je      .found
.less:  sub     bx, 16
        cmp     bx, 64
        ja      .probe
.found: mov     [BDA_EBDA], ax
        dec     bx
        mov     [BDA_MEMSIZE], bx
        mov     word [BDA_EQUIP], 0020h ; 80x25 colour text
        mov     word [BDA_KBHEAD], BDA_KBBUF
        mov     word [BDA_KBTAIL], BDA_KBBUF
        mov     word [BDA_KBSTART], BDA_KBBUF
        mov     word [BDA_KBEND], BDA_KBBUF + 32

        ; Our own data.
        mov     ax, [BDA_EBDA]
        mov     es, ax
        xor     di, di
        mov     cx, 512
        xor     ax, ax
        rep stosw
        mov     byte [es:E_SIZE], 1

        ; Screen.
        mov     ax, 0003h
        int     10h
        mov     si, msg_banner
        call    puts
        push    ds
        mov     ax, BDA_SEG
        mov     ds, ax
        mov     ax, [BDA_MEMSIZE]
        pop     ds
        inc     ax
        call    putdec
        mov     si, msg_memory
        call    puts

        ; Disk.
        call    disk_setup

        sti
        int     19h

; Vectors we fill in: number, handler.
vector_table:
        db 00h
        dw exc_00
        db 06h
        dw exc_06
        db 08h
        dw int08
        db 09h
        dw int09
        db 0Ah
        dw irq_0A
        db 0Bh
        dw irq_0B
        db 0Ch
        dw irq_0C
        db 0Dh
        dw irq_0D
        db 0Eh
        dw irq_0E
        db 0Fh
        dw irq_0F
        db 10h
        dw int10
        db 11h
        dw int11
        db 12h
        dw int12
        db 13h
        dw int13
        db 14h
        dw int14
        db 15h
        dw int15
        db 16h
        dw int16
        db 17h
        dw int17
        db 18h
        dw int18
        db 19h
        dw int19
        db 1Ah
        dw int1A
        db 0FFh

msg_banner:     db "Mach86 BIOS 0.1, ", 0
msg_memory:     db " KB memory", 13, 10, 0
msg_nocard:     db "No SD card: step ", 0
msg_answer:     db ", answer ", 0
msg_crlf:       db 13, 10, 0
msg_nomem:      db "Memory training failed. System halted.", 13, 10, 0
msg_card:       db "SD card, ", 0
msg_floppy:     db " MB, floppy image", 13, 10, 0
msg_hard:       db " MB", 13, 10, 0
msg_noboot:     db "No boot disk. System halted.", 13, 10, 0
msg_exc:        db 13, 10, "Mach86 BIOS: unexpected exception ", 0
msg_at:         db " at ", 0

; ====================================================================
; Console helpers for the BIOS's own messages
; ====================================================================

; Print the zero-terminated string at cs:si.
puts:   push    ax
        push    bx
.next:  cs lodsb
        test    al, al
        jz      .done
        mov     ah, 0Eh
        mov     bx, 0007h
        int     10h
        jmp     .next
.done:  pop     bx
        pop     ax
        ret

; Print ax in decimal.
putdec: push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        xor     cx, cx
.div:   xor     dx, dx
        div     bx
        push    dx
        inc     cx
        test    ax, ax
        jnz     .div
.out:   pop     ax
        add     al, '0'
        mov     ah, 0Eh
        mov     bx, 0007h
        int     10h
        loop    .out
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; Print ax in hexadecimal, four digits.
puthex: push    ax
        push    bx
        push    cx
        mov     cx, 4
.digit: rol     ax, 4
        push    ax
        and     al, 0Fh
        add     al, '0'
        cmp     al, '9'
        jbe     .show
        add     al, 'A' - '0' - 10
.show:  mov     ah, 0Eh
        mov     bx, 0007h
        int     10h
        pop     ax
        loop    .digit
        pop     cx
        pop     bx
        pop     ax
        ret

; ====================================================================
; Interrupts with no service behind them
; ====================================================================

int_dummy:
        iret

; Hardware interrupt on the second controller with no handler.
irq_slave:
        push    ax
        mov     al, 20h
        out     PIC2_CMD, al
        out     PIC1_CMD, al
        pop     ax
        iret

; Vectors 0Ah-0Fh are both hardware interrupts 2-7 and, on a 386, CPU
; exceptions. The controller's in-service register tells them apart.
%macro  IRQ_OR_EXC 2            ; vector, in-service bit
irq_%1: push    ax
        mov     ax, (0x%1 << 8) | %2
        jmp     irq_or_exc
%endmacro

        IRQ_OR_EXC 0A, 04h
        IRQ_OR_EXC 0B, 08h
        IRQ_OR_EXC 0C, 10h
        IRQ_OR_EXC 0D, 20h
        IRQ_OR_EXC 0E, 40h
        IRQ_OR_EXC 0F, 80h

irq_or_exc:
        push    bx
        mov     bx, ax
        mov     al, 0Bh                 ; read the in-service register
        out     PIC1_CMD, al
        in      al, PIC1_CMD
        test    al, bl
        jz      .exc
        mov     al, 20h
        out     PIC1_CMD, al
        pop     bx
        pop     ax
        iret
.exc:   mov     al, bh
        pop     bx
        add     sp, 2
        jmp     exc_report

exc_00: mov     al, 00h
        jmp     exc_report
exc_06: mov     al, 06h
        ; fall through

; An exception nobody handles: say where, and stop.
; al = vector; the interrupt frame is on the stack.
exc_report:
        mov     bp, sp
        movzx   dx, al
        mov     si, msg_exc
        call    puts
        mov     ax, dx
        call    puthex
        mov     si, msg_at
        call    puts
        mov     ax, [bp+2]
        call    puthex
        mov     ax, 0E3Ah               ; ':'
        mov     bx, 0007h
        int     10h
        mov     ax, [bp]
        call    puthex
.stop:  cli
        hlt
        jmp     .stop

; ====================================================================
; INT 08h: timer tick
; ====================================================================

int08:  push    ax
        push    ds
        mov     ax, BDA_SEG
        mov     ds, ax
        inc     word [BDA_TICKS]
        jnz     .day
        inc     word [BDA_TICKS+2]
.day:   cmp     word [BDA_TICKS+2], 18h ; 1800B0h ticks in a day
        jne     .user
        cmp     word [BDA_TICKS], 00B0h
        jne     .user
        mov     word [BDA_TICKS], 0
        mov     word [BDA_TICKS+2], 0
        mov     byte [BDA_MIDNIGHT], 1
.user:  int     1Ch
        mov     al, 20h
        out     PIC1_CMD, al
        pop     ds
        pop     ax
        iret

; ====================================================================
; INT 09h: keyboard
; ====================================================================

KB_RSHIFT       equ 01h
KB_LSHIFT       equ 02h
KB_CTRL         equ 04h
KB_ALT          equ 08h
KB_CAPS         equ 40h

int09:  push    ax
        push    bx
        push    cx
        push    ds
        mov     ax, BDA_SEG
        mov     ds, ax
        in      al, KBD_DATA
        mov     ah, al                  ; ah = scancode from here on

        ; E0h comes before the code of a key the 101-key keyboard
        ; added (the grey arrows, right Ctrl and Alt, ...). Such a key
        ; then acts as the old key with the same code, except that
        ; Shift does not turn the grey arrows into digits.
        mov     ch, [BDA_KBSTATE]       ; ch bit 1: this code follows E0h
        and     byte [BDA_KBSTATE], ~02h
        cmp     al, 0E0h
        jne     .code
        or      byte [BDA_KBSTATE], 02h
        jmp     .done
.code:

        ; Shift-type keys only change the flags.
        mov     bl, KB_LSHIFT
        cmp     al, 2Ah
        je      .set
        cmp     al, 0AAh
        je      .clear
        mov     bl, KB_RSHIFT
        cmp     al, 36h
        je      .set
        cmp     al, 0B6h
        je      .clear
        mov     bl, KB_CTRL
        cmp     al, 1Dh
        je      .set
        cmp     al, 9Dh
        je      .clear
        mov     bl, KB_ALT
        cmp     al, 38h
        je      .set
        cmp     al, 0B8h
        je      .clear
        cmp     al, 3Ah
        jne     .key
        xor     byte [BDA_KBFLAGS], KB_CAPS
        jmp     .done
.set:   or      [BDA_KBFLAGS], bl
        jmp     .done
.clear: not     bl
        and     [BDA_KBFLAGS], bl
        jmp     .done

.key:   test    al, 80h                 ; key release, or a prefix byte
        jnz     .done
        cmp     al, KEYMAP_SIZE
        jae     .done

        ; Ctrl-Alt-Del restarts the machine.
        cmp     al, 53h
        jne     .map
        mov     bl, [BDA_KBFLAGS]
        and     bl, KB_CTRL | KB_ALT
        cmp     bl, KB_CTRL | KB_ALT
        jne     .map
        jmp     0F000h:post

.map:   mov     bx, keymap_plain
        test    ch, 02h
        jnz     .xlat
        test    byte [BDA_KBFLAGS], KB_LSHIFT | KB_RSHIFT
        jz      .xlat
        mov     bx, keymap_shift
.xlat:  cs xlatb                        ; al = character, or 0

        ; Caps Lock swaps the case of letters.
        test    byte [BDA_KBFLAGS], KB_CAPS
        jz      .ctrl
        mov     cl, al
        or      cl, 20h
        cmp     cl, 'a'
        jb      .ctrl
        cmp     cl, 'z'
        ja      .ctrl
        xor     al, 20h
.ctrl:  test    byte [BDA_KBFLAGS], KB_CTRL
        jz      .alt
        mov     cl, al
        or      cl, 20h
        cmp     cl, 'a'
        jb      .alt
        cmp     cl, 'z'
        ja      .alt
        and     al, 1Fh
.alt:   test    byte [BDA_KBFLAGS], KB_ALT
        jz      .store
        xor     al, al

        ; Put scancode and character in the buffer, if there is room.
.store: mov     bx, [BDA_KBTAIL]
        mov     cx, bx
        add     cx, 2
        cmp     cx, [BDA_KBEND]
        jne     .room
        mov     cx, [BDA_KBSTART]
.room:  cmp     cx, [BDA_KBHEAD]
        je      .done                   ; full: the key is dropped
        mov     [bx], ax
        mov     [BDA_KBTAIL], cx

.done:  mov     al, 20h
        out     PIC1_CMD, al
        pop     ds
        pop     cx
        pop     bx
        pop     ax
        iret

; Scancode (set 1) to character. Zero means the key has no character.
keymap_plain:
        db 0, 27, "1234567890-=", 8, 9
        db "qwertyuiop[]", 13, 0
        db "asdfghjkl;'`", 0, "\"
        db "zxcvbnm,./", 0, "*", 0, " ", 0
        times 10 db 0                   ; F1-F10
        db 0, 0                         ; Num Lock, Scroll Lock
        db 0, 0, 0, "-", 0, 0, 0, "+", 0, 0, 0, 0, 0
KEYMAP_SIZE     equ $ - keymap_plain

keymap_shift:
        db 0, 27, "!@#$%^&*()_+", 8, 0
        db "QWERTYUIOP{}", 13, 0
        db "ASDFGHJKL:", 34, "~", 0, "|"
        db "ZXCVBNM<>?", 0, "*", 0, " ", 0
        times 10 db 0
        db 0, 0
        db "789-456+1230."

; ====================================================================
; INT 16h: keyboard service
; ====================================================================

int16:  SVC_ENTER
        mov     ax, BDA_SEG
        mov     ds, ax
        mov     ah, F_AH
        and     ah, 0EFh                ; 10h-12h are the same as 00h-02h
        jz      .read
        dec     ah
        jz      .peek
        dec     ah
        jnz     .out
        mov     al, [BDA_KBFLAGS]       ; 02h: shift flags
        mov     F_AL, al
.out:   jmp     svc_leave

.read:  sti                             ; 00h: wait for a key
.wait:  mov     bx, [BDA_KBHEAD]
        cmp     bx, [BDA_KBTAIL]
        jne     .have
        hlt
        jmp     .wait
.have:  cli
        mov     ax, [bx]
        add     bx, 2
        cmp     bx, [BDA_KBEND]
        jne     .keep
        mov     bx, [BDA_KBSTART]
.keep:  mov     [BDA_KBHEAD], bx
        mov     F_AX, ax
        jmp     svc_leave

.peek:  mov     bx, [BDA_KBHEAD]        ; 01h: is a key waiting?
        cmp     bx, [BDA_KBTAIL]
        je      .none
        mov     ax, [bx]
        mov     F_AX, ax
        and     F_FLAGS, 0BFh           ; ZF clear: yes
        jmp     svc_leave
.none:  or      F_FLAGS, 40h            ; ZF set: no
        jmp     svc_leave

; ====================================================================
; INT 10h: video, 80x25 text
; ====================================================================

int10:  SVC_ENTER
        mov     si, BDA_SEG
        mov     ds, si
        mov     si, VIDEO_SEG
        mov     es, si
        cmp     ah, 1Ah
        ja      svc_leave
        movzx   si, ah
        shl     si, 1
        jmp     [cs:int10_table+si]

int10_table:
        dw v_setmode, v_curshape, v_setcur, v_getcur    ; 00-03
        dw svc_leave, svc_leave, v_scroll, v_scroll     ; 04-07
        dw v_readch, v_writech, v_writech, v_cgapal     ; 08-0B
        dw v_putpixel, v_getpixel, v_tty, v_getmode     ; 0C-0F
        dw v_palette, v_font, v_alt, v_string           ; 10-13
        dw svc_leave, svc_leave, svc_leave, svc_leave   ; 14-17
        dw svc_leave, svc_leave, v_dcc                  ; 18-1A

%include "video.inc"

; dx = row:column  ->  di = offset in video memory. Keeps ax.
vid_addr:
        push    ax
        mov     al, dh
        mov     ah, COLS
        mul     ah
        movzx   di, dl
        add     di, ax
        shl     di, 1
        pop     ax
        ret

; Move the hardware cursor to dx = row:column.
vid_setcur:
        push    ax
        push    bx
        push    dx
        mov     al, dh
        mov     ah, COLS
        mul     ah
        movzx   bx, dl
        add     bx, ax
        mov     dx, CRTC_INDEX
        mov     al, 0Eh
        out     dx, al
        inc     dx
        mov     al, bh
        out     dx, al
        dec     dx
        mov     al, 0Fh
        out     dx, al
        inc     dx
        mov     al, bl
        out     dx, al
        pop     dx
        pop     bx
        pop     ax
        ret

; 01h: cursor shape
v_curshape:
        mov     [BDA_CURSHAPE], cx
        mov     dx, CRTC_INDEX
        mov     al, 0Ah
        out     dx, al
        inc     dx
        mov     al, ch
        out     dx, al
        dec     dx
        mov     al, 0Bh
        out     dx, al
        inc     dx
        mov     al, cl
        out     dx, al
        jmp     svc_leave

; 02h: set cursor position (bh = page)
v_setcur:
        movzx   si, bh
        and     si, 7
        shl     si, 1
        mov     [BDA_CURSOR+si], dx
        test    bh, bh
        jnz     svc_leave
        call    vid_setcur
        jmp     svc_leave

; 03h: get cursor position and shape
v_getcur:
        movzx   si, bh
        and     si, 7
        shl     si, 1
        mov     ax, [BDA_CURSOR+si]
        mov     F_DX, ax
        mov     ax, [BDA_CURSHAPE]
        mov     F_CX, ax
        jmp     svc_leave

; 06h, 07h: scroll a window up or down. In a graphics mode the whole
; picture is cleared (al = 0) or moved up, whatever the window.
v_scroll:
        cmp     byte [BDA_VKIND], K_TEXT
        jne     .gfx
        call    vid_scroll
        jmp     svc_leave
.gfx:   test    al, al
        jnz     .move
        call    vid_clear
        jmp     svc_leave
.move:  cmp     ah, 6
        jne     svc_leave
        movzx   bx, al
.again: call    gfx_scroll
        dec     bx
        jnz     .again
        jmp     svc_leave

; ah = 6 (up) or 7 (down), al = lines (0 = clear), bh = attribute,
; ch,cl = top left, dh,dl = bottom right. es = video. Uses everything.
vid_scroll:
        cmp     dh, ROWS - 1
        jbe     .rowok
        mov     dh, ROWS - 1
.rowok: cmp     dl, COLS - 1
        jbe     .colok
        mov     dl, COLS - 1
.colok: cmp     ch, dh
        ja      .ret
        cmp     cl, dl
        ja      .ret
        mov     bl, dh
        sub     bl, ch
        inc     bl                      ; bl = rows in the window
        test    al, al
        jz      .all
        cmp     al, bl
        jb      .some
.all:   mov     al, bl
.some:  sub     dl, cl
        inc     dl                      ; dl = width
        sub     bl, al                  ; bl = rows that move
        push    ds
        push    es
        pop     ds
        cmp     ah, 7
        je      .down

        mov     ah, ch                  ; ah = row being written
.upmove:
        test    bl, bl
        jz      .upfill
        call    .rowaddr
        push    ax
        mov     ah, COLS * 2
        mul     ah
        mov     si, di
        add     si, ax
        pop     ax
        call    .copy
        inc     ah
        dec     bl
        jmp     .upmove
.upfill:
        test    al, al
        jz      .out
        call    .rowaddr
        call    .fill
        inc     ah
        dec     al
        jmp     .upfill

.down:  mov     ah, dh
.dnmove:
        test    bl, bl
        jz      .dnfill
        call    .rowaddr
        push    ax
        mov     ah, COLS * 2
        mul     ah
        mov     si, di
        sub     si, ax
        pop     ax
        call    .copy
        dec     ah
        dec     bl
        jmp     .dnmove
.dnfill:
        test    al, al
        jz      .out
        call    .rowaddr
        call    .fill
        dec     ah
        dec     al
        jmp     .dnfill

.out:   pop     ds
.ret:   ret

.rowaddr:                               ; ah = row, cl = column -> di
        push    ax
        mov     al, ah
        mov     ah, COLS
        mul     ah
        movzx   di, cl
        add     di, ax
        shl     di, 1
        pop     ax
        ret
.copy:  push    cx
        movzx   cx, dl
        rep movsw
        pop     cx
        ret
.fill:  push    cx
        push    ax
        movzx   cx, dl
        mov     ah, bh
        mov     al, ' '
        rep stosw
        pop     ax
        pop     cx
        ret

; 08h: read character and attribute at the cursor
v_readch:
        cmp     byte [BDA_VKIND], K_TEXT
        je      .text
        mov     F_AX, 0
        jmp     svc_leave
.text:  mov     dx, [BDA_CURSOR]
        call    vid_addr
        mov     ax, [es:di]
        mov     F_AX, ax
        jmp     svc_leave

; 09h: write character and attribute, cx times; 0Ah: character only
v_writech:
        mov     dx, [BDA_CURSOR]
        test    cx, cx
        jz      svc_leave
        cmp     byte [BDA_VKIND], K_TEXT
        je      .text
.gfx:   call    gfx_char                ; al = character, bl = colour
        inc     dl
        loop    .gfx
        jmp     svc_leave
.text:  call    vid_addr
        cmp     ah, 0Ah
        je      .chars
        mov     ah, bl
        rep stosw
        jmp     svc_leave
.chars: stosb
        inc     di
        loop    .chars
        jmp     svc_leave

; 0Eh: write a character as a terminal would
v_tty:  call    vid_tty
        jmp     svc_leave

; al = character. ds = BDA, es = video. Uses ax, bx, cx, dx, si, di.
vid_tty:
        push    ax
.full:  in      al, DEBUG_PORT          ; wait for room in the debug console
        test    al, 80h
        jnz     .full
        pop     ax
        out     DEBUG_PORT, al          ; and copy the character to it
        cmp     al, 7
        je      vid_bell
        cmp     byte [BDA_VKIND], K_TEXT
        jne     gfx_tty                 ; (bl = the caller's colour)
        mov     dx, [BDA_CURSOR]
        cmp     al, 13
        je      .cr
        cmp     al, 10
        je      .lf
        cmp     al, 8
        je      .bs
        cmp     al, 7
        je      .done
        call    vid_addr
        mov     [es:di], al
        inc     dl
        cmp     dl, COLS
        jb      .set
        xor     dl, dl
.lf:    inc     dh
        cmp     dh, ROWS
        jb      .set
        mov     dh, ROWS - 1
        push    dx
        mov     ax, 0601h
        mov     bh, 07h
        xor     cx, cx
        mov     dx, ((ROWS - 1) << 8) | (COLS - 1)
        call    vid_scroll
        pop     dx
        jmp     .set
.cr:    xor     dl, dl
        jmp     .set
.bs:    test    dl, dl
        jz      .set
        dec     dl
.set:   mov     [BDA_CURSOR], dx
        call    vid_setcur
.done:  ret

; The bell: the speaker at 896 Hz for 200 of its periods, a little
; under a quarter of a second, timed by watching the timer channel's
; output in port 61h (interrupts may be off here). If the output does
; not move, it gives up.
vid_bell:
        push    ax
        push    bx
        push    cx
        mov     al, 0B6h                ; channel 2: both bytes, square wave
        out     43h, al
        mov     al, 33h                 ; 1,193,182 / 1331 = 896 Hz
        out     42h, al
        mov     al, 05h
        out     42h, al
        in      al, 61h
        push    ax
        or      al, 03h                 ; gate and speaker on
        out     61h, al
        mov     bx, 400                 ; half periods
.half:  xor     cx, cx
        in      al, 61h
        and     al, 20h
        mov     ah, al
.same:  in      al, 61h
        and     al, 20h
        cmp     al, ah
        jne     .moved
        loop    .same
        jmp     .off                    ; it does not move
.moved: dec     bx
        jnz     .half
.off:   pop     ax
        and     al, 0Fh
        out     61h, al
        pop     cx
        pop     bx
        pop     ax
        ret

; 0Fh: current mode
v_getmode:
        mov     al, [BDA_VMODE]
        mov     ah, COLS
        mov     F_AX, ax
        mov     F_BH, 0
        jmp     svc_leave

; 13h: write string. al bit 0: move the cursor; bit 1: the string has
; attributes. bl = attribute, cx = length, dx = position, es:bp = string.
v_string:
        mov     si, F_BP
        push    word [BDA_CURSOR]
        mov     [BDA_CURSOR], dx
        jcxz    .end
.char:  push    es
        mov     es, F_ES
        mov     al, [es:si]
        inc     si
        mov     ah, bl
        test    F_AL, 2
        jz      .one
        mov     ah, [es:si]
        inc     si
.one:   pop     es
        push    si
        push    cx
        push    bx
        cmp     al, 13
        jbe     .ctl                    ; control characters act
        mov     bl, ah                  ; (graphics: the colour)
        cmp     byte [BDA_VKIND], K_TEXT
        jne     .ctl
        mov     dx, [BDA_CURSOR]
        call    vid_addr
        mov     byte [es:di+1], ah      ; set the attribute first
.ctl:   call    vid_tty
        pop     bx
        pop     cx
        pop     si
        loop    .char
.end:   pop     dx
        test    F_AL, 1
        jnz     svc_leave
        mov     [BDA_CURSOR], dx        ; put the cursor back
        call    vid_setcur
        jmp     svc_leave

; ====================================================================
; Small services
; ====================================================================

; INT 11h: equipment
int11:  push    ds
        mov     ax, BDA_SEG
        mov     ds, ax
        mov     ax, [BDA_EQUIP]
        pop     ds
        iret

; INT 12h: conventional memory in KB
int12:  push    ds
        mov     ax, BDA_SEG
        mov     ds, ax
        mov     ax, [BDA_MEMSIZE]
        pop     ds
        iret

; INT 14h: serial ports: none yet, report a timeout
int14:  mov     ah, 80h
        iret

; INT 17h: printer: none, report a timeout
int17:  mov     ah, 01h
        iret

; INT 15h: system services
int15:  SVC_ENTER
        cmp     ah, 87h
        je      .move
        cmp     ah, 88h
        je      .extmem
        cmp     ah, 90h
        je      .ok
        cmp     ah, 91h
        je      .ok
        mov     F_AH, 86h               ; not supported
        jmp     svc_carry
.extmem:
        ; Memory above 1 MB, in KB, as the configuration memory has it.
        mov     al, 31h
        out     70h, al
        in      al, 71h
        mov     ah, al
        mov     al, 30h
        out     70h, al
        in      al, 71h
        mov     F_AX, ax
        jmp     svc_nocarry
.ok:    mov     F_AH, 0
        jmp     svc_nocarry

; 87h: move CX words between any two places in memory. ES:SI is the
; caller's table of descriptors; the third (at 10h) describes the
; source and the fourth (at 18h) the destination, and only their base
; addresses are used. The move is made in real mode with the segment
; limits lifted for its duration ("unreal mode"): a step into
; protected mode to load limits of 4 GB, the copy with 32-bit
; addresses, and a second step to put limits of 64 KB back. Address
; line 20 is on meanwhile, and left as it was found.
.move:  push    eax
        push    ecx
        push    esi
        push    edi
        sub     sp, 6
        mov     di, sp
        sgdt    [ss:di]                 ; the caller's table register
        in      al, 92h
        push    ax
        or      al, 02h
        out     92h, al
        mov     edi, [es:si + 1Ah]
        and     edi, 00FFFFFFh
        movzx   eax, byte [es:si + 1Fh]
        shl     eax, 24
        or      edi, eax
        mov     eax, [es:si + 12h]
        and     eax, 00FFFFFFh
        movzx   ecx, byte [es:si + 17h]
        shl     ecx, 24
        or      eax, ecx
        mov     esi, eax
        movzx   ecx, F_CX
        mov     ax, 08h                 ; limits of 4 GB
        call    bm_limits
        a32 rep movsw
        mov     ax, 10h                 ; and of 64 KB again
        call    bm_limits
        pop     ax
        out     92h, al
        mov     di, sp
        lgdt    [ss:di]
        add     sp, 6
        pop     edi
        pop     esi
        pop     ecx
        pop     eax
        mov     F_AH, 0
        jmp     svc_nocarry

; Load DS and ES from descriptor AX of the table below, in protected
; mode, and come back to real mode with their bases zero. Interrupts
; are off (this is inside a service). Changes EAX.
bm_limits:
        push    bx
        mov     bx, ax
        lgdt    [cs:bm_gdtr]
        mov     eax, cr0
        or      al, 1
        mov     cr0, eax
        mov     ds, bx
        mov     es, bx
        and     al, 0FEh
        mov     cr0, eax
        xor     ax, ax
        mov     ds, ax
        mov     es, ax
        pop     bx
        ret

        align   8
bm_gdt: dq      0
        dw      0FFFFh, 0               ; 08h: data, 4 GB
        db      0, 92h, 8Fh, 0
        dw      0FFFFh, 0               ; 10h: data, 64 KB
        db      0, 92h, 00h, 0
bm_gdtr: dw     23
        dd      0F0000h + bm_gdt

; INT 1Ah: time
int1A:  SVC_ENTER
        mov     bx, BDA_SEG
        mov     ds, bx
        cmp     ah, 0
        je      .get
        cmp     ah, 1
        je      .set
        cmp     ah, 2
        je      .time
        cmp     ah, 4
        je      .date
        jmp     svc_carry
.get:   mov     ax, [BDA_TICKS]
        mov     F_DX, ax
        mov     ax, [BDA_TICKS+2]
        mov     F_CX, ax
        mov     al, [BDA_MIDNIGHT]
        mov     F_AL, al
        mov     byte [BDA_MIDNIGHT], 0
        jmp     svc_leave
.set:   mov     [BDA_TICKS], dx
        mov     [BDA_TICKS+2], cx
        mov     byte [BDA_MIDNIGHT], 0
        jmp     svc_leave
.time:  mov     al, 04h                 ; hours, minutes, seconds in BCD
        call    cmos_read
        mov     F_CH, al
        mov     al, 02h
        call    cmos_read
        mov     F_CL, al
        mov     al, 00h
        call    cmos_read
        mov     F_DH, al
        mov     F_DL, 0
        jmp     svc_nocarry
.date:  mov     al, 32h                 ; century, year, month, day in BCD
        call    cmos_read
        mov     F_CH, al
        mov     al, 09h
        call    cmos_read
        mov     F_CL, al
        mov     al, 08h
        call    cmos_read
        mov     F_DH, al
        mov     al, 07h
        call    cmos_read
        mov     F_DL, al
        jmp     svc_nocarry

cmos_read:
        out     CMOS_INDEX, al
        in      al, CMOS_DATA
        ret

; ====================================================================
; SD card over SPI
; ====================================================================

; Send al, return the byte received in al.
spi_xfer:
        out     SPI_DATA, al
.busy:  in      al, SPI_CTRL
        test    al, 80h
        jnz     .busy
        in      al, SPI_DATA
        ret

spi_idle:
        mov     al, 0FFh
        jmp     spi_xfer

sd_select:
        mov     al, 1
        out     SPI_CTRL, al
        ret

sd_deselect:
        xor     al, al
        out     SPI_CTRL, al
        jmp     spi_idle

; ah = command, edx = argument. Returns the R1 byte in al (FFh if the
; card did not answer). The card stays selected for what follows.
sd_cmd: push    cx
        call    sd_deselect
        call    sd_select
        mov     al, ah
        or      al, 40h
        call    spi_xfer
        mov     cx, 4
.arg:   rol     edx, 8
        mov     al, dl
        call    spi_xfer
        loop    .arg
        mov     al, 95h                 ; checksum of command 0
        test    ah, ah
        jz      .crc
        mov     al, 87h                 ; and of command 8 with 1AAh
        cmp     ah, 8
        je      .crc
        mov     al, 01h                 ; the rest are not checked
.crc:   call    spi_xfer
        mov     cx, 16
.wait:  call    spi_idle
        test    al, 80h
        jz      .got
        loop    .wait
.got:   mov     [E_SDANS], al
        pop     cx
        ret

; Bring the card up. Carry set if there is none we can use.
; On success E_TOTAL holds its size in sectors. ds = EBDA.
sd_init:
        mov     al, SPI_SLOW            ; a card starts at 400 kHz or less
        out     SPI_CTRL, al
        call    sd_deselect
        mov     cx, 10                  ; 80 clocks with the card deselected
.wake:  call    spi_idle
        loop    .wake

        mov     byte [E_SDSTEP], 1
        mov     cx, 16                  ; command 0: reset. A card may need
.reset: xor     ah, ah                  ; asking more than once.
        xor     edx, edx
        call    sd_cmd
        cmp     al, 1
        je      .idle
        loop    .reset
        jmp     .fail
.idle:  mov     byte [E_SDSTEP], 2
        mov     ah, 8                   ; command 8: voltage check
        mov     edx, 1AAh
        call    sd_cmd
        cmp     al, 1
        jne     .fail                   ; version 1 cards: not supported yet
        mov     cx, 4
.r7:    call    spi_idle
        loop    .r7

        mov     byte [E_SDSTEP], 3
        xor     cx, cx                  ; initialise, with high capacity
.init:  mov     ah, 55
        xor     edx, edx
        call    sd_cmd
        mov     ah, 41
        mov     edx, 40000000h
        call    sd_cmd
        test    al, al
        jz      .ready
        loop    .init
        jmp     .fail

.ready: mov     byte [E_SDSTEP], 4
        mov     ah, 58                  ; operating conditions
        xor     edx, edx
        call    sd_cmd
        test    al, al
        jnz     .fail
        call    spi_idle
        mov     bl, al
        mov     cx, 3
.ocr:   call    spi_idle
        loop    .ocr
        mov     byte [E_SDSTEP], 5
        mov     [E_SDANS], bl
        test    bl, 40h
        jz      .fail                   ; byte-addressed cards: not yet

        mov     byte [E_SDSTEP], 6
        mov     ah, 9                   ; card-specific data
        xor     edx, edx
        call    sd_cmd
        test    al, al
        jnz     .fail
        call    sd_token
        jc      .fail
        xor     edx, edx
        xor     bx, bx                  ; bx = index of the byte
.csd:   call    spi_idle
        test    bx, bx
        jnz     .size
        mov     byte [E_SDSTEP], 7
        mov     [E_SDANS], al
        and     al, 0C0h
        cmp     al, 40h
        jne     .fail                   ; not version 2.0
.size:  cmp     bx, 7
        jb      .skip
        cmp     bx, 9
        ja      .skip
        shl     edx, 8
        mov     dl, al
.skip:  inc     bx
        cmp     bx, 18                  ; 16 bytes and the checksum
        jb      .csd
        and     edx, 3FFFFFh
        inc     edx
        shl     edx, 10                 ; (C_SIZE + 1) * 1024 sectors
        mov     [E_TOTAL], edx
        call    sd_deselect
        mov     al, SPI_FAST            ; the card is up: full speed
        out     SPI_CTRL, al
        clc
        ret
.fail:  call    sd_deselect
        stc
        ret

; Wait for the start-of-data token. Carry set if it does not come.
sd_token:
        push    cx
        xor     cx, cx
.wait:  call    spi_idle
        cmp     al, 0FEh
        je      .ok
        loop    .wait
        pop     cx
        stc
        ret
.ok:    pop     cx
        clc
        ret

; Read sector eax to es:di. di advances. Carry set on error.
sd_read:
        push    cx
        push    edx
        mov     edx, eax
        mov     ah, 17
        call    sd_cmd
        test    al, al
        jnz     .err
        call    sd_token
        jc      .err
        mov     cx, 512
.data:  call    spi_idle
        stosb
        loop    .data
        call    spi_idle                ; checksum, not checked
        call    spi_idle
        call    sd_deselect
        pop     edx
        pop     cx
        clc
        ret
.err:   call    sd_deselect
        pop     edx
        pop     cx
        stc
        ret

; Write sector eax from es:di. di advances. Carry set on error.
sd_write:
        push    cx
        push    edx
        mov     edx, eax
        mov     ah, 24
        call    sd_cmd
        test    al, al
        jnz     .err
        call    spi_idle
        mov     al, 0FEh
        call    spi_xfer
        mov     cx, 512
.data:  mov     al, [es:di]
        inc     di
        call    spi_xfer
        loop    .data
        call    spi_idle                ; checksum, not checked
        call    spi_idle
        mov     cx, 8                   ; data response, which a card may
.resp:  call    spi_idle                ; take a byte or two to give
        cmp     al, 0FFh
        jne     .answer
        loop    .resp
        jmp     .err
.answer:
        and     al, 1Fh
        cmp     al, 05h
        jne     .err
        xor     cx, cx                  ; busy until it reads non-zero
.busy:  call    spi_idle
        test    al, al
        jnz     .done
        loop    .busy
        jmp     .err
.done:  call    sd_deselect
        pop     edx
        pop     cx
        clc
        ret
.err:   call    sd_deselect
        pop     edx
        pop     cx
        stc
        ret

; ====================================================================
; Disk setup at power-on
; ====================================================================

; Find the card and decide what it is. A card whose first sector
; describes a floppy-sized volume is presented as drive A:, with that
; geometry. Anything else is hard disk 80h.
disk_setup:
        push    ds
        push    es
        mov     ax, BDA_SEG
        mov     ds, ax
        mov     ax, [BDA_EBDA]
        mov     ds, ax
        call    sd_init
        jnc     .card
        ; Say how far bringing the card up got (the steps are numbered
        ; in sd_init) and what the card last answered, for a first
        ; test on a board.
        mov     si, msg_nocard
        call    puts
        xor     ah, ah
        mov     al, [E_SDSTEP]
        call    putdec
        mov     si, msg_answer
        call    puts
        xor     ah, ah
        mov     al, [E_SDANS]
        call    puthex
        mov     si, msg_crlf
        call    puts
        jmp     .out

.card:  mov     si, msg_card
        call    puts
        mov     eax, [E_TOTAL]
        shr     eax, 11                 ; sectors to megabytes
        call    putdec

        xor     ax, ax                  ; first sector to 0000:7C00
        mov     es, ax
        mov     di, BOOT_OFF
        xor     eax, eax
        call    sd_read
        jc      .hard

        cmp     word [es:BOOT_OFF+0Bh], 512     ; bytes per sector
        jne     .hard
        cmp     byte [es:BOOT_OFF+15h], 0F0h    ; media descriptor
        jb      .hard
        mov     ax, [es:BOOT_OFF+13h]           ; sectors on the volume
        test    ax, ax
        jz      .hard
        cmp     ax, 5760
        ja      .hard
        mov     bx, [es:BOOT_OFF+18h]           ; sectors per track
        test    bx, bx
        jz      .hard
        cmp     bx, 36
        ja      .hard
        mov     cx, [es:BOOT_OFF+1Ah]           ; heads
        test    cx, cx
        jz      .hard
        cmp     cx, 2
        ja      .hard

        mov     byte [E_KIND], 1
        mov     [E_FD+G_SPT], bl
        mov     [E_FD+G_HEADS], cl
        push    ax
        mov     ax, bx
        mul     cx                      ; sectors per cylinder
        mov     bx, ax
        pop     ax
        xor     dx, dx
        div     bx
        mov     [E_FD+G_CYLS], ax
        movzx   eax, word [es:BOOT_OFF+13h]
        mov     [E_TOTAL], eax          ; the volume, not the whole card
        mov     ax, BDA_SEG
        mov     es, ax
        or      word [es:BDA_EQUIP], 0001h      ; one diskette drive
        mov     si, msg_floppy
        call    puts
        jmp     .out

.hard:  mov     byte [E_KIND], 2
        ; Geometry. If the first sector holds a partition table, take
        ; the heads and sectors per track from where its first
        ; partition ends: that is the geometry whoever made the disk
        ; had in mind, and the boot sector inside the partition was
        ; written for it. A card's size says nothing about that.
        cmp     word [es:BOOT_OFF+510], 0AA55h
        jne     .size
        test    byte [es:BOOT_OFF+446], 7Fh     ; boot flag: 00h or 80h
        jnz     .size
        cmp     byte [es:BOOT_OFF+446+4], 0     ; partition type
        je      .size
        mov     ch, [es:BOOT_OFF+446+6]         ; end sector, low six bits
        and     ch, 3Fh
        jz      .size
        mov     cl, [es:BOOT_OFF+446+5]         ; end head
        cmp     cl, 254
        ja      .size
        inc     cl
        jmp     .geom
        ; Otherwise 63 sectors and the fewest heads that reach the end.
.size:  mov     ch, 63
        mov     eax, [E_TOTAL]
        mov     cl, 16
.heads: movzx   ebx, cl
        imul    ebx, 63 * 1024
        cmp     eax, ebx
        jbe     .geom
        cmp     cl, 128
        jae     .max
        shl     cl, 1
        jmp     .heads
.max:   mov     cl, 255
.geom:  mov     [E_HD+G_SPT], ch
        mov     [E_HD+G_HEADS], cl
        movzx   ebx, cl
        movzx   eax, ch
        imul    ebx, eax                ; sectors per cylinder
        mov     eax, [E_TOTAL]
        xor     edx, edx
        div     ebx
        cmp     eax, 1024
        jbe     .cyls
        mov     eax, 1024
.cyls:  mov     [E_HD+G_CYLS], ax
        mov     ax, BDA_SEG
        mov     es, ax
        mov     byte [es:BDA_HDCOUNT], 1
        mov     si, msg_hard
        call    puts
.out:   pop     es
        pop     ds
        ret

; ====================================================================
; INT 13h: disk
; ====================================================================

int13:  SVC_ENTER
        sti
        mov     bx, BDA_SEG
        mov     ds, bx
        mov     bx, [BDA_EBDA]
        mov     ds, bx

        ; si = geometry of the drive asked for, or no such drive.
        cmp     dl, 00h
        jne     .not_a
        cmp     byte [E_KIND], 1
        jne     .nodrive
        mov     si, E_FD
        jmp     .drive
.not_a: cmp     dl, 80h
        jne     .nodrive
        cmp     byte [E_KIND], 2
        jne     .nodrive
        mov     si, E_HD

.drive: cmp     ah, 01h
        je      .status
        cmp     ah, 02h
        je      .rw
        cmp     ah, 03h
        je      .rw
        cmp     ah, 04h
        je      .rw
        cmp     ah, 08h
        je      .params
        cmp     ah, 15h
        je      .type
        cmp     ah, 41h
        je      .ext
        cmp     ah, 42h
        je      .lba
        cmp     ah, 43h
        je      .lba
        cmp     ah, 44h
        je      .lba
        cmp     ah, 48h
        je      .extparams
        cmp     ah, 00h
        je      .ok
        cmp     ah, 0Ch
        je      .ok
        cmp     ah, 0Dh
        je      .ok
        cmp     ah, 10h
        je      .ok
        cmp     ah, 11h
        je      .ok
        cmp     ah, 14h
        je      .ok
        cmp     ah, 16h
        je      .ok
.bad:   mov     al, 01h                 ; invalid request
.fail:  mov     [E_STATUS], al
        mov     F_AH, al
        jmp     svc_carry
.ok:    mov     byte [E_STATUS], 0
        mov     F_AH, 0
        jmp     svc_nocarry

.nodrive:
        cmp     ah, 15h
        jne     .bad
        mov     F_AH, 0                 ; 15h: no such drive
        jmp     svc_nocarry

.status:
        mov     al, [E_STATUS]
        mov     F_AH, al
        jmp     svc_nocarry

; 02h read, 03h write, 04h verify
.rw:    cmp     F_AL, 0
        je      .bad
        mov     bx, cx
        and     bx, 3Fh                 ; sector, from 1
        jz      .nosector
        cmp     bl, [si+G_SPT]
        ja      .nosector
        movzx   eax, ch                 ; cylinder: ch and the top of cl
        mov     dl, cl
        shr     dl, 6
        mov     ah, dl
        movzx   ecx, byte [si+G_HEADS]
        movzx   edx, F_DH
        cmp     dx, cx
        jae     .nosector
        push    edx
        mul     ecx
        pop     edx
        add     eax, edx
        movzx   ecx, byte [si+G_SPT]
        mul     ecx
        dec     bx
        movzx   ebx, bx
        add     eax, ebx                ; eax = sector number on the card

        mov     di, F_BX
        mov     es, F_ES
        movzx   cx, F_AL
        mov     F_AL, 0                 ; counts the sectors done
.next:  cmp     eax, [E_TOTAL]
        jae     .nosector
        push    eax
        cmp     F_AH, 03h
        je      .write
        cmp     F_AH, 04h
        je      .verify
        call    sd_read
        jmp     .check
.write: call    sd_write
        jmp     .check
.verify:
        clc
.check: pop     eax
        jc      .ioerr
        inc     eax
        inc     F_AL
        loop    .next
        jmp     .ok
.nosector:
        mov     al, 04h                 ; sector not found
        jmp     .fail
.ioerr: mov     al, 20h                 ; controller failure
        jmp     .fail

; 41h: are the calls with sector numbers there? (hard disk only)
.ext:   cmp     si, E_HD
        jne     .bad
        cmp     F_BX, 55AAh
        jne     .bad
        mov     F_BX, 0AA55h
        mov     F_AH, 01h               ; version 1.x
        mov     F_CX, 0001h             ; 42h to 44h, 47h and 48h
        mov     byte [E_STATUS], 0
        jmp     svc_nocarry

; 42h read, 43h write, 44h verify, by sector number. The caller's
; ds:si points at a packet: size, count (word, at 2), buffer (far
; pointer, at 4), first sector (64 bits, at 8). The count is set to
; the number of sectors done.
.lba:   cmp     si, E_HD
        jne     .bad
        mov     fs, F_DS
        mov     bx, F_SI
        cmp     byte [fs:bx], 10h
        jb      .bad
        cmp     dword [fs:bx+12], 0
        jne     .nosector
        mov     eax, [fs:bx+8]
        mov     cx, [fs:bx+2]
        les     di, [fs:bx+4]
        mov     word [fs:bx+2], 0
        test    cx, cx
        jz      .ok
.lnext: cmp     eax, [E_TOTAL]
        jae     .nosector
        push    eax
        cmp     F_AH, 43h
        je      .lwrite
        cmp     F_AH, 44h
        je      .lverify
        call    sd_read
        jmp     .lcheck
.lwrite:
        call    sd_write
        jmp     .lcheck
.lverify:
        clc
.lcheck:
        pop     eax
        jc      .ioerr
        inc     eax
        inc     word [fs:bx+2]
        ; A buffer that runs off the end of its segment goes on in the
        ; next (sixty-four kilobytes are 128 sectors: callers do ask).
        test    di, di
        jnz     .lsame
        mov     dx, es
        add     dx, 1000h
        mov     es, dx
.lsame: loop    .lnext
        jmp     .ok

; 48h: the drive's size, to the caller's ds:si.
.extparams:
        cmp     si, E_HD
        jne     .bad
        mov     fs, F_DS
        mov     bx, F_SI
        cmp     word [fs:bx], 1Ah
        jb      .bad
        mov     word [fs:bx], 1Ah
        mov     word [fs:bx+2], 0002h   ; the geometry below is valid
        movzx   eax, word [si+G_CYLS]
        mov     [fs:bx+4], eax
        movzx   eax, byte [si+G_HEADS]
        mov     [fs:bx+8], eax
        movzx   eax, byte [si+G_SPT]
        mov     [fs:bx+12], eax
        mov     eax, [E_TOTAL]
        mov     [fs:bx+16], eax
        mov     dword [fs:bx+20], 0
        mov     word [fs:bx+24], 512
        jmp     .ok

; 08h: drive parameters
.params:
        mov     bx, [si+G_CYLS]
        dec     bx
        mov     ch, bl
        mov     cl, bh
        shl     cl, 6
        or      cl, [si+G_SPT]
        mov     F_CX, cx
        mov     dh, [si+G_HEADS]
        dec     dh
        mov     dl, 1                   ; one drive of this kind
        mov     F_DX, dx
        mov     F_AX, 0
        cmp     si, E_FD
        jne     .ok
        mov     bx, 0004h               ; drive type: 1.44 MB
        mov     ax, [E_TOTAL]
        cmp     ax, 720
        jne     .t2
        mov     bl, 1                   ; 360 KB
.t2:    cmp     ax, 2400
        jne     .t3
        mov     bl, 2                   ; 1.2 MB
.t3:    cmp     ax, 1440
        jne     .t4
        mov     bl, 3                   ; 720 KB
.t4:    mov     F_BX, bx
        mov     F_ES, cs
        mov     F_DI, diskette_table
        jmp     .ok

; 15h: drive type
.type:  cmp     si, E_FD
        jne     .fixed
        mov     F_AH, 1                 ; diskette, no change line
        jmp     svc_nocarry
.fixed: mov     F_AH, 3                 ; fixed disk: cx:dx = sectors
        mov     ax, [E_TOTAL]
        mov     F_DX, ax
        mov     ax, [E_TOTAL+2]
        mov     F_CX, ax
        jmp     svc_nocarry

; Diskette parameter table, pointed to by vector 1Eh.
diskette_table:
        db 0DFh, 02h, 25h, 02h, 18, 1Bh, 0FFh, 54h, 0F6h, 0Fh, 08h

; ====================================================================
; Boot
; ====================================================================

; INT 19h: load the first sector of the disk and run it.
int19:  sti
        xor     ax, ax
        mov     ds, ax
        mov     es, ax
        mov     ax, [BDA_SEG * 16 + BDA_EBDA]
        mov     fs, ax
        mov     dl, 00h
        cmp     byte [fs:E_KIND], 1
        je      .load
        mov     dl, 80h
        cmp     byte [fs:E_KIND], 2
        jne     .none
.load:  push    dx
        xor     ah, ah
        int     13h
        pop     dx
        push    dx
        mov     ax, 0201h
        mov     bx, BOOT_OFF
        mov     cx, 0001h
        xor     dh, dh
        int     13h
        pop     dx
        jc      .none
        test    dl, dl
        jz      .go                     ; a diskette needs no signature
        cmp     word [BOOT_OFF+510], 0AA55h
        jne     .none
.go:    jmp     0000h:BOOT_OFF
.none:  int     18h

; INT 18h: nothing to boot
int18:  mov     si, msg_noboot
        call    puts
.stop:  hlt
        jmp     .stop

; ====================================================================
; The DDR3 trainer: a program of its own (sw/train), run from the
; text screen's memory before there is any other.
; ====================================================================

train_blob:
        incbin  "train.bin"
train_end:

; ====================================================================
; Fixed locations at the top of the image
; ====================================================================

        times   0FFF0h - ($ - $$) db 0FFh
reset:  jmp     0F000h:post
        db      "11/15/26"              ; date of this BIOS
        db      0FFh
        db      0FCh                    ; machine type: AT class
        db      0FFh
