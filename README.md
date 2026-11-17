# Mach86

**A 386DX/486SX-class PC on an FPGA, written from scratch.**

Mach86 is a clean-room PC-compatible computer in plain Verilog. It
boots DOS from an SD card and runs DOS software and games on small
Lattice ECP5 boards, with its own CPU core, BIOS, VGA, sound and USB
input. The CPU, its microcode and the BIOS are our own, written
against public documentation
([docs/cleanroom.md](docs/cleanroom.md)) and checked instruction by
instruction against a reference model and against test vectors
captured from real hardware.

It is the sister project of [Zeitlos](https://github.com/machdyne/zeitlos)
and shares its licence; a few vendored files have their own
([License](#license)).

## Features

- **CPU:** the 486SX instruction set, 16- and 32-bit, at about 21
  million instructions a second at 33 MHz (measured on a board). A decoded-instruction
  cache and microcode make most instructions one or two clock cycles
  ([docs/cpu_b.md](docs/cpu_b.md)). No FPU.
- **Protected mode:** segments, 32-bit code and stacks, interrupts
  and faults through gates, at one privilege level: enough for
  DOS/4GW
  ([docs/pmode.md](docs/pmode.md)). Extended memory through an XMS
  driver.
- **Graphics:** a VGA with text, CGA, EGA and VGA modes up to
  640 x 480 in 16 colours and 320 x 200 in 256, on DVI/HDMI
  ([docs/video.md](docs/video.md)).
- **Sound:** PC speaker and AdLib (OPL2), over HDMI, S/PDIF or a
  one-pin sigma-delta output ([docs/sound.md](docs/sound.md)).
- **Input:** USB keyboard and mouse, with an INT 33h mouse driver
  ([docs/mouse.md](docs/mouse.md)).
- **Storage:** an SD card as the hard disk: FAT32 partitions, CD
  images mounted as drives ([docs/card.md](docs/card.md)).
- **Its own BIOS,** 16 KB ([docs/bios.md](docs/bios.md)); boots
  FreeDOS.
- **A speed control** for programs that break on fast machines
  ([docs/speed.md](docs/speed.md)).
- **Verification:** 1.7 million instruction tests captured from a
  real 386, the gateware compared with a C model after every
  instruction, and the whole machine simulated down to its pins
  ([docs/verification.md](docs/verification.md)).
- **Boards:** Sergei ML2 (ECP5 45F, DDR3; about 20,000 LUTs) and
  Lakritz (ECP5 25F, SDRAM; about 17,000)
  ([docs/boards.md](docs/boards.md)). Built with Yosys and nextpnr.

## Status

What has run on a board, what has only been simulated, and what is
not there.

| | |
|---|---|
| **Works on a Sergei ML2** | DOS boots from the card; the measured speed is what the simulation predicts (`SPEED` prints 21.4 million instructions a second on a plain loop at 33.16 MHz; 20.3 at 31.5 before); the display; DDR3 memory; PC speaker and AdLib sound right; the Monkey Island demo runs, with music, under `SLOW 5`; **DOOM's shareware episode runs** (round 26, at 33 MHz, about ten frames a second by eye, sound not yet tried) |
| **Passes in simulation, not confirmed on a board** | Sound over HDMI; the 486 instructions and protected mode beyond what DOOM uses. Also the mouse, the 640 x 350 and 640 x 480 modes, and the whole Lakritz build. The USB keyboard has not been reported on either way |
| **Not tested at all** | Any DOS extender but DOS/4GW, any protected-mode program but DOOM and our own tests |
| **Not there** | Privilege levels, paging, virtual 8086 mode (so no EMM386, no Windows); an FPU; Sound Blaster; AdLib's rhythm mode; a mouse cursor in graphics modes |

## Goals

- Run DOS and DOS games from the shareware era, up to 386 protected
  mode titles.
- Fit a Machdyne Lakritz (ECP5 25F, 32 MB SDRAM). Development happens
  on Sergei ML2 (ECP5 45F, 512 MB DDR3L).
- Be a clean-room implementation, written from public specifications
  ([docs/cleanroom.md](docs/cleanroom.md)). Zeitlos code is the one
  exception, because it is ours.
- Depend on no GPL code in the repository
  ([docs/software.md](docs/software.md)).

Windows is not a goal. It is used as a stress test where it is cheap.
An FPU is not planned for now.

## Building for a board

```
make sergei_ml2        # output/sergei_ml2/mach86.bit
make lakritz           # output/lakritz/mach86.bit
tools/fetch_dos.sh     # FreeDOS and HimemX, fetched, not in the repository
make card              # output/card/mach86-boot.img, the boot disk
```

The bitstreams need a recent
[OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build)
(Yosys, nextpnr-ecp5, ecppack) on the path.
[docs/running.md](docs/running.md) says how to put the card together
and what should happen.

## Documents

The list is in [docs/README.md](docs/README.md). Start with
[docs/running.md](docs/running.md) to try it on a board, or
[docs/cpu_b.md](docs/cpu_b.md) for how the CPU works.

## Checks

```
make check
```

This verifies the documentation links, builds the reference model and
the BIOS, runs the directed programs, boots the BIOS test on the
first RTL core and on design B in lockstep with the model, runs the
unit benches and the SoC's boot test, and the 486 and protected-mode
test programs on the model, in lockstep and on the SoC. It needs a C
compiler, NASM, Verilator, Icarus Verilog and Python 3. The other
targets are listed by `make help`.

```
tools/fetch_vectors.sh
make vectors
```

This runs the CPU model against the hardware-captured instruction
vectors ([docs/model.md](docs/model.md)). The vectors are about 580 MB
and are not part of the repository.

```
tools/fetch_dos.sh
make dos
```

This boots DOS in the model and runs a scripted session. The DOS
files are third-party and are fetched, not committed
([docs/software.md](docs/software.md)).

`make rtl-vectors` and `make rtl-dos` run the same two things on the
RTL core, and `make synth` reports its size
([docs/cpu.md](docs/cpu.md)).

## License

The contents of this repo are released under the
[Lone Dynamics Open License](LICENSE.md) with the following exceptions:

- rtl/ext/usb\_hid\_host (the USB HID host by nand2mario, based on
  work by hi631) uses the Apache 2.0 license.
- rtl/ext/zeitlos/sdram\_kianv.v (the SDRAM controller by Hirosh
  Dabui) uses the Apache 2.0 license.
- rtl/ext/zeitlos/tmds\_encoder.v (the TMDS encoder by Hirosh Dabui)
  uses an ISC-style license.
- sw/font/font8x8.mem is Daniel Hepper's public-domain 8x8 font.

The other files in rtl/ext/zeitlos, the DDR3 training code in
sw/train, tools/ddmi.py and sw/font/font16.mem come from
[Zeitlos](https://github.com/machdyne/zeitlos) and are under the same
license as this repo. No DOS, test vectors or games are in the repo:
the scripts in tools/ fetch what the tests need
([docs/software.md](docs/software.md)).
