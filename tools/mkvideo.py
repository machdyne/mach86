#!/usr/bin/env python3
"""Make the tables the BIOS's video code carries.

usage: mkvideo.py FONT8X8_MEM OUTDIR

OUTDIR/font8.bin    256 characters of 8 rows, bit 7 the leftmost pixel:
                    ASCII 20h to 7Fh from the font, the rest blank
OUTDIR/dac_ega.bin  64 colours, 3 bytes each (red, green, blue, 0-63):
                    the six-bit colour numbers of the EGA, two bits a
                    gun (bits 2,1,0 two thirds; bits 5,4,3 one third)
OUTDIR/dac_cga.bin  64 colours for the modes whose palette values are
                    the CGA's: bits 2,1,0 two thirds of a gun, bit 4
                    one third on all three, and brown for colour 6
OUTDIR/dac_256.bin  the 256 colours a VGA starts mode 13h with: the 16
                    of the CGA, 16 greys, then three brightnesses of
                    three saturations of a 24-step colour wheel, and
                    eight blacks

The rules for the colours are the published description of the VGA's
default palette, not a copy of any ROM's table.
"""
import sys


def font8(path, out):
    rows = [line.split() for line in open(path) if line.strip()]
    glyphs = [rows[i:i + 8] for i in range(0, len(rows), 8)]
    data = bytearray(256 * 8)
    for n in range(96):                     # ASCII 20h-7Fh come first
        for r in range(8):
            byte = 0
            for x in range(8):
                byte |= int(glyphs[n][r][x]) << (7 - x)
            data[(0x20 + n) * 8 + r] = byte
    open(out, 'wb').write(data)


def ega(i):
    return [0x2A * (i >> b & 1) + 0x15 * (i >> (b + 3) & 1) for b in (2, 1, 0)]


def cga(i):
    if (i & 0x17) == 6:
        return [0x2A, 0x15, 0x00]
    return [0x2A * (i >> b & 1) + 0x15 * (i >> 4 & 1) for b in (2, 1, 0)]


def wheel(v):
    """24 colours round the wheel from blue, on five levels v[0..4]."""
    out = []
    for k in range(4): out.append((v[k], v[0], v[4]))           # blue to magenta
    for k in range(4): out.append((v[4], v[0], v[4 - k]))       # to red
    for k in range(4): out.append((v[4], v[k], v[0]))           # to yellow
    for k in range(4): out.append((v[4 - k], v[4], v[0]))       # to green
    for k in range(4): out.append((v[0], v[4], v[k]))           # to cyan
    for k in range(4): out.append((v[0], v[4 - k], v[4]))       # to blue
    return out


def vga256():
    pal = []
    for c in range(16):                     # the CGA's sixteen
        i = (c & 7) | (0x10 if c & 8 else 0)
        pal.append(tuple(cga(i)))
    for g in (0, 5, 8, 11, 14, 17, 20, 24, 28, 32, 36, 40, 45, 50, 56, 63):
        pal.append((g, g, g))
    levels = [
        ([0, 16, 31, 47, 63], [31, 39, 47, 55, 63], [45, 49, 54, 58, 63]),
        ([0, 7, 14, 21, 28], [14, 17, 21, 24, 28], [20, 22, 24, 26, 28]),
        ([0, 4, 8, 12, 16], [8, 10, 12, 14, 16], [11, 12, 13, 15, 16]),
    ]
    for bright in levels:
        for sat in bright:
            pal.extend(wheel(sat))
    pal.extend([(0, 0, 0)] * 8)
    assert len(pal) == 256
    return pal


def main():
    src, out = sys.argv[1], sys.argv[2]
    font8(src, out + '/font8.bin')
    open(out + '/dac_ega.bin', 'wb').write(bytes(x for i in range(64) for x in ega(i)))
    open(out + '/dac_cga.bin', 'wb').write(bytes(x for i in range(64) for x in cga(i)))
    open(out + '/dac_256.bin', 'wb').write(bytes(x for c in vga256() for x in c))


if __name__ == '__main__':
    main()
