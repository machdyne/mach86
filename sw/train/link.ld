/* Mach86 BIOS -- the DDR3 trainer: a flat program at offset 0 of the
 * segment it is copied to; its variables follow the code there. */
OUTPUT_FORMAT(binary)
SECTIONS
{
    . = 0;
    .text : { *(.start) *(.text*) *(.rodata*) *(.data*) }
    _image_end = .;
    .bss  : { *(.bss*) *(COMMON) }
    _end = .;
    /DISCARD/ : { *(.eh_frame) *(.comment) *(.note*) }
}
