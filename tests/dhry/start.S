/* Mach86: entry of a flat 16-bit C program (tests/dhry/rom.asm). */
        .code16gcc
        .section .start, "ax"
        .globl  _start
_start: calll   main
        lretw
