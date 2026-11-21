/*
 * m86fpu.h: x87 arithmetic for the model (docs/fpu.md).
 *
 * The numbers are the 80-bit extended format: a sign and 15-bit
 * exponent, and a 64-bit significand with its integer bit explicit.
 * Every operation takes the control word's rounding and precision
 * fields and gives back the exception flags it raises, as the masked
 * response of a 387 (and a 486's FPU) does.
 *
 * Checked against the x87 of the machine the tests run on: sim/fputest.c.
 */
#ifndef M86FPU_H
#define M86FPU_H

#include <stdint.h>

typedef struct {
    uint64_t m;         /* significand, integer bit at bit 63 */
    uint16_t se;        /* sign (bit 15) and exponent */
} m86f80;

/* Exception flags, as in the status word. */
#define FX_I    0x01    /* invalid operation */
#define FX_D    0x02    /* denormal operand */
#define FX_Z    0x04    /* divide by zero */
#define FX_O    0x08    /* overflow */
#define FX_U    0x10    /* underflow */
#define FX_P    0x20    /* precision (inexact) */
#define FX_C1   0x200   /* the result was rounded up (status word's C1) */

/* What an operation is told and tells. */
typedef struct {
    int      rc;        /* rounding: 0 nearest, 1 down, 2 up, 3 toward zero */
    int      pc;        /* precision: 0 24 bits, 2 53 bits, 1 and 3 64 bits */
    unsigned fl;        /* flags raised (FX_*), OR-ed in */
    unsigned um;        /* FX_O, FX_U: not masked, so the result comes with
                         * its exponent moved by 24576 instead (and
                         * underflow is flagged whether or not it is exact) */
} m86fctx;

m86f80 m86f_add(m86fctx *c, m86f80 a, m86f80 b);
m86f80 m86f_sub(m86fctx *c, m86f80 a, m86f80 b);       /* a - b */
m86f80 m86f_mul(m86fctx *c, m86f80 a, m86f80 b);
m86f80 m86f_div(m86fctx *c, m86f80 a, m86f80 b);       /* a / b */
m86f80 m86f_sqrt(m86fctx *c, m86f80 a);
m86f80 m86f_rndint(m86fctx *c, m86f80 a);

/* Conversions. A result that does not fit is the "indefinite" integer
 * (the most negative), with FX_I. */
m86f80   m86f_from_i64(int64_t v);
int64_t  m86f_to_int(m86fctx *c, m86f80 a, int bits);  /* 16, 32 or 64 */
m86f80   m86f_from_f32(m86fctx *c, uint32_t v);
m86f80   m86f_from_f64(m86fctx *c, uint64_t v);
uint32_t m86f_to_f32(m86fctx *c, m86f80 a);
uint64_t m86f_to_f64(m86fctx *c, m86f80 a);

/* Comparison: the status word's C3, C2, C0 as bits 14, 10, 8 (unordered
 * is all three). quiet: a quiet NaN is not an invalid operation (FUCOM). */
unsigned m86f_cmp(m86fctx *c, m86f80 a, m86f80 b, int quiet);

/* Partial remainder (FPREM; ieee: FPREM1). *cc: C0, C1, C2, C3 as in the
 * status word (C2: not finished). */
m86f80 m86f_prem(m86fctx *c, m86f80 a, m86f80 b, int ieee, unsigned *cc);
m86f80 m86f_scale(m86fctx *c, m86f80 a, m86f80 b);     /* a * 2^trunc(b) */
/* FXTRACT: the exponent as a number; *sig: the significand. */
m86f80 m86f_xtract(m86fctx *c, m86f80 a, m86f80 *sig);
/* Packed decimal: ten bytes, 18 digits and a sign. */
m86f80 m86f_from_bcd(const uint8_t *p);
void   m86f_to_bcd(m86fctx *c, m86f80 a, uint8_t *p);

/* The transcendental functions. These are this project's own: sequences
 * of the operations above with fixed constants (docs/fpu.md), so that
 * hardware doing the same sequence gets the same bits. They are within
 * a few units in the last place of the true value, as a 387's are, but
 * are not any real chip's bits. sincos: nonzero, and nothing done, when
 * the operand is too large (C2). */
int    m86f_sincos(m86fctx *c, m86f80 a, m86f80 *s, m86f80 *co);
m86f80 m86f_atan2(m86fctx *c, m86f80 y, m86f80 x);
m86f80 m86f_2xm1(m86fctx *c, m86f80 a);
m86f80 m86f_yl2x(m86fctx *c, m86f80 x, m86f80 y);      /* y * log2(x) */
m86f80 m86f_yl2xp1(m86fctx *c, m86f80 x, m86f80 y);    /* y * log2(1 + x) */
/* FLD1 ... FLDZ: which = 0 one, 1 log2(10), 2 log2(e), 3 pi, 4 log10(2), 5 ln(2), 6 zero. */
m86f80 m86f_const(m86fctx *c, int which);

/* The class of a number. */
enum { FC_ZERO, FC_DENORMAL, FC_NORMAL, FC_INF, FC_QNAN, FC_SNAN, FC_UNSUPPORTED };
int m86f_class(m86f80 a);

#endif
