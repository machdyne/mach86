/*
 * Mach86 -- reference model of the FM synthesiser (AdLib, YM3812).
 * rtl/soc/m86_opl2.v computes the same numbers, sample for sample;
 * docs/sound.md says what it is and is not.
 */
#ifndef OPL2_H
#define OPL2_H
#include <stdint.h>

typedef struct {
    uint8_t  reg[256];
    uint16_t rom[512];
    uint32_t ph[18];        /* phase, 20 bits */
    uint16_t env[18];       /* attenuation, 0 loud .. 511 silent */
    uint8_t  egs[18];       /* 0 attack, 1 decay, 2 sustain, 3 release */
    uint8_t  pk[18];        /* the key as it was */
    int16_t  fb1[9], fb2[9];
    uint32_t egc;           /* samples */
    uint8_t  am_div, am_pos;
} opl2;

int     opl2_init(opl2 *o, const char *romfile);
void    opl2_write(opl2 *o, uint8_t reg, uint8_t val);
int16_t opl2_sample(opl2 *o);

#endif
