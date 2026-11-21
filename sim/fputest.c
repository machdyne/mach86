/*
 * fputest.c: the model's x87 arithmetic (m86fpu.c) against the x87 of
 * the machine this runs on. x86 hosts only: every operation is done
 * twice, by the processor and by the model's code, on the same
 * operands, and the results and the status word's flags must be the
 * same, bit for bit, for all rounding and precision settings.
 *
 * usage: fputest [count]       operations of each kind (a million if not given)
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "m86fpu.h"

#if !defined(__x86_64__) && !defined(__i386__)
int main(void)
{
    printf("fputest: needs an x86 host; skipped\n");
    return 0;
}
#else

typedef struct { uint64_t m; uint16_t se; uint8_t pad[6]; } __attribute__((packed)) tbyte;

static uint64_t rs = 0x9E3779B97F4A7C15ull;
static uint64_t rnd(void)
{
    rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17;
    return rs;
}

/* Operands that find the corners: specials, the ends of the exponent's
 * range, significands of few bits or nearly all, and pairs close
 * together. */
static m86f80 operand(void)
{
    static const m86f80 fixed[] = {
        { 0, 0x0000 }, { 0, 0x8000 },                                   /* zeros */
        { 0x8000000000000000ull, 0x7FFF }, { 0x8000000000000000ull, 0xFFFF },   /* infinities */
        { 0xC000000000000000ull, 0x7FFF }, { 0xC000000000000001ull, 0xFFFF },   /* quiet NaNs */
        { 0xA000000000000000ull, 0x7FFF }, { 0x8000000000000001ull, 0xFFFF },   /* signalling */
        { 0xFFFFFFFFFFFFFFFFull, 0x7FFF }, { 0xBFFFFFFFFFFFFFFFull, 0x7FFF },
        { 0x8000000000000000ull, 0x3FFF }, { 0x8000000000000000ull, 0xBFFF },   /* one */
        { 0x0000000000000001ull, 0x0000 }, { 0x7FFFFFFFFFFFFFFFull, 0x8000 },   /* denormals */
        { 0x8000000000000000ull, 0x0000 }, { 0xFFFFFFFFFFFFFFFFull, 0x0000 },   /* pseudo-denormals */
        { 0x8000000000000000ull, 0x0001 }, { 0xFFFFFFFFFFFFFFFFull, 0x7FFE },   /* smallest, largest */
        { 0x4000000000000000ull, 0x3FFF }, { 0x0000000000000000ull, 0x4000 },   /* unsupported */
        { 0x0000000000000000ull, 0x7FFF }, { 0x7000000000000000ull, 0xFFFF },
    };
    uint64_t r = rnd();
    m86f80 v;
    if ((r & 15) == 0)
        return fixed[(r >> 8) % (sizeof fixed / sizeof fixed[0])];
    v.m = rnd();
    switch ((r >> 4) & 7) {
    case 0: v.m &= 0xFFFFFF0000000000ull; break;        /* fits in 24 bits */
    case 1: v.m &= 0xFFFFFFFFFFFFF800ull; break;        /* in 53 */
    case 2: v.m |= 0x7FFFFFFFFFFFFF00ull; break;        /* nearly all ones */
    case 3: v.m &= 0xFF00000000000003ull; break;        /* a few bits at each end */
    case 4: v.m = (v.m & 0xFFFFFF0000000000ull) | ((uint64_t)1 << (rnd() % 40)); break;
    default: break;
    }
    v.m |= 0x8000000000000000ull;
    unsigned e;
    switch ((r >> 8) & 7) {
    case 0: e = 1 + (unsigned)(rnd() % 80); break;              /* near the bottom */
    case 1: e = 0x7FFE - (unsigned)(rnd() % 80); break;         /* near the top */
    case 2: e = 0x3FFF - 1100 + (unsigned)(rnd() % 80); break;  /* where doubles end */
    case 3: e = 0x3FFF + 1000 + (unsigned)(rnd() % 80); break;
    case 4: e = 0x3FFF - 160 + (unsigned)(rnd() % 20); break;   /* and singles */
    case 5: e = 0x3FFF + 120 + (unsigned)(rnd() % 20); break;
    case 6: e = (unsigned)(rnd() % 0x7FFE) + 1; break;
    default: e = 0x3FFF - 70 + (unsigned)(rnd() % 140); break;  /* near one */
    }
    if (((r >> 12) & 63) == 0) {        /* a denormal */
        e = 0;
        v.m >>= 1 + (rnd() % 63);
    }
    v.se = (uint16_t)(e | ((r >> 20) & 1 ? 0x8000 : 0));
    return v;
}

