/*
 * Mach86 reference model -- the whole machine: CPU, PC hardware, BIOS
 * image and an SD card image.
 *
 * usage: m86pc -bios bios.bin [-disk image] [options] [script...]
 *
 *   -disk image     the SD card; a floppy-sized image boots as drive A:
 *   -max N          stop after N instructions in total (default 2e9)
 *   -mem KB         conventional memory (default 640)
 *   -card MB        the SD card's size, if larger than the image: the
 *                   rest reads as zeros
 *   -screen         print the final screen
 *   -debug          send the debug console (port E0h) to stderr
 *   -profile        print the instruction-class profile at the end
 *   -where          print the CPU state at the end
 *   -i              interactive: the screen in this terminal, keys from
 *                   it; Ctrl-] quits
 *
 * A script is a sequence of steps, run in order:
 *
 *   -expect TEXT    run until TEXT appears on a screen row that has
 *                   changed since the previous step
 *   -type TEXT      type TEXT (\r is Enter)
 *   -run N          run N instructions
 *   -snap FILE      write the picture on the display to FILE (PPM)
 *   -dexpect TEXT   run until TEXT appears on the debug console
 * With -font FILE (the character ROM, as tools/mkfont.py writes it)
 * before the script, -snap draws text modes too.
 *
 * Exit status 0 if every -expect was met.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <termios.h>
#include <sys/select.h>
#include <sys/time.h>
#include "pc.h"

static pc machine;
static uint8_t font[4096];
static int font_loaded;

/* Built with LOCKSTEP, every step is also run on the RTL core and the
 * two are compared (lockstep.cpp). */
#ifdef LOCKSTEP
void lockstep_attach(pc *a, const char *bios, const char *disk);
void lockstep_run(pc *a, uint64_t n);
void lockstep_key(int ch);
void lockstep_report(void);
#define RUN(n)  lockstep_run(&machine, (n))
#define KEY(ch) do { pc_key_ascii(&machine, (ch)); lockstep_key(ch); } while (0)
#else
#define RUN(n)  pc_run(&machine, (n))
#define KEY(ch) pc_key_ascii(&machine, (ch))
#endif
static uint64_t budget = 2000000000ull;
static uint64_t used;

static void screen_rows(const pc *p, char rows[PC_ROWS][PC_COLS + 1])
{
    for (int r = 0; r < PC_ROWS; r++) {
        for (int c = 0; c < PC_COLS; c++) {
            uint8_t ch = pc_screen_char(p, r, c);
            rows[r][c] = (ch >= 32 && ch < 127) ? (char)ch : ' ';
        }
        rows[r][PC_COLS] = 0;
    }
}

static void print_screen(const pc *p, FILE *out)
{
    char rows[PC_ROWS][PC_COLS + 1];
    screen_rows(p, rows);
    int last = PC_ROWS - 1;
    while (last > 0 && strspn(rows[last], " ") == PC_COLS)
        last--;
    for (int r = 0; r <= last; r++) {
        int n = PC_COLS;
        while (n > 0 && rows[r][n - 1] == ' ')
            n--;
        fprintf(out, "%.*s\n", n, rows[r]);
    }
}

static void run(uint64_t n)
{
    if (n > budget - used)
        n = budget - used;
    RUN(n);
    used += n;
}

/* Type text a key at a time, letting the guest take each one. */
static void type_text(const char *s)
{
    for (; *s; s++) {
        int ch = *s;
        if (ch == '\\' && s[1] == 'r') {
            ch = '\r';
            s++;
        } else if (ch == '\\' && s[1] == 'n') {
            ch = '\r';
            s++;
        }
        KEY(ch);
        for (int i = 0; i < 200 && pc_keys_pending(&machine)
                        && used < budget; i++)
            run(20000);
        run(100000);
    }
}

static int expect_text(const char *text)
{
    static char before[PC_ROWS][PC_COLS + 1];
    static int have_before;
    char now[PC_ROWS][PC_COLS + 1];

    for (;;) {
        screen_rows(&machine, now);
        for (int r = 0; r < PC_ROWS; r++)
            if ((!have_before || strcmp(now[r], before[r]))
                && strstr(now[r], text)) {
                memcpy(before, now, sizeof before);
                have_before = 1;
                return 1;
            }
        if (used >= budget || pc_stopped(&machine)
            || (machine.cpu.halted && !(machine.cpu.s.eflags & M86_IF)
                && !pc_keys_pending(&machine)))
            return 0;
        run(200000);
    }
}

/* ---- interactive ------------------------------------------------- */

static struct termios saved_tty;

static void restore_tty(void)
{
    tcsetattr(0, TCSANOW, &saved_tty);
    printf("\033[0m\033[?25h\n");
}

