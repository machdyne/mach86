# Running Mach86 on a board

How to put Mach86 on a Sergei ML2 or a Lakritz, and what should
happen. What has and has not been seen on real hardware is in the
[README](../README.md#status): most of what is below is confirmed on
Sergei ML2; **the Lakritz build has not run on a board yet.**

## What is in the bitstream

| | Sergei ML2 | Lakritz |
|---|---|---|
| FPGA | ECP5 45F | ECP5 25F |
| CPU | Design B ([cpu_b.md](cpu_b.md)), at 33.16 MHz from the board's 48 MHz oscillator | The same |
| Memory | 64 MB of the DDR3, behind a 32 KB cache | 32 MB of SDRAM, behind a 16 KB cache |
| BIOS | Ours, 16 KB, in block RAM | The same |
| Display | DVI on the HDMI connector, 640 x 480 at 60 Hz ([video.md](video.md)); HDMI with sound after `HDMI ON` ([sound.md](sound.md)) | The same |
| Keyboard | A low-speed USB keyboard, as a PC keyboard (US layout); also the serial console | USB keyboard; no serial console |
| Mouse | A USB mouse on the other USB port ([mouse.md](mouse.md)) | The same |
| Console | The board's UART, 115200 baud, 8N1 | None |
| Disk | The microSD card, in SPI mode ([card.md](card.md)) | The same |
| Sound | PC speaker and AdLib: on the optical output, and on HDMI after `HDMI ON` | On the audio pins (sigma-delta), and on HDMI |
| Not used | Ethernet, the configuration flash | The configuration flash |

The pins are in `boards/sergei_ml2.lpf` and `boards/lakritz.lpf`.
The design is described in [soc.md](soc.md) and
[boards.md](boards.md), which also has the four boards whose builds
exist and have never been tried: Konfekt and Mozart ML0, ML1 and
ML2.

**USB keyboards and mice must be low-speed devices** that speak the
HID boot protocol. Most plain ones are; many gaming keyboards, and
keyboards with a built-in hub, are not and will not be seen.

## What you need

- The board, and the way you normally program it (for Sergei ML2:
  `openFPGALoader -c dirtyJtag`).
- A display with an HDMI or DVI input.
- A microSD card of the SDHC or SDXC kind, 4 GB or more.
  **Everything on the card is overwritten.**
- On Sergei ML2, optionally a serial terminal at 115200 baud.
- To build: a C compiler, NASM, Python 3, mtools, and a recent
  [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build)
  (Yosys, nextpnr-ecp5, ecppack) on the path. The Ubuntu packages of
  Yosys 0.33 and nextpnr 0.6 are too old for the Sergei build.

## 1. The card

```
tools/fetch_dos.sh                              # FreeDOS and HimemX; not in the repository
make card                                       # output/card/mach86-boot.img
sudo python3 tools/mkcard.py /dev/sdX output/card/mach86-boot.img
```

The card gets the 4 MB boot disk as its first partition (C:) and the
rest as FAT32 (D:), where your own programs and CD images go
([card.md](card.md)).

## 2. The bitstream

```
make sergei_ml2           # output/sergei_ml2/mach86.bit
make lakritz              # output/lakritz/mach86.bit
```

Timing depends on the placement seed and has only a few per cent of
margin: if the tool says the CPU clock fails, try another
(`make sergei_ml2 BOARD_SEED=1`, `make lakritz LAK_SEED=1`).

Load it into the FPGA's RAM, which leaves whatever is in the
configuration flash alone:

```
openFPGALoader -c dirtyJtag output/sergei_ml2/mach86.bit
```

## 3. What should happen

On Sergei ML2 the serial console first shows the BIOS training the
DDR3 (a few dozen lines ending in `ddr3 check ... ok`). Then, on the
display and the console:

```
Mach86 BIOS 0.1, 640 KB memory
SD card, 30250 MB
FreeDOS kernel 2043 (build 2043 OEM:0xfd) [compiled May 13 2021]
 ...
C: HD1, Pri[ 1], CHS=    0-1-1, start=     0 MB, size=     3 MB
D: HD1, Pri[ 2], CHS=    8-2-3, start=     4 MB, size= 30246 MB
HimemX 3.40 ...
FreeCom version 0.86 - WATCOMC - XMS_Swap [Dec 30 2024 22:10:51]
Mach86 mouse driver
Mach86. D: is the FAT32 part of the card. MOUNT file.ISO puts a CD image on E:.
C:\>
```

The LED blinks slowly while the design is configured and its clock
runs, and fast (six times a second) once the CPU has taken a fault.

Programs on the boot disk:

| | |
|---|---|
| `DOSTEST` | A short self-test of DOS calls |
| `SPEED` | Instructions a second on a plain loop: 21.4 million on a Sergei ML2 |
| `GFX`, `GFX2` | Test pictures in the graphics modes |
| `TUNE`, `ADLIB` | A scale on the PC speaker, and on the AdLib |
| `MOUSET` | Shows the mouse's position and buttons |
| `XMSTEST` | Takes a megabyte of extended memory and checks it |
| `SLOW n` | Slows the CPU for programs that break on a fast machine ([speed.md](speed.md)) |
| `HDMI ON`, `HDMI OFF` | Sound on the display's cable |
| `MOUNT file.ISO` | Puts a CD image on E: |

## Games

Shareware games go on D:. Two have been run on a Sergei ML2:

- **The Secret of Monkey Island demo** needs `SLOW 5` before it is
  started with AdLib sound (`midemo a`): its sound driver divides by
  zero on a machine this fast, as it does on a real 486.
- **DOOM** (shareware 1.9): `doom -nosound` is what has run on a
  board. It pauses for a minute or so at `R_Init`. Since round 30
  there is a Sound Blaster, **untested on a board**: for sound,
  DOOM wants a `DEFAULT.CFG` beside it that names the card (its
  `SETUP.EXE` writes one; the lines that matter are below), and is
  then started as plain `doom`. On the model it plays effects
  through the Sound Blaster and music through the AdLib.

  ```
  snd_musicdevice		2
  snd_sfxdevice		3
  snd_sbport		544
  snd_sbirq		7
  snd_sbdma		1
  ```

`SBTEST` on C: plays a short tone twice through the Sound Blaster
and says whether the card answered as it should.

## A memory manager (untested on a board)

Since round 29 the CPU has paging and virtual 8086 mode, which is
what a memory manager of the EMM386 kind needs. In simulation
Jemm386 loads and DOS, the speed test and DOOM run under it
([pmode.md](pmode.md#tests)); nobody has tried it on a board yet.
To try: build or download `JEMM386.EXE`
(github.com/Baron-von-Riedesel/Jemm), put it on D:, and at the
prompt:

```
D:\>jemm386 load
Jemm386 loaded
D:\>c:\speed
```

`SPEED` should then print roughly half of what it prints without
(paging costs every memory access two or three cycles). `JEMM386
UNLOAD` goes back to real mode. If the machine hangs or resets
instead, that is worth knowing: it is the first time this part of
the CPU has met real hardware.

## If it does not work

| What you see | What it says | What to try |
|---|---|---|
| LED dark or steady, no picture | The FPGA is not configured, or the PLL has not locked | Load again. Check the board variant: the constraints are for the Sechzig ML2 module |
| LED blinks slowly, nothing on the serial console | The design runs; the serial line does not reach you | TX and RX swapped, the wrong UART, the baud rate |
| `ddr3 ... init timeout`, or `ddr3 training FAILED` | The DDR3 did not come up | Load again; note the lines printed |
| The banner with less than 640 KB, rubbish, or an exception | The memory works for the trainer and not through the cache | Note everything from `ddr3` on |
| The banner, then nothing, or `No SD card: step n` | The BIOS could not set the card up | Try another card (SDHC or SDXC) |
| `No boot disk. System halted.` | The card answers; what is on it is not the boot disk | Write the card again |
| DOS starts, the keyboard does nothing | The USB keyboard is not a low-speed boot-protocol device | Another keyboard; on Sergei ML2 the serial console works as one |
| No picture, but the serial console works | The display does not like the signal | `HDMI OFF` if it was switched on; another display |
| LED blinks fast | The CPU took a fault | Note what was running |
| A program dies with "divide by zero" or runs far too fast | It was written for a slower machine | `SLOW 3`, then 5, 8, 15 |