enum { OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_SQRT, OP_RND, OP_CMP, OP_UCMP,
       OP_IST16, OP_IST32, OP_IST64, OP_ILD, OP_ST32, OP_ST64, OP_LD32, OP_LD64,
       OP_PREM, OP_PREM1, OP_SCALE, OP_XTRACT, OP_BSTP, OP_BLD, OP_CONST,
       OP_SIN, OP_COS, OP_TAN, OP_ATAN, OP_2XM1, OP_YL2X, OP_YL2XP1, OP_N };
static const char *opname[OP_N] = { "add", "sub", "mul", "div", "sqrt", "rndint", "com", "ucom",
                                    "fist 16", "fist 32", "fist 64", "fild", "fst 32", "fst 64",
                                    "fld 32", "fld 64", "prem", "prem1", "scale", "xtract", "fbstp", "fbld",
                                    "constant", "sin", "cos", "tan", "atan", "2xm1", "yl2x", "yl2xp1" };

/* The processor's answer: the result (or what was stored) and the
 * status word. */
static void host(int op, unsigned cw, m86f80 a, m86f80 b, tbyte *r, tbyte *r2, uint64_t *mem, uint8_t *bcd, uint16_t *sw)
{
    tbyte ta, tb;
    uint16_t cww = (uint16_t)cw, s = 0;
    uint64_t q = *mem;
    memset(&ta, 0, sizeof ta); memset(&tb, 0, sizeof tb); memset(r, 0, sizeof *r);
    ta.m = a.m; ta.se = a.se; tb.m = b.m; tb.se = b.se;
    __asm__ volatile ("fninit; fldcw %0" : : "m"(cww));
    switch (op) {
#define BIN(insn) \
        __asm__ volatile ("fldt %3; fldt %2; fnclex; " insn "; fnstsw %1; fnclex; fstpt %0; fstp %%st(0)" \
                          : "=m"(*r), "=m"(s) : "m"(ta), "m"(tb))
    case OP_ADD: BIN("fadd %%st(1), %%st"); break;
    case OP_SUB: BIN("fsub %%st(1), %%st"); break;
    case OP_MUL: BIN("fmul %%st(1), %%st"); break;
    case OP_DIV: BIN("fdiv %%st(1), %%st"); break;
    case OP_SQRT:
        __asm__ volatile ("fldt %2; fnclex; fsqrt; fnstsw %1; fnclex; fstpt %0"
                          : "=m"(*r), "=m"(s) : "m"(ta)); break;
    case OP_RND:
        __asm__ volatile ("fldt %2; fnclex; frndint; fnstsw %1; fnclex; fstpt %0"
                          : "=m"(*r), "=m"(s) : "m"(ta)); break;
    case OP_CMP:
        __asm__ volatile ("fldt %2; fldt %1; fnclex; fcom %%st(1); fnstsw %0; fnclex; fstp %%st(0); fstp %%st(0)"
                          : "=m"(s) : "m"(ta), "m"(tb)); break;
    case OP_UCMP:
        __asm__ volatile ("fldt %2; fldt %1; fnclex; fucom %%st(1); fnstsw %0; fnclex; fstp %%st(0); fstp %%st(0)"
                          : "=m"(s) : "m"(ta), "m"(tb)); break;
    case OP_IST16:
        __asm__ volatile ("fldt %2; fnclex; fistps %0; fnstsw %1; fnclex; fstp %%st(0)" : "+m"(q), "=m"(s) : "m"(ta)); break;
    case OP_IST32:
        __asm__ volatile ("fldt %2; fnclex; fistpl %0; fnstsw %1; fnclex; fstp %%st(0)" : "+m"(q), "=m"(s) : "m"(ta)); break;
    case OP_IST64:
        __asm__ volatile ("fldt %2; fnclex; fistpll %0; fnstsw %1; fnclex; fstp %%st(0)" : "+m"(q), "=m"(s) : "m"(ta)); break;
    case OP_ILD:
        __asm__ volatile ("fnclex; fildll %2; fnstsw %1; fnclex; fstpt %0" : "=m"(*r), "=m"(s) : "m"(q)); break;
    case OP_ST32:
        __asm__ volatile ("fldt %2; fnclex; fstps %0; fnstsw %1; fnclex; fstp %%st(0)" : "+m"(q), "=m"(s) : "m"(ta)); break;
    case OP_ST64:
        __asm__ volatile ("fldt %2; fnclex; fstpl %0; fnstsw %1; fnclex; fstp %%st(0)" : "+m"(q), "=m"(s) : "m"(ta)); break;
    case OP_LD32:
        __asm__ volatile ("fnclex; flds %2; fnstsw %1; fnclex; fstpt %0" : "=m"(*r), "=m"(s) : "m"(q)); break;
    case OP_LD64:
        __asm__ volatile ("fnclex; fldl %2; fnstsw %1; fnclex; fstpt %0" : "=m"(*r), "=m"(s) : "m"(q)); break;
    case OP_PREM: BIN("fprem"); break;
    case OP_PREM1: BIN("fprem1"); break;
    case OP_SCALE: BIN("fscale"); break;
    case OP_XTRACT:
        __asm__ volatile ("fldt %3; fnclex; fxtract; fnstsw %2; fnclex; fstpt %1; fstpt %0"
                          : "=m"(*r), "=m"(*r2), "=m"(s) : "m"(ta)); break;
    case OP_BSTP:
        __asm__ volatile ("fldt %2; fnclex; fbstp %0; fnstsw %1; fnclex" : "=m"(*(tbyte *)bcd), "=m"(s) : "m"(ta)); break;
    case OP_BLD:
        __asm__ volatile ("fnclex; fbld %2; fnstsw %1; fnclex; fstpt %0" : "=m"(*r), "=m"(s) : "m"(*(tbyte *)bcd)); break;
    case OP_CONST:
        switch (q % 7) {
        case 0: __asm__ volatile ("fld1; fnstsw %1; fnclex; fstpt %0" : "=m"(*r), "=m"(s)); break;
        case 1: __asm__ volatile ("fldl2t; fnstsw %1; fnclex; fstpt %0" : "=m"(*r), "=m"(s)); break;
        case 2: __asm__ volatile ("fldl2e; fnstsw %1; fnclex; fstpt %0" : "=m"(*r), "=m"(s)); break;
        case 3: __asm__ volatile ("fldpi; fnstsw %1; fnclex; fstpt %0" : "=m"(*r), "=m"(s)); break;
        case 4: __asm__ volatile ("fldlg2; fnstsw %1; fnclex; fstpt %0" : "=m"(*r), "=m"(s)); break;
        case 5: __asm__ volatile ("fldln2; fnstsw %1; fnclex; fstpt %0" : "=m"(*r), "=m"(s)); break;
        default: __asm__ volatile ("fldz; fnstsw %1; fnclex; fstpt %0" : "=m"(*r), "=m"(s)); break;
        }
        break;
    case OP_SIN:
        __asm__ volatile ("fldt %2; fnclex; fsin; fnstsw %1; fnclex; fstpt %0" : "=m"(*r), "=m"(s) : "m"(ta)); break;
    case OP_COS:
        __asm__ volatile ("fldt %2; fnclex; fcos; fnstsw %1; fnclex; fstpt %0" : "=m"(*r), "=m"(s) : "m"(ta)); break;
    case OP_TAN:
        __asm__ volatile ("fldt %2; fnclex; fptan; fnstsw %1; fnclex; fstp %%st(0); fstpt %0" : "=m"(*r), "=m"(s) : "m"(ta)); break;
    case OP_ATAN:       /* ST(1) = a (y), ST = b (x) */
        __asm__ volatile ("fldt %2; fldt %3; fnclex; fpatan; fnstsw %1; fnclex; fstpt %0" : "=m"(*r), "=m"(s) : "m"(ta), "m"(tb)); break;
    case OP_2XM1:
        __asm__ volatile ("fldt %2; fnclex; f2xm1; fnstsw %1; fnclex; fstpt %0" : "=m"(*r), "=m"(s) : "m"(ta)); break;
    case OP_YL2X:       /* ST(1) = b (y), ST = a (x) */
        __asm__ volatile ("fldt %3; fldt %2; fnclex; fyl2x; fnstsw %1; fnclex; fstpt %0" : "=m"(*r), "=m"(s) : "m"(ta), "m"(tb)); break;
    case OP_YL2XP1:
        __asm__ volatile ("fldt %3; fldt %2; fnclex; fyl2xp1; fnstsw %1; fnclex; fstpt %0" : "=m"(*r), "=m"(s) : "m"(ta), "m"(tb)); break;
    }
    __asm__ volatile ("fninit");     /* (the compiler's own use of it finds it clean) */
    *mem = q;
    *sw = s;
}

