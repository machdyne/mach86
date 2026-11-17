/*
 * Mach86 -- instruction vector runner.
 *
 * Runs a CPU against hardware-captured single-instruction tests in MOO
 * format (docs/verification.md, layer 1). The format is described in
 * the MOO specification, version 1.1. The CPU is a back end: the C
 * model (vectest_model.c) or the RTL core under Verilator
 * (vectest_rtl.cpp).
 *
 * usage: vectest [-d] [-H] [-n shown] [-r revocation_list] [-c metadata.csv]
 *                [-k known_deviations] file.MOO[.gz] ...
 *
 *   -d  dump the initial state of each failure shown
 *   -H  print the hash of every failing test (to build a -k list)
 *
 * For each test: load registers and memory, run until HLT, compare
 * registers and memory with the captured result. Bits the capture
 * marks as undefined are masked out.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include "vectest.h"

#define MEM_SIZE (1u << 24)     /* the captures have 24 address lines */
#define MEM_MASK (MEM_SIZE - 1)

static uint8_t *mem;
static uint8_t *written;        /* per address: written during this test */
static uint32_t touched[1 << 16];
static int n_touched;
static uint32_t wlist[1 << 12];
static int n_wlist;

static void touch(uint32_t a)
{
    if (n_touched < (int)(sizeof touched / sizeof touched[0]))
        touched[n_touched++] = a;
}

uint8_t vt_mem_read(uint32_t a)
{
    return mem[a & MEM_MASK];
}

void vt_mem_write(uint32_t a, uint8_t v)
{
    a &= MEM_MASK;
    mem[a] = v;
    touch(a);
    if (!written[a] && n_wlist < (int)(sizeof wlist / sizeof wlist[0])) {
        written[a] = 1;
        wlist[n_wlist++] = a;
    }
}

/* ---- MOO parsing ------------------------------------------------ */

static uint32_t u32(const uint8_t *p)
{
    return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24);
}

/* Find a chunk by tag inside [p, end). Returns payload, sets *len. */
static const uint8_t *find(const uint8_t *p, const uint8_t *end,
                           const char *tag, uint32_t *len)
{
    while (p + 8 <= end) {
        uint32_t n = u32(p + 4);
        if (!memcmp(p, tag, 4)) {
            *len = n;
            return p + 8;
        }
        p += 8 + n;
    }
    return NULL;
}

/* Decode an RG32 or RM32 payload. `have` gets the presence bitmask. */
static void regs32(const uint8_t *p, uint32_t v[RG_COUNT], uint32_t *have)
{
    uint32_t mask = u32(p);
    p += 4;
    *have = mask;
    for (int i = 0; i < RG_COUNT; i++)
        if (mask & (1u << i)) {
            v[i] = u32(p);
            p += 4;
        }
}

/* Registers whose model value is not meaningful to compare. */
#define IGNORE_REGS ((1u << RG_CR0) | (1u << RG_DR6) | (1u << RG_DR7))
#define EFLAGS_CMP  0x00037FD7u

/* ---- revocation list -------------------------------------------- */

static char (*revoked)[41];
static int n_revoked;

static void load_revoked(const char *path)
{
    FILE *f = fopen(path, "r");
    char line[256];
    if (!f)
        return;
    while (fgets(line, sizeof line, f)) {
        if (strlen(line) < 40)
            continue;
        revoked = realloc(revoked, (size_t)(n_revoked + 1) * sizeof *revoked);
        memcpy(revoked[n_revoked], line, 40);
        revoked[n_revoked][40] = 0;
        n_revoked++;
    }
    fclose(f);
}

static char (*known)[41];
static int n_known;
static int print_hashes;

static void load_known(const char *path)
{
    FILE *f = fopen(path, "r");
    char line[256];
    if (!f) {
        fprintf(stderr, "cannot read %s\n", path);
        exit(2);
    }
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '#' || strlen(line) < 40)
            continue;
        known = realloc(known, (size_t)(n_known + 1) * sizeof *known);
        memcpy(known[n_known], line, 40);
        known[n_known][40] = 0;
        n_known++;
    }
    fclose(f);
}

static int is_known(const uint8_t *hash)
{
    char hex[41];
    for (int i = 0; i < 20; i++)
        sprintf(hex + 2 * i, "%02x", hash[i]);
    for (int i = 0; i < n_known; i++)
        if (!strcasecmp(hex, known[i]))
            return 1;
    return 0;
}

