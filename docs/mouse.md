# Mouse

Round 21. A USB mouse on either of Sergei's two host ports, and the
interrupt 33h interface DOS programs use for a mouse.

## How it is put together

| Part | Where | What |
|---|---|---|
| USB | `rtl/ext/usb_hid_host/`, twice, in `rtl/boards/sergei_ml2.v` | Each port says whether it has a keyboard or a mouse; the board routes each to the SoC, so either device works in either port. A combined keyboard-and-mouse receiver shows up as one device and gives one of the two |
| The port | `rtl/soc/m86_usbmouse.v` | Port E3h, interrupt 12. Movement is added up until read |
| The driver | `tests/dos/mouse.asm` → `MOUSE.COM` | Stays in memory (about 1 KB), gives interrupt 33h. `AUTOEXEC.BAT` on the boot disk loads it |

**Why not a PC's mouse hardware.** A PC has a serial mouse on COM1 or
a PS/2 mouse behind the keyboard controller, and a driver from the
mouse's maker. The free drivers that speak those are GPL, which this
project keeps out of its tree, and both need a fair amount of
hardware emulated only so that a driver can undo it again. Programs
do not talk to the mouse; they talk to interrupt 33h. So the
hardware is the simplest thing that works and the driver is ours.
What is lost: a program that brings its own serial or PS/2 mouse
code and ignores interrupt 33h finds no mouse. That is rare.

## The port

Read E3h three times:

| Read | |
|---|---|
| 1 | Bit 0 left, 1 right, 2 middle button; bit 6: more movement is waiting than this reading takes, read three more; bit 7: a mouse has been seen since reset |
| 2 | Movement right since last taken, −128 to 127 |
| 3 | Movement down, the same |

Any write starts the three again. Interrupt 12 comes with every
report from the mouse.

## The driver

| Function | |
|---|---|
| 00h, 21h | Reset: AX = FFFFh, BX = 3 buttons |
| 01h, 02h | Show and hide the cursor |
| 03h | Position and buttons |
| 04h | Set position |
| 05h, 06h | Presses and releases of a button since last asked, and where |
| 07h, 08h | Horizontal and vertical range |
| 0Bh | Movement since last asked, in mickeys |
| 0Ch, 14h | The program's event handler: set, swap |
| 15h–17h | Size of the driver's state; save; restore |
| 1Bh, 24h | Sensitivity (fixed), version and type |

Positions are in the usual virtual screen, 640 across in every mode
and as many lines down as the mode has; one mickey moves one unit
across and half a unit down.

**The driver draws a cursor in text modes only** (the cell's colours
inverted). In graphics modes a program that asks the driver to show
a cursor gets none; games draw their own, and those are who this is
for now. Not there either: functions above 24h, light-pen
emulation, the text cursor's mask and the graphics cursor's shape
(09h, 0Ah), the double-speed threshold, acceleration.

## Tests

- `make check-mouse` (`tests/prog/mousetest.asm`): reports become
  interrupt 12 and the three bytes, on the model and on the
  simulated SoC, where they come in as the USB host gives them.
- `make check-card`: under DOS on the model, `MOUSE` loads,
  `MOUSET` asks the driver for positions and buttons as reports
  come, more movement than one reading holds included, and counts
  its event handler's calls.
- `MOUSET.COM` on the boot disk is the test for a board: it prints
  the position and buttons as they change.
- Not tested: the two USB ports with real devices; the "more is
  waiting" bit on the SoC (the model has it); the driver on the
  simulated SoC.
