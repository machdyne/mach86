# Boards

Two boards are supported, Lakritz and Sergei ML2, and four more
have build rules that have never been run
([Konfekt and Mozart](#konfekt-and-mozart)). Mach86 keeps its own
board list and does not aim to run on everything Zeitlos does. Facts about them are taken from Zeitlos
(`release/hw/boards/*.spec` and `docs/boards.md` at commit `ede46a8`).

| | Lakritz | Sergei ML2 |
|---|---|---|
| Role | Minimum target | Development board |
| FPGA | ECP5 25F: 24,288 LUTs, 56 block RAMs, 28 multipliers, 2 PLLs | ECP5 45F: 43,848 LUTs, 108 block RAMs, 72 multipliers, 4 PLLs |
| Main memory | 32 MB SDRAM | 512 MB DDR3L |
| Oscillator | 48 MHz | 48 MHz |
| Video | DVI over HDMI connector | DVI over HDMI connector |
| USB | Host | Host |
| Storage | microSD | microSD |
| Audio | Stereo sigma-delta | S/PDIF optical |
| Network | None on board | RMII Ethernet |
| Expansion | One PMOD (serial console lives there) | — |

For scale: Zeitlos itself uses 78% of Lakritz's LUTs and 35 of its 56
block RAMs in the measured build, and notes that placement gets
difficult above about 75%.

## What this means for the design

- **Block RAM is scarce on Lakritz.** 56 blocks is about 126 KB.
  All video memory therefore lives in SDRAM there. The BIOS is
  still 16 KB of block RAM on both boards; moving it out is the
  next thing to give when block RAM is needed.
- **Two memory types.** Lakritz is SDRAM, Sergei ML2 is DDR3. Both
  controllers come from Zeitlos and sit behind the same cache, so the
  rest of Mach86 does not see the difference once memory is running.
- **DDR3 has to be trained.** On Sergei ML2 a small RISC-V core runs
  the Zeitlos training code before the x86 core leaves reset. Lakritz's
  SDRAM needs nothing of the kind.
- **Memory offered to the PC.** Lakritz offers 16 MB at first, a size
  every DOS program understands, with the rest of the 32 MB holding
  video memory and reserved for disk caching by the meta interface.
  Sergei ML2 offers the same by default and up to 64 MB as an option;
  DOS software gains nothing beyond that.

## Lakritz budget

These are the **estimates made before any of it was built**, kept
for comparison. What the build actually takes is under
[Lakritz: where it stands](#lakritz-where-it-stands): fewer LUTs
than estimated and far more block RAM, all 56.

| Part | LUTs | Block RAMs |
|---|---:|---:|
| CPU core, design B, all levels | 9,000 | 15 |
| Memory: SDRAM controller, 16 KB cache, arbiter, A20, shadow | 1,800 | 10 |
| PC hardware: interrupt controllers, timer, clock, keyboard controller, DMA, UART | 1,800 | 0 |
| VGA: registers, memory logic, scan-out, palette | 2,200 | 3 |
| DVI output | 800 | 0 |
| USB HID host | 700 | 1 |
| Sound: speaker, OPL2 (one time-shared operator), Sound Blaster, mixer | 1,800 | 2 |
| SD SPI, BIOS loader, glue | 400 | 1 |
| **Total** | **18,500 (76%)** | **32** |

Measured so far against this, on the 45F build: design B about 5,800
cells and 29 block RAMs since round 17 (twice its block RAM row: the
2,048-entry instruction cache is 22 of them, and it is what the
speed needed; on Lakritz it can be 1,024 entries and 11 blocks at
the price [cpu_b.md](cpu_b.md#in-lockstep-with-the-model) measures);
the PC devices,
serial console and SD port about 1,300 cells; text video and DVI
about 400 cells and 2 block RAMs, with 4 more for the text memory
until that moves to main memory. The RAM multiplexing of the block
RAM build (about 1,200 cells) is not part of the Lakritz design.

**Measurements so far.** The first CPU core, a plain state machine,
was 28,653 LUT4: more than the whole board ([cpu.md](cpu.md#size)). It
is replaced by design B, which is 4,908 cells with 19 block RAMs
with nearly all of real mode, interrupts and I/O
([cpu_b.md](cpu_b.md#measurements)). The finished core is expected at
5,500 to 7,500 cells, inside the CPU row above. The block RAM row is
already over by three.

Three things follow.

- The other rows are estimates and will grow, sound most of all. The
  gap between 76% and full is there for that, not for more CPU.
- Block RAM now matters. Design B moves the CPU's cost from LUTs to
  block RAM: 32 of 56 blocks are spoken for with a 16 KB data cache.
- There is still no room set aside for a service processor on
  Lakritz.

The sound row assumes the OPL2 computes its operators one after
another in a single shared datapath. There is ample time for that at
48 MHz, and it is far smaller than one circuit per operator.

Block RAM is the tight resource. With the CPU at 29, a 16 KB data
cache at 10, the BIOS ROM 4, text memory and font 4, USB 1 and sound
2, Lakritz stands at 50 of 56. The Lakritz build has not been made
yet; when it is, this table is replaced by its measurements.

## Lakritz: where it stands

**There is a build since round 23 (`make lakritz`,
`rtl/boards/lakritz.v`), and it has not run on a board.**

| | Lakritz build | Has |
|---|---:|---:|
| Logic cells | **23,591** (round 32; 19,900 before paging and virtual 8086 mode) | 24,288 (**97%**) |
| Block RAM | **56: all of them** (round 26) | 56 |
| CPU clock | routed at 35.4 MHz (round 32, one seed, with the placer's timing weight raised as on the Sergei) | runs at 33.16 |

Round 29 took 2,500 logic cells for paging, virtual 8086 mode and
the I/O permission bitmap, and Lakritz is full: about 700 cells are
left. Round 32's faster decoder (the window,
[cpu_b.md](cpu_b.md#the-decoders-window)) did not fit by 34 cells and
is left out of this build (`CPU_WIN(0)` in `rtl/boards/lakritz.v`);
the round's other gains are in. Task switches, if they come, have
to take their cells from something. Lakritz stays on design B: the
faster core that is planned ([cpu_c.md](cpu_c.md)) is for the 45F
boards.

What is different from Sergei, underneath; a program sees the same
machine:

| | Sergei ML2 | Lakritz |
|---|---|---|
| Memory | 64 MB of DDR3 on its own clock, behind a bridge, trained by the BIOS | 32 MB of SDRAM on the CPU's clock: Zeitlos's controller (`rtl/ext/zeitlos/sdram_kianv.v`), no bridge, no training. 640 KB and 31,488 KB above 1 MB |
| Data cache | 32 KB | 16 KB |
| Video memory | 64 KB in block RAM, the rest in the DDR3 | All of it in the SDRAM (its top 256 KB): `VGA_BRAM = 0` |
| Sound | S/PDIF, optical | One-bit sigma-delta on `AUDIO_L` and `AUDIO_R` |
| Serial console | UART pins | None: Zeitlos's pin file has no serial port for this board |

Where the block RAM goes: CPU 29, BIOS ROM 8, data cache 10,
character ROM 2, colours 1, line buffer 1, USB hosts 2, AdLib 2.
One block is free.

**The price of having no block RAM for video.** The display reads
every line of every mode out of the SDRAM, a line ahead, and keeps
the memory while it does. With four-word burst reads that is 10
microseconds of every line's 32 (measured against Zeitlos's model of
the part, `sim/m86_lakritz_tb.v`); one word at a time it was 23, too
much to be of use. So on Lakritz about a third of the memory's time
is the display's whatever the program does, a cache miss can wait
up to 10 microseconds, and a write to the screen takes some ten
cycles where Sergei takes one. Text scrolling and drawing will be
visibly slower than on Sergei. How much slower programs run has not
been measured.

What is tested: the SoC as Lakritz builds it shows the text screen
and all seven graphics pictures exactly as the model does
(`make check-nobram`); the memory path, with Zeitlos's controller
and Zeitlos's model of the SDRAM at the board's clocks, keeps every
line in time and every word right (`make check-tb`). What is not:
anything on the board. The risks, most likely first:

1. **The DVI output.** Ours sends two bits a cycle of a 126 MHz
   clock through an ordinary double-data-rate cell; Zeitlos on this
   board uses a different cell at a different clock, for reasons its
   notes do not give. If the monitor shows nothing, this is where to
   look first.
2. The SDRAM's read timing at 33 MHz with the clock sent inverted,
   which is Zeitlos's way at 48 MHz and has more margin here.
3. Pins: copied from Zeitlos's file by name.

The LED blinks slowly when the machine runs, with or without a
picture.

## Sergei ML2

**The current build** ([running.md](running.md), [soc.md](soc.md)):
design B at 31.5 MHz (33.16 in round 23's build), 64 MB of the DDR3 behind a 32 KB cache, a VGA
with 64 KB of video memory in block RAM on DDMI, a USB keyboard, a
serial console, the SD card, a USB mouse, and the PC speaker and an
AdLib on the optical output; video memory past 64 KB in the DDR3.
27,557 logic cells of 43,848 (62%) and 97 of 108 block RAMs in round 32, routed at 34.6 MHz. It runs on the board ([README](../README.md#status)).

**The first test build** used none of the board's DDR3: 160 KB of
RAM in block RAM, 8,000 logic cells and all 108 block RAMs, routed
at 33.9 MHz. It booted DOS on the board at the first attempt. The block RAM is the limit: the CPU takes 19, the BIOS ROM 4,
the screen memory 4, and the 80 left are the 160 KB. DOS boots in
that and no less (144 KB is too little for this kernel). The pins are
Zeitlos's for this module (`boards/sergei_ml2.lpf`).

The plan below is for the full design, which uses under half of the
45F. The spare room is for
development instruments and later additions.

## Clock

The oscillator is 48 MHz, as in Zeitlos. The CPU clock is whatever
the finished core routes at, 38 to 39 MHz as design B stands.
The video and USB clocks stay where those interfaces need them; the
design keeps those clock domains separate for that reason.

The DDR3 controller does not run on the CPU's clock. Its PHY makes a
96 MHz clock for the memory and divides it by two for the
controller, and the two must stay in step; the CPU's clock comes
from another PLL and is whatever the core routes at. Requests cross
between the two in `rtl/soc/m86_xclk.v` ([soc.md](soc.md#the-main-memory)).

## Konfekt and Mozart

Four more boards have build rules, constraint files and nothing
else: **none has been built into a bitstream, and none has run.**
What was checked is that each design elaborates and that every port
of its top level has a pin in its constraint file and the other way
round. Each is one of the two builds above with another constraint
file and a few switches.

| | Konfekt | Mozart ML0 | Mozart ML1 | Mozart ML2 |
|---|---|---|---|---|
| FPGA | ECP5 12F | ECP5 25F | ECP5 45F | ECP5 45F |
| Memory | 32 MB SDRAM | 32 MB SDRAM | 32 MB SDRAM | 512 MB DDR3L |
| Built as | Lakritz | Lakritz | Lakritz | Sergei ML2 |
| Sound | Sigma-delta pins, HDMI | PT8211 DAC, HDMI | PT8211 DAC, HDMI | PT8211 DAC, HDMI |
| Serial console | No | Yes | Yes | Yes |
| Constraints | `boards/konfekt.lpf` | `boards/mozart_ml1.lpf` | `boards/mozart_ml1.lpf` | `boards/mozart_ml2.lpf` |
| Build | `make konfekt` | `make mozart_ml0` | `make mozart_ml1` | `make mozart_ml2` |

The pins are Zeitlos's (`boards/konfekt_v0.lpf`, `mozart_ml1.lpf`,
`mozart_ml2.lpf` there), trimmed to what Mach86 uses. Mozart ML0 is
the ML1's ball map on the smaller FPGA. Mozart ML2 is the Sechzig
ML2 module that Sergei ML2 has, in another carrier: its constraint
file is Sergei's with the sound's pins changed, and Zeitlos's file
agrees with it on every other pin used.

What to expect, and what is not known:

- **Konfekt may not fit.** The Lakritz build is 20,100 logic cells
  and all 56 block RAMs of a 25F. A 12F is the same package with
  half the logic and, by its data sheet, fewer block RAMs; whether
  the tools accept this design for it has not been tried. If they
  do not, something has to come out of the Konfekt build.
- **Mozart ML0 is Lakritz's design** on the same FPGA with other
  pins, and should build as Lakritz does. Mozart ML1 has the 45F's
  room but is built with Lakritz's small cache and no block RAM
  video memory; that is a setting to change once it runs.
- **The PT8211 output** (`rtl/soc/m86_pt8211.v`) is new and tested
  only in simulation, by a receiver that knows the DAC's rule
  (`make check-tb`). Its scheme is Zeitlos's, which runs on these
  boards.
- The Konfekt's second USB port has pull-downs in Zeitlos's file and
  the first has not; both are used as on Lakritz, a keyboard on one
  and a mouse on the other.