static void interactive(void)
{
    struct termios raw;
    tcgetattr(0, &saved_tty);
    atexit(restore_tty);
    raw = saved_tty;
    cfmakeraw(&raw);
    tcsetattr(0, TCSANOW, &raw);
    printf("\033[2J");

    char shown[PC_ROWS][PC_COLS + 1];
    memset(shown, 0, sizeof shown);
    for (;;) {
        fd_set fds;
        struct timeval tv = { 0, 0 };
        FD_ZERO(&fds);
        FD_SET(0, &fds);
        if (select(1, &fds, NULL, NULL, &tv) > 0) {
            unsigned char ch;
            if (read(0, &ch, 1) != 1 || ch == 0x1D)
                return;
            KEY(ch == 0x7F ? '\b' : ch);
        }
        RUN(300000);
        if (pc_stopped(&machine))
            return;

        char now[PC_ROWS][PC_COLS + 1];
        screen_rows(&machine, now);
        for (int r = 0; r < PC_ROWS; r++)
            if (strcmp(now[r], shown[r])) {
                printf("\033[%d;1H%s", r + 1, now[r]);
                memcpy(shown[r], now[r], sizeof shown[r]);
            }
        int row, col;
        pc_cursor(&machine, &row, &col);
        printf("\033[%d;%dH", row + 1, col + 1);
        fflush(stdout);
        if (machine.cpu.halted)
            usleep(2000);
    }
}

