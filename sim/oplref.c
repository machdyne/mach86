/*
 * Mach86 -- runs the FM synthesiser's reference model over a script
 * of register writes and writes the samples: as hex for the RTL's
 * bench to compare with, as a WAV to listen to, or both.
 *
 * usage: oplref ROM.hex SCRIPT [-hex OUT] [-wav OUT] [-freq A B]
 *
 * SCRIPT: lines "N REG VAL" (hex): write VAL to REG, then make N
 * samples. -freq A B prints the frequency of samples A..B by their
 * upward zero crossings.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "opl2.h"

int main(int argc, char **argv)
{
    static opl2 o;
    static int16_t buf[1 << 22];
    int n = 0;
    if (argc < 3 || opl2_init(&o, argv[1])) {
        fprintf(stderr, "usage: oplref ROM.hex SCRIPT [-hex OUT] [-wav OUT] [-freq A B]\n");
        return 2;
    }
    FILE *f = fopen(argv[2], "r");
    if (!f) { perror(argv[2]); return 2; }
    unsigned cnt, reg, val;
    char line[128];
    while (fgets(line, sizeof line, f)) {
        if (sscanf(line, "%x %x %x", &cnt, &reg, &val) != 3)
            continue;
        opl2_write(&o, (uint8_t)reg, (uint8_t)val);
        for (unsigned i = 0; i < cnt && n < (1 << 22); i++)
            buf[n++] = opl2_sample(&o);
    }
    fclose(f);
    for (int i = 3; i < argc; i++) {
        if (!strcmp(argv[i], "-hex") && i + 1 < argc) {
            FILE *g = fopen(argv[++i], "w");
            for (int k = 0; k < n; k++)
                fprintf(g, "%04x\n", (uint16_t)buf[k]);
            fclose(g);
        } else if (!strcmp(argv[i], "-wav") && i + 1 < argc) {
            FILE *g = fopen(argv[++i], "wb");
            uint32_t bytes = (uint32_t)n * 2, v;
            fwrite("RIFF", 1, 4, g); v = 36 + bytes; fwrite(&v, 4, 1, g);
            fwrite("WAVEfmt ", 1, 8, g); v = 16; fwrite(&v, 4, 1, g);
            uint16_t h[2] = {1, 1}; fwrite(h, 2, 2, g);
            v = 48000; fwrite(&v, 4, 1, g); v = 96000; fwrite(&v, 4, 1, g);
            uint16_t h2[2] = {2, 16}; fwrite(h2, 2, 2, g);
            fwrite("data", 1, 4, g); fwrite(&bytes, 4, 1, g);
            fwrite(buf, 2, (size_t)n, g);
            fclose(g);
        } else if (!strcmp(argv[i], "-freq") && i + 2 < argc) {
            int a = atoi(argv[i + 1]), b = atoi(argv[i + 2]), z = 0, peak = 0;
            i += 2;
            for (int k = a + 1; k <= b && k < n; k++) {
                if (buf[k - 1] < 0 && buf[k] >= 0) z++;
                if (abs(buf[k]) > peak) peak = abs(buf[k]);
            }
            printf("freq %d peak %d\n", (int)((long long)z * 48000 / (b - a)), peak);
        }
    }
    printf("samples %d\n", n);
    return 0;
}
