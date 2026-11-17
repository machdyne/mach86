#!/usr/bin/env python3
"""Read a picture of the text screen back as text.

usage: readscreen.py FRAME_PPM FONT_HEX

FRAME_PPM is 640 x 480, as sim/soc_tb.cpp writes it from the
display's pins. Each 8 x 16 cell of the middle 400 lines is matched
against the character ROM: the two colours in the cell give a bitmap,
and the character with that bitmap (or its inverse) is printed. A cell
that matches nothing is printed as '?'. This is how a test checks
that what a program printed is what the display shows.
"""
import sys


def main():
    data = open(sys.argv[1], 'rb').read()
    assert data[:15] == b'P6\n640 480\n255\n', 'not a 640x480 PPM'
    pix = data[15:]
    font = [int(line, 16) for line in open(sys.argv[2])]
    glyphs = {}
    for ch in range(255, -1, -1):
        glyphs[tuple(font[ch * 16:ch * 16 + 16])] = ch
    # Prefer printable ASCII where two characters share a shape.
    for ch in range(0x7E, 0x1F, -1):
        glyphs[tuple(font[ch * 16:ch * 16 + 16])] = ch
    for row in range(25):
        line = ''
        for col in range(80):
            cell = []
            for y in range(16):
                o = ((40 + row * 16 + y) * 640 + col * 8) * 3
                cell.append([pix[o + 3 * x:o + 3 * x + 3] for x in range(8)])
            colours = sorted({p for r in cell for p in r})
            if len(colours) == 1:
                line += ' '
                continue
            found = '?'
            for ink in colours[:2]:
                bitmap = tuple(sum((p == ink) << (7 - x) for x, p in enumerate(r))
                               for r in cell)
                if bitmap in glyphs:
                    found = chr(glyphs[bitmap]) if 0x20 <= glyphs[bitmap] < 0x7F else '#'
                    break
            line += found
        print(line.rstrip())


if __name__ == '__main__':
    main()
