/*
 * m86fpu.c: x87 arithmetic for the model. See m86fpu.h and docs/fpu.md.
 *
 * Clean-room: written from the published behaviour of the 387 and the
 * IEEE 754 standard, and checked against a real x87 (sim/fputest.c).
 */
#include "m86fpu.h"

typedef unsigned __int128 u128;

#define BIAS    16383
#define QUIET   0x4000000000000000ull
#define INTBIT  0x8000000000000000ull

static const m86f80 f_indef = { 0xC000000000000000ull, 0xFFFF };

int m86f_class(m86f80 a)
{
    unsigned e = a.se & 0x7FFF;
    if (e == 0)
        return a.m ? FC_DENORMAL : FC_ZERO;
    if (!(a.m & INTBIT))
        return FC_UNSUPPORTED;
    if (e != 0x7FFF)
        return FC_NORMAL;
    if (a.m == INTBIT)
        return FC_INF;
    return (a.m & QUIET) ? FC_QNAN : FC_SNAN;
}

static int is_nan(int k) { return k == FC_QNAN || k == FC_SNAN; }

static m86f80 pack(int sign, unsigned e, uint64_t m)
{
    m86f80 r = { m, (uint16_t)((sign ? 0x8000 : 0) | e) };
    return r;
}

/* A finite, nonzero number as sign, exponent and a significand with
 * its top bit set. (A denormal's exponent field of 0 means 1.) */
static void unpack(m86f80 a, int *sign, int *exp, uint64_t *m)
{
    int e = a.se & 0x7FFF, s;
    if (e == 0)
        e = 1;
    s = __builtin_clzll(a.m);
    *sign = a.se >> 15;
    *exp = e - s;
    *m = a.m << s;
}

/* Shift right, keeping what falls off as a set lowest bit. */
static u128 shr_jam(u128 v, int n)
{
    if (n <= 0)
        return v;
    if (n >= 128)
        return v != 0;
    return (v >> n) | ((v << (128 - n)) != 0);
}

/*
 * Round and pack. The value is sig * 2^(exp - BIAS - 127), sig with its
 * top bit (127) set; `p` bits of it are kept (64, 53 or 24). `emax` is
 * the format's all-ones exponent field (7FFFh here; this also rounds
 * for the 32- and 64-bit formats, with their exponents and 24 or 53
 * bits). What comes back is the significand at the top of 64 bits and
 * the exponent field in *eout (0: zero or denormal; emax: infinity).
 */
/* One rounding of a 128-bit significand to p bits at the top of 64.
 * *carry: it rounded up out of the top (and comes back as 8000...). */
static uint64_t round1(int rc, int sign, u128 sig, int p, int *inexact, int *up, int *carry)
{
    uint64_t hi = (uint64_t)(sig >> 64), lo = (uint64_t)sig;
    int d = 64 - p;                     /* bits of hi that are dropped */
    uint64_t frac, half, keep, unit = (uint64_t)1 << d;
    int extra;
    if (d == 0) {
        frac = lo; half = INTBIT; extra = 0; keep = hi;
    } else {
        frac = hi & (unit - 1);
        half = unit >> 1;
        extra = (lo != 0);
        keep = hi & ~(unit - 1);
    }
    *inexact = (frac != 0) || extra;
    *up = 0;
    *carry = 0;
    switch (rc) {
    case 0: *up = frac > half || (frac == half && (extra || (keep & unit))); break;
    case 1: *up = *inexact && sign; break;
    case 2: *up = *inexact && !sign; break;
    default: break;
    }
    if (*up) {
        keep += unit;
        if (keep == 0) {
            keep = INTBIT;
            *carry = 1;
        }
    }
    return keep;
}

static uint64_t round_to(m86fctx *c, int sign, int exp, u128 sig, int p, int emax, int *eout)
{
    int inexact, up, carry, tiny = (exp <= 0);
    if (tiny) {
        /* Tiny is judged after rounding: a result that rounds up to the
         * smallest normal number has not underflowed. */
        if (exp == 0) {
            round1(c->rc, sign, sig, p, &inexact, &up, &carry);
            if (carry)
                tiny = 0;
        }
        sig = shr_jam(sig, 1 - exp);
        exp = 0;                        /* (the field: a denormal's) */
    }
    uint64_t keep = round1(c->rc, sign, sig, p, &inexact, &up, &carry);
    if (carry)
        exp++;
    else if (exp == 0 && (keep & INTBIT))
        exp = 1;
    if (inexact) {
        c->fl |= FX_P;
        if (up) c->fl |= FX_C1;
        if (tiny) c->fl |= FX_U;
    }
    if (tiny && (c->um & FX_U))
        c->fl |= FX_U;                  /* not masked: exact or not */
    if (exp >= emax) {
        /* Overflow: infinity, or the largest number, by the rounding. */
        int inf = (c->rc == 0) || (c->rc == 1 && sign) || (c->rc == 2 && !sign);
        c->fl |= FX_O | FX_P;
        if (inf) {
            c->fl |= FX_C1;
            *eout = emax;
            return INTBIT;
        }
        c->fl &= ~(unsigned)FX_C1;
        *eout = emax - 1;
        return ~(uint64_t)0 << (64 - p);
    }
    *eout = exp;
    return keep;
}

