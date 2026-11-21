/*
 * fparith_tb.cpp: the FPU's arithmetic in RTL (rtl/cpu/m86_fparith.v)
 * against the model's (m86fpu.c): the same operands to both, and the
 * results and flags must be the same bits. See docs/fpu.md.
 *
 * usage: fparith_tb [count]    operations of each kind (200000 if not given)
 */
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include "Vm86_fparith.h"
extern "C" {
#include "m86fpu.h"
}

static uint64_t rs = 0x9E3779B97F4A7C15ull;
static uint64_t rnd(void)
{
    rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17;
    return rs;
}

/* (The same choice of operands as fputest.c.) */
static m86f80 operand(void)
{
    static const m86f80 fixed[] = {
        { 0, 0x0000 }, { 0, 0x8000 },
        { 0x8000000000000000ull, 0x7FFF }, { 0x8000000000000000ull, 0xFFFF },
        { 0xC000000000000000ull, 0x7FFF }, { 0xC000000000000001ull, 0xFFFF },
        { 0xA000000000000000ull, 0x7FFF }, { 0x8000000000000001ull, 0xFFFF },
        { 0xFFFFFFFFFFFFFFFFull, 0x7FFF }, { 0xBFFFFFFFFFFFFFFFull, 0x7FFF },
        { 0x8000000000000000ull, 0x3FFF }, { 0x8000000000000000ull, 0xBFFF },
        { 0x0000000000000001ull, 0x0000 }, { 0x7FFFFFFFFFFFFFFFull, 0x8000 },
        { 0x8000000000000000ull, 0x0000 }, { 0xFFFFFFFFFFFFFFFFull, 0x0000 },
        { 0x8000000000000000ull, 0x0001 }, { 0xFFFFFFFFFFFFFFFFull, 0x7FFE },
        { 0x4000000000000000ull, 0x3FFF }, { 0x0000000000000000ull, 0x4000 },
        { 0x0000000000000000ull, 0x7FFF }, { 0x7000000000000000ull, 0xFFFF },
    };
    uint64_t r = rnd();
    m86f80 v;
    if ((r & 15) == 0)
        return fixed[(r >> 8) % (sizeof fixed / sizeof fixed[0])];
    v.m = rnd();
    switch ((r >> 4) & 7) {
    case 0: v.m &= 0xFFFFFF0000000000ull; break;
    case 1: v.m &= 0xFFFFFFFFFFFFF800ull; break;
    case 2: v.m |= 0x7FFFFFFFFFFFFF00ull; break;
    case 3: v.m &= 0xFF00000000000003ull; break;
    case 4: v.m = (v.m & 0xFFFFFF0000000000ull) | ((uint64_t)1 << (rnd() % 40)); break;
    default: break;
    }
    v.m |= 0x8000000000000000ull;
    unsigned e;
    switch ((r >> 8) & 7) {
    case 0: e = 1 + (unsigned)(rnd() % 80); break;
    case 1: e = 0x7FFE - (unsigned)(rnd() % 80); break;
    case 2: e = 0x3FFF - 1100 + (unsigned)(rnd() % 80); break;
    case 3: e = 0x3FFF + 1000 + (unsigned)(rnd() % 80); break;
    case 4: e = 0x3FFF - 160 + (unsigned)(rnd() % 20); break;
    case 5: e = 0x3FFF + 120 + (unsigned)(rnd() % 20); break;
    case 6: e = (unsigned)(rnd() % 0x7FFE) + 1; break;
    default: e = 0x3FFF - 70 + (unsigned)(rnd() % 140); break;
    }
    if (((r >> 12) & 63) == 0) {
        e = 0;
        v.m >>= 1 + (rnd() % 63);
    }
    v.se = (uint16_t)(e | ((r >> 20) & 1 ? 0x8000 : 0));
    return v;
}

static Vm86_fparith *top;
static unsigned long long clocks;

static void tick(void)
{
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
    clocks++;
}

static void put80(uint32_t *w, m86f80 v)
{
    w[0] = (uint32_t)v.m; w[1] = (uint32_t)(v.m >> 32); w[2] = v.se;
}