static int is_revoked(const uint8_t *hash)
{
    char hex[41];
    for (int i = 0; i < 20; i++)
        sprintf(hex + 2 * i, "%02x", hash[i]);
    for (int i = 0; i < n_revoked; i++)
        if (!strcasecmp(hex, revoked[i]))
            return 1;
    return 0;
}

/* ---- undefined-flag masks from the suite's metadata -------------- */

/* The suite ships a CSV with, per opcode, a mask of the flags that are
 * defined. Keyed here as "OP" or "OP.N" for group opcodes. */
static struct { char key[16]; uint32_t mask; } *csv;
static int n_csv;

static void load_csv(const char *path)
{
    FILE *f = fopen(path, "r");
    char line[4096];
    if (!f) {
        fprintf(stderr, "cannot read %s\n", path);
        exit(2);
    }
    while (fgets(line, sizeof line, f)) {
        char *col[48];
        int n = 0;
        for (char *p = line; n < 48; ) {
            col[n++] = p;
            p = strchr(p, ',');
            if (!p)
                break;
            *p++ = 0;
        }
        if (n < 40 || !col[39][0] || strncmp(col[39], "0x", 2))
            continue;
        csv = realloc(csv, (size_t)(n_csv + 1) * sizeof *csv);
        if (col[4][0])
            snprintf(csv[n_csv].key, sizeof csv[n_csv].key, "%s.%s",
                     col[0], col[4]);
        else
            snprintf(csv[n_csv].key, sizeof csv[n_csv].key, "%s", col[0]);
        csv[n_csv].mask = 0xFFFF0000u | (uint32_t)strtoul(col[39], NULL, 16);
        n_csv++;
    }
    fclose(f);
}

/* File names are [67][66]OP[.N].MOO[.gz]. */
static uint32_t csv_mask(const char *path)
{
    char key[32];
    const char *b = strrchr(path, '/');
    b = b ? b + 1 : path;
    snprintf(key, sizeof key, "%s", b);
    char *dot = strstr(key, ".MOO");
    if (dot)
        *dot = 0;
    char *k = key;
    while ((!strncmp(k, "66", 2) || !strncmp(k, "67", 2)) && strlen(k) > 2
           && k[2] != '.')
        k += 2;
    for (int i = 0; i < n_csv; i++)
        if (!strcasecmp(csv[i].key, k))
            return csv[i].mask;
    return 0xFFFFFFFFu;
}

/* ---- one file ---------------------------------------------------- */

static uint8_t *slurp(const char *path, size_t *len)
{
    char cmd[1024];
    size_t n = strlen(path);
    int gz = n > 3 && !strcmp(path + n - 3, ".gz");
    FILE *f;
    if (gz) {
        snprintf(cmd, sizeof cmd, "gzip -dc '%s'", path);
        f = popen(cmd, "r");
    } else {
        f = fopen(path, "rb");
    }
    if (!f)
        return NULL;
    size_t cap = 1 << 22, used = 0;
    uint8_t *buf = malloc(cap);
    for (;;) {
        size_t got = fread(buf + used, 1, cap - used, f);
        used += got;
        if (got == 0)
            break;
        if (used == cap)
            buf = realloc(buf, cap *= 2);
    }
    if (gz)
        pclose(f);
    else
        fclose(f);
    *len = used;
    return buf;
}

static int show_max = 3;
static int dump_state;
static long total_pass, total_fail, total_skip, total_known, total_fixed;

