/*
 * Mach86 -- reference model of the FM synthesiser. See opl2.h.
 *
 * Source: the YM3812 application manual, for the registers and what
 * each does (frequency = F-number * 2^(block-20) * 49,716 Hz, the
 * multiples, the envelope's four parts, key scaling, feedback, the
 * two connections, vibrato and tremolo, the four waveforms). How the
 * numbers are computed is ours, and is not the chip's bit for bit:
 * the envelope's timing in particular is close, not exact.
 *
 * It makes 48,000 samples a second and not the chip's 49,716; the
 * phase steps are scaled to keep the pitch.
 */
#include <stdio.h>
#include <string.h>
#include "opl2.h"

static const uint8_t multx2[16] = {1, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 20, 24, 24, 30, 30};
static const uint8_t kslrom[16] = {0, 32, 40, 45, 48, 51, 53, 55, 56, 58, 59, 60, 61, 62, 63, 64};
static const uint8_t pat[4] = {0xAA, 0xBA, 0xEE, 0xFE};     /* bit i: step i of 8 */

int opl2_init(opl2 *o, const char *romfile)
{
    memset(o, 0, sizeof *o);
    FILE *f = fopen(romfile, "r");
    if (!f)
        return -1;
    for (int i = 0; i < 512; i++) {
        unsigned v;
        if (fscanf(f, "%x", &v) != 1) {
            fclose(f);
            return -1;
        }
        o->rom[i] = (uint16_t)v;
    }
    fclose(f);
    for (int i = 0; i < 18; i++) {
        o->env[i] = 511;
        o->egs[i] = 3;
    }
    return 0;
}

void opl2_write(opl2 *o, uint8_t reg, uint8_t val)
{
    o->reg[reg] = val;
}

/* One operator: slot s (channel s/2, operator s%2), its phase
 * modulation; returns its output, -4084..4084. */
static int op(opl2 *o, int s, int mod, int am_val, int vib_pos)
{
    int ch = s >> 1;
    int off = (ch / 3) * 8 + ch % 3 + 3 * (s & 1);
    uint8_t r20 = o->reg[0x20 + off], r40 = o->reg[0x40 + off];
    uint8_t r60 = o->reg[0x60 + off], r80 = o->reg[0x80 + off];
    uint8_t rE0 = o->reg[0xE0 + off];
    uint8_t rA0 = o->reg[0xA0 + ch], rB0 = o->reg[0xB0 + ch];
    int kon = (rB0 >> 5) & 1, block = (rB0 >> 2) & 7;
    int fnum = ((rB0 & 3) << 8) | rA0;

    /* The phase step. */
    int f = fnum;
    if (r20 & 0x40) {
        int d = fnum >> 7;
        if ((vib_pos & 3) == 0) d = 0;
        else if (vib_pos & 1) d >>= 1;
        if (!(o->reg[0xBD] & 0x40)) d >>= 1;
        f = (vib_pos & 4) ? fnum - d : fnum + d;
    }
    uint32_t inc = (((uint32_t)f << block) * multx2[r20 & 15]) >> 1;
    inc = inc + (inc >> 5) + (inc >> 8) + (inc >> 11);      /* 49,716 / 48,000 */

    /* The key. */
    int st = o->egs[s], e = o->env[s];
    uint32_t p = o->ph[s];
    if (!kon)
        st = 3;
    else if (!o->pk[s]) {
        st = 0;
        p = 0;
    }
    o->pk[s] = (uint8_t)kon;

    /* The envelope. */
    int ksr = (block << 1) | (fnum >> 9);
    if (!(r20 & 0x10)) ksr >>= 2;
    int r = st == 0 ? r60 >> 4 : st == 1 ? r60 & 15 :
            st == 2 ? ((r20 & 0x20) ? 0 : r80 & 15) : r80 & 15;
    int eff = r ? r * 4 + ksr : 0;
    if (eff > 63) eff = 63;
    int hi = eff >> 2, lo = eff & 3, step = 0;
    if (eff) {
        if (hi <= 12) {
            int sh = 12 - hi;
            if ((o->egc & ((1u << sh) - 1)) == 0)
                step = (pat[lo] >> ((o->egc >> sh) & 7)) & 1;
        } else
            step = (1 + ((pat[lo] >> (o->egc & 7)) & 1)) << (hi - 13);
    }
    if (st == 0) {
        if (eff >= 60)
            e = 0;
        else
            e += (-(e + 1) * step) >> 3;        /* rounds down */
        if (e <= 0) {
            e = 0;
            st = 1;
        }
    } else {
        e += step;
        if (e > 511) e = 511;
        int sl = r80 >> 4;
        if (sl == 15) sl = 31;
        if (st == 1 && (e >> 4) >= sl)
            st = 2;
    }

    /* The level. */
    int ksl = (kslrom[fnum >> 6] << 2) - ((8 - block) << 5);
    if (ksl < 0) ksl = 0;
    switch (r40 >> 6) {
    case 0: ksl = 0; break;
    case 1: ksl >>= 1; break;       /* 3 dB an octave */
    case 2: ksl >>= 2; break;       /* 1.5 */
    default: break;                 /* 6 */
    }
    int att = e + ((r40 & 63) << 2) + ksl + ((r20 & 0x80) ? am_val : 0);
    if (att > 511) att = 511;

    /* The wave. */
    int ph10 = (int)((p >> 10) + (uint32_t)mod) & 1023;
    int neg = ph10 >> 9, zero = 0;
    int idx = (ph10 & 255) ^ ((ph10 & 256) ? 255 : 0);
    switch ((o->reg[0x01] & 0x20) ? rE0 & 3 : 0) {
    case 1: zero = neg; break;
    case 2: neg = 0; break;
    case 3: zero = (ph10 >> 8) & 1; neg = 0; break;
    default: break;
    }
    int lv = o->rom[idx] + (att << 3);
    int sh = lv >> 8;
    int mag = sh > 12 ? 0 : (((o->rom[256 + (~lv & 255)] | 1024) << 1) >> sh);
    int out = zero ? 0 : neg ? -mag : mag;

    o->egs[s] = (uint8_t)st;
    o->env[s] = (uint16_t)e;
    o->ph[s] = (p + inc) & 0xFFFFF;
    return out;
}

int16_t opl2_sample(opl2 *o)
{
    int am_val = o->am_pos < 105 ? o->am_pos : 210 - o->am_pos;
    am_val >>= 2;
    if (!(o->reg[0xBD] & 0x80)) am_val >>= 2;
    int vib_pos = (o->egc >> 10) & 7;

    int mix = 0;
    for (int ch = 0; ch < 9; ch++) {
        uint8_t rC0 = o->reg[0xC0 + ch];
        int fb = (rC0 >> 1) & 7;
        int m = fb ? (o->fb1[ch] + o->fb2[ch]) >> (9 - fb) : 0;
        int a = op(o, ch * 2, m, am_val, vib_pos);
        o->fb2[ch] = o->fb1[ch];
        o->fb1[ch] = (int16_t)a;
        int b = op(o, ch * 2 + 1, (rC0 & 1) ? 0 : a, am_val, vib_pos);
        mix += (rC0 & 1) ? a + b : b;
    }
    mix *= 2;
    if (mix > 32767) mix = 32767;
    if (mix < -32768) mix = -32768;

    o->egc++;
    if (++o->am_div == 64) {
        o->am_div = 0;
        o->am_pos = (o->am_pos + 1) % 210;
    }
    return (int16_t)mix;
}
