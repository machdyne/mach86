/*
 * Mach86 reference model -- run a ROM image on the bare CPU model.
 *
 * usage: m86run [-p] [-m max_instructions] image.bin
 *
 * The image is placed so that it ends at the top of the first megabyte,
 * as a BIOS is, and the CPU starts at the reset vector. There is no PC
 * hardware here yet: only RAM and the debug console, a byte written to
 * port E0h (docs/hwmap.md). The run ends at HLT with interrupts off.
 *
 *   -p  print the instruction-class profile and the cycles-per-
 *       instruction estimate (docs/model.md)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "m86.h"

#define MEM_SIZE   (1u << 24)
#define PORT_DEBUG 0xE0

static uint8_t *mem;
static uint32_t rom_base;       /* writes at or above this are ignored */

static uint8_t bus_read(void *bus, uint32_t a)
{
    (void)bus;
    return a < MEM_SIZE ? mem[a] : 0xFF;
}

static void bus_write(void *bus, uint32_t a, uint8_t v)
{
    (void)bus;
    if (a < MEM_SIZE && !(a >= rom_base && a < 0x100000))
        mem[a] = v;
}

static uint32_t bus_in(void *bus, uint16_t port, int size)
{
    (void)bus; (void)port;
    return size == 1 ? 0xFF : size == 2 ? 0xFFFF : 0xFFFFFFFF;
}

static void bus_out(void *bus, uint16_t port, int size, uint32_t v)
{
    (void)bus; (void)size;
    if (port == PORT_DEBUG)
        putchar((int)(v & 0xFF));
}

int main(int argc, char **argv)
{
    int profile = 0, i = 1;
    uint64_t max = 100000000ull;
    for (; i < argc && argv[i][0] == '-'; i++) {
        if (!strcmp(argv[i], "-p"))
            profile = 1;
        else if (!strcmp(argv[i], "-m") && i + 1 < argc)
            max = strtoull(argv[++i], NULL, 0);
        else
            break;
    }
    if (i + 1 != argc) {
        fprintf(stderr, "usage: m86run [-p] [-m max_instructions] image.bin\n");
        return 2;
    }

    FILE *f = fopen(argv[i], "rb");
    if (!f) {
        perror(argv[i]);
        return 2;
    }
    mem = calloc(MEM_SIZE, 1);
    static uint8_t image[0x100000];
    size_t n = fread(image, 1, sizeof image, f);
    fclose(f);
    if (n == 0 || n > 0x100000) {
        fprintf(stderr, "%s: image must be 1 byte to 1 MB\n", argv[i]);
        return 2;
    }
    rom_base = 0x100000 - (uint32_t)n;
    memcpy(mem + rom_base, image, n);

    m86 c;
    m86_init(&c);
    c.mem_read = bus_read;
    c.mem_write = bus_write;
    c.io_read = bus_in;
    c.io_write = bus_out;

    while (c.icount < max && !c.shutdown && !c.unsupported
           && !(c.halted && !(c.s.eflags & M86_IF)))
        m86_step(&c);
    fflush(stdout);

    int rc = 0;
    if (c.shutdown) {
        fprintf(stderr, "m86run: CPU shutdown at %04x:%08x\n",
                c.s.seg[M86_CS].sel, c.s.eip);
        rc = 1;
    } else if (c.unsupported) {
        fprintf(stderr, "m86run: protected mode requested at %04x:%08x; "
                        "the model does not have it yet\n",
                c.s.seg[M86_CS].sel, c.s.eip);
        rc = 1;
    } else if (!c.halted) {
        fprintf(stderr, "m86run: stopped after %llu instructions without "
                        "reaching HLT\n", (unsigned long long)c.icount);
        rc = 1;
    }

    if (profile) {
        double cycles = 0;
        fprintf(stderr, "\n%-34s %12s %7s %7s\n", "class", "count", "share",
                "cycles");
        for (int k = 0; k < M86_CL_COUNT; k++) {
            double share = c.icount ? 100.0 * (double)c.class_count[k]
                                      / (double)c.icount : 0;
            cycles += (double)c.class_count[k] * m86_class_cycles[k];
            fprintf(stderr, "%-34s %12llu %6.1f%% %7.0f\n", m86_class_name[k],
                    (unsigned long long)c.class_count[k], share,
                    m86_class_cycles[k]);
        }
        fprintf(stderr, "%-34s %12llu\n", "instructions",
                (unsigned long long)c.icount);
        if (c.icount)
            fprintf(stderr, "base cycles per instruction: %.2f "
                            "(before cache misses and stalls)\n",
                    cycles / (double)c.icount);
    }
    return rc;
}