static int prec(m86fctx *c)
{
    return c->pc == 0 ? 24 : c->pc == 2 ? 53 : 64;
}

static m86f80 round_pack(m86fctx *c, int sign, int exp, u128 sig)
{
    int e, p = prec(c);
    uint64_t m;
    if (c->um) {
        int inexact, up, carry;
        m = round1(c->rc, sign, sig, p, &inexact, &up, &carry);
        e = exp + carry;
        if ((e <= 0 && (c->um & FX_U)) || (e >= 0x7FFF && (c->um & FX_O))) {
            /* Not masked: the result with its exponent moved into
             * range, for the handler. */
            c->fl |= e <= 0 ? FX_U : FX_O;
            if (inexact) {
                c->fl |= FX_P;
                if (up) c->fl |= FX_C1;
            }
            if (e <= 0) {
                e += 24576;
                if (e <= 0) {           /* still under: nothing */
                    c->fl |= FX_P;
                    c->fl &= ~(unsigned)FX_C1;
                    return pack(sign, 0, 0);
                }
            } else {
                e -= 24576;
                if (e >= 0x7FFF) {      /* still over */
                    c->fl |= FX_P | FX_C1;
                    return pack(sign, 0x7FFF, INTBIT);
                }
            }
            return pack(sign, (unsigned)e, m);
        }
    }
    m = round_to(c, sign, exp, sig, p, 0x7FFF, &e);
    return pack(sign, (unsigned)e, m);
}

/* What two operands of which at least one is not a number give: the
 * NaN with the larger significand, made quiet. A signalling NaN and an
 * unsupported format are invalid operations. */
static m86f80 nan2(m86fctx *c, m86f80 a, m86f80 b)
{
    int ka = m86f_class(a), kb = m86f_class(b);
    if (ka == FC_UNSUPPORTED || kb == FC_UNSUPPORTED) {
        c->fl |= FX_I;
        return f_indef;
    }
    if (ka == FC_SNAN || kb == FC_SNAN)
        c->fl |= FX_I;
    m86f80 r;
    if (!is_nan(kb))
        r = a;
    else if (!is_nan(ka))
        r = b;
    else if (ka != kb)
        r = ka == FC_QNAN ? a : b;      /* the quiet one of the two */
    else if (a.m != b.m)
        r = a.m > b.m ? a : b;          /* the larger significand */
    else
        r = (a.se & 0x8000) ? b : a;    /* the same: the positive one */
    r.m |= QUIET;
    return r;
}

static int special(int ka, int kb)
{
    return is_nan(ka) || is_nan(kb) || ka == FC_UNSUPPORTED || kb == FC_UNSUPPORTED;
}

static void denormals(m86fctx *c, int ka, int kb)
{
    if (ka == FC_DENORMAL || kb == FC_DENORMAL)
        c->fl |= FX_D;
}

static m86f80 addsub(m86fctx *c, m86f80 a, m86f80 b, int sub)
{
    int ka = m86f_class(a), kb = m86f_class(b);
    if (special(ka, kb))
        return nan2(c, a, b);
    if (sub)
        b.se ^= 0x8000;
    int sa = a.se >> 15, sb = b.se >> 15;
    if (ka == FC_INF || kb == FC_INF) {
        if (ka == FC_INF && kb == FC_INF && sa != sb) {
            c->fl |= FX_I;
            return f_indef;
        }
        denormals(c, ka, kb);
        return ka == FC_INF ? a : b;
    }
    denormals(c, ka, kb);
    if (ka == FC_ZERO && kb == FC_ZERO)
        return pack(sa == sb ? sa : c->rc == 1, 0, 0);
    int ea = 0, eb = 0;
    uint64_t ma = 0, mb = 0;
    if (ka != FC_ZERO) unpack(a, &sa, &ea, &ma);
    if (kb != FC_ZERO) unpack(b, &sb, &eb, &mb);
    if (ka == FC_ZERO)
        return round_pack(c, sb, eb, (u128)mb << 64);
    if (kb == FC_ZERO)
        return round_pack(c, sa, ea, (u128)ma << 64);
    /* The significands with a spare bit above and 63 below. */
    u128 xa = (u128)ma << 63, xb = (u128)mb << 63;
    int e;
    if (ea >= eb) { xb = shr_jam(xb, ea - eb); e = ea; }
    else          { xa = shr_jam(xa, eb - ea); e = eb; }
    u128 r;
    int sign;
    if (sa == sb) {
        r = xa + xb;
        sign = sa;
    } else if (xa >= xb) {
        r = xa - xb;
        sign = sa;
    } else {
        r = xb - xa;
        sign = sb;
    }
    if (r == 0)
        return pack(c->rc == 1, 0, 0);
    /* Put the top bit at 127: the exponent was for a top bit at 126. */
    int s = (r >> 64) ? __builtin_clzll((uint64_t)(r >> 64))
                      : 64 + __builtin_clzll((uint64_t)r);
    r <<= s;
    return round_pack(c, sign, e + 1 - s, r);
}