int main(int argc, char **argv)
{
    uint32_t card_mb = 0;
    const char *bios = NULL, *disk = NULL;
    int show_screen = 0, profile = 0, inter = 0, where = 0, ok = 1, i;

    pc_init(&machine);
    for (i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *v = i + 1 < argc ? argv[i + 1] : NULL;
        if (!strcmp(a, "-bios") && v) { bios = v; i++; }
        else if (!strcmp(a, "-disk") && v) { disk = v; i++; }
        else if (!strcmp(a, "-max") && v) { budget = strtoull(v, NULL, 0); i++; }
        else if (!strcmp(a, "-mem") && v) {     /* conventional memory, KB */
            machine.conv_size = (uint32_t)strtoul(v, NULL, 0) << 10;
            i++;
        }
        else if (!strcmp(a, "-card") && v) {    /* the card's size, MB */
            card_mb = (uint32_t)strtoul(v, NULL, 0);
            i++;
        }
        else if (!strcmp(a, "-screen")) show_screen = 1;
        else if (!strcmp(a, "-font") && i + 1 < argc) {
            FILE *f = fopen(argv[++i], "r");
            unsigned x;
            int n = 0;
            while (f && n < 4096 && fscanf(f, "%x", &x) == 1)
                font[n++] = (uint8_t)x;
            if (f) fclose(f);
            font_loaded = (n == 4096);
        }
        else if (!strcmp(a, "-fpu")) {          /* a 486DX: with the floating-point unit */
            machine.cpu.has_fpu = 1;
            m86_reset(&machine.cpu);
        }
        else if (!strcmp(a, "-debug")) machine.debug_out = stderr;
        else if (!strcmp(a, "-profile")) profile = 1;
        else if (!strcmp(a, "-where")) where = 1;
        else if (!strcmp(a, "-i")) inter = 1;
        else break;
    }
    if (!bios) {
        fprintf(stderr, "usage: m86pc -bios bios.bin [-disk image] [-max N] "
                        "[-screen] [-debug] [-profile] [-i]\n"
                        "             [-expect TEXT | -type TEXT | -run N]...\n");
        return 2;
    }
    if (pc_load_bios(&machine, bios)) {
        fprintf(stderr, "m86pc: cannot load BIOS %s\n", bios);
        return 2;
    }
    if (disk && pc_attach_disk(&machine, disk)) {
        fprintf(stderr, "m86pc: cannot open disk image %s\n", disk);
        return 2;
    }
    if (card_mb)                        /* a card larger than its image */
        machine.sd.sectors = card_mb * 2048u;

#ifdef LOCKSTEP
    lockstep_attach(&machine, bios, disk);
#endif

    if (inter) {
        interactive();
        return 0;
    }

    int scripted = i < argc;
    for (; i < argc && ok; i++) {
        const char *a = argv[i];
        const char *v = i + 1 < argc ? argv[i + 1] : NULL;
        if (!v) {
            fprintf(stderr, "m86pc: %s needs an argument\n", a);
            return 2;
        }
        if (!strcmp(a, "-snap")) {
            static uint8_t rgb[640 * 480 * 3];
            FILE *f = fopen(v, "wb");
            if (!f) {
                fprintf(stderr, "m86pc: cannot write %s\n", v);
                return 2;
            }
            vga_render(&machine.vga, rgb, font_loaded ? font : NULL);
            fprintf(f, "P6\n640 480\n255\n");
            fwrite(rgb, 1, sizeof rgb, f);
            fclose(f);
            i++;
            continue;
        }
        if (!strcmp(a, "-dexpect")) {
            /* Text on the debug console (what the BIOS's teletype call
             * writes, in any video mode) since the last such step. */
            static uint32_t from;
            size_t n = strlen(v);
            int found = 0;
            for (;;) {
                while (from + n <= machine.dbg_count) {
                    size_t k = 0;
                    while (k < n && machine.dbg_log[(from + k) & 0xFFFF] == v[k])
                        k++;
                    if (k == n) { found = 1; from += (uint32_t)n; break; }
                    from++;
                }
                if (found || used >= budget || pc_stopped(&machine))
                    break;
                run(200000);
            }
            if (!found) {
                fprintf(stderr, "m86pc: did not see \"%s\" on the debug console\n", v);
                ok = 0;
            }
            i++;
            continue;
        }
        if (!strcmp(a, "-expect")) {
            if (!expect_text(v)) {
                fprintf(stderr, "m86pc: did not see \"%s\" "
                                "(%llu instructions run)\n", v,
                        (unsigned long long)used);
                ok = 0;
            }
        } else if (!strcmp(a, "-mouse")) {
            /* a mouse report: DX,DY,BUTTONS */
            int dx = 0, dy = 0, b = 0;
            sscanf(v, "%d,%d,%d", &dx, &dy, &b);
            pc_mouse(&machine, dx, dy, b);
        } else if (!strcmp(a, "-type")) {
            type_text(v);
        } else if (!strcmp(a, "-run")) {
            run(strtoull(v, NULL, 0));
        } else {
            fprintf(stderr, "m86pc: unknown step %s\n", a);
            return 2;
        }
        i++;
    }
    if (!scripted)
        run(budget);

    if (machine.cpu.shutdown)
        fprintf(stderr, "m86pc: CPU shutdown at %04x:%08x\n",
                machine.cpu.s.seg[M86_CS].sel, machine.cpu.s.eip);
    if (machine.cpu.unsupported)
        fprintf(stderr, "m86pc: protected mode requested at %04x:%08x; "
                        "the model does not have it yet\n",
                machine.cpu.s.seg[M86_CS].sel, machine.cpu.s.eip);
    if (show_screen || !ok)
        print_screen(&machine, ok ? stdout : stderr);
    if (show_screen) {
        unsigned at = machine.vga.crtc[14] << 8 | machine.vga.crtc[15];
        fprintf(stderr, "cursor: row %u, column %u\n", at / 80, at % 80);
    }
    if (where) {
        const m86 *c = &machine.cpu;
        fprintf(stderr, "cpu: %04x:%04x%s flags=%04x ax=%04x bx=%04x cx=%04x "
                        "dx=%04x si=%04x di=%04x bp=%04x ss:sp=%04x:%04x "
                        "ds=%04x es=%04x\n",
                c->s.seg[M86_CS].sel, c->s.eip, c->halted ? " (halted)" : "",
                c->s.eflags & 0xFFFF, c->s.r[0] & 0xFFFF, c->s.r[3] & 0xFFFF,
                c->s.r[1] & 0xFFFF, c->s.r[2] & 0xFFFF, c->s.r[6] & 0xFFFF,
                c->s.r[7] & 0xFFFF, c->s.r[5] & 0xFFFF, c->s.seg[M86_SS].sel,
                c->s.r[4] & 0xFFFF, c->s.seg[M86_DS].sel,
                c->s.seg[M86_ES].sel);
        fprintf(stderr, "code:");
        uint32_t a = c->s.seg[M86_CS].base + c->s.eip;
        for (int k = -8; k < 16; k++)
            fprintf(stderr, "%s%02x", k == 0 ? " | " : " ",
                    machine.ram[(a + (uint32_t)k) & (PC_RAM_SIZE - 1)]);
        fprintf(stderr, "\nlast exception: %d, instructions: %llu\n",
                c->last_exception, (unsigned long long)c->icount);
    }

    if (profile) {
        const m86 *c = &machine.cpu;
        double cycles = 0;
        fprintf(stderr, "\n%-34s %12s %7s\n", "class", "count", "share");
        for (int k = 0; k < M86_CL_COUNT; k++) {
            cycles += (double)c->class_count[k] * m86_class_cycles[k];
            fprintf(stderr, "%-34s %12llu %6.1f%%\n", m86_class_name[k],
                    (unsigned long long)c->class_count[k],
                    c->icount ? 100.0 * (double)c->class_count[k]
                                / (double)c->icount : 0.0);
        }
        fprintf(stderr, "%-34s %12llu\n", "instructions",
                (unsigned long long)c->icount);
        if (c->icount)
            fprintf(stderr, "base cycles per instruction: %.2f\n",
                    cycles / (double)c->icount);

        /* Which instructions make up the slow path. */
        fprintf(stderr, "\nslow path, most frequent opcodes:\n");
        uint64_t slow[512];
        memcpy(slow, c->slow_count, sizeof slow);
        for (int n = 0; n < 10; n++) {
            int best = 0;
            for (int k = 1; k < 512; k++)
                if (slow[k] > slow[best])
                    best = k;
            if (!slow[best])
                break;
            fprintf(stderr, "  %s%02X %12llu %5.1f%% of all\n",
                    best >= 256 ? "0F " : "", best & 0xFF,
                    (unsigned long long)slow[best],
                    100.0 * (double)slow[best] / (double)c->icount);
            slow[best] = 0;
        }
    }
#ifdef LOCKSTEP
    lockstep_report();
#endif
    return ok ? 0 : 1;
}
