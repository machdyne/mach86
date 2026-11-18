# The first SoC

`rtl/soc/m86_soc.v` is the machine: design B, its memory (block RAM
in the first versions and the small simulations; the board's DDR3 or
SDRAM behind a cache since), the PC devices the BIOS and DOS need, a
VGA, sound, a serial console and an SD card. It is the machine the reference model
implements ([model.md](model.md)), with real time in place of the
model's counted instructions. [running.md](running.md) is the test on
Sergei ML2.

## What is in it

| File | What |
|---|---|
| `rtl/cpu/m86b_core.v` | The CPU ([cpu_b.md](cpu_b.md)) |
| `rtl/soc/m86_soc.v` | Address decoding, the bus, the small devices: port 61h, the configuration memory |
| `rtl/soc/m86_mem.v` | A memory in four byte lanes, read or written one, two or four bytes at any address in a cycle |
| `rtl/soc/m86_pic.v` | Both interrupt controllers (8259A) |
| `rtl/soc/m86_pit.v` | The timer (8254) |
| `rtl/soc/m86_kbd.v` | The keyboard controller (8042), port 92h, and a keyboard made from the serial line |
| `rtl/soc/m86_vga.v` | The VGA: the first 64 KB of video memory, the registers, the graphics controller, and the display, 640 x 480 at 60 Hz ([video.md](video.md)) |
| `rtl/soc/m86_vfetch.v` | For a board: the display's line buffer for video memory in the main memory, and the three-way share of that memory |
| `rtl/soc/m86_dvi.v` | DVI encoding and serialising |
| `rtl/soc/m86_spk.v`, `m86_opl2.v`, `m86_audio.v` | Sound: the PC speaker's bit as samples, the AdLib's synthesiser, and the two added up for S/PDIF or a sigma-delta pin ([sound.md](sound.md)). The AdLib's ports are in `m86_soc`; the rest is the board's |
| `rtl/soc/m86_usbmouse.v` | A USB mouse as port E3h and interrupt 12 ([mouse.md](mouse.md)) |
| `rtl/soc/m86_uart.v` | The console's serial port |
| `rtl/soc/m86_spi.v` | The SD card's SPI port |
| `rtl/boards/sergei_ml2.v`, `boards/sergei_ml2.lpf` | The board: PLL, reset, pins |

Each file's header says what of its chip is there and what is not.
The devices follow the model in `sim/pc.c` function for function, so
that what was tested against the model is what is built.

## Memory and ports

| | |
|---|---|
| 00000h up | RAM. In block RAM, `RAM_KB` kilobytes; or, with `MAIN_MEM`, the main memory: everything below 2^`MEM_AW` bytes that is not A0000h–FFFFFh (64 MB on Sergei ML2) |
| A0000h–BFFFFh | The VGA's memory ([video.md](video.md)) |
| F0000h–FFFFFh | The BIOS: a 16 KB ROM, repeated |
| Anywhere else | Reads FFh, writes are lost |

The BIOS finds out how much RAM there is: it looks for memory
downwards from 640 KB in 16 KB steps ([bios.md](bios.md)). Its own
image is 64 KB with the code in the first 12 KB and the reset vector
in the last 16 bytes; `tools/lanes.py` folds that into 16 KB.

The ports are those of [hwmap.md](hwmap.md) that have a device today:
20h, 21h, A0h, A1h, 40h–43h, 60h, 61h, 64h, 70h, 71h, 92h, the VGA's
3C0h–3DFh, and the private E0h–E2h, E4h, E8h and ECh. They are a
byte wide, except E8h and ECh: a 16- or 32-bit access to the others
reads FFh in its upper bytes and writes only its lowest. (A word
written to one of the VGA's index ports sets the index and the
register.)

## The main memory

With `MAIN_MEM = 1` the RAM is outside the SoC, and slow: a DDR3 or
SDRAM controller. Between it and the CPU is a cache,
`rtl/soc/m86_dcache.v`:

- Direct-mapped, lines of 16 bytes — one DDR3 burst — and 2^
  `CACHE_LINE_BITS` of them: 64 KB on Sergei ML2.
- Any access the CPU makes: one, two or four bytes at any address. An
  access that straddles two lines looks both up at once.
