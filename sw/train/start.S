/* Mach86 BIOS -- entry of the DDR3 trainer (ddr3_train.c): called far
 * by the BIOS at B800:0000 with DS = ES = SS = B800h. Returns AX. */
        .code16gcc
        .section .start, "ax"
        .globl  _start
_start: calll   main
        lretw
