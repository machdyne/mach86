#!/usr/bin/env python3
"""Lay out an SD card for Mach86: a small boot partition and the rest
as an ordinary FAT32 volume.

usage: mkcard.py TARGET BOOT_IMAGE [-size MB] [FILE ...]

TARGET is a card (/dev/sdX: run as root, and be sure of the name --
everything on it is lost) or an image file, which is created with
-size megabytes.

  partition 1   BOOT_IMAGE as it is: the 4 MB DOS boot disk, with its
                own partition table entry. DOS calls it C:.
  partition 2   from 4 MB to the end, FAT32. DOS calls it D:. Mount it
                on any computer and copy files to it: CD images
                (.ISO), programs, directories.

FILEs are copied to partition 2 (for the tests; needs mtools).
Needs mkfs.fat (dosfstools 4.2 or later, for --offset).
"""
import os
import struct
import subprocess
import sys

SECTOR = 512
P2_START = 8192                 # sectors: 4 MB


def main():
    args = sys.argv[1:]
    size_mb = None
    if '-size' in args:
        i = args.index('-size')
        size_mb = int(args[i + 1])
        del args[i:i + 2]
    if len(args) < 2:
        sys.exit(__doc__)
    target, boot = args[0], args[1]
    files = args[2:]
    image = open(boot, 'rb').read()
    if len(image) > P2_START * SECTOR:
        sys.exit('mkcard: the boot image is larger than 4 MB')
    if image[510:512] != b'\x55\xaa':
        sys.exit('mkcard: the boot image has no partition table')

    if size_mb is not None:
        with open(target, 'wb') as f:
            f.truncate(size_mb * 1024 * 1024)
    with open(target, 'r+b') as f:
        total = f.seek(0, os.SEEK_END) // SECTOR
        if total < P2_START + 70000:
            sys.exit('mkcard: too small for a FAT32 partition after the boot disk')
        f.seek(0)
        f.write(image)
        # Partition 2: FAT32 with sector addresses (type 0Ch).
        p2_size = total - P2_START
        if p2_size > 0xFFFFFFFF:
            sys.exit('mkcard: cards over 2 TB are not for this table')
        # Its cylinder-head-sector fields, in the geometry partition 1
        # was made for (where that one ends says what it is); DOS
        # grumbles if the start does not agree with the sector number.
        # An end past cylinder 1023 cannot be written and says so.
        heads = image[446 + 5] + 1
        spt = image[446 + 6] & 63

        def chs(lba):
            c, rest = divmod(lba, heads * spt)
            h, sec = divmod(rest, spt)
            if c > 1023:
                c, h, sec = 1023, heads - 1, spt - 1
            return bytes([h, (sec + 1) | (c >> 8) << 6, c & 255])

        entry = struct.pack('<B3sB3sII', 0x00, chs(P2_START), 0x0C,
                            chs(P2_START + p2_size - 1), P2_START, p2_size)
        f.seek(446 + 16)
        f.write(entry)
        f.flush()
        os.fsync(f.fileno())

    # mkfs.fat counts the size in kilobytes and the offset in sectors.
    # (-I: mkfs.fat will not otherwise touch a whole device that has
    # partitions. It is given the whole device and an offset, not the
    # partition's own name, so that the kernel need not have noticed
    # the new table yet.)
    subprocess.check_call(['mkfs.fat', '-I', '-F', '32', '-n', 'MACH86',
                           '--offset', str(P2_START), target,
                           str(p2_size * SECTOR // 1024)],
                          stdout=subprocess.DEVNULL)
    for name in files:
        subprocess.check_call(['mcopy', '-i',
                               '%s@@%d' % (target, P2_START * SECTOR),
                               name, '::'])
    print('mkcard: %s: boot disk, and %d MB of FAT32 from sector %d'
          % (target, p2_size // 2048, P2_START))


if __name__ == '__main__':
    main()