static void run_file(const char *path)
{
    size_t len;
    uint8_t *buf = slurp(path, &len);
    if (!buf || len < 8 || memcmp(buf, "MOO ", 4)) {
        fprintf(stderr, "%s: not a MOO file\n", path);
        total_fail++;
        free(buf);
        return;
    }
    const uint8_t *end = buf + len, *p = buf;
    uint32_t file_mask[RG_COUNT], file_mask_have = 0;
    uint32_t meta_mask = csv_mask(path);
    long pass = 0, fail = 0, skip = 0, kn = 0;
    int shown = 0;

    while (p + 8 <= end) {
        uint32_t n = u32(p + 4);
        const uint8_t *body = p + 8, *bend = body + n;
        if (!memcmp(p, "RM32", 4)) {
            regs32(body, file_mask, &file_mask_have);
        } else if (!memcmp(p, "TEST", 4)) {
            const uint8_t *sub = body + 4;
            uint32_t l, l2;
            const uint8_t *name = find(sub, bend, "NAME", &l);
            const uint8_t *byts = find(sub, bend, "BYTS", &l);
            const uint8_t *init = find(sub, bend, "INIT", &l);
            const uint8_t *iend = init ? init + l : NULL;
            const uint8_t *fina = find(sub, bend, "FINA", &l);
            const uint8_t *fend = fina ? fina + l : NULL;
            const uint8_t *excp = find(sub, bend, "EXCP", &l);
            const uint8_t *hash = find(sub, bend, "HASH", &l);
            if (!init || !fina) {
                skip++;
                goto next;
            }
            if (hash && is_revoked(hash)) {
                skip++;
                goto next;
            }

            uint32_t ir[RG_COUNT] = { 0 }, fr[RG_COUNT], tm[RG_COUNT];
            uint32_t have, fhave = 0, tm_have = 0;
            const uint8_t *q;

            q = find(init, iend, "RG32", &l2);
            if (!q) {
                skip++;
                goto next;
            }
            regs32(q, ir, &have);
            memcpy(fr, ir, sizeof fr);
            q = find(fina, fend, "RG32", &l2);
            if (q)
                regs32(q, fr, &fhave);
            q = find(fina, fend, "RM32", &l2);
            if (q)
                regs32(q, tm, &tm_have);

            /* Initial memory. */
            const uint8_t *iram = find(init, iend, "RAM ", &l2);
            uint32_t iram_n = iram ? u32(iram) : 0;
            for (uint32_t i = 0; i < iram_n; i++) {
                uint32_t a = u32(iram + 4 + 5 * i) & MEM_MASK;
                mem[a] = iram[4 + 5 * i + 4];
                touch(a);
            }

            backend_set(ir);
            n_wlist = 0;
            int stop = backend_run();

            /* Compare. */
            char why[1024];
            int w = 0;
            why[0] = 0;
            uint32_t mr[RG_COUNT];
            backend_get(mr);
            if (stop)
                w += snprintf(why + w, sizeof why - (size_t)w,
                              " [did not reach HLT%s]",
                              stop == 2 ? ": shutdown" :
                              stop == 3 ? ": unsupported" : "");
            for (int i = 0; i < RG_COUNT; i++) {
                uint32_t m = 0xFFFFFFFFu;
                if (IGNORE_REGS & (1u << i))
                    continue;
                if (i == RG_EFLAGS)
                    m = EFLAGS_CMP & meta_mask;
                if (i >= RG_CS && i <= RG_SS)
                    m = 0xFFFF;
                if (file_mask_have & (1u << i))
                    m &= file_mask[i];
                if (tm_have & (1u << i))
                    m &= tm[i];
                if ((mr[i] & m) != (fr[i] & m) && w < 900)
                    w += snprintf(why + w, sizeof why - (size_t)w,
                                  " %s=%08x want %08x", rg_name[i],
                                  mr[i] & m, fr[i] & m);
            }

            /* Final memory. A flags image pushed by an exception may
             * hold undefined flags; mask those the same way. */
            uint32_t fl_addr = 0xFFFFFFFFu, fl_mask = 0xFFFF;
            if (excp) {
                fl_addr = u32(excp + 1) & MEM_MASK;
                fl_mask = EFLAGS_CMP & meta_mask;
                if (file_mask_have & (1u << RG_EFLAGS))
                    fl_mask &= file_mask[RG_EFLAGS];
                if (tm_have & (1u << RG_EFLAGS))
                    fl_mask &= tm[RG_EFLAGS];
            }
            const uint8_t *fram = find(fina, fend, "RAM ", &l2);
            uint32_t fram_n = fram ? u32(fram) : 0;
            for (uint32_t i = 0; i < fram_n; i++) {
                uint32_t a = u32(fram + 4 + 5 * i) & MEM_MASK;
                uint8_t want = fram[4 + 5 * i + 4], m = 0xFF;
                if (a == fl_addr)
                    m = (uint8_t)fl_mask;
                else if (a == ((fl_addr + 1) & MEM_MASK))
                    m = (uint8_t)(fl_mask >> 8);
                written[a] = 2;         /* accounted for */
                if ((mem[a] & m) != (want & m) && w < 900)
                    w += snprintf(why + w, sizeof why - (size_t)w,
                                  " mem[%06x]=%02x want %02x", a, mem[a], want);
            }
            /* Writes the capture does not list must leave the byte as
             * it started. */
            for (int i = 0; i < n_wlist; i++) {
                uint32_t a = wlist[i];
                if (written[a] == 1) {
                    int found = 0;
                    uint8_t orig = 0;
                    for (uint32_t k = 0; k < iram_n; k++)
                        if ((u32(iram + 4 + 5 * k) & MEM_MASK) == a) {
                            orig = iram[4 + 5 * k + 4];
                            found = 1;
                        }
                    uint8_t m = 0xFF;
                    if (a == fl_addr)
                        m = (uint8_t)fl_mask;
                    else if (a == ((fl_addr + 1) & MEM_MASK))
                        m = (uint8_t)(fl_mask >> 8);
                    if ((!found || (mem[a] & m) != (orig & m)) && w < 900)
                        w += snprintf(why + w, sizeof why - (size_t)w,
                                      " stray write mem[%06x]=%02x", a, mem[a]);
                }
                written[a] = 0;
            }
            for (uint32_t i = 0; i < fram_n; i++)
                written[u32(fram + 4 + 5 * i) & MEM_MASK] = 0;

            int expected_fail = hash && is_known(hash);
            if (w == 0) {
                pass++;
                if (expected_fail) {
                    total_fixed++;
                    printf("  NOTE #%u is listed as a known deviation but "
                           "passes\n", u32(body));
                }
            } else if (expected_fail) {
                kn++;
            } else {
                fail++;
                if (print_hashes && hash) {
                    for (int k = 0; k < 20; k++)
                        printf("%02x", hash[k]);
                    printf("  %s #%u %.*s\n", strrchr(path, '/')
                           ? strrchr(path, '/') + 1 : path, u32(body),
                           name ? (int)u32(name) : 0,
                           name ? (const char *)name + 4 : "");
                }
                if (shown < show_max) {
                    shown++;
                    printf("  FAIL #%u %.*s  [", u32(body),
                           name ? (int)u32(name) : 0,
                           name ? (const char *)name + 4 : "");
                    if (byts)
                        for (uint32_t i = 0; i < u32(byts); i++)
                            printf("%s%02x", i ? " " : "", byts[4 + i]);
                    printf("]%s%s\n", excp ? " (exception expected)" : "", why);
                    if (excp)
                        printf("       expected exception %u, model took %d\n",
                               excp[0], backend_last_exception());
                    if (dump_state) {
                        printf("       initial:");
                        for (int k = 0; k < RG_COUNT; k++)
                            if (!(IGNORE_REGS & (1u << k)) && k != RG_CR3)
                                printf(" %s=%x", rg_name[k], ir[k]);
                        printf("\n       memory:");
                        for (uint32_t k = 0; k < iram_n; k++)
                            printf(" %06x:%02x", u32(iram + 4 + 5 * k),
                                   iram[4 + 5 * k + 4]);
                        printf("\n       final memory:");
                        for (uint32_t k = 0; k < fram_n; k++)
                            printf(" %06x:%02x", u32(fram + 4 + 5 * k),
                                   fram[4 + 5 * k + 4]);
                        printf("\n");
                    }
                }
            }
            (void)fhave;

            /* Clean memory for the next test. */
            for (int i = 0; i < n_touched; i++)
                mem[touched[i]] = 0;
            n_touched = 0;
        }
next:
        p = bend;
    }

    const char *base = strrchr(path, '/');
    printf("%-22s %6ld pass %6ld fail", base ? base + 1 : path, pass, fail);
    if (kn)
        printf(" %4ld known", kn);
    if (skip)
        printf(" %4ld skipped", skip);
    printf("\n");
    total_known += kn;
    total_pass += pass;
    total_fail += fail;
    total_skip += skip;
    free(buf);
}

