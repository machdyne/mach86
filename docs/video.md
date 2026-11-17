# Video

The VGA: the modes, how the memory is laid out, what the registers
do, what the BIOS offers, how it is tested, and what is not there.
Round 19 built it with 64 KB of video memory; round 22 added the
rest of the 256 KB, in the board's main memory, and with it the
350- and 480-line modes. The hardware is `rtl/soc/m86_vga.v` and
`rtl/soc/m86_vfetch.v`; the reference model is `sim/vga.c`; the
BIOS part is `sw/bios/video.inc`.

Sources: the IBM VGA technical reference as it describes the
registers and the graphics controller's write and read modes; the
640 x 480 at 60 Hz display timing ([cleanroom.md](cleanroom.md)).

## Modes

| Mode | What | Memory layout | Shown as |
|---|---|---|---|
| 03h (and 00h–02h, 07h) | 80 x 25 text, 16 colours | odd/even at B8000h | 640 x 400 |
| 04h, 05h | 320 x 200, 4 colours (CGA) | odd/even at B8000h, two halves | each pixel 2 x 2 |
| 06h | 640 x 200, 2 colours (CGA) | plane 0 at B8000h, two halves | each line twice |
| 0Dh | 320 x 200, 16 colours (EGA) | four planes at A0000h | each pixel 2 x 2 |
| 0Eh | 640 x 200, 16 colours (EGA) | four planes at A0000h | each line twice |
| 10h | 640 x 350, 16 colours (EGA) | four planes | as it is, lines 65 to 414 |
| 11h | 640 x 480, 2 colours | plane 0 | as it is |
| 12h | 640 x 480, 16 colours (VGA) | four planes | as it is |
| 13h | 320 x 200, 256 colours | chained at A0000h | each pixel 2 x 2 |

The picture a mode makes has 350, 400 or 480 lines; which, the
display takes from the sync polarities in the miscellaneous output
register, as a monitor does. It is always sent inside a 640 x 480
picture at 60 Hz, centred. A real VGA shows the 350- and 400-line
modes at 70 Hz; programs that count pictures to keep time run a
seventh slow in those.

Programs that set the registers themselves get what the registers
say: the line count from the polarities, lines shown twice when the
double-scan bit or a two-line character cell says so, the line
length from the offset register, the first word from the start
address (in the 256-colour modes too). So the unchained 256-colour
modes ("mode X": 320 x 200 or, with 480 lines shown twice,
320 x 240, with pages to flip between) should work; **nothing here
tests them**.

Not there: mode 0Fh (640 x 350 monochrome); 40-column text as its
own picture (modes 00h and 01h give 80 columns); more than one text
page; 360-pixel-wide and other non-standard timings (the picture is
always 640 wide); smooth scrolling by the pixel-panning register;
split screen; text with other than 16 lines a character; fonts
loaded by programs. BIOS text in modes 10h to 12h uses the 8 x 8
font and the top 200 lines.

## The memory

256 KB, as a VGA has: 65,536 words of four bytes, one byte for each
plane. The first 16,384 words are block RAM with one port for the
CPU and one for the display; the rest are in the board's main
memory (below). What a CPU address in A0000h–BFFFFh reaches depends
on two sequencer bits, as on the real thing:

| Layout | When | Byte at offset *a* |
|---|---|---|
| planar | sequencer register 4: odd/even off, chain-4 off | all planes of word *a*, through the graphics controller |
| chained | chain-4 on | plane *a* mod 4 of word *a* / 4 |
| odd/even | odd/even on (text, CGA four colours) | plane *a* mod 2 of word *a* / 2 |

The window comes from graphics controller register 6: A0000h for
128 KB or 64 KB, B0000h or B8000h for 32 KB. Outside the window
reads give FFh and writes are lost.

Two things differ from a real VGA and only unusual programs can
tell. A chained byte lies at word *a* / 4 here and at word *a*
there, so a program that draws chained and reads planar (or the
other way) finds the bytes elsewhere. And the graphics controller's
logic is not applied to chained and odd/even writes; in the standard
modes its registers are set so that it would do nothing.