m86f80 m86f_add(m86fctx *c, m86f80 a, m86f80 b) { return addsub(c, a, b, 0); }
m86f80 m86f_sub(m86fctx *c, m86f80 a, m86f80 b) { return addsub(c, a, b, 1); }

m86f80 m86f_mul(m86fctx *c, m86f80 a, m86f80 b)
{
    int ka = m86f_class(a), kb = m86f_class(b);
    if (special(ka, kb))
        return nan2(c, a, b);
    int sign = (a.se ^ b.se) >> 15;
    if (ka == FC_INF || kb == FC_INF) {
        if (ka == FC_ZERO || kb == FC_ZERO) {
            c->fl |= FX_I;
            return f_indef;
        }
        denormals(c, ka, kb);
        return pack(sign, 0x7FFF, INTBIT);
    }
    denormals(c, ka, kb);
    if (ka == FC_ZERO || kb == FC_ZERO)
        return pack(sign, 0, 0);
    int sa, sb, ea, eb;
    uint64_t ma, mb;
    unpack(a, &sa, &ea, &ma);
    unpack(b, &sb, &eb, &mb);
    u128 p = (u128)ma * mb;
    int e = ea + eb - BIAS + 1;
    if (!(p >> 127)) {
        p <<= 1;
        e--;
    }
    return round_pack(c, sign, e, p);
}

m86f80 m86f_div(m86fctx *c, m86f80 a, m86f80 b)
{
    int ka = m86f_class(a), kb = m86f_class(b);
    if (special(ka, kb))
        return nan2(c, a, b);
    int sign = (a.se ^ b.se) >> 15;
    if (ka == FC_INF) {
        if (kb == FC_INF) {
            c->fl |= FX_I;
            return f_indef;
        }
        denormals(c, ka, kb);
        return pack(sign, 0x7FFF, INTBIT);
    }
    if (kb == FC_INF) {
        denormals(c, ka, kb);
        return pack(sign, 0, 0);
    }
    if (kb == FC_ZERO) {
        if (ka == FC_ZERO) {
            c->fl |= FX_I;
            return f_indef;
        }
        c->fl |= FX_Z;                  /* (and not the denormal flag) */
        return pack(sign, 0x7FFF, INTBIT);
    }
    denormals(c, ka, kb);
    if (ka == FC_ZERO)
        return pack(sign, 0, 0);
    int sa, sb, ea, eb;
    uint64_t ma, mb;
    unpack(a, &sa, &ea, &ma);
    unpack(b, &sb, &eb, &mb);
    int e = ea - eb + BIAS;
    u128 n = (u128)ma << 63;
    if (ma < mb) {
        n <<= 1;
        e--;
    }
    uint64_t q = (uint64_t)(n / mb), r = (uint64_t)(n % mb);
    u128 n2 = (u128)r << 64;
    uint64_t q2 = (uint64_t)(n2 / mb);
    if (n2 % mb)
        q2 |= 1;
    return round_pack(c, sign, e, ((u128)q << 64) | q2);
}

m86f80 m86f_sqrt(m86fctx *c, m86f80 a)
{
    int ka = m86f_class(a);
    if (is_nan(ka) || ka == FC_UNSUPPORTED)
        return nan2(c, a, a);
    if (ka == FC_ZERO)
        return a;
    if (a.se & 0x8000) {
        c->fl |= FX_I;
        return f_indef;
    }
    if (ka == FC_INF)
        return a;
    if (ka == FC_DENORMAL)
        c->fl |= FX_D;
    int s, e;
    uint64_t m;
    unpack(a, &s, &e, &m);
    int t = e - BIAS;                   /* the value is (m / 2^63) * 2^t */
    u128 n = (u128)m << 63;
    if (t & 1) {
        n <<= 1;
        t--;
    }
    /* The integer square root of n, 64 bits with the top bit set. */
    uint64_t r = 0;
    for (int bit = 63; bit >= 0; bit--) {
        uint64_t x = r | ((uint64_t)1 << bit);
        if ((u128)x * x <= n)
            r = x;
    }
    u128 rem = n - (u128)r * r;
    /* Half a unit more is r + 1/2, whose square is r^2 + r + 1/4. */
    uint64_t lo = rem > r ? 0xC000000000000000ull : (rem != 0);
    return round_pack(c, 0, t / 2 + BIAS, ((u128)r << 64) | lo);
}

/* To an integer, by the rounding in force. *inexact and *up say what
 * happened; the magnitude comes back (meaningless at 2^64 and over:
 * *big). */
static uint64_t to_integer(m86fctx *c, int sign, int exp, uint64_t m, int *big)
{
    int t = exp - BIAS;                 /* the value is (m / 2^63) * 2^t */
    *big = 0;
    if (t >= 64) {
        *big = 1;
        return 0;
    }
    u128 v = (u128)m << 64;             /* m.0, to be shifted right by 63 - t */
    v = shr_jam(v, 63 - t);
    uint64_t i = (uint64_t)(v >> 64), frac = (uint64_t)v;
    int up = 0;
    switch (c->rc) {
    case 0: up = frac > INTBIT || (frac == INTBIT && (i & 1)); break;
    case 1: up = frac && sign; break;
    case 2: up = frac && !sign; break;
    default: break;
    }
    if (frac) {
        c->fl |= FX_P;
        if (up) c->fl |= FX_C1;
    }
    if (up && ++i == 0)
        *big = 1;
    return i;
}

