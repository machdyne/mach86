# Font

`font16.mem` is Zeitlos's 8x16 font (its `sw/data/font/font16.mem`, at
commit `ede46a8`), copied as it is: 96 glyphs, ASCII 20h to 7Fh,
sixteen lines of eight 0/1 values each. Same owner and licence as
Mach86.

`tools/mkfont.py` makes the text mode's character ROM from it: the 256
characters of code page 437. The ASCII range is the font. The line
and block drawing characters (B0h to DFh) are drawn by rule. Accented
letters are shown as their base letter, and a few symbols (arrows,
triangles, bullets) are drawn simply; the rest are blank for now. No
glyph is taken from an IBM or other ROM.

`font8x8.mem` is Zeitlos's 8x8 font (its `sw/data/font/font8x8.mem`,
same commit), copied as it is: Daniel Hepper's public-domain font
(github.com/dhepper/font8x8), in the same format with eight lines a
glyph. `tools/mkvideo.py` makes the BIOS's 8 x 8 character table
from it, for text in the graphics modes: ASCII 20h to 7Fh, the rest
blank for now.
