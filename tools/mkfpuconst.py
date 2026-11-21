#!/usr/bin/env python3
"""The constants of the x87 model's transcendental functions (sim/m86fpu.c):
written once into that file's table; kept so the table can be checked or
made again.  Everything is worked out here with integers (no library's
floating point), to 256 bits, and rounded to nearest.

usage: mkfpuconst.py > sim/m86fconst.h
"""
from fractions import Fraction as F

BITS = 300
ONE = 1 << BITS

def atan_inv(n):                    # atan(1/n) * ONE
    s, t, k, n2 = 0, ONE // n, 0, n * n
    while t:
        s += t // (2 * k + 1) * (-1 if k & 1 else 1)
        t //= n2
        k += 1
    return s

PI = 4 * (4 * atan_inv(5) - atan_inv(239))

def ln_frac(x):                     # ln(x) * ONE for a Fraction x > 0, by atanh
    s = F(x - 1, x + 1)
    num, den = s.numerator, s.denominator
    t = ONE * num // den
    tot, k = 0, 0
    while t:
        tot += t // (2 * k + 1)
        t = t * num * num // (den * den)
        k += 1
    return 2 * tot

LN2 = ln_frac(F(2))
LN10 = ln_frac(F(10))

def atan_frac(x):                   # atan(x) * ONE for a Fraction 0 <= x <= 1
    if x == 0:
        return 0
    if x == 1:
        return PI // 4
    # atan(x) = 2 atan(x / (1 + sqrt(1 + x^2))) is not rational: use the
    # series after two reductions by atan(a) = atan(c) + atan((a-c)/(1+ac)).
    tot = 0
    for c in (F(1, 2), F(1, 4), F(1, 8)):
        if x > c:
            tot += atan_series(c)
            x = (x - c) / (1 + x * c)
    return tot + atan_series(x)

def atan_series(x):
    num, den = x.numerator, x.denominator
    t = ONE * num // den
    tot, k = 0, 0
    while t:
        tot += t // (2 * k + 1) * (-1 if k & 1 else 1)
        t = t * num * num // (den * den)
        k += 1
    return tot

def f80(v, bits=64, mode='n'):
    """v: a value times ONE (an integer, any sign).  Sign/exponent word and
    significand, rounded to `bits` bits; and what is left over (times ONE)."""
    if v == 0:
        return 0, 0, 0
    sign = v < 0
    a = -v if sign else v
    e = a.bit_length() - 1 - BITS           # the value is in [2^e, 2^(e+1))
    sh = a.bit_length() - bits
    m = a >> sh
    rem = a - (m << sh)
    if mode == 'n' and rem * 2 >= (1 << sh):
        m += 1
        rem -= 1 << sh
        if m >> bits:
            m >>= 1
            e += 1
    m <<= 64 - bits
    return (0x8000 if sign else 0) | (16383 + e), m, (-rem if sign else rem)

def c(name, v, bits=64, mode='n'):
    se, m, _ = f80(v, bits, mode)
    print("static const m86f80 %s = { 0x%016Xull, 0x%04X };" % (name, m, se))

def arr(name, vals):
    print("static const m86f80 %s[%d] = {" % (name, len(vals)))
    for v in vals:
        se, m, _ = f80(v)
        print("    { 0x%016Xull, 0x%04X }," % (m, se))
    print("};")

print("/* Made by tools/mkfpuconst.py: do not edit. */")
# What FLDPI and the others load: to nearest, and cut short (for rounding
# down or towards zero: all are positive).
for name, v in (("PI", PI), ("L2T", LN10 * ONE // LN2), ("L2E", ONE * ONE // LN2),
                ("LG2", LN2 * ONE // LN10), ("LN2", LN2)):
    c("K_%s" % name, v)
    c("K_%s_DN" % name, v, 64, 't')
# Pi/2 in three parts (32 bits, 32 and 64) for taking multiples of it off: a
# multiple below 2^32 of each of the first two is exact.
h = PI // 2
se, m, rem = f80(h, 32, 't'); print("static const m86f80 K_PIO2_1 = { 0x%016Xull, 0x%04X };" % (m, se))
se, m, rem = f80(rem, 32, 't'); print("static const m86f80 K_PIO2_2 = { 0x%016Xull, 0x%04X };" % (m, se))
c("K_PIO2_3", rem)
c("K_2OPI", ONE * ONE * 2 // PI)
# Pi and pi/2 in two parts, for pi - x and pi/2 - x.
se, m, rem = f80(PI, 64, 't'); print("static const m86f80 K_PI_HI = { 0x%016Xull, 0x%04X };" % (m, se)); c("K_PI_LO", rem)
se, m, rem = f80(h, 64, 't'); print("static const m86f80 K_PIO2_HI = { 0x%016Xull, 0x%04X };" % (m, se)); c("K_PIO2_LO", rem)
se, m, rem = f80(PI // 4, 64, 't'); print("static const m86f80 K_PIO4_HI = { 0x%016Xull, 0x%04X };" % (m, se)); c("K_PIO4_LO", rem)
se, m, rem = f80(3 * PI // 4, 64, 't'); print("static const m86f80 K_3PIO4_HI = { 0x%016Xull, 0x%04X };" % (m, se)); c("K_3PIO4_LO", rem)
# Series: sin x = x + x^3 (S0 + S1 x^2 + ...), cos x = 1 - x^2/2 + x^4 (C0 + ...),
# e^x - 1 = x + x^2 (E0 + E1 x + ...), atanh s = s (L0 + L1 s^2 + ...) with L0 = 1,
# atan u = u (A0 + A1 u^2 + ...); and atan(k/16).
def fact(n):
    r = 1
    for i in range(2, n + 1):
        r *= i
    return r
arr("K_SIN", [(-1 if k & 1 else 1) * ONE // fact(2 * k + 3) * -1 for k in range(10)])
arr("K_COS", [(-1 if k & 1 else 1) * ONE // fact(2 * k + 4) for k in range(10)])
arr("K_EXP", [ONE // fact(k) for k in range(2, 24)])
arr("K_LOG", [ONE // (2 * k + 1) for k in range(14)])
arr("K_ATAN", [(-1 if k & 1 else 1) * ONE // (2 * k + 1) for k in range(8)])
arr("K_ATANT", [atan_frac(F(k, 16)) for k in range(17)])
