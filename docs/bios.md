# BIOS

`sw/bios/bios.asm` is the Mach86 BIOS: one NASM source, a 64 KB image
for F000:0000. It is written from public descriptions of the BIOS
interrupt interface and of the chips ([cleanroom.md](cleanroom.md));
no BIOS listing or disassembly was used.

It is enough to boot DOS today. It is not complete, and this page says
where.

## Power-on

0. If the machine says its memory needs training (port E4h, bit 1),
   train it first: [below](#memory-training). Nothing else can be
   done before, because there is no RAM for a stack.
1. Clear the interrupt vector table and BIOS data area; point every
   vector at a handler that just returns, then install the services.
2. Program both interrupt controllers (bases 08h and 70h) and timer
   channel 0 for 18.2 ticks a second.
3. Find how much conventional memory there is: look for RAM
   downwards from 640 KB in 16 KB steps, by writing and reading back.
   Fill in the BIOS data area and reserve the last kilobyte found for
   the BIOS's own variables. With 640 KB programs see 639 KB and that
   kilobyte is at segment 9FC0h; the block RAM build had 160 KB.
4. Set 80x25 text mode and print a banner with the memory size.
5. Find the SD card and decide what kind of disk it is (below).
6. Enable interrupts and boot (interrupt 19h).

## Memory training

DDR3 memory cannot be read until the read path has been tuned to the
board: which clock phase, which cycle, which beat. Zeitlos does this
in software and so do we, with Zeitlos's algorithm
(`sw/train/ddr3_train.c`; its comments tell what was learned on the
hardware). It is C, compiled with `gcc -m16` for the 386 in real
mode, linked as a flat 3 KB program and carried in the BIOS ROM.

Before training there is no RAM at all — except the text screen's
4 KB, which is block RAM. The BIOS clears it, copies the trainer to
B800:0000, puts the stack at the top of the same 4 KB, and calls it.
The trainer reaches the controller's registers and raw words of the
memory through the memory port (E4h, E8h, ECh:
[hwmap.md](hwmap.md#io-ports)), which goes past the cache. It
reports on the debug console only — the serial line — since the
screen is where it lives; the screen is cleared when the BIOS sets
the text mode afterwards.

What it prints: the controller's status; a map of where the read
gate catches the memory's strobe; for the first write delay at which
both byte lanes can be read, a map per lane of the settings that
work; the setting chosen (`ddr3 tune ...`, `C` for a lane whose
choice has working neighbours on both sides, `e` for an edge); and a
check through the normal path (`ddr3 check ... ok`). If no setting
works it prints `ddr3 training FAILED` and what does come back, and
the BIOS stops with `Memory training failed. System halted.`

The whole of it takes well under a second.

## Services

| Interrupt | Service | State |
|---|---|---|
| 08h | Timer tick: tick count, midnight flag, calls 1Ch | Done |
| 09h | Keyboard: scancodes to characters, Shift, Ctrl, Alt, Caps Lock, Ctrl-Alt-Del | US layout only. A key that follows the E0h prefix acts as the old key with the same code, except that Shift does not make digits of the grey arrows. No Num Lock, no Ctrl-Break, no Alt or Ctrl codes for the function keys |
| 15h | 88h: memory above 1 MB, in KB. 87h: move a block anywhere in memory (through unreal mode; [pmode.md](pmode.md)). 90h, 91h: nothing | Round 24. E801h and E820h are not there; programs fall back to 88h |
| 10h | Video: set mode, cursor, scroll, characters, teletype, write string; pixels; palette and DAC; font and display information | Modes 03h, 04h–06h, 0Dh, 0Eh, 13h; a mode that is not there gives text. One page. The bell (07h) sounds the speaker ([sound.md](sound.md)). The list is in [video.md](video.md#the-bios) |
| 11h, 12h | Equipment word (with the FPU's bit when there is one: [fpu.md](fpu.md)), memory size | Done |
| 75h | The FPU's error (interrupt 13): port F0h, end of interrupt, then INT 02h | Done; no hardware raises it yet |
| 13h | Disk: reset, status, read, write, verify, parameters, drive type; and by sector number (41h check, 42h read, 43h write, 44h verify, 48h size) for the hard disk | One drive. No format |
| 14h, 17h | Serial, printer | Report a timeout: no ports yet |
| 15h | System: extended memory size, device hooks | Reports no extended memory until the CPU has protected mode. Everything else is "not supported" |
| 16h | Keyboard: read, peek, shift flags (and the enhanced forms) | Done |
| 18h, 19h | No boot disk; boot | Done |
| 1Ah | Tick count; clock time and date from the CMOS clock | No alarm, no setting the clock |

Vector 1Eh points at a diskette parameter table.

Everything the teletype function prints is also sent to the debug
console port ([hwmap.md](hwmap.md#io-ports)), so a boot can be
followed without a screen.

## The disk

The disk is the SD card, reached through the SPI ports
([hwmap.md](hwmap.md#io-ports)). The BIOS
brings the card up at power-on, reads its size, and then reads and
writes single 512-byte blocks. The card is brought up at the slow
speed a card requires (port E2h) and then switched to the fast one.
Only high-capacity cards (SDHC, SDXC) are supported. If the card does
not come up, the BIOS says which step failed and what the card last
answered ([running.md](running.md#if-it-does-not-work)).

**The console.** Every character the teletype service draws is also
written to port E0h, after waiting for the port to have room. On the
first board that port is the serial console, and it is all there is
to see.

**What kind of disk.** The BIOS reads the card's first sector:

- If it holds a diskette-style volume (512-byte sectors, at most 5,760
  of them, 1 or 2 heads, a plausible sectors-per-track), the card is
  **drive A:** with the geometry the volume states. A diskette image
  written to a card boots as a diskette.
- Otherwise the card is **hard disk 80h**, 63 sectors per track, with
  16 heads for cards up to 504 MB and more heads above that, to a
  limit of 1,024 cylinders.

Limits today:

- Only high-capacity (block-addressed) cards are accepted. Older
  standard-capacity cards are refused. This needs fixing before
  hardware.
- The cylinder-head-sector calls reach the first 8 GB. The calls by
  sector number reach the whole card, and DOS uses them
  ([card.md](card.md)).
- One disk. A card is a diskette or a hard disk, never both.

**Hard disk geometry.** If the first sector is a partition table, the
heads and sectors per track are those its first partition ends on:
the geometry whoever made the disk had in mind, and the one the boot
sector inside the partition was written for. A card's size says
nothing about that: the 4 MB test image is laid out for 16 heads, and
a 32 GB card sized by its capacity would be given 255. Without a
partition table it is 63 sectors and the fewest heads that reach the
end of the card.

## Unhandled exceptions

On a 386, vectors 0Ah to 0Fh are both hardware interrupts 2 to 7 and
CPU exceptions (a segment-limit violation arrives on vector 0Dh). The
handlers ask the interrupt controller which it was. A hardware
interrupt is acknowledged and dismissed. An exception, like a divide
error or invalid opcode that no program has taken over, prints

```
Mach86 BIOS: unexpected exception 000D at 1234:5678
```

and stops. A real PC of the period would hang silently.

## Testing

`tests/prog/boottest.asm` is a bootable diskette image that calls the
services DOS depends on and checks the results: memory size,
equipment, disk parameters, read, write and read back, a request past
the end of the disk, the timer, the clock, the screen, and the
keyboard. `make check` boots it in the model with scripted keys.

Two DOS-level tests sit above it ([model.md](model.md#dos)).
