#!/usr/bin/env python3
"""Split a binary into four hex files, one for each byte lane of
rtl/soc/m86_mem.v.

usage: lanes.py BINARY OUT_PREFIX [SIZE [TAIL]]

Writes OUT_PREFIX0.hex to OUT_PREFIX3.hex. With SIZE (bytes), the
image is the first SIZE bytes of the binary; with TAIL as well, the
last TAIL bytes of that image are taken from the end of the binary.
That is how a 64 KB BIOS image whose code is at the start and whose
reset vector is in the last 16 bytes becomes a small ROM that is
mirrored through the segment.
"""
import sys


def main():
    data = open(sys.argv[1], 'rb').read()
    if len(sys.argv) > 3:
        size = int(sys.argv[3], 0)
        tail = int(sys.argv[4], 0) if len(sys.argv) > 4 else 0
        middle = data[size - tail:len(data) - tail]
        if any(b not in (0x00, 0xFF) for b in middle):
            sys.exit('lanes.py: the binary does not fit %d bytes' % size)
        data = data[:size - tail] + data[len(data) - tail:]
    data += bytes(-len(data) % 4)
    for lane in range(4):
        with open('%s%d.hex' % (sys.argv[2], lane), 'w') as f:
            for b in data[lane::4]:
                f.write('%02x\n' % b)


if __name__ == '__main__':
    main()