m86f80 m86f_rndint(m86fctx *c, m86f80 a)
{
    int ka = m86f_class(a);
    if (is_nan(ka) || ka == FC_UNSUPPORTED)
        return nan2(c, a, a);
    if (ka == FC_ZERO || ka == FC_INF)
        return a;
    if (ka == FC_DENORMAL)
        c->fl |= FX_D;
    int s, e, big;
    uint64_t m;
    unpack(a, &s, &e, &m);
    if (e - BIAS >= 63)
        return a;                       /* an integer already */
    unsigned f0 = c->fl;
    uint64_t i = to_integer(c, s, e, m, &big);
    (void)f0;
    if (i == 0)
        return pack(s, 0, 0);
    int sh = __builtin_clzll(i);
    return pack(s, (unsigned)(BIAS + 63 - sh), i << sh);
}

m86f80 m86f_from_i64(int64_t v)
{
    if (v == 0)
        return pack(0, 0, 0);
    int sign = v < 0;
    uint64_t m = sign ? (uint64_t)0 - (uint64_t)v : (uint64_t)v;
    int sh = __builtin_clzll(m);
    return pack(sign, (unsigned)(BIAS + 63 - sh), m << sh);
}

int64_t m86f_to_int(m86fctx *c, m86f80 a, int bits)
{
    int64_t indef = (int64_t)((uint64_t)1 << (bits - 1));
    if (bits < 64)
        indef = -indef;                 /* (8000h, 80000000h, sign-extended) */
    int ka = m86f_class(a);
    if (ka == FC_ZERO)
        return 0;
    if (is_nan(ka) || ka == FC_UNSUPPORTED || ka == FC_INF) {
        c->fl |= FX_I;
        return indef;
    }
    int s, e, big;
    uint64_t m;
    unpack(a, &s, &e, &m);
    unsigned f0 = c->fl;
    uint64_t i = to_integer(c, s, e, m, &big);
    uint64_t lim = (uint64_t)1 << (bits - 1);
    if (big || i > lim || (i == lim && !s)) {
        c->fl = f0 | FX_I;              /* (not inexact as well) */
        return indef;
    }
    return s ? (int64_t)((uint64_t)0 - i) : (int64_t)i;
}

m86f80 m86f_from_f32(m86fctx *c, uint32_t v)
{
    int sign = v >> 31, e = (v >> 23) & 0xFF;
    uint64_t f = (uint64_t)(v & 0x7FFFFF) << 40;
    if (e == 0xFF) {
        if (f && !(f & QUIET))
            c->fl |= FX_I;
        return pack(sign, 0x7FFF, INTBIT | f | (f ? QUIET : 0));
    }
    if (e == 0) {
        if (!f)
            return pack(sign, 0, 0);
        c->fl |= FX_D;
        int sh = __builtin_clzll(f);
        return pack(sign, (unsigned)(BIAS - 126 - sh), f << sh);
    }
    return pack(sign, (unsigned)(e - 127 + BIAS), INTBIT | f);
}

m86f80 m86f_from_f64(m86fctx *c, uint64_t v)
{
    int sign = (int)(v >> 63), e = (int)((v >> 52) & 0x7FF);
    uint64_t f = (v & 0xFFFFFFFFFFFFFull) << 11;
    if (e == 0x7FF) {
        if (f && !(f & QUIET))
            c->fl |= FX_I;
        return pack(sign, 0x7FFF, INTBIT | f | (f ? QUIET : 0));
    }
    if (e == 0) {
        if (!f)
            return pack(sign, 0, 0);
        c->fl |= FX_D;
        int sh = __builtin_clzll(f);
        return pack(sign, (unsigned)(BIAS - 1022 - sh), f << sh);
    }
    return pack(sign, (unsigned)(e - 1023 + BIAS), INTBIT | f);
}

/* To a narrower format: p bits, exponent bias b, all-ones field emax. */
static uint64_t narrow(m86fctx *c, m86f80 a, int p, int b, int emax, int *sign, int *eout)
{
    int ka = m86f_class(a);
    *sign = a.se >> 15;
    if (ka == FC_ZERO) {
        *eout = 0;
        return 0;
    }
    if (ka == FC_UNSUPPORTED) {
        c->fl |= FX_I;
        *sign = 1;
        *eout = emax;
        return 0xC000000000000000ull;
    }
    if (ka == FC_INF) {
        *eout = emax;
        return INTBIT;
    }
    if (is_nan(ka)) {
        if (ka == FC_SNAN)
            c->fl |= FX_I;
        *eout = emax;
        return a.m | QUIET;
    }
    int s, e;
    uint64_t m;
    unpack(a, &s, &e, &m);
    return round_to(c, s, e - BIAS + b, (u128)m << 64, p, emax, eout);
}

uint32_t m86f_to_f32(m86fctx *c, m86f80 a)
{
    int sign, e;
    uint64_t m = narrow(c, a, 24, 127, 0xFF, &sign, &e);
    return ((uint32_t)sign << 31) | ((uint32_t)e << 23) | ((uint32_t)(m >> 40) & 0x7FFFFF);
}