- **A read that hits costs the CPU no waiting.** The core says a cycle
  early what it is about to read (`e_req`, `e_addr`: the address as
  the address unit works it out, before the bus's registers), the
  cache looks it up at once, and the data is there in the cycle the
  request appears on the bus: a load is two cycles, address and data.
  Until round 17 the lookup began when the request appeared, and
  every load on the board took three. Only reads that lie within one
  32-bit word go this way; the others, and the instruction decoder's
  reads, take the extra cycle.
- Writes go into a queue of four and are done when the CPU's write
  cycle is; the CPU core has a `d_st_rdy` input that holds a store
  back while the queue is full.
- The data has separate ports for reading and writing, so a read is
  looked up while the write before it is being done, and a read
  announced in the same cycle as a write arrives goes ahead of it —
  unless they touch the same word, when it waits. "Store, then load"
  is most of what a stack does.
- A miss fetches the line, after writing back the line it replaces
  if that was changed.

The memory side is a word at a time (`m_req`, `m_we`, `m_addr`,
`m_wdata`, `m_rdata`, `m_ack`), on the CPU's clock. On Sergei ML2
that goes through `rtl/soc/m86_xclk.v` — one request at a time
across to the 48 MHz clock that Zeitlos's DDR3 controller makes for
itself — and into `rtl/ext/zeitlos/ddr3.v`. The controller's own
block register answers the second, third and fourth word of a line
without going to the memory again.

The memory port (E4h, E8h, ECh) shares the memory side with the
cache and has a second, similar path (`x_`) to the controller's
registers. The BIOS uses it to train the DDR3 before anything else
([bios.md](bios.md#memory-training)); `MEM_TRAIN = 1` is what tells
it to.

The A20 gate is in front of all of it: until it is opened (port 92h
or the keyboard controller) address bit 20 is zero, so the first
megabyte repeats above itself as on an AT, and DOS starts that way.

## The bus

The CPU has one data bus for memory and ports. A read request is held
until it is answered; everything in this SoC answers in the cycle
after the request, as block RAM must. A write is done in the one
cycle it is asked in. So every memory read costs the CPU a cycle more
than in the simulations of the core alone, where memory answers at
once: the core's stall logic was checked for this by running all the
vectors and the DOS session in lockstep with such a wait
(`M86B_WAIT=1`).

## The keyboard

Two at once, both ending in the keyboard controller's queue
(`m86_kbd.v`, ports 60h and 64h, interrupt 1):

- **A USB keyboard.** A HID host outside the SoC (on Sergei ML2,
  `rtl/ext/usb_hid_host`) hands over each boot-protocol report: the
  modifier byte and up to four keys held. `m86_usbkbd.v` compares it
  with the one before and sends what a PC keyboard would have: set-1
  make and break codes, E0h before the keys the 101-key keyboard
  added, and it repeats the last key pressed after half a second,
  eleven times a second, because a USB keyboard leaves that to the
  host. Programs that read port 60h themselves — games — see a PC
  keyboard. Not done: Pause, the lock lights, more than four keys at
  once besides the modifiers.
- **The serial console**, as before: each character received becomes
  the key strokes that type it on a US keyboard.

The BIOS turns scancodes into characters for a US layout
([bios.md](bios.md)).

## The console

Port E0h written sends a character; read, bit 7 says the 16-character
queue is full, and the BIOS waits. The BIOS's teletype call copies
every character it draws to this port, so the console shows what DOS
and well-behaved programs print. What arrives on the serial line
becomes key presses: Ctrl or Shift down, the key down, the key up, as
set-1 scancodes through the keyboard controller, so that the BIOS and
DOS see a keyboard and not a serial port.

## The display

A VGA since round 19: text, the CGA and EGA 200-line graphics modes
and 320 x 200 in 256 colours, all shown in the standard 640 x 480
picture at 60 Hz on a 25.2 MHz pixel clock. [video.md](video.md) is
its page: the modes, the memory, the registers, the tests. The
character ROM is code page 437, made by `tools/mkfont.py` from
Zeitlos's font ([sw/font](../sw/font/README.md)).

The video memory is 64 KB of block RAM with two ports, one for the
CPU and one for the display.
The memory trainer still runs from it at B8000h: after reset the VGA
is in the text layout, before any mode is set.

DVI is ours (`m86_dvi.v`, from the DVI specification), serialised the
way Zeitlos does it on these boards: a 126 MHz bit clock, two bits a
cycle through a double-data-rate output cell.

Tested three ways. `sim/m86_dvi_tb.v` receives what the encoder
sends, ten bits a pixel off the serial outputs, decodes it by the DVI
rule and compares, for every byte value and every sync combination.
`make check-soc` takes a whole picture off the display's pins at the
end of the boot test and reads it back as text
(`tools/readscreen.py` matches each cell against the character ROM):
what the BIOS printed must be what the display shows. And
`make check-gfx` compares pictures in five modes with the model's.

## The SD card

Ports E1h and E2h ([hwmap.md](hwmap.md)). The card is brought up at
375 kHz, then run at 6 MHz. The BIOS does the protocol; the port only
shifts bytes.

## How it is tested

| | What runs | How |
|---|---|---|
| `make check-soc` | The BIOS boot test | The SoC's RTL under Verilator, through its pins: a terminal on the serial line and the model's SD card, a bit at a time, on the SPI lines (`sim/soc_tb.cpp`) |
| `make soc-dos` | DOS, then a session at the prompt | The same |
| `make check-soc` (second half) | The boot test typed on a USB keyboard | HID reports into the SoC, with Shift, through `m86_usbkbd.v`, the keyboard controller and the BIOS |
| `make check-tb` | (The cache test announces reads early, with and without a write beside them, and sometimes does not follow through, as the CPU does after a fault.) The USB keyboard translation against the scancodes a PC keyboard sends, with repeat (`sim/m86_usbkbd_tb.v`). The cache alone: 200,000 random accesses against a copy. The cache, the clock crossing and Zeitlos's DDR3 controller with its registers, on two unrelated clocks, against Zeitlos's DRAM model, which checks the DDR3 protocol and timing. The DVI encoder | Icarus Verilog (`sim/m86_dcache_tb.v`, `m86_ddr3_tb.v`, `m86_dvi_tb.v`) |
| `make check-gfx` | A program that draws in five video modes | The model's picture and the one off the SoC's display pins, compared pixel for pixel ([video.md](video.md#tests)) |
| `make check-gfx2` | A program that draws in 640 x 480 and 640 x 350 | The same comparison, on the SoC built with video memory outside ([video.md](video.md#tests)) |
| `make check-nobram` | The boot test and both graphics tests | On the SoC built as Lakritz builds it, all video memory outside: text and seven pictures are the model's |
| `make check-spk` | A program that sounds the speaker, and the BIOS's bell | The bench measures the speaker bit's frequency ([sound.md](sound.md#tests)) |
| `make check-opl` | The AdLib's synthesiser | RTL against the reference model, 24,748 samples ([sound.md](sound.md)) |
| `make check-mouse` | Mouse reports | Interrupt 12 and the port's bytes, model and SoC ([mouse.md](mouse.md)) |
| `make check-soc-train` | The BIOS trains the memory, then the boot test; and a memory that cannot be trained | The SoC with `MAIN_MEM` and `MEM_TRAIN`; the bench is the memory and stands in for a read path with one right setting, which the trainer has to find |
| `make check-soc-main` | The boot test and the DOS session, memory behind the cache | The same bench as a plain memory |
| `make check-gate` | The BIOS boot test | The netlist Yosys makes for the ECP5, with models of the block RAM and multiplier, on the same bench |
| `make gate-dos` | The session at the prompt | The same. About twenty minutes |

The SoC is not run in lockstep with the model: its timer and serial
line keep real time and the model's keep count of instructions, so
the two would drift apart at the first timer interrupt. The CPU is
run in lockstep ([verification.md](verification.md)); the SoC is
tested by what it does.

**The gate-level run earned its keep at once.** A register in the CPU
was assigned in two always blocks. Simulation of the RTL took the
last assignment; synthesis resolved the conflict to a constant, and
said so in one line among forty thousand. The check now fails the
build on that line. Yosys ships its ECP5 block RAM and multiplier as
black boxes, so the two models are ours: `tools/ecp5_bram_sim.py`
follows Yosys's own mapping file for what a port sees at each width.

What simulation cannot say: whether the pins are right, whether a
real card behaves as the model card does, whether the PLL locks.
That is the board test.

**And the DDR3 PHY.** Zeitlos's ECP5 PHY is made of the FPGA's own
delay and capture cells, which we have no models of, and training is
about their analogue behaviour. So the stand-in in
`make check-soc-train` proves that the trainer, as translated, runs
on our CPU and finds the answer when there is one; `make check-tb`
proves our cache and clock crossing against the real controller; and
that the PHY and the trained settings work is known from Zeitlos on
this same board, not from anything here.

## Size, on the LFE5U-45F

| | |
|---|---:|
| Logic cells | 25,600 of 43,848 (58%; round 30. Paging took about 1,600 in round 29, virtual 8086 mode and the I/O bitmap 600, the Sound Blaster 130) |
| Block RAM | 97 of 108: CPU 30, cache 19, ROM 8, video memory 32, line buffer 1, character ROM 2, colours 1, USB hosts 2, AdLib 2 |
| Multiplier blocks | 9 |
| Routed clock | 34.6 MHz for the 33.16 it runs at (round 30), with the placer told to weigh timing three times as heavily as it does by itself (`PNR_OPT` in the Makefile). Without that the same design gives 33.45 at best and 32.2 on another seed; with it two seeds gave 34.6 and 33.9. The 48 MHz clocks of the sound and the memory route at 56 and 75 |

That is with the DDR3 memory and the USB keyboard. Zeitlos's
controller and PHY are about 3,000 cells; the USB host and the
keyboard translation about 1,000, more than they need to be (the
translation looks its table up in several places at once) and a
thing to trim for Lakritz. The build with 160 KB of block RAM in place of it
(round 14) was 8,000 cells and all 108 block RAMs.

The VGA and DVI output are about 2,000 cells and 35 block RAMs (the
text display they replace was 400 and 6). Sixteen block RAMs are
free, after the data cache gave up half of its own.

The slowest path now starts in the RAM: twenty block RAMs' outputs
through a multiplexer, the lane rotation, and into the CPU's ALU.
