#!/usr/bin/env python3
"""Add files to the root directory of a FAT12 or FAT16 disk image.

usage: fatimg.py IMAGE FILE[=NAME] ...

IMAGE is a diskette image, or a hard disk image whose first partition
holds the volume. Each FILE is copied into the root directory under
its own name, or under NAME if given. Names must fit 8.3. Files are
stored in the first free clusters, in the order given, so a system
file listed first lands where a boot sector expects it.

This writes; it does not format. The volume must already exist.
"""
import struct
import sys


class Volume:
    def __init__(self, data):
        self.d = data
        self.base = 0
        # A partition table, and not a volume boot record?
        if data[510:512] == b'\x55\xaa' and data[0] not in (0xEB, 0xE9):
            start = struct.unpack_from('<I', data, 446 + 8)[0]
            if start:
                self.base = start * 512
        b = self.base
        (self.bps, self.spc, self.reserved, self.nfats, self.nroot,
         total16, _media, self.spf) = struct.unpack_from('<HBHBHHBH', data,
                                                         b + 11)
        total = total16 or struct.unpack_from('<I', data, b + 32)[0]
        if self.bps != 512 or not self.spc or not self.nfats:
            raise SystemExit('fatimg: no FAT volume found in the image')
        self.fat = b + self.reserved * 512
        self.root = self.fat + self.nfats * self.spf * 512
        root_sectors = (self.nroot * 32 + 511) // 512
        self.data = self.root + root_sectors * 512
        self.clusters = (total - self.reserved - self.nfats * self.spf
                         - root_sectors) // self.spc
        self.fat16 = self.clusters >= 4085

    def get(self, n):
        if self.fat16:
            return struct.unpack_from('<H', self.d, self.fat + 2 * n)[0]
        v = struct.unpack_from('<H', self.d, self.fat + n * 3 // 2)[0]
        return v >> 4 if n & 1 else v & 0xFFF

    def put(self, n, value):
        for copy in range(self.nfats):
            f = self.fat + copy * self.spf * 512
            if self.fat16:
                struct.pack_into('<H', self.d, f + 2 * n, value)
                continue
            off = f + n * 3 // 2
            v = struct.unpack_from('<H', self.d, off)[0]
            if n & 1:
                v = (v & 0x000F) | (value << 4)
            else:
                v = (v & 0xF000) | (value & 0xFFF)
            struct.pack_into('<H', self.d, off, v)

    def add(self, name, content):
        base, _, ext = name.upper().partition('.')
        if not base or len(base) > 8 or len(ext) > 3:
            raise SystemExit('fatimg: %s is not an 8.3 name' % name)
        short = base.ljust(8).encode('ascii') + ext.ljust(3).encode('ascii')

        slot = None
        for i in range(self.nroot):
            e = self.root + 32 * i
            if self.d[e:e + 11] == short:
                raise SystemExit('fatimg: %s is already there' % name)
            if self.d[e] in (0x00, 0xE5) and slot is None:
                slot = e
        if slot is None:
            raise SystemExit('fatimg: root directory is full')

        size = self.spc * 512
        need = (len(content) + size - 1) // size
        free = [n for n in range(2, self.clusters + 2) if self.get(n) == 0]
        if len(free) < need:
            raise SystemExit('fatimg: no room for %s' % name)
        chain = free[:need]
        end = 0xFFFF if self.fat16 else 0xFFF
        for k, n in enumerate(chain):
            self.put(n, chain[k + 1] if k + 1 < need else end)
            off = self.data + (n - 2) * size
            part = content[k * size:(k + 1) * size]
            self.d[off:off + len(part)] = part

        entry = bytearray(32)
        entry[0:11] = short
        entry[11] = 0x20
        struct.pack_into('<HH', entry, 22, 0x6000, 0x1421)   # 1990-01-01 12:00
        struct.pack_into('<HI', entry, 26, chain[0] if chain else 0,
                         len(content))
        self.d[slot:slot + 32] = entry


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    with open(path, 'rb') as f:
        data = bytearray(f.read())
    vol = Volume(data)
    for arg in sys.argv[2:]:
        src, _, name = arg.partition('=')
        with open(src, 'rb') as f:
            vol.add(name or src.rsplit('/', 1)[-1], f.read())
    with open(path, 'wb') as f:
        f.write(data)


if __name__ == '__main__':
    main()