uint64_t m86f_to_f64(m86fctx *c, m86f80 a)
{
    int sign, e;
    uint64_t m = narrow(c, a, 53, 1023, 0x7FF, &sign, &e);
    return ((uint64_t)sign << 63) | ((uint64_t)e << 52) | ((m >> 11) & 0xFFFFFFFFFFFFFull);
}

unsigned m86f_cmp(m86fctx *c, m86f80 a, m86f80 b, int quiet)
{
    int ka = m86f_class(a), kb = m86f_class(b);
    if (special(ka, kb)) {
        if (!quiet || ka == FC_SNAN || kb == FC_SNAN ||
            ka == FC_UNSUPPORTED || kb == FC_UNSUPPORTED)
            c->fl |= FX_I;
        return 0x4500;
    }
    denormals(c, ka, kb);
    int sa = a.se >> 15, sb = b.se >> 15;
    if (ka == FC_ZERO && kb == FC_ZERO)
        return 0x4000;
    if (ka == FC_ZERO)
        return sb ? 0 : 0x0100;
    if (kb == FC_ZERO)
        return sa ? 0x0100 : 0;
    if (sa != sb)
        return sa ? 0x0100 : 0;
    int ea = 0x7FFF, eb = 0x7FFF, x;
    uint64_t ma = INTBIT, mb = INTBIT;
    if (ka != FC_INF) unpack(a, &x, &ea, &ma);
    if (kb != FC_INF) unpack(b, &x, &eb, &mb);
    int gt = ea != eb ? ea > eb : ma > mb;
    if (ea == eb && ma == mb)
        return 0x4000;
    return (gt != sa) ? 0 : 0x0100;
}

/* ---- remainder, scale, extract, decimal ---- */

#define CC0 0x0100u
#define CC1 0x0200u
#define CC2 0x0400u
#define CC3 0x4000u

/* A pseudo-denormal (exponent field 0, top bit set) as the number it is. */
static m86f80 canon(m86f80 a)
{
    if (!(a.se & 0x7FFF) && (a.m & INTBIT))
        a.se |= 1;
    return a;
}

m86f80 m86f_prem(m86fctx *c, m86f80 a, m86f80 b, int ieee, unsigned *cc)
{
    int ka = m86f_class(a), kb = m86f_class(b);
    *cc = 0;
    if (special(ka, kb))
        return nan2(c, a, b);
    if (ka == FC_INF || kb == FC_ZERO) {
        c->fl |= FX_I;
        return f_indef;
    }
    denormals(c, ka, kb);
    if (ka == FC_ZERO || kb == FC_INF)
        return canon(a);
    int sa, sb, ea, eb;
    uint64_t ma, mb;
    unpack(a, &sa, &ea, &ma);
    unpack(b, &sb, &eb, &mb);
    int d = ea - eb, e;
    if (d < (ieee ? -1 : 0)) {
        /* Smaller than the divisor (than half of it): as it is. (A
         * pseudo-denormal comes back as the denormal it stands for.) */
        (void)e;
        return canon(a);
    }
    /* Long division, a quotient bit a step: all of it if the exponents
     * are less than 64 apart, else a part (and C2 says to come again). */
    int part = d >= 64, steps = part ? 32 + (d & 31) : d;
    u128 r = ma;
    uint64_t q = 0;
    if (steps < 0) {
        /* (FPREM1 with the dividend below the divisor by one in the
         * exponent: the quotient is 0 or 1, by rounding.) */
        r = ma; steps = 0;
        /* a is ma * 2^-1 against mb: twice the remainder is ma. */
        if ((u128)ma > mb) {            /* over half: round up to 1 */
            /* a - b: (ma/2 - mb), negative */
            u128 x = ((u128)mb << 1) - ma;      /* 2 (b - a), exact */
            uint64_t m;
            int s = 0;
            while (!(x >> 127)) { x <<= 1; s++; }
            m = round_to(c, !sa, eb + 63 - s, x, 64, 0x7FFF, &e);
            *cc = CC1;
            return pack(!sa, (unsigned)e, m);
        }
        return canon(a);
    }
    for (int i = 0; ; i++) {
        q <<= 1;
        if (r >= mb) {
            r -= mb;
            q |= 1;
        }
        if (i == steps)
            break;
        r <<= 1;
    }
    int sign = sa;
    if (part)
        *cc = CC2;
    else {
        if (ieee) {
            u128 r2 = r << 1;
            if (r2 > mb || (r2 == mb && (q & 1))) {
                q++;
                r = mb - r;
                sign = !sa;
            }
        }
        *cc = ((q & 4) ? CC0 : 0) | ((q & 2) ? CC3 : 0) | ((q & 1) ? CC1 : 0);
    }
    if (r == 0)
        return pack(sa, 0, 0);
    /* r is at the divisor's scale after the last step. */
    int s = __builtin_clzll((uint64_t)r);
    uint64_t m = round_to(c, sign, ea - steps - s, (u128)((uint64_t)r << s) << 64, 64, 0x7FFF, &e);
    return pack(sign, (unsigned)e, m);
}

