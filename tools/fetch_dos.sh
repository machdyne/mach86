#!/bin/sh
# Fetch the third-party pieces of the DOS boot tests into output/dos
# (docs/software.md). None of this is committed.
#
#   KERNEL.SYS          FreeDOS kernel 2043, 8086 build (GPL)
#   boot-svardos.img    an empty 4 MB hard disk image with a FreeDOS-style
#                       boot sector that loads KERNEL.SYS (from SvarDOS)
#   COMMAND.COM,        MS-DOS 2.0 binaries published by Microsoft (MIT)
#   CHKDSK.COM
set -e
DEST="${1:-output/dos}"
mkdir -p "$DEST"
cd "$DEST"

if [ ! -f KERNEL.SYS ]; then
    curl -sSL -o kernel.zip \
        https://github.com/FDOS/kernel/releases/download/ke2043/ke2043_86f16.zip
    unzip -o -q -j kernel.zip bin/KERNEL.SYS
    rm kernel.zip
fi

# One file out of a repository, without downloading the rest.
fetch_file() {  # repository, path, destination
    rm -rf tmp.git
    git clone --quiet --depth 1 --filter=blob:none --no-checkout "$1" tmp.git
    git -C tmp.git checkout --quiet HEAD -- "$2"
    cp "tmp.git/$2" "$3"
    rm -rf tmp.git
}

[ -f boot-svardos.img ] || \
    fetch_file https://github.com/SvarDOS/core files/boot-svardos.img boot-svardos.img
[ -f COMMAND.COM ] || \
    fetch_file https://github.com/microsoft/MS-DOS v2.0/bin/COMMAND.COM COMMAND.COM
[ -f CHKDSK.COM ] || \
    fetch_file https://github.com/microsoft/MS-DOS v2.0/bin/CHKDSK.COM CHKDSK.COM

# For the card with a FAT32 partition and CD images (docs/card.md):
#
#   KERNEL32.SYS        the same kernel built with FAT32 (GPL)
#   FREECOM.COM         FreeCOM 0.86, the FreeDOS command shell (GPL)
#   shsucd/             the SHSUCD suite's source (zlib licence): the CD
#                       redirector SHSUCDX and the image-file CD driver
#                       SHSUCDHD are assembled from it by sim/Makefile
if [ ! -f KERNEL32.SYS ]; then
    curl -sSL -o kernel32.zip \
        https://github.com/FDOS/kernel/releases/download/ke2043/ke2043_86f32.zip
    unzip -o -q -j kernel32.zip bin/KERNEL.SYS -d k32
    mv k32/KERNEL.SYS KERNEL32.SYS
    rm -rf k32 kernel32.zip
fi
if [ ! -f FREECOM.COM ]; then
    curl -sSL -o freecom.zip \
        https://github.com/FDOS/freecom/releases/download/com086/command.zip
    unzip -o -q -j freecom.zip BIN/COMMAND.COM -d fc
    mv fc/COMMAND.COM FREECOM.COM
    rm -rf fc freecom.zip
fi
# HIMEMX.EXE          HimemX 3.40, the FreeDOS extended memory (XMS)
#                     driver (GPL): what makes memory above 1 MB usable
#                     by DOS programs (docs/pmode.md)
if [ ! -f HIMEMX.EXE ]; then
    curl -sSL -o himemx.zip \
        https://github.com/Baron-von-Riedesel/HimemX/releases/download/v3.40/HimemX340.zip
    unzip -o -q -j himemx.zip HimemX.exe -d hx
    mv hx/HimemX.exe HIMEMX.EXE
    rm -rf hx himemx.zip
fi
[ -d shsucd ] || git clone --quiet --depth 1 https://github.com/adoxa/shsucd shsucd

ls -l KERNEL.SYS boot-svardos.img COMMAND.COM CHKDSK.COM KERNEL32.SYS FREECOM.COM HIMEMX.EXE
