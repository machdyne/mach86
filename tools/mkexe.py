#!/usr/bin/env python3
"""Make a DOS .EXE of a flat binary that needs no relocation.

usage: mkexe.py FLAT.BIN OUT.EXE

The binary is one group of code and data assembled at offset 0. Its
last four bytes are two words put there for this tool: the offset at
which its uninitialised data ends, and its entry point. They stay in
the program (they are past its last instruction). The stack, 256
bytes, follows the uninitialised data; CS, DS-to-be and SS are the
same segment.

This stands in for an OMF linker when building SHSUCDHD from its
source (sim/Makefile): the program's own makefile uses ALINK, which is
not to be had as a package.
"""
import struct
import sys


def main():
    data = open(sys.argv[1], 'rb').read()
    bss_end, entry = struct.unpack('<HH', data[-4:])
    header = 32
    size = header + len(data)
    stack_top = (bss_end + 256 + 1) & ~1
    extra = max(0, stack_top - len(data))
    mz = struct.pack('<2sHHHHHHHHHHHHH', b'MZ',
                     size % 512, (size + 511) // 512,
                     0,                     # relocations
                     header // 16,
                     (extra + 15) // 16,    # memory needed past the file
                     0xFFFF,
                     0, stack_top,          # SS:SP
                     0,                     # checksum
                     entry, 0,              # IP, CS
                     0x1C, 0)               # relocation table offset, overlay
    mz += bytes(header - len(mz))
    open(sys.argv[2], 'wb').write(mz + data)


if __name__ == '__main__':
    main()
