/*
 * Mach86 reference model -- the VGA.
 *
 * Sources: the IBM VGA technical reference as it describes the
 * registers (sequencer, graphics controller, attribute controller,
 * display controller, DAC) and the write and read modes; docs/video.md
 * says what of it is here and how the memory is laid out.
 */
#ifndef VGA_H
#define VGA_H

#include <stdint.h>

#define VGA_WORDS 65536         /* 256 KB: four planes of 64 KB */

typedef struct {
    uint32_t mem[VGA_WORDS];    /* a word is the four planes' bytes, plane 0 lowest */
    uint32_t latch;
    uint8_t  seq_index, seq[8];
    uint8_t  gc_index, gc[16];
    uint8_t  ac_index, ac[32];
    int      ac_data;           /* the next write to 3C0h is data */
    uint8_t  crtc_index, crtc[32];
    uint8_t  misc;
    uint8_t  dac[256][3], dac_mask;
    uint8_t  dac_ridx, dac_widx;
    int      dac_rsub, dac_wsub;
    uint8_t  status;
} vga;

void    vga_reset(vga *v);
uint8_t vga_mem_read(vga *v, uint32_t addr);        /* addr: A0000h-BFFFFh */
void    vga_mem_write(vga *v, uint32_t addr, uint8_t val);
int     vga_port(uint16_t port);                    /* is it one of ours? */
uint8_t vga_in(vga *v, uint16_t port);
void    vga_out(vga *v, uint16_t port, uint8_t val);

/* The character cell at a position of the text screen: {attribute, character}. */
uint16_t vga_text_cell(const vga *v, int row, int col);

/* The picture as the display shows it: 640 x 480, three bytes a pixel.
 * font: 256 characters of 16 rows, or NULL (then text is not drawn). */
void    vga_render(const vga *v, uint8_t *rgb, const uint8_t *font);

#endif
