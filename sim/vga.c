/*
 * Mach86 reference model -- the VGA. See vga.h and docs/video.md.
 *
 * The memory is 16,384 words of four bytes, one for each plane. How a
 * CPU address reaches it depends on the mode, as on the real thing:
 *
 *   planar (16 colours)      the word at the offset; the graphics
 *                            controller's write and read modes apply
 *   chained (256 colours)    byte a is plane a mod 4 of word a / 4
 *   odd/even (text, CGA      byte a is plane a mod 2 of word a / 2
 *   four colours)
 *
 * The last two are plain bytes: the graphics controller's logic is not
 * applied to them. (The real thing applies it, with settings that make
 * it do nothing in the standard modes; and it stores a chained byte at
 * word a, not a / 4, which only programs that mix chained and planar
 * access to the same picture could tell.)
 */
#include <string.h>
#include "vga.h"

/* The registers as they are after reset: the memory at B8000h as plain
 * bytes (odd/even), which is what the BIOS's DDR3 trainer runs in
 * before any mode is set; the screen off. The memory keeps what it
 * holds. */
void vga_reset(vga *v)
{
    memset((char *)v + sizeof v->mem, 0, sizeof *v - sizeof v->mem);
    v->dac_mask = 0xFF;
    v->seq[2] = 0x03;           /* text: planes 0 and 1, odd/even */
    v->seq[4] = 0x02;
    v->gc[5] = 0x10;
    v->gc[6] = 0x0E;            /* B8000h, odd/even */
    v->gc[8] = 0xFF;
}

/* Where the CPU sees the memory, and how wide the window is. */
static int window(const vga *v, uint32_t addr, uint32_t *off)
{
    switch ((v->gc[6] >> 2) & 3) {
    case 0: *off = addr - 0xA0000; return addr < 0xC0000;
    case 1: *off = addr - 0xA0000; return addr < 0xB0000;
    case 2: *off = addr - 0xB0000; return addr >= 0xB0000 && addr < 0xB8000;
    default: *off = addr - 0xB8000; return addr >= 0xB8000;
    }
}

static int chained(const vga *v) { return (v->seq[4] & 0x08) != 0; }
static int oddeven(const vga *v) { return !(v->seq[4] & 0x04); }

static uint8_t rotate(const vga *v, uint8_t x)
{
    int n = v->gc[3] & 7;
    return (uint8_t)((x >> n) | (x << (8 - n)));
}

uint8_t vga_mem_read(vga *v, uint32_t addr)
{
    uint32_t off;
    if (!window(v, addr, &off))
        return 0xFF;
    if (chained(v))
        return (uint8_t)(v->mem[(off >> 2) % VGA_WORDS] >> (8 * (off & 3)));
    if (oddeven(v))
        return (uint8_t)(v->mem[(off >> 1) % VGA_WORDS] >> (8 * (off & 1)));
    v->latch = v->mem[off % VGA_WORDS];
    if (!(v->gc[5] & 0x08))                     /* read mode 0: one plane */
        return (uint8_t)(v->latch >> (8 * (v->gc[4] & 3)));
    /* Read mode 1: a bit is set where the pixel is the compare colour,
     * in the planes that are cared about. */
    uint8_t same = 0xFF;
    for (int p = 0; p < 4; p++)
        if (v->gc[7] >> p & 1) {
            uint8_t plane = (uint8_t)(v->latch >> (8 * p));
            same &= (uint8_t)~(plane ^ ((v->gc[2] >> p & 1) ? 0xFF : 0x00));
        }
    return same;
}