m86f80 m86f_scale(m86fctx *c, m86f80 a, m86f80 b)
{
    int ka = m86f_class(a), kb = m86f_class(b);
    if (special(ka, kb))
        return nan2(c, a, b);
    int sa = a.se >> 15, sb = b.se >> 15;
    if (kb == FC_INF) {
        /* 2^inf and 2^-inf. */
        if ((ka == FC_ZERO && !sb) || (ka == FC_INF && sb)) {
            c->fl |= FX_I;
            return f_indef;
        }
        denormals(c, ka, kb);
        return sb ? pack(sa, 0, 0) : pack(sa, 0x7FFF, INTBIT);
    }
    denormals(c, ka, kb);
    if (ka == FC_ZERO || ka == FC_INF)
        return a;
    int ea, eb, x;
    uint64_t ma, mb;
    unpack(a, &x, &ea, &ma);
    long n = 0;
    if (kb != FC_ZERO) {
        unpack(b, &x, &eb, &mb);
        int t = eb - BIAS;
        if (t >= 16)
            n = 0x10000;                /* (more than any exponent) */
        else if (t >= 0)
            n = (long)(mb >> (63 - t));
        if (sb)
            n = -n;
    }
    if (kb == FC_ZERO)
        return canon(a);
    long e = ea + n;
    if (e > 0x10000) e = 0x10000;
    if (e < -0x10000) e = -0x10000;
    /* (To 64 bits whatever the precision control says.) */
    m86fctx c2 = { c->rc, 3, 0, c->um };
    m86f80 r = round_pack(&c2, sa, (int)e, (u128)ma << 64);
    c->fl |= c2.fl;
    return r;
}

m86f80 m86f_xtract(m86fctx *c, m86f80 a, m86f80 *sig)
{
    int ka = m86f_class(a), sa = a.se >> 15;
    if (is_nan(ka) || ka == FC_UNSUPPORTED) {
        *sig = nan2(c, a, a);
        return *sig;
    }
    if (ka == FC_ZERO) {
        c->fl |= FX_Z;
        *sig = a;
        return pack(1, 0x7FFF, INTBIT);
    }
    if (ka == FC_INF) {
        *sig = a;
        return pack(0, 0x7FFF, INTBIT);
    }
    if (ka == FC_DENORMAL)
        c->fl |= FX_D;
    int s, e;
    uint64_t m;
    unpack(a, &s, &e, &m);
    *sig = pack(sa, BIAS, m);
    return m86f_from_i64(e - BIAS);
}

m86f80 m86f_from_bcd(const uint8_t *p)
{
    uint64_t v = 0;
    for (int i = 8; i >= 0; i--)
        v = v * 100 + (uint64_t)((p[i] >> 4) * 10 + (p[i] & 15));
    m86f80 r = m86f_from_i64((int64_t)v);
    if (p[9] & 0x80)
        r.se |= 0x8000;
    return r;
}

void m86f_to_bcd(m86fctx *c, m86f80 a, uint8_t *p)
{
    int ka = m86f_class(a), big = 1, s = a.se >> 15, e;
    uint64_t m, i = 0;
    unsigned f0 = c->fl;
    if (ka == FC_ZERO)
        big = 0;
    else if (ka == FC_NORMAL || ka == FC_DENORMAL) {
        unpack(a, &s, &e, &m);
        i = to_integer(c, s, e, m, &big);
        if (i > 999999999999999999ull)
            big = 1;
    }
    if (big) {
        static const uint8_t indef[10] = { 0, 0, 0, 0, 0, 0, 0, 0xC0, 0xFF, 0xFF };
        c->fl = f0 | FX_I;
        for (int k = 0; k < 10; k++)
            p[k] = indef[k];
        return;
    }
    for (int k = 0; k < 9; k++) {
        unsigned d = (unsigned)(i % 100);
        p[k] = (uint8_t)(((d / 10) << 4) | (d % 10));
        i /= 100;
    }
    p[9] = s ? 0x80 : 0;
}

/* ---- transcendental functions ---- */

#include "m86fconst.h"

static const m86f80 f_one = { INTBIT, BIAS };

/* The steps these are made of: to nearest, 64 bits, flags not kept. */
static m86f80 t_add(m86f80 a, m86f80 b) { m86fctx x = { 0, 3, 0, 0 }; return m86f_add(&x, a, b); }
static m86f80 t_sub(m86f80 a, m86f80 b) { m86fctx x = { 0, 3, 0, 0 }; return m86f_sub(&x, a, b); }
static m86f80 t_mul(m86f80 a, m86f80 b) { m86fctx x = { 0, 3, 0, 0 }; return m86f_mul(&x, a, b); }
static m86f80 t_div(m86f80 a, m86f80 b) { m86fctx x = { 0, 3, 0, 0 }; return m86f_div(&x, a, b); }

/* k[n-1] + ... : ((k[n-1] z + k[n-2]) z + ...) z + k[0]. */
static m86f80 poly(m86f80 z, const m86f80 *k, int n)
{
    m86f80 p = k[n - 1];
    for (int i = n - 2; i >= 0; i--)
        p = t_add(t_mul(p, z), k[i]);
    return p;
}

