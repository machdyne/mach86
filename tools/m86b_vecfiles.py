#!/usr/bin/env python3
"""List the instruction-vector files for opcodes that design B has
microcode for.

usage: m86b_vecfiles.py ATTR_HEX VECTOR_DIR

(ucode.hex is read from beside ATTR_HEX.)

Reads the opcode attribute ROM image and prints the names of the
matching files in VECTOR_DIR, one per line. A file name is the opcode
with optional 66 and 67 prefixes and, for group opcodes, the ModRM reg
field after a dot.
"""
import os
import sys


def main():
    attr = [int(line, 16) for line in open(sys.argv[1])]
    ucode = [int(line, 16) for line in
             open(os.path.join(os.path.dirname(sys.argv[1]), 'ucode.hex'))]

    def written(a, reg):
        if not a >> 15 & 1:
            return False
        if not a >> 16 & 1:
            return True
        w = ucode[(a & 0x3FF) + reg]
        raises = (w >> 23 & 7) == 7 and (w >> 26 & 15) == 5
        return not (raises and w >> 65 & 1 and (w >> 48 & 0x3FF) == 6)

    # Index: bit 8 is the 0F map. An opcode counts if either its
    # register or its memory form has microcode.
    have = {i & 0x1FF for i, a in enumerate(attr) if a >> 15 & 1}
    for name in sorted(os.listdir(sys.argv[2])):
        key = name.split('.')[0]
        while len(key) > 2 and key[:2] in ('66', '67'):
            key = key[2:]
        if len(key) == 4 and key[:2] == '0F':
            op = 0x100 | int(key[2:], 16)
        elif len(key) == 2:
            op = int(key, 16)
        else:
            continue
        if op not in have:
            continue
        # A member of an opcode group whose microcode is only the
        # invalid-opcode placeholder is not written yet.
        parts = name.split('.')
        if len(parts[1]) == 1 and not any(
                written(attr[form << 9 | op], int(parts[1]))
                for form in (0, 1)):
            continue
        print(name)


if __name__ == '__main__':
    main()