void vga_mem_write(vga *v, uint32_t addr, uint8_t val)
{
    uint32_t off;
    if (!window(v, addr, &off))
        return;
    if (chained(v) || oddeven(v)) {
        int sh = chained(v) ? 2 : 1;
        uint32_t w = (off >> sh) % VGA_WORDS;
        int lane = (int)(off & ((1u << sh) - 1));
        v->mem[w] = (v->mem[w] & ~(0xFFu << (8 * lane))) | ((uint32_t)val << (8 * lane));
        return;
    }
    uint32_t w = off % VGA_WORDS, out = v->mem[w];
    int mode = v->gc[5] & 3, func = (v->gc[3] >> 3) & 3;
    uint8_t mask = v->gc[8];
    for (int p = 0; p < 4; p++) {
        uint8_t lat = (uint8_t)(v->latch >> (8 * p)), d;
        if (!(v->seq[2] >> p & 1))
            continue;
        switch (mode) {
        case 0:
            d = (v->gc[1] >> p & 1) ? ((v->gc[0] >> p & 1) ? 0xFF : 0x00)
                                    : rotate(v, val);
            break;
        case 1:
            d = lat;
            break;
        case 2:
            d = (val >> p & 1) ? 0xFF : 0x00;
            break;
        default:
            d = (v->gc[0] >> p & 1) ? 0xFF : 0x00;
            mask = (uint8_t)(rotate(v, val) & v->gc[8]);
            break;
        }
        if (mode != 1) {
            if (func == 1) d &= lat;
            else if (func == 2) d |= lat;
            else if (func == 3) d ^= lat;
        }
        if (mode != 1)
            d = (uint8_t)((d & mask) | (lat & ~mask));
        out = (out & ~(0xFFu << (8 * p))) | ((uint32_t)d << (8 * p));
    }
    v->mem[w] = out;
}

int vga_port(uint16_t port)
{
    return (port >= 0x3C0 && port <= 0x3CF) || port == 0x3D4 || port == 0x3D5 ||
           port == 0x3DA;
}

uint8_t vga_in(vga *v, uint16_t port)
{
    switch (port) {
    case 0x3C0: return v->ac_index;
    case 0x3C1: return v->ac[v->ac_index & 31];
    case 0x3C4: return v->seq_index;
    case 0x3C5: return v->seq[v->seq_index & 7];
    case 0x3C6: return v->dac_mask;
    case 0x3C7: return 0x00;
    case 0x3C8: return v->dac_widx;
    case 0x3C9: {
        uint8_t x = v->dac[v->dac_ridx][v->dac_rsub];
        if (++v->dac_rsub == 3) { v->dac_rsub = 0; v->dac_ridx++; }
        return x;
    }
    case 0x3CC: return v->misc;
    case 0x3CE: return v->gc_index;
    case 0x3CF: return v->gc[v->gc_index & 15];
    case 0x3D4: return v->crtc_index;
    case 0x3D5: return v->crtc[v->crtc_index & 31];
    case 0x3DA:
        v->ac_data = 0;
        /* Alternate so that loops waiting for either edge finish. */
        v->status ^= 0x09;
        return v->status;
    default: return 0xFF;
    }
}

void vga_out(vga *v, uint16_t port, uint8_t val)
{
    switch (port) {
    case 0x3C0:
        if (!v->ac_data)
            v->ac_index = val;
        else
            v->ac[v->ac_index & 31] = val;
        v->ac_data = !v->ac_data;
        break;
    case 0x3C2: v->misc = val; break;
    case 0x3C4: v->seq_index = val; break;
    case 0x3C5: v->seq[v->seq_index & 7] = val; break;
    case 0x3C6: v->dac_mask = val; break;
    case 0x3C7: v->dac_ridx = val; v->dac_rsub = 0; break;
    case 0x3C8: v->dac_widx = val; v->dac_wsub = 0; break;
    case 0x3C9:
        v->dac[v->dac_widx][v->dac_wsub] = val & 0x3F;
        if (++v->dac_wsub == 3) { v->dac_wsub = 0; v->dac_widx++; }
        break;
    case 0x3CE: v->gc_index = val; break;
    case 0x3CF: v->gc[v->gc_index & 15] = val; break;
    case 0x3D4: v->crtc_index = val; break;
    case 0x3D5: v->crtc[v->crtc_index & 31] = val; break;
    default: break;
    }
}

static uint32_t start_address(const vga *v)
{
    return ((uint32_t)v->crtc[0x0C] << 8) | v->crtc[0x0D];
}

