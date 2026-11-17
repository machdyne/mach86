#!/usr/bin/env python3
"""Mach86: a script of register writes for the FM synthesiser's
comparison (make -C sim check-opl): random instruments on all nine
voices, keys pressed and released, every register field used. The
same script every time.

Lines: "N REG VAL" in hex: write VAL to REG, then N samples.
usage: oplscript.py OUT [SAMPLES]
"""
import random
import sys

rnd = random.Random(86)
total = int(sys.argv[2]) if len(sys.argv) > 2 else 24000
out = []
OFF = [0, 1, 2, 8, 9, 10, 16, 17, 18]

def w(n, reg, val):
    out.append("%x %02x %02x" % (n, reg, val & 255))

w(0, 0x01, 0x20)                                # waveforms on
made = 0
while made < total:
    ch = rnd.randrange(9)
    w(0, 0xBD, rnd.choice([0x00, 0x40, 0x80, 0xC0]))
    for op in (0, 3):
        o = OFF[ch] + op
        w(0, 0x20 + o, rnd.randrange(256))
        w(0, 0x40 + o, (rnd.randrange(4) << 6) | rnd.choice([0, 0, 5, 12, 20, 40]))
        w(0, 0x60 + o, (rnd.choice([15, 15, 13, 11, 9, 6]) << 4) | rnd.randrange(16))
        w(0, 0x80 + o, (rnd.randrange(16) << 4) | rnd.choice([15, 12, 9, 7, 4, 0]))
        w(0, 0xE0 + o, rnd.randrange(4))
    w(0, 0xC0 + ch, rnd.randrange(16))
    w(0, 0xA0 + ch, rnd.randrange(256))
    hi = (rnd.randrange(8) << 2) | rnd.randrange(4)
    n = rnd.choice([1, 7, 100, 400, 900])
    w(n, 0xB0 + ch, 0x20 | hi)                  # key on
    made += n
    if rnd.random() < 0.6:
        n = rnd.choice([1, 50, 300])
        w(n, 0xB0 + ch, hi)                     # key off
        made += n
    if rnd.random() < 0.1:
        w(0, 0x01, rnd.choice([0x00, 0x20]))
open(sys.argv[1], "w").write("\n".join(out) + "\n")