/* The final result: rounded as the control word says, always inexact. */
static m86f80 t_final(m86fctx *c, m86f80 v)
{
    static const m86f80 zero = { 0, 0 };
    if (m86f_class(v) == FC_ZERO)
        return v;
    c->fl |= FX_P;
    return m86f_add(c, v, zero);
}

static m86f80 f_neg(m86f80 a) { a.se ^= 0x8000; return a; }
static m86f80 f_abs(m86f80 a) { a.se &= 0x7FFF; return a; }

/* sin and cos of r, |r| <= pi/4 (or a little over). */
static m86f80 k_sin(m86f80 r)
{
    m86f80 z = t_mul(r, r);
    return t_add(r, t_mul(t_mul(r, z), poly(z, K_SIN, 10)));
}

static m86f80 k_cos(m86f80 r)
{
    m86f80 z = t_mul(r, r), h = z;
    if (m86f_class(h) != FC_ZERO)
        h.se--;                         /* z / 2 */
    return t_add(t_sub(f_one, h), t_mul(t_mul(z, z), poly(z, K_COS, 10)));
}

int m86f_sincos(m86fctx *c, m86f80 a, m86f80 *s, m86f80 *co)
{
    int ka = m86f_class(a);
    if (is_nan(ka) || ka == FC_UNSUPPORTED) {
        *s = *co = nan2(c, a, a);
        return 0;
    }
    if (ka == FC_INF) {
        c->fl |= FX_I;
        *s = *co = f_indef;
        return 0;
    }
    if (ka == FC_ZERO) {
        *s = a;
        *co = f_one;
        return 0;
    }
    if (ka == FC_DENORMAL)
        c->fl |= FX_D;
    if ((a.se & 0x7FFF) >= BIAS + 63)
        return 1;
    if ((a.se & 0x7FFF) < BIAS - 34) {
        /* x and 1 to more than 64 bits. */
        c->fl |= FX_P;
        *s = t_final(c, a);
        *co = f_one;
        return 0;
    }
    /* r = x - n pi/2, n the nearest integer to x * 2/pi. */
    m86fctx x = { 0, 3, 0, 0 };
    int64_t n = m86f_to_int(&x, t_mul(a, K_2OPI), 64);
    m86f80 fn = m86f_from_i64(n), r = a;
    if (n) {
        r = t_sub(a, t_mul(fn, K_PIO2_1));
        r = t_sub(r, t_mul(fn, K_PIO2_2));
        r = t_sub(r, t_mul(fn, K_PIO2_3));
    }
    m86f80 sr = k_sin(r), cr = k_cos(r);
    switch (n & 3) {
    case 0: *s = sr;        *co = cr;        break;
    case 1: *s = cr;        *co = f_neg(sr); break;
    case 2: *s = f_neg(sr); *co = f_neg(cr); break;
    default: *s = f_neg(cr); *co = sr;       break;
    }
    *s = t_final(c, *s);
    *co = t_final(c, *co);
    return 0;
}

/* atan of t, 0 <= t <= 1, in two parts (the larger first). */
static m86f80 k_atan(m86f80 t, m86f80 *lo)
{
    m86fctx x = { 0, 3, 0, 0 };
    m86f80 sixteen = { INTBIT, BIAS + 4 };
    int k = (int)m86f_to_int(&x, t_mul(t, sixteen), 16);
    m86f80 u = t;
    if (k) {
        m86f80 cc = m86f_from_i64(k);
        cc.se -= 4;                     /* k / 16 */
        u = t_div(t_sub(t, cc), t_add(f_one, t_mul(t, cc)));
    }
    *lo = t_mul(u, poly(t_mul(u, u), K_ATAN, 8));
    return K_ATANT[k];
}

m86f80 m86f_atan2(m86fctx *c, m86f80 y, m86f80 x)
{
    int ky = m86f_class(y), kx = m86f_class(x);
    if (special(ky, kx))
        return nan2(c, y, x);           /* (y is the destination: ST(1)) */
    int sy = y.se >> 15, sx = x.se >> 15;
    denormals(c, ky, kx);
    m86f80 hi, lo;
    static const m86f80 zero = { 0, 0 };
    if (ky == FC_ZERO) {
        if (!sx)
            return y;                   /* (also for 0, 0) */
        hi = K_PI_HI; lo = K_PI_LO;
    } else if (kx == FC_ZERO || (ky == FC_INF && kx != FC_INF)) {
        hi = K_PIO2_HI; lo = K_PIO2_LO;
    } else if (ky == FC_INF) {          /* both infinite */
        hi = sx ? K_3PIO4_HI : K_PIO4_HI;
        lo = sx ? K_3PIO4_LO : K_PIO4_LO;
    } else if (kx == FC_INF) {
        if (!sx)
            return pack(sy, 0, 0);
        hi = K_PI_HI; lo = K_PI_LO;
    } else {
        m86f80 ay = f_abs(y), ax = f_abs(x), l2;
        m86fctx q = { 0, 3, 0, 0 };
        int swap = (m86f_cmp(&q, ay, ax, 1) == 0);      /* |y| > |x| */
        m86f80 t = swap ? t_div(ax, ay) : t_div(ay, ax);
        hi = k_atan(t, &l2);
        lo = l2;
        if (swap) {                     /* pi/2 - atan */
            hi = t_sub(K_PIO2_HI, hi);
            lo = t_sub(K_PIO2_LO, lo);
        }
        if (sx) {                       /* pi - that */
            hi = t_sub(K_PI_HI, hi);
            lo = t_sub(K_PI_LO, lo);
        }
        if (m86f_class(hi) == FC_ZERO && m86f_class(lo) == FC_ZERO) {
            /* (The quotient underflowed to nothing.) */
            c->fl |= FX_U | FX_P;
            return pack(sy, 0, 0);
        }
    }
    (void)zero;
    m86f80 r = t_add(hi, lo);
    if (sy)
        r = f_neg(r);
    return t_final(c, r);
}