### Planar writes and reads

A write of one byte goes to the planes enabled in sequencer register
2, by graphics controller register 5's write mode:

| Mode | Each plane gets |
|---|---|
| 0 | the byte rotated (register 3), or all ones or zeros from set/reset (registers 0 and 1) for the planes enabled there; then the logical function with the latch (register 3); then the bit mask (register 8) chooses between that and the latch |
| 1 | the latch |
| 2 | all ones or zeros by the byte's bit for that plane; then function and bit mask as mode 0 |
| 3 | set/reset for every plane; the bit mask is register 8 and the rotated byte |

A read loads the latch with the word and returns one plane of it
(read mode 0, register 4 says which) or, in read mode 1, a bit for
each pixel that has the compare colour (register 2) in the planes
cared about (register 7).

An access of two or four bytes is done a byte at a time in order,
as the 386 does it on a real card, so `rep movsw` in write mode 1
copies as it should.

### Past 64 KB

Only planar words can be past the first 16,384 (the other two
layouts reach a quarter and a half of the address space). For
those, on a board built with `VGA_EXT`:

- **The CPU's side** asks the board for the word (`xv_` on the SoC:
  a request held until answered, with the planes a write changes).
  On Sergei that is a bridge to the DDR3, above the 64 MB the
  machine uses. A write is one memory write; nothing is read first.
  It takes some 15 CPU cycles where the block RAM takes one.
