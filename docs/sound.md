# Sound

Rounds 20 and 21: the PC speaker and the AdLib card's FM
synthesiser, added up and sent out as S/PDIF (Sergei) or as a
one-bit sigma-delta signal (Lakritz). This page says what is built,
how it is tested, and what "sound" still lacks.

## The PC speaker

A PC's speaker is one bit: timer channel 2's output, switched by bit
1 of port 61h (bit 0 is the channel's gate). Programs use it two
ways: they set the channel to a square wave and let it run, which is
a tone; or they stop the channel, which leaves its output high, and
switch bit 1 themselves, fast and with varying width, which plays
recorded sound after a fashion.

| Part | Where | What |
|---|---|---|
| The bit | `rtl/soc/m86_soc.v`, `m86_pit.v` | `spk` = channel 2's output and port 61h bit 1. The channel's output is high while its gate is low (modes 2 and 3), which the second way needs |
| Bit to samples | `rtl/soc/m86_spk.v` | 48,000 samples a second: each is the share of its 1,000 clock cycles the bit was high, with the unchanging level taken out (above 30 Hz everything passes). A square wave comes out at a quarter of full scale |
| Samples to light | `rtl/ext/zeitlos/audio_spdif.v` | Zeitlos's S/PDIF transmitter, unchanged, on the board's 48 MHz oscillator as in Zeitlos |
| The pin | `boards/sergei_ml2.lpf` | `AUD_OPTICAL`, ball A13: the optical output |

Counting how long the bit is high, and not just looking at it 48,000
times a second, is what a speaker cone does to a signal too fast for
it. It is what makes the second way come out as sound and not as
whistles, and it keeps tones above a few kilohertz in tune.

The audio side runs on the 48 MHz oscillator and not on the CPU's
clock for the reason Zeitlos gives: 48 MHz makes 48,000 Hz exactly
(1,000 cycles a sample, S/PDIF half-cells of 7 or 8 cycles), and the
transmitter is known to work on this board at that clock. The
speaker bit crosses over through a synchroniser.

**On Sergei the sound comes out of the optical connector only:** it
needs a receiver, amplifier or DAC with an optical (TOSLINK) input,
set to that input. The stream is always there, silent or not, so a
receiver stays locked. Nothing goes over the DDMI cable: the display
output is DVI, which carries no sound.

## The BIOS

The bell (character 07h through interrupt 10h's teletype call, which
is what DOS uses for Ctrl-G) sounds 896 Hz for just under a quarter
of a second. It times itself by the timer channel's own output, so
it works with interrupts off.

## Tests

- `make check-tb` (`sim/m86_spk_tb.v`): the speaker bit into
  `m86_spk.v` into the transmitter, and a receiver in the bench that
  knows only the S/PDIF format: it finds the preambles on the line,
  decodes the bits, checks parity and takes the samples out. A 1 kHz
  square wave must come out as 48,000 samples a second that repeat
  every 48 and swing about 4,000 either way, left and right the
  same; a bit held high must die away to exactly nothing; pulses at
  16 kHz with changing width must come out as a level that follows
  the width.
- `make check-spk` (`tests/prog/spktest.asm`): on the simulated SoC
  the bench measures the speaker bit. 1,000 Hz when the program sets
  that; nothing with the speaker switched off, and nothing with only
  the gate on; 896 Hz while the BIOS rings its bell (890 measured,
  the tenth of a second it is measured over being short), and
  nothing after. The same program runs on the model, where only the
  bell's ending can be seen.
- `TUNE.COM` on the boot disk plays a scale and the bell: the test
  for a board, and part of `make check-card` on the model.
- Not tested in simulation: the path as a whole from a program to
  the optical pin (its two halves are, separately), and the pin.

## The AdLib

The AdLib card is one chip, the YM3812 ("OPL2"), at ports 388h and
389h: nine voices of two sine-wave operators each, the first
modulating the second or both sounding, each with its own envelope.

| Part | Where | What |
|---|---|---|
| The bus side | `m86_opl2_bus` in `rtl/soc/m86_opl2.v`, inside the SoC | The register index, the two timers and the status byte: what a program needs to find the card |
| The sound | `m86_opl2` in the same file, in the board's audio part | The register file and one operator's arithmetic, used 18 times a sample |
| The tables | `tools/mkopl.py` | A quarter sine as attenuation, and the exponential back: 512 words, one block RAM |
| The reference | `sim/opl2.c`, `sim/oplref.c` | The same computation in C; writes WAV files to listen to |

There: frequency, the multiples, the four waveforms, the envelope
(attack, decay, sustain, release, with and without sustaining, rate
scaling by pitch), total level and level scaling by pitch, feedback,
both connections, vibrato and tremolo with both depths.

**Not there: the rhythm mode** (register BDh bit 5: bass drum,
snare, tom, cymbal, hi-hat from voices 7 to 9). Music that uses it
plays those three voices as ordinary ones, which is wrong but not
silent. Also not there: the composite sine wave mode, and the chip's
exact bit patterns: the envelope's timing is close, not identical.

It makes 48,000 samples a second where the chip makes 49,716; the
phase steps are scaled by that ratio (to one part in 10,000), so
pitch is right and envelopes run 3.5% slow.

Source: the YM3812 application manual, for the registers and what
each does. How the numbers are computed is ours.

## The outputs

`rtl/soc/m86_audio.v` adds speaker and AdLib (saturating) and gives:

- samples and strobes for Zeitlos's S/PDIF transmitter: Sergei's
  optical connector;
- **a one-bit sigma-delta signal** (Zeitlos's second-order modulator,
  `audio_sd`, unchanged, at 48 MHz): for a pin with a resistor and a
  capacitor, which is Lakritz's audio output (`AUDIO_L` M3,
  `AUDIO_R` N1 in Zeitlos's constraints). Built and tested here;
  on Lakritz since round 23
  ([boards.md](boards.md#lakritz-where-it-stands));
- **the display's cable** (round 25, both boards): see below;
- **a PT8211 DAC** (`rtl/soc/m86_pt8211.v`), for the Mozart boards:
  simulated, not run ([boards.md](boards.md#konfekt-and-mozart)).

### Sound on the display's cable

`HDMI ON` (port 1E1h bit 0) makes the display output HDMI rather
than DVI: between the pixels it sends data islands with the sound in
them, 48,000 frames a second of 16 bits, the same samples the other
outputs get, on both channels. `HDMI OFF` is plain DVI again, and
`HDMI` alone says which it is. It is off at power-on, because a
monitor that only knows DVI may show nothing when it is on; put
`HDMI ON` in `AUTOEXEC.BAT` when the display or capture device takes
it. Ctrl-Alt-Del leaves it as it is. The switch is taken at the start
of a picture.

The islands are Zeitlos's: `rtl/ext/zeitlos/ddmi_island.v` and its
encoder `tmds_encoder.v`, unchanged. One island on every line, two
packets in it: sound samples in the first; in the second, general
control, the AVI, SPD and audio InfoFrames once a picture, and clock
regeneration every eighth line (N = 6144, CTS = 25200: the pixel
clock is 25.2 MHz from the oscillator the sound clock is, so the
numbers are exact). The picture says it is format 1, 640 x 480 at
60 Hz, which it always is ([video.md](video.md)). The SPD InfoFrame
still says "Zeitlos".

`rtl/soc/m86_hdmi.v` is ours: it rebuilds the line and character
counters the scheduler wants (they start at the front porch; the
VGA's start at the picture) from the display's signals, and
serialises as `m86_dvi.v` does. The sound crosses from the 48 MHz
clock in the scheduler's own queue of 16 frames.

**Test** (`make check-tb`): `sim/m86_hdmi_tb.v` writes a picture's
worth of characters to a file and Zeitlos's receiver model
(`tools/ddmi.py`, unchanged) takes it apart knowing nothing of the
gateware: with the switch off it must be DVI; with it on it must find
every packet with good parity, the InfoFrames, 800 frames of a known
sound sequence unbroken, at 48,000 a second by the clock
regeneration numbers. `HDMI ON` and `OFF` run under DOS in
`make check-card`. **It works on a Sergei ML2** with the display it
was tried on.

Cost: about 600 LUTs.

## Tests of the AdLib and the outputs

- `make check-opl`: the reference plays A above middle C and its
  pitch is measured (439 to 441 Hz); then a script of random
  instruments and notes on all nine voices, every register field
  used, is played by the reference and by the RTL, and the 24,748
  samples must be the same, every one.
- `make check-tb` (`sim/m86_audio_tb.v`): speaker and AdLib
  together swing further than the speaker alone; the one-bit
  output, averaged over each millisecond, is the samples (within 2
  of 32,768).
- `ADLIB.COM` on the boot disk finds the card by its timers the way
  programs do, plays a scale and a chord. In `make check-card` on
  the model, which has the bus side only: it checks the finding.
- Not tested: the sound of real music (nothing checks the reference
  but its pitch, the manual and listening to `output/opl/*.wav`),
  and register writes crossing from the CPU's clock on the board.

## Size

Speaker and transmitter 450 cells; the AdLib about 1,300 cells, two block RAMs and five multipliers.

## What is not there

- **Sound Blaster** (digitised sound: speech, effects). It needs
  the DMA controller, which is not built either.
- The AdLib's rhythm mode (above).
- A volume control. The level is fixed.
- Sound on a Lakritz pin: the signal is there, the board file is not.