int main(int argc, char **argv)
{
    int i = 1;
    while (i < argc && argv[i][0] == '-' && i + 1 < argc) {
        if (!strcmp(argv[i], "-d") || !strcmp(argv[i], "-H")) {
            if (argv[i][1] == 'd')
                dump_state = 1;
            else
                print_hashes = 1;
            i++;
            continue;
        }
        if (!strcmp(argv[i], "-n"))
            show_max = atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "-r"))
            load_revoked(argv[i + 1]);
        else if (!strcmp(argv[i], "-c"))
            load_csv(argv[i + 1]);
        else if (!strcmp(argv[i], "-k"))
            load_known(argv[i + 1]);
        else
            break;
        i += 2;
    }
    if (i >= argc) {
        fprintf(stderr, "usage: vectest [-d] [-H] [-n shown] [-r revocation_list] "
                        "[-c metadata.csv] [-k known_deviations] "
                        "file.MOO[.gz] ...\n");
        return 2;
    }
    mem = calloc(MEM_SIZE, 1);
    written = calloc(MEM_SIZE, 1);
    backend_init();

    for (; i < argc; i++)
        run_file(argv[i]);

    printf("total: %ld pass, %ld fail, %ld known deviations, %ld skipped\n",
           total_pass, total_fail, total_known, total_skip);
    return (total_fail || total_fixed) ? 1 : 0;
}
