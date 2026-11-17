# The SD card: a boot disk, a FAT32 volume, and CD images

How programs get onto the machine. Copy them to the card on any
computer; a CD image is a file like any other and is put in a drive
with one command.

## Layout

| | | In DOS |
|---|---|---|
| Partition 1 | The boot disk, 4 MB, FAT12: kernel, shell, the CD tools, our test programs. Written by `tools/mkcard.py` from `mach86-boot.img` | C: |
| Partition 2 | The rest of the card, FAT32. Yours: CD images (`.ISO`), programs, directories | D: |
| A CD image, once mounted | Any `.ISO` file on D: | E: |

The BIOS knows nothing of this. It offers the card as one hard disk;
DOS finds the two partitions. What the BIOS had to learn is to
address the disk by sector number (interrupt 13h, functions 41h to
44h and 48h): the old cylinder-head-sector calls stop at 8 GB, and
DOS uses the new ones for a FAT32 partition wherever it lies.

## Making a card (Linux)

Everything on the card is lost. Be sure of the device name (`lsblk`).

```
make -C sim card                               # builds output/card/mach86-boot.img
sudo python3 tools/mkcard.py /dev/sdX output/card/mach86-boot.img
```

The tool writes the boot disk, adds the second partition to its
table and formats it (it needs `mkfs.fat` from dosfstools 4.2 or
later). The boot disk's `CONFIG.SYS` loads HimemX (extended memory) and
`AUTOEXEC.BAT` the mouse driver.

To put a newer boot disk's files on a card without losing D:, copy
them onto partition 1 (the programs in `output/` and
`tests/dos/mount.bat`, `autoexec.bat`, say):

```
sudo mount /dev/sdX1 /mnt && sudo cp GFX.COM mount.bat /mnt/ && sudo umount /mnt
```

Then, as often as you like:

```
sudo mount /dev/sdX2 /mnt
sudo cp something.iso /mnt/          # and anything else
sudo umount /mnt
```

Names: DOS sees the short form of a long name (`SIMTEL~1.ISO` for
`Simtel-MSDOS-Sep1996-CD1.iso`); `dir d:` shows what it is. Renaming
a file to eight characters and `.ISO` before copying saves guessing.

The card must be FAT32. Cards of 64 GB and more come formatted as
exFAT, which DOS cannot read; the tool formats partition 2 as FAT32
whatever the card's size.

## Using it

```
C:\>dir d:
C:\>mount d:\simtel.iso
d:\simtel.iso is on E:
C:\>e:
E:\>dir
```

`MOUNT` is a batch file on the boot disk. It takes out whatever image
was mounted before and puts the new one in, so it is also how to
change discs. The CD is at the root of E:, read-only, as a program
that expects to run from a CD wants it. D: is an ordinary disk:
programs can be copied there, installed there, and write there.

## What does the work

| | | Licence |
|---|---|---|
| FreeDOS kernel 2043, FAT32 build | Reads partition 2 | GPL; fetched |
| FreeCOM 0.86 | The command shell. (The MS-DOS 2.0 shell of the first test disk needs DOS to say it is version 2, and then the CD tools refuse to load.) | GPL; fetched |
| SHSUCDHD | A CD-ROM device driver whose "drive" is an image file | zlib; source fetched, assembled here |
| SHSUCDX | The CD redirector: the free equivalent of MSCDEX. Gives the driver's CD a drive letter | zlib; source fetched, assembled here |

None of these is in the repository (`tools/fetch_dos.sh`,
[software.md](software.md)). SHSUCDHD's own makefile links it with a
linker that is not to be had as a package; `sim/Makefile` assembles
it flat and `tools/mkexe.py` gives it its header, which works
because the program needs no relocation.

## How it is tested

`make check-card` (needs the fetched files, `mkfs.fat`, `mtools`,
`genisoimage`): a 64 MB card image with a small CD image on its
FAT32 partition, booted on the reference model; `dir d:`, `mount`,
`dir e:`, a file typed and a program run from the CD, a second
mount. The same session has been run in lockstep on the CPU's RTL
and on the simulated SoC, and on a 30 GB card image on the model. A
BIOS changed to refuse cylinder-head-sector calls beyond the boot
disk still reads D:, which shows DOS uses the sector-number calls
there.

## Limits, and what is not done

- Mounting is by command, not from a menu at power-on.
- One CD image at a time, always E:.
- CD audio tracks are not there: an `.ISO` holds the data track only.
- Partition 1 is small. A larger C: wants a boot sector for FAT16 or
  FAT32 that loads this kernel, which we do not have yet; meanwhile
  D: is the big disk.
- The boot disk's 4 MB FAT12 image still comes from SvarDOS with its
  boot sector.
