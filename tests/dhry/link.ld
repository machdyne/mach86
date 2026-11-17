/* Mach86: a flat 16-bit program at 0100h in one 64 KB segment. */
OUTPUT_FORMAT(binary)
SECTIONS
{
    . = 0x100;
    .text : { *(.start) *(.text*) *(.rodata*) }
    .data : { *(.data*) }
    .bss  : { *(.bss*) *(COMMON) }
    /DISCARD/ : { *(.eh_frame) *(.comment) *(.note*) }
}