#define NOPS 22
static const char *opname[NOPS] = { "add", "sub", "mul", "div", "com", "ucom", "sqrt", "rndint",
                                    "fist 16", "fist 32", "fist 64", "fild", "fst 32", "fst 64",
                                    "fld 32", "fld 64", "prem", "prem1", "scale", "xtract", "fbld", "fbstp" };

int main(int argc, char **argv)
{
    long count = argc > 1 ? atol(argv[1]) : 200000, bad = 0, total = 0;
    top = new Vm86_fparith;
    top->rst = 1; tick(); tick(); top->rst = 0;
    for (int op = 0; op < NOPS; op++) {
        long opbad = 0;
        unsigned long long c0 = clocks;
        for (long n = 0; n < count; n++) {
            m86f80 a = operand(), b = operand(), r = { 0, 0 };
            if ((rnd() & 7) == 0) {
                b = a;
                b.m ^= (uint64_t)1 << (rnd() % 8);
                if (rnd() & 1) b.se ^= 0x8000;
                if (rnd() & 1) b.se = (uint16_t)(b.se + ((b.se & 0x7FFF) < 0x7FF0 && (b.se & 0x7FFF) ? 1 : 0));
            }
            if ((op >= 8 && op <= 10) && (rnd() & 1)) {         /* of a size to fit, often */
                a.se = (uint16_t)((a.se & 0x8000) | (0x3FFF - 3 + rnd() % 70));
                a.m |= 0x8000000000000000ull;
            }
            if ((op == 16 || op == 17) && (rnd() & 1)) {        /* exponents close enough for the whole of it */
                a.se = (uint16_t)((a.se & 0x8000) | (0x3FFF - 40 + rnd() % 120)); a.m |= 0x8000000000000000ull;
                b.se = (uint16_t)((b.se & 0x8000) | (0x3FFF - 40 + rnd() % 80));  b.m |= 0x8000000000000000ull;
            }
            if (op == 18 && (rnd() & 1)) {
                b.se = (uint16_t)((b.se & 0x8000) | (0x3FFF - 2 + rnd() % 18)); b.m |= 0x8000000000000000ull;
            }
            if (op == 21 && (rnd() & 1)) {
                a.se = (uint16_t)((a.se & 0x8000) | (0x3FFF - 3 + rnd() % 66)); a.m |= 0x8000000000000000ull;
            }
            uint8_t bcd[10], wbcd[10];
            for (int k = 0; k < 9; k++) bcd[k] = (uint8_t)(((rnd() % 10) << 4) | (rnd() % 10));
            if (rnd() & 1) for (int k = 4 + rnd() % 5; k < 9; k++) bcd[k] = 0;
            bcd[9] = (uint8_t)rnd();
            m86f80 r2 = { 0, 0 };
            int two = 0, isbcd = 0;
            int rc = (int)(rnd() & 3), pc = (int)((rnd() >> 2) & 3);
            if (pc == 1) pc = 3;
            unsigned um = (rnd() & 3) ? 0 : (unsigned)(rnd() & 3);      /* bit 0 O, bit 1 U */
            uint64_t mem = rnd(), got = 0, want = 0;
            if (op == 14) {
                if ((rnd() & 3) == 0) mem = (mem & 0x807FFFFF) | ((rnd() & 1) ? 0x7F800000 : 0);
                mem &= 0xFFFFFFFFull;
            }
            if (op == 15 && (rnd() & 3) == 0)
                mem = (mem & 0x800FFFFFFFFFFFFFull) | ((rnd() & 1) ? 0x7FF0000000000000ull : 0);
            if (op == 11 && (rnd() & 1))
                mem = (uint64_t)((int64_t)mem >> (rnd() % 64));
            m86fctx c = { rc, pc, 0, ((um & 1) ? FX_O : 0u) | ((um & 2) ? FX_U : 0u) };
            unsigned cc = 0;
            int raw = 0;
            switch (op) {
            case 0: r = m86f_add(&c, a, b); break;
            case 1: r = m86f_sub(&c, a, b); break;
            case 2: r = m86f_mul(&c, a, b); break;
            case 3: r = m86f_div(&c, a, b); break;
            case 4: cc = m86f_cmp(&c, a, b, 0); break;
            case 5: cc = m86f_cmp(&c, a, b, 1); break;
            case 6: r = m86f_sqrt(&c, a); break;
            case 7: r = m86f_rndint(&c, a); break;
            case 8: want = (uint64_t)m86f_to_int(&c, a, 16); raw = 1; break;
            case 9: want = (uint64_t)m86f_to_int(&c, a, 32); raw = 1; break;
            case 10: want = (uint64_t)m86f_to_int(&c, a, 64); raw = 1; break;
            case 11: r = m86f_from_i64((int64_t)mem); break;
            case 12: want = m86f_to_f32(&c, a); raw = 1; break;
            case 13: want = m86f_to_f64(&c, a); raw = 1; break;
            case 14: r = m86f_from_f32(&c, (uint32_t)mem); break;
            case 15: r = m86f_from_f64(&c, mem); break;
            case 16: r = m86f_prem(&c, a, b, 0, &cc); break;
            case 17: r = m86f_prem(&c, a, b, 1, &cc); break;
            case 18: r = m86f_scale(&c, a, b); break;
            case 19: r = m86f_xtract(&c, a, &r2); two = 1; break;
            case 20: r = m86f_from_bcd(bcd); break;
            default: m86f_to_bcd(&c, a, wbcd); isbcd = 1; break;
            }
            if (op == 11 || op == 14 || op == 15) {
                top->a[0] = (uint32_t)mem; top->a[1] = (uint32_t)(mem >> 32); top->a[2] = 0;
            } else if (op == 20) {
                m86f80 t;
                t.m = 0; for (int k = 7; k >= 0; k--) t.m = (t.m << 8) | bcd[k];
                t.se = (uint16_t)(bcd[8] | (bcd[9] << 8));
                put80(top->a, t);
            } else
                put80(top->a, a);
            put80(top->b, b);
            top->op = op; top->rc = rc; top->pc = pc; top->um = um;
            top->start = 1; tick(); top->start = 0;
            int guard = 0;
            while (!top->done && guard++ < 1000)
                tick();
            got = top->r[0] | ((uint64_t)top->r[1] << 32);
            unsigned gse = top->r[2] & 0xFFFF;
            unsigned wfl = (c.fl & 0x3F) | ((c.fl & FX_C1) ? 0x40 : 0);
            unsigned wcc = ((cc & 0x4000) ? 8 : 0) | ((cc & 0x0400) ? 4 : 0) | ((cc & 0x0200) ? 2 : 0) | ((cc & 0x0100) ? 1 : 0);
            int ok = guard < 1000 && top->fl == wfl;
            if (isbcd) {
                uint64_t wm = 0;
                for (int k = 7; k >= 0; k--) wm = (wm << 8) | wbcd[k];
                r.m = wm; r.se = (uint16_t)(wbcd[8] | (wbcd[9] << 8));
            }
            if (op == 16 || op == 17)
                ok = ok && top->cc == wcc;
            if (two)
                ok = ok && (top->r2[0] | ((uint64_t)top->r2[1] << 32)) == r2.m && (top->r2[2] & 0xFFFF) == r2.se;
            if (op == 4 || op == 5)
                ok = ok && top->cc == wcc;
            else if (raw)
                ok = ok && got == want;
            else
                ok = ok && got == r.m && gse == r.se;
            total++;
            if (!ok) {
                bad++;
                if (opbad++ < 5)
                    printf("%s rc %d pc %d um %u: a %04x %016llx  b %04x %016llx  mem %016llx\n"
                           "    model: %04x %016llx  int %016llx  flags %02x cc %u\n"
                           "    rtl:   %04x %016llx                         flags %02x cc %u%s\n",
                           opname[op], rc, pc, um, a.se, (unsigned long long)a.m, b.se, (unsigned long long)b.m,
                           (unsigned long long)mem, r.se, (unsigned long long)r.m, (unsigned long long)want, wfl, wcc,
                           gse, (unsigned long long)got, top->fl, top->cc, guard >= 1000 ? "  (never done)" : "");
            }
        }
        printf("fparith: %-8s %ld of %ld differ; %.1f clocks each\n", opname[op], opbad, count,
               (double)(clocks - c0) / count);
    }
    printf("fparith: %ld operations, %ld differences between the RTL and the model\n", total, bad);
    return bad != 0;
}
