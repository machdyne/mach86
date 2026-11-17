#!/bin/sh
# Mach86: fetch Dhrystone 2.1 and build it as ROM images for the model
# and the RTL, in output/dhry. The source is not kept in the
# repository. Needs gcc with -m16, GNU ld, NASM.
#
# usage: tools/dhry.sh [RUNS ...]      default: 10 110
set -e
cd "$(dirname "$0")/.."
out=output/dhry
src=https://raw.githubusercontent.com/Keith-S-Thompson/dhrystone/master/v2.1
mkdir -p $out
for f in dhry.h dhry_1.c dhry_2.c; do
    [ -s $out/$f ] || curl -sSfL -o $out/$f $src/$f
done
cflags="-m16 -march=i386 -O2 -ffreestanding -fno-pic -fno-builtin
        -fno-stack-protector -fno-asynchronous-unwind-tables -msoft-float
        -mno-80387 -std=gnu89 -w -DTIME -nostdinc -Itests/dhry/include -I$out"
[ $# -gt 0 ] || set -- 10 110
for runs in "$@"; do
    gcc $cflags -c tests/dhry/start.S -o $out/start.o
    for f in $out/dhry_1.c $out/dhry_2.c tests/dhry/support.c; do
        gcc $cflags -DRUNS=$runs -c $f -o $out/$(basename $f .c).o
    done
    ld -m elf_i386 -T tests/dhry/link.ld -o $out/dhry$runs.bin \
        $out/start.o $out/dhry_1.o $out/dhry_2.o $out/support.o
    nasm -f bin -DPROG="'$out/dhry$runs.bin'" -o $out/dhry$runs.rom \
        tests/dhry/rom.asm
    echo "$out/dhry$runs.rom"
done
