#!/usr/bin/env python3
"""Mach86: the two tables of the FM synthesiser (rtl/soc/m86_opl2.v,
sim/opl2.c), as one ROM image of 512 words of 12 bits.

  0..255    the first quarter of a sine as attenuation: -log2(sin) in
            1/256 of an octave (of amplitude), at the middle of each
            of the 256 steps
  256..511  the way back: (2^(i/256) - 1) * 1024

usage: mkopl.py OUT.hex
"""
import math
import sys

rom = []
for i in range(256):
    rom.append(round(-math.log2(math.sin((i + 0.5) * math.pi / 512)) * 256))
for i in range(256):
    rom.append(round((2 ** (i / 256) - 1) * 1024))
assert max(rom) < 4096
with open(sys.argv[1], "w") as f:
    for v in rom:
        f.write("%03x\n" % v)