m86f80 m86f_2xm1(m86fctx *c, m86f80 a)
{
    int ka = m86f_class(a);
    if (is_nan(ka) || ka == FC_UNSUPPORTED)
        return nan2(c, a, a);
    if (ka == FC_ZERO)
        return a;
    if (ka == FC_INF)
        return (a.se & 0x8000) ? f_neg(f_one) : a;
    if (ka == FC_DENORMAL)
        c->fl |= FX_D;
    m86f80 z = t_mul(a, K_LN2);
    /* e^z - 1 = z + z^2 (1/2 + z/6 + ...). */
    m86f80 r = t_add(z, t_mul(t_mul(z, z), poly(z, K_EXP, 22)));
    if (m86f_class(r) == FC_DENORMAL || m86f_class(r) == FC_ZERO) {
        c->fl |= FX_U | FX_P;
        return r;
    }
    return t_final(c, r);
}

/* ln of ((1 + s) / (1 - s)) = 2 s (1 + s^2/3 + s^4/5 + ...), as log2. */
static m86f80 k_log2s(m86f80 s)
{
    m86f80 l = t_mul(s, poly(t_mul(s, s), K_LOG, 14));
    if (m86f_class(l) != FC_ZERO)
        l.se++;
    return t_mul(l, K_L2E);
}

m86f80 m86f_yl2x(m86fctx *c, m86f80 x, m86f80 y)
{
    int kx = m86f_class(x), ky = m86f_class(y);
    if (special(kx, ky))
        return nan2(c, y, x);
    m86f80 lg;
    if (kx == FC_ZERO) {
        if (ky == FC_ZERO) {
            c->fl |= FX_I;
            return f_indef;
        }
        if (ky != FC_INF)
            c->fl |= FX_Z;
        return pack(!(y.se >> 15), 0x7FFF, INTBIT);
    }
    if (x.se & 0x8000) {
        c->fl |= FX_I;
        return f_indef;
    }
    denormals(c, kx, ky);
    if (kx == FC_INF)
        lg = x;
    else {
        int s, e;
        uint64_t m;
        unpack(x, &s, &e, &m);
        e -= BIAS;
        if (m > 0xB504F333F9DE6484ull)  /* over the square root of 2: halve */
            e++;
        m86f80 f = pack(0, (unsigned)(BIAS + (m > 0xB504F333F9DE6484ull ? -1 : 0)), m);
        m86f80 l = k_log2s(t_div(t_sub(f, f_one), t_add(f, f_one)));
        lg = e ? t_add(m86f_from_i64(e), l) : l;
        if (m86f_class(lg) == FC_ZERO) {
            /* x is one: y times nothing. */
            if (ky == FC_INF) {
                c->fl |= FX_I;
                return f_indef;
            }
            return pack(y.se >> 15, 0, 0);
        }
    }
    unsigned f0 = c->fl;
    m86f80 r = m86f_mul(c, y, lg);
    if (m86f_class(r) == FC_NORMAL || m86f_class(r) == FC_DENORMAL)
        c->fl |= FX_P;
    (void)f0;
    return r;
}

m86f80 m86f_yl2xp1(m86fctx *c, m86f80 x, m86f80 y)
{
    int kx = m86f_class(x), ky = m86f_class(y);
    if (special(kx, ky))
        return nan2(c, y, x);
    denormals(c, kx, ky);
    m86f80 lg;
    if (kx == FC_ZERO || kx == FC_INF)
        lg = x;
    else {
        m86f80 two = { INTBIT, BIAS + 1 };
        lg = k_log2s(t_div(x, t_add(two, x)));
    }
    m86f80 r = m86f_mul(c, y, lg);
    if (m86f_class(r) == FC_NORMAL || m86f_class(r) == FC_DENORMAL)
        c->fl |= FX_P;
    return r;
}

m86f80 m86f_const(m86fctx *c, int which)
{
    static const m86f80 zero = { 0, 0 };
    int dn = (c->rc == 1 || c->rc == 3);
    m86f80 r;
    switch (which) {
    case 0: return f_one;
    case 1:
        r = K_L2T;                      /* (the one that is rounded down to nearest) */
        if (c->rc == 2) r.m++;
        return r;
    case 2: return dn ? K_L2E_DN : K_L2E;
    case 3: return dn ? K_PI_DN : K_PI;
    case 4: return dn ? K_LG2_DN : K_LG2;
    case 5: return dn ? K_LN2_DN : K_LN2;
    default: return zero;
    }
}