- **The display** cannot wait for memory. At the start of each line
  it asks for the next line's 80 words (`vf_`), `m86_vfetch.v` reads
  them (four at a time where the memory can: the SDRAM) into one half of a two-line buffer on the memory's clock, and
  the display reads the buffer on its own clock. It asks only when
  the line reaches past the block RAM, so the 200-line modes cause
  no memory traffic. While a line is being read the display keeps
  the memory (about 9 of a line's 32 microseconds); the CPU's cache
  waits.
- Words below 16,384 are shown from the block RAM even in these
  modes: the top 204 lines of a 640-wide picture.

Writes to the VGA's registers go through the same queue as writes
to its memory, and reads of them wait for the queue: a program's
order is kept even when memory is slow. (Round 22's test found a
write overtaken by the register change after it.)

**With no block RAM at all** (`VGA_BRAM = 0`, Lakritz) every word of
every layout goes the same way: the CPU's side asks the board for
each word, and the display asks for every line of every mode, text
included. `make check-nobram` shows the text screen and all seven
graphics pictures to be the same that way.

Without `VGA_EXT` (the plain simulated SoC) addresses wrap at 64 KB
and the modes above 200 lines show rubbish below line 204.

## Registers

Ports 3C0h–3CFh, 3D4h, 3D5h, 3DAh. A word written to an index port
(3C4h, 3CEh, 3D4h) sets the index and the register.

| Group | Used | Kept only |
|---|---|---|
| Sequencer (3C4h) | 1 bit 3 (pixels two wide), 2 (planes written), 4 (layout) | — |
| Graphics controller (3CEh) | 0–8 as above; 5 bit 5 (CGA four colours), bit 6 (256 colours); 6 bit 0 (graphics), bits 3:2 (window) | — |
| Attribute controller (3C0h) | 0–0Fh palette; 10h bit 7; 12h plane enable; 14h colour select; the index's bit 5 turns the screen on | the rest read as 0 |
| Display controller (3D4h) | 09h bit 7 and a cell of two lines (lines shown twice); 0Ah bit 5, 0Eh, 0Fh (cursor); 0Ch, 0Dh (start address); 13h (line length); 17h bit 0 (CGA line addressing) | all others: they read back what was written |
| DAC (3C6h–3C9h) | 256 colours of 18 bits, the mask | — |
| Status (3DAh) | bit 0 not showing a pixel, bit 3 vertical sync, from the display's real counters; a read resets the attribute controller's index/data switch | — |
| Miscellaneous (3C2h, 3CCh) | Bits 7:6, the sync polarities: 350, 400 or 480 lines | the rest reads back |

The timing registers do nothing: the picture is always sent as the
same 640 x 480. The cursor is the bottom two lines of its cell; the
cursor's shape registers are kept and not used.

## The BIOS

Interrupt 10h ([bios.md](bios.md)):

| Function | |
|---|---|
| 00h | Set mode: the table in `video.inc` gives each mode its register values, palette and colours. Bit 7 of the mode keeps the memory's contents |
| 01h–03h, 05h, 0Fh | Cursor, page (one page), mode asked |
| 06h, 07h | Scroll: in graphics modes too, any window |
| 08h–0Ah, 0Eh, 13h | Characters: in graphics modes drawn with the 8 x 8 font, in the 16-colour modes with XOR when bit 7 of the colour is set |
| 0Bh | CGA palette and background |
| 0Ch, 0Dh | Write and read a pixel, in every graphics mode |
| 10h | Palette registers and DAC: 00h–02h, 07h, 10h, 12h, 15h, 17h, 18h, 19h, 1Ah |
| 11h/30h | Where the fonts are (the 8 x 8 one; vector 43h and 1Fh point at it too) |
| 12h/BL=10h | EGA information: colour, 256 KB (what programs expect to hear) |
| 1Ah/00h | Display combination: VGA with a colour display |

The 8 x 8 font is Zeitlos's ([sw/font](../sw/font/README.md)); the
default colours are the standard 16, the CGA's, and the VGA's 256
(computed by `tools/mkvideo.py` from their rule: 16 EGA colours, 16
greys, then hue, saturation and brightness steps).

The BIOS grew from 8 to 12 KB; the ROM is now 16 KB.

## Speed

An access takes a cycle for each word of the video memory it
touches: a planar byte is a word, a chained double word is one, a
text cell is one. The CPU does not wait for a write: writes go
through a queue of four (`st_rdy`, as with the data cache). A read
takes two cycles a word, and one more. Nothing is cached; video
memory is never in the data cache.

## Tests

- `make check-gfx`: `tests/prog/gfxtest.asm` boots, and in modes
  13h, 0Dh, 04h, 06h and back in 03h draws through the BIOS and
  straight into the memory: bytes, words and double words; write
  modes 0 to 3, the logical functions, rotate, bit mask, set/reset,
  both read modes, a latch copy; the CGA's two halves. It reads back
  what it drew and prints the values. After each mode the model's
  picture (`m86pc -snap`) and the picture taken off the SoC's
  display pins (`soc_tb -snap`) are compared: they must be the same
  in every pixel.
- `make check-gfx2`: `tests/prog/gfxtest2.asm` does the like in
  modes 12h and 10h, most of it past 64 KB: bands by set/reset,
  pixels through the BIOS, a block with two planes open, a latch
  copy, write mode 2. On the SoC built with `VGA_EXT`, where the
  bench stands in for the board's memory and line buffer. Both
  pictures are the model's in every pixel.
- `make check-tb` (`sim/m86_vfetch_tb.v`): the line buffer's filler
  and the share of the memory, with two other masters reading and
  writing as fast as they are answered: 60 lines whole and in time,
  nobody answered with another's data.
- `make check-soc` still reads the text screen back from the
  display's pins as text.
- **Not tested in simulation:** the three together on the board's
  DDR3 (the bench's memory is a stand-in with made-up timing); how
  long a line really takes to read; modes 11h and X.
- The model is what the pictures are compared with, and nothing
  checks the model but the reference manual and looking at its
  pictures. `GFX.COM` and `GFX2.COM` on the boot disk are the same
  programs, for a board.

## Size

About 1,800 cells more than the text display it replaced. Block RAM:
32 for the memory, 2 for the 8 x 16 font, 1 for the colours, 1 for
the line buffer. The figures for the whole board are in
[boards.md](boards.md).