static long double ld(m86f80 v)
{
    tbyte t;
    long double x;
    memset(&t, 0, sizeof t);
    t.m = v.m; t.se = v.se;
    memcpy(&x, &t, sizeof x);
    return x;
}

/* An operand for a transcendental function: of ordinary size. */
static m86f80 modest(int lo, int hi)
{
    m86f80 v;
    v.m = rnd() | 0x8000000000000000ull;
    if ((rnd() & 7) == 0) v.m &= 0xFFFF000000000000ull;
    v.se = (uint16_t)((0x3FFF + lo + (int)(rnd() % (unsigned)(hi - lo + 1))) | ((rnd() & 1) ? 0x8000 : 0));
    return v;
}

int main(int argc, char **argv)
{
    long count = argc > 1 ? atol(argv[1]) : 1000000, bad = 0, total = 0;
    for (int op = 0; op < OP_N; op++) {
        long opbad = 0;
        long double worst = 0;
        int approx = op >= OP_SIN;
        for (long n = 0; n < count; n++) {
            m86f80 a = operand(), b = operand(), r = { 0, 0 }, r2 = { 0, 0 };
            if ((rnd() & 7) == 0) {     /* a pair close together */
                b = a;
                b.m ^= (uint64_t)1 << (rnd() % 8);
                if (rnd() & 1) b.se ^= 0x8000;
                if (rnd() & 1) b.se = (uint16_t)(b.se + ((b.se & 0x7FFF) < 0x7FF0 && (b.se & 0x7FFF) ? 1 : 0));
            }
            if ((op == OP_PREM || op == OP_PREM1) && (rnd() & 1)) {
                /* Exponents close enough for the whole of it. */
                a = modest(-40, 80); b = modest(-40, 40);
            }
            if (op == OP_SCALE && (rnd() & 1))
                b = modest(-2, 15);
            if (op == OP_BSTP && (rnd() & 1))
                a = modest(-3, 62);
            int rc = (int)(rnd() & 3), pc = (int)((rnd() >> 2) & 3);
            if (pc == 1) pc = 3;
            /* Sometimes with exceptions not masked (never precision). */
            unsigned mask = (rnd() & 3) ? 0x3F : (unsigned)(rnd() & 0x1F) | 0x20;
            if (approx || op == OP_CONST || op == OP_PREM || op == OP_PREM1 || op == OP_BSTP ||
                op == OP_BLD || op == OP_XTRACT)
                mask = 0x3F;
            if (approx) {
                rc = 0; pc = 3;
                switch (op) {
                case OP_SIN: case OP_COS: case OP_TAN: a = modest(-30, 20); break;
                case OP_ATAN: a = modest(-30, 30); b = modest(-30, 30); break;
                case OP_2XM1: a = modest(-40, -1); break;
                case OP_YL2X: a = modest(-200, 200); a.se &= 0x7FFF; b = modest(-10, 10);
                              if ((rnd() & 3) == 0) { a.se = 0x3FFF - (rnd() & 1); a.m = (rnd() & 1) ? ~(rnd() >> 20) : (0x8000000000000000ull | (rnd() >> 20)); }
                              break;
                default: a = modest(-40, -3); b = modest(-10, 10); break;
                }
            }
            unsigned cw = 0x0340 | mask | ((unsigned)rc << 10);
            cw = (cw & ~0x300u) | ((unsigned)pc << 8);
            uint64_t mem = rnd(), want_mem, got_mem = 0;
            uint8_t bcd[16], gbcd[16];
            memset(bcd, 0, sizeof bcd); memset(gbcd, 0, sizeof gbcd);
            if (op == OP_BLD) {
                for (int i = 0; i < 9; i++)
                    bcd[i] = (uint8_t)(((rnd() % 10) << 4) | (rnd() % 10));
                if (rnd() & 1) memset(bcd + (rnd() % 9), 0, 4);
                bcd[9] = (uint8_t)rnd();
            }
            if (op == OP_LD32) {        /* any single: often a special one */
                if ((rnd() & 3) == 0) mem = (mem & 0x807FFFFF) | ((rnd() & 1) ? 0x7F800000 : 0);
                mem &= 0xFFFFFFFFull;
            }
            if (op == OP_LD64 && (rnd() & 3) == 0)
                mem = (mem & 0x800FFFFFFFFFFFFFull) | ((rnd() & 1) ? 0x7FF0000000000000ull : 0);
            if (op == OP_ILD && (rnd() & 1))
                mem = (uint64_t)((int64_t)mem >> (rnd() % 64));
            uint64_t mem0 = mem;
            tbyte hr, hr2;
            uint16_t sw;
            memset(&hr2, 0, sizeof hr2);
            host(op, cw, a, b, &hr, &hr2, &mem, bcd, &sw);
            want_mem = mem;
            m86fctx c = { rc, pc, 0, ~mask & (FX_O | FX_U) };
            unsigned cc = 0, ccmask = 0;
            int store = 0, bits = 0, two = 0;
            m86f80 keep = a;            /* what is left when nothing is done */
            switch (op) {
            case OP_ADD:  r = m86f_add(&c, a, b); break;
            case OP_SUB:  r = m86f_sub(&c, a, b); break;
            case OP_MUL:  r = m86f_mul(&c, a, b); break;
            case OP_DIV:  r = m86f_div(&c, a, b); break;
            case OP_SQRT: r = m86f_sqrt(&c, a); break;
            case OP_RND:  r = m86f_rndint(&c, a); break;
            case OP_CMP:  cc = m86f_cmp(&c, a, b, 0); ccmask = 0x4500; break;
            case OP_UCMP: cc = m86f_cmp(&c, a, b, 1); ccmask = 0x4500; break;
            case OP_IST16: got_mem = (uint16_t)m86f_to_int(&c, a, 16); store = 1; bits = 16; break;
            case OP_IST32: got_mem = (uint32_t)m86f_to_int(&c, a, 32); store = 1; bits = 32; break;
            case OP_IST64: got_mem = (uint64_t)m86f_to_int(&c, a, 64); store = 1; bits = 64; break;
            case OP_ILD:  r = m86f_from_i64((int64_t)mem0); break;
            case OP_ST32: got_mem = m86f_to_f32(&c, a); store = 1; bits = 32; break;
            case OP_ST64: got_mem = m86f_to_f64(&c, a); store = 1; bits = 64; break;
            case OP_LD32: r = m86f_from_f32(&c, (uint32_t)mem0); break;
            case OP_LD64: r = m86f_from_f64(&c, mem0); break;
            case OP_PREM: r = m86f_prem(&c, a, b, 0, &cc); ccmask = 0x4700; break;
            case OP_PREM1: r = m86f_prem(&c, a, b, 1, &cc); ccmask = 0x4700; break;
            case OP_SCALE: r = m86f_scale(&c, a, b); break;
            case OP_XTRACT: r = m86f_xtract(&c, a, &r2); two = 1; break;
            case OP_BSTP: m86f_to_bcd(&c, a, gbcd); break;
            case OP_BLD:  r = m86f_from_bcd(bcd); break;
            case OP_CONST: r = m86f_const(&c, (int)(mem0 % 7)); break;
            case OP_SIN: { m86f80 x; if (m86f_sincos(&c, a, &r, &x)) r = a; break; }
            case OP_COS: { m86f80 x; if (m86f_sincos(&c, a, &x, &r)) r = a; break; }
            case OP_TAN: { m86f80 x, y; m86fctx q = { 0, 3, 0, 0 };
                           if (m86f_sincos(&c, a, &x, &y)) r = a; else r = m86f_div(&q, x, y); break; }
            case OP_ATAN: r = m86f_atan2(&c, a, b); break;
            case OP_2XM1: r = m86f_2xm1(&c, a); break;
            case OP_YL2X: r = m86f_yl2x(&c, a, b); break;
            case OP_YL2XP1: r = m86f_yl2xp1(&c, a, b); break;
            }
            /* Not masked: an invalid operation, a denormal operand or a
             * division by zero stop the operation before it does
             * anything; so do overflow and underflow of a store. */
            unsigned stop = c.fl & ~mask & (FX_I | FX_D | FX_Z);
            if (store)
                stop |= c.fl & ~mask & (FX_O | FX_U);
            if (stop) {
                c.fl = stop & (FX_I | FX_D | FX_Z) ? c.fl & (FX_I | FX_D | FX_Z) : c.fl & (FX_O | FX_U);
                if (op != OP_LD32 && op != OP_LD64)
                    r = keep;
                else if (stop & FX_I)   /* (a denormal is loaded all the same) */
                    r.m = 0, r.se = 0;
                got_mem = mem0;
                cc = 0; ccmask = 0;
            }
            uint64_t mask2 = bits == 64 ? ~(uint64_t)0 : (((uint64_t)1 << bits) - 1);
            unsigned want = sw & (0x3F | (ccmask ? 0 : 0x200) | ccmask);
            unsigned got = (c.fl & (ccmask ? 0x3F : 0x23F)) | cc;
            int ok;
            if (approx) {
                /* Within a few units in the last place. */
                m86f80 h = { hr.m, hr.se };
                long double x = ld(h), y = ld(r), d, u;
                /* (The library's, for these: the processor's own take
                 * multiples of a 66-bit pi off, and are far out.) */
                if (op == OP_SIN) x = sinl(ld(a));
                if (op == OP_COS) x = cosl(ld(a));
                if (op == OP_TAN) x = tanl(ld(a));
                d = x - y;
                if (d < 0) d = -d;
                u = (x < 0 ? -x : x) * 0x1p-63L;
                long double e = u > 0 ? d / u : (d != 0);
                if (x != x || y != y) e = (x != x && y != y) ? 0 : 1e9;
                if (e > worst) worst = e;
                ok = e <= 4.0L;
            } else {
                ok = (want == got);
                if (op == OP_BSTP)
                    ok = ok && !memcmp(bcd, gbcd, 10);
                else if (store)
                    ok = ok && ((want_mem & mask2) == (got_mem & mask2));
                else if (op != OP_CMP && op != OP_UCMP)
                    ok = ok && hr.m == r.m && hr.se == r.se;
                if (two)
                    ok = ok && hr2.m == r2.m && hr2.se == r2.se;
            }
            total++;
            if (!ok) {
                bad++;
                if (opbad++ < 6)
                    printf("%s rc %d pc %d mask %02x: a %04x %016llx  b %04x %016llx  mem %016llx\n"
                           "    processor: %04x %016llx (%04x %016llx) mem %016llx  flags %04x\n"
                           "    model:     %04x %016llx (%04x %016llx) mem %016llx  flags %04x\n",
                           opname[op], rc, pc, mask, a.se, (unsigned long long)a.m, b.se, (unsigned long long)b.m,
                           (unsigned long long)mem0,
                           hr.se, (unsigned long long)hr.m, hr2.se, (unsigned long long)hr2.m,
                           (unsigned long long)(want_mem & mask2), want,
                           r.se, (unsigned long long)r.m, r2.se, (unsigned long long)r2.m,
                           (unsigned long long)(got_mem & mask2), got);
            }
        }
        if (approx)
            printf("fputest: %-8s %ld of %ld over 4 units in the last place from this machine's (worst %.2Lf)\n",
                   opname[op], opbad, count, worst);
        else
            printf("fputest: %-8s %ld of %ld differ\n", opname[op], opbad, count);
    }
    printf("fputest: %ld operations, %ld differences from this machine's x87\n", total, bad);
    return bad != 0;
}
#endif