uint16_t vga_text_cell(const vga *v, int row, int col)
{
    return (uint16_t)v->mem[(start_address(v) + (uint32_t)(row * 80 + col)) % VGA_WORDS];
}

/* A 16-colour value through the attribute controller to a DAC index. */
static uint8_t attr_colour(const vga *v, int c)
{
    uint8_t idx = v->ac[c & 15] & 0x3F;
    if (v->ac[0x10] & 0x80)
        idx = (uint8_t)((idx & 0x0F) | ((v->ac[0x14] & 3) << 4));
    return (uint8_t)(idx | ((v->ac[0x14] & 0x0C) << 4));
}

static void put(const vga *v, uint8_t *rgb, uint8_t idx)
{
    idx &= v->dac_mask;
    for (int k = 0; k < 3; k++) {
        uint8_t six = v->dac[idx][k];
        rgb[k] = (uint8_t)((six << 2) | (six >> 4));
    }
}

void vga_render(const vga *v, uint8_t *rgb, const uint8_t *font)
{
    int graphics = v->gc[6] & 1;
    int on = v->ac_index & 0x20;
    uint32_t start = start_address(v);
    memset(rgb, 0, 640 * 480 * 3);
    if (!on)
        return;
    /* The picture has 350, 400 or 480 lines, by the sync polarities a
     * program sets for them, centred in the 480. Lines are shown twice
     * when the mode says so (the 200-line modes). */
    int lines = (v->misc >> 6) == 2 ? 350 : (v->misc >> 6) == 3 ? 480 : 400;
    int first = (480 - lines) / 2;
    int twice = (v->crtc[0x09] & 0x80) || (v->crtc[0x09] & 0x1F) == 1;
    uint32_t stride = 2u * v->crtc[0x13];
    for (int y = first; y < first + lines; y++) {
        int ty = y - first;
        int sy = twice ? ty / 2 : ty;
        for (int x = 0; x < 640; x++) {
            uint8_t *px = rgb + 3 * (y * 640 + x);
            if (!graphics) {
                if (!font)
                    continue;
                uint16_t cell = vga_text_cell(v, ty / 16, x / 8);
                int ink = font[(cell & 0xFF) * 16 + ty % 16] >> (7 - x % 8) & 1;
                put(v, px, attr_colour(v, ink ? (cell >> 8) & 15 : (cell >> 12) & 7));
            } else if (v->gc[5] & 0x40) {
                /* 256 colours: four pixels a word, each two wide. */
                uint32_t w = (start + (uint32_t)sy * stride + (uint32_t)(x / 8)) % VGA_WORDS;
                put(v, px, (uint8_t)(v->mem[w] >> (8 * ((x / 2) & 3))));
            } else if (v->gc[5] & 0x20) {
                /* Four colours, the CGA way: even lines in one half of
                 * the memory, odd lines in the other; odd/even bytes. */
                int sx = x / 2;
                uint32_t a = (uint32_t)((sy & 1) * 0x2000 + (sy >> 1) * 80 + sx / 4);
                uint8_t b = (uint8_t)(v->mem[(a >> 1) % VGA_WORDS] >> (8 * (a & 1)));
                put(v, px, attr_colour(v, (b >> (6 - 2 * (sx & 3))) & 3));
            } else {
                /* Planes. With half the dot clock a pixel is two wide.
                 * With the CGA's addressing (mode 6) lines alternate
                 * between halves. */
                int sx = (v->seq[1] & 0x08) ? x / 2 : x;
                uint32_t a;
                if (!(v->crtc[0x17] & 1))
                    a = (uint32_t)((sy & 1) * 0x2000 + (sy >> 1) * 80 + sx / 8);
                else
                    a = start + (uint32_t)sy * stride + (uint32_t)(sx / 8);
                uint32_t w = v->mem[a % VGA_WORDS];
                int c = 0;
                for (int p = 0; p < 4; p++)
                    if ((v->ac[0x12] >> p & 1) && (w >> (8 * p + 7 - (sx & 7)) & 1))
                        c |= 1 << p;
                put(v, px, attr_colour(v, c));
            }
        }
    }
}
