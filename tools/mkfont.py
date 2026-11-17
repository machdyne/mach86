#!/usr/bin/env python3
"""Make the text mode's character ROM: code page 437, 8 x 16.

usage: mkfont.py FONT16_MEM OUT_HEX

OUT_HEX has 4,096 lines, one byte each: character * 16 + row, bit 7
the leftmost pixel. See sw/font/README.md for where the shapes come
from.
"""
import sys
import unicodedata

W, H = 8, 16


def blank():
    return [[0] * W for _ in range(H)]


def rect(g, x0, x1, y0, y1):
    for y in range(max(y0, 0), min(y1, H - 1) + 1):
        for x in range(max(x0, 0), min(x1, W - 1) + 1):
            g[y][x] = 1


# Box drawing: for each code, the arms up, down, left, right;
# 0 none, 1 single, 2 double.
BOX = {
    0xB3: (1, 1, 0, 0), 0xB4: (1, 1, 1, 0), 0xB5: (1, 1, 2, 0), 0xB6: (2, 2, 1, 0),
    0xB7: (0, 2, 1, 0), 0xB8: (0, 1, 2, 0), 0xB9: (2, 2, 2, 0), 0xBA: (2, 2, 0, 0),
    0xBB: (0, 2, 2, 0), 0xBC: (2, 0, 2, 0), 0xBD: (2, 0, 1, 0), 0xBE: (1, 0, 2, 0),
    0xBF: (0, 1, 1, 0), 0xC0: (1, 0, 0, 1), 0xC1: (1, 0, 1, 1), 0xC2: (0, 1, 1, 1),
    0xC3: (1, 1, 0, 1), 0xC4: (0, 0, 1, 1), 0xC5: (1, 1, 1, 1), 0xC6: (1, 1, 0, 2),
    0xC7: (2, 2, 0, 1), 0xC8: (2, 0, 0, 2), 0xC9: (0, 2, 0, 2), 0xCA: (2, 0, 2, 2),
    0xCB: (0, 2, 2, 2), 0xCC: (2, 2, 0, 2), 0xCD: (0, 0, 2, 2), 0xCE: (2, 2, 2, 2),
    0xCF: (1, 0, 2, 2), 0xD0: (2, 0, 1, 1), 0xD1: (0, 1, 2, 2), 0xD2: (0, 2, 1, 1),
    0xD3: (2, 0, 0, 1), 0xD4: (1, 0, 0, 2), 0xD5: (0, 1, 0, 2), 0xD6: (0, 2, 0, 1),
    0xD7: (2, 2, 1, 1), 0xD8: (1, 1, 2, 2), 0xD9: (1, 0, 1, 0), 0xDA: (0, 1, 0, 1),
}


def box(up, down, left, right):
    g = blank()
    # Single lines: columns 3-4, rows 7-8. Double: columns 2 and 5,
    # rows 6 and 9, around a ring in the middle.
    if up == 1:
        rect(g, 3, 4, 0, 8)
    if down == 1:
        rect(g, 3, 4, 7, 15)
    if left == 1:
        rect(g, 0, 4, 7, 8)
    if right == 1:
        rect(g, 3, 7, 7, 8)
    if up == 2:
        rect(g, 2, 2, 0, 6)
        rect(g, 5, 5, 0, 6)
    if down == 2:
        rect(g, 2, 2, 9, 15)
        rect(g, 5, 5, 9, 15)
    if left == 2:
        rect(g, 0, 2, 6, 6)
        rect(g, 0, 2, 9, 9)
    if right == 2:
        rect(g, 5, 7, 6, 6)
        rect(g, 5, 7, 9, 9)
    if 2 in (up, down, left, right):
        # The ring's side is closed where no double arm leaves it.
        if up != 2:
            rect(g, 2, 5, 6, 6)
        if down != 2:
            rect(g, 2, 5, 9, 9)
        if left != 2:
            rect(g, 2, 2, 6, 9)
        if right != 2:
            rect(g, 5, 5, 6, 9)
    return g


def shade(level):
    g = blank()
    for y in range(H):
        for x in range(W):
            if level == 1:
                g[y][x] = int(x % 4 == (2 * (y % 2)) and True)
            elif level == 2:
                g[y][x] = (x + y) % 2
            else:
                g[y][x] = int(not (x % 4 == (2 * (y % 2))))
    return g


def triangle(direction):
    g = blank()
    for i in range(7):
        if direction == 'right':
            rect(g, 1, 1 + min(i, 6 - i), 4 + i, 4 + i)
        elif direction == 'left':
            rect(g, 6 - min(i, 6 - i), 6, 4 + i, 4 + i)
    for i in range(4):
        if direction == 'up':
            rect(g, 3 - i, 4 + i, 5 + i * 2, 6 + i * 2)
        elif direction == 'down':
            rect(g, i, 7 - i, 4 + i * 2, 5 + i * 2)
    return g


def arrow(direction):
    g = blank()
    if direction in ('up', 'down'):
        rect(g, 3, 4, 3, 12)
        for i in range(3):
            y = 3 + i if direction == 'up' else 12 - i
            rect(g, 3 - i, 4 + i, y, y)
    else:
        rect(g, 1, 6, 7, 8)
        for i in range(3):
            x = 6 - i if direction == 'right' else 1 + i
            rect(g, x, x, 7 - i, 8 + i)
    return g


def main():
    rows = [[int(v) for v in line.split()] for line in open(sys.argv[1]) if line.strip()]
    ascii_glyphs = [rows[i * H:(i + 1) * H] for i in range(96)]
    font = [blank() for _ in range(256)]
    for i, g in enumerate(ascii_glyphs):
        font[0x20 + i] = g
    font[0x7F] = blank()
    for code in range(0x80, 0x100):
        ch = bytes([code]).decode('cp437')
        base = unicodedata.normalize('NFD', ch)[0]
        if 0x20 < ord(base) < 0x7F:
            font[code] = ascii_glyphs[ord(base) - 0x20]
    for code, arms in BOX.items():
        font[code] = box(*arms)
    font[0xB0], font[0xB1], font[0xB2] = shade(1), shade(2), shade(3)
    for code, (x0, x1, y0, y1) in {0xDB: (0, 7, 0, 15), 0xDC: (0, 7, 8, 15),
                                   0xDD: (0, 3, 0, 15), 0xDE: (4, 7, 0, 15),
                                   0xDF: (0, 7, 0, 7), 0xFE: (2, 5, 5, 10),
                                   0x07: (2, 5, 6, 9), 0xF9: (3, 4, 7, 8),
                                   0xFA: (3, 4, 7, 8), 0x16: (0, 7, 11, 13)}.items():
        g = blank()
        rect(g, x0, x1, y0, y1)
        font[code] = g
    font[0x10], font[0x11] = triangle('right'), triangle('left')
    font[0x1E], font[0x1F] = triangle('up'), triangle('down')
    font[0x18], font[0x19] = arrow('up'), arrow('down')
    font[0x1A], font[0x1B] = arrow('right'), arrow('left')
    font[0xFF] = blank()
    with open(sys.argv[2], 'w') as f:
        for g in font:
            for row in g:
                f.write('%02x\n' % int(''.join(str(b) for b in row), 2))


if __name__ == '__main__':
    main()
