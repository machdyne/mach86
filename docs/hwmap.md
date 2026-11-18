# Hardware map

The PC-compatible map Mach86 implements. The "Phase" column says when
each item first exists; before that the address reads as unpopulated.

## Memory

| Range | Use | Phase |
|---|---|---|
| 00000h–003FFh | Interrupt vector table | 1 |
| 00400h–004FFh | BIOS data area | 1 |
| 00500h–9FFFFh | Conventional memory | 1 |
| A0000h–AFFFFh | VGA graphics memory | 3 (round 19) |
| B0000h–B7FFFh | Monochrome text memory | 3 (round 19: the VGA's window can be put there) |
| B8000h–BFFFFh | Colour text memory | 3 |
| C0000h–C7FFFh | Video BIOS (shadowed RAM) | 4 |
| C8000h–EFFFFh | Upper memory, free for memory managers | 7 |
| F0000h–FFFFFh | System BIOS (shadowed RAM, write-protected) | 1 |
| 100000h–10FFEFh | High memory area, with A20 enabled | 4 |
| 100000h and up | Extended memory | 4 |
| FFFF0000h–FFFFFFFFh | Alias of the system BIOS; reset starts at FFFFFFF0h | 6 |

Extended memory offered to the PC is capped per board in
[boards.md](boards.md). Video memory (256 KB) is to be taken from main
memory outside the PC's address space; for now it is 64 KB of block
RAM ([video.md](video.md)).

Before level 3 of the core there are no address bits above the real
mode range, and reset starts at FFFF:0000h, which is the same place.

## I/O ports

| Ports | Device | Phase |
|---|---|---|
| 000h–00Fh, 083h | DMA controller 1 (8237): channel 1 only, for the Sound Blaster | 3 (round 30, [sound.md](sound.md#the-sound-blaster)) |
| 020h–021h | Interrupt controller 1 (8259) | 3 |
| 040h–043h | Timer (8254) | 3 |
| 060h, 064h | Keyboard controller (8042) | 3 (data port), 4 (full) |
| 061h | System control port B: speaker gate and timer channel 2 | 3 (round 20: the speaker sounds, [sound.md](sound.md)) |
| 070h–071h | Real-time clock and CMOS memory; NMI mask | 4 |
| 080h–08Fh | DMA page registers; 080h takes POST codes | 5 (080h: 3) |
| 092h | System control port A: fast A20, fast reset | 4 |
| 0A0h–0A1h | Interrupt controller 2 | 4 |
| 0C0h–0DFh | DMA controller 2 | 5 |
| 0E0h | Mach86 private: debug console. Write: a character. Read: bit 7 set while there is no room for one | 1 |
| 0E1h | Mach86 private: SPI data. Write sends a byte to the SD card; read returns the byte received | 1 |
| 0E2h | Mach86 private: SPI control. Bit 0: card selected. Written with bit 2 set, bit 1 sets the speed (0: 400 kHz or less, 1: fast). Bit 7, read only: transfer in progress | 1 |
| 0E4h | Mach86 private: memory port, command. Read: bit 0 there is a main memory behind a cache, bit 1 it needs training, bit 7 a transfer is in progress. Write starts a transfer: bit 0 write (else read), bit 1 a register of the memory controller (else a word of memory) | 3 |
| 0E8h | Mach86 private: memory port, address (32 bits): a word number in the memory, or a register number | 3 |
| 0ECh | Mach86 private: memory port, data (32 bits) | 3 |
| 0E3h, 0E5h–0E7h, 0E9h–0EBh, 0EDh–0EFh | Mach86 private: shadow control, meta interface (provisional) | 3 |
| 201h | Game port | 5 |
| 220h–22Fh | Sound Blaster: the DSP of a 2.0; the AdLib again at 228h, 229h | 3 (round 30, [sound.md](sound.md#the-sound-blaster)) |
| 388h–389h | AdLib (OPL2); also reachable through the Sound Blaster ports | 3 (round 21, [sound.md](sound.md)) |
| 1E0h | Mach86's speed control: cycles the CPU waits after each instruction ([speed.md](speed.md)) | 3 (round 24) |
| 1E1h | Mach86's display switch: bit 0 set is HDMI with sound, clear is DVI ([sound.md](sound.md#sound-on-the-displays-cable)) | 3 (round 25) |
| 1E8h | The CPU's own: what its paging unit read across two pages ([cpu_b.md](cpu_b.md#round-29)). Reads give the core's `x_rd`, writes are ignored; software has no use for it | 3 (round 29) |
| 0E3h | Mach86's mouse port (not a PC's), with interrupt 12 ([mouse.md](mouse.md)) | 3 (round 21) |
| 3B0h–3BBh | VGA, monochrome register addresses | 4 |
| 3C0h–3CFh | VGA | 4 |
| 3D0h–3DFh | VGA, colour register addresses (CRTC subset in phase 3) | 3 |
| 3F8h–3FFh | COM1 (16550) | 3 |

Not present: floppy controller (3F0h–3F7h), ATA (1F0h–1F7h, 3F6h),
parallel port (378h–37Ah), coprocessor (0F0h–0FFh). Reads of absent
ports return FFh.

The memory port reaches the main memory and its controller directly,
past the cache. It is for the BIOS, before the memory works
([bios.md](bios.md#memory-training)); nothing else should use it,
and the cache does not see what is written through it.

Ports 0E0h to 0E2h are what the BIOS and the model use today
("phase 1" above means the model; the gateware follows in phase 3).
The rest of the private range is provisional.

## Interrupt lines

| IRQ | Source | Phase |
|---|---|---|
| 0 | Timer channel 0 | 3 |
| 1 | Keyboard | 3 |
| 2 | Cascade from controller 2 | 4 |
| 4 | COM1 (also the serial mouse) | 3 |
| 7 | Sound Blaster | 3 (round 30) |
| 8 | Real-time clock | 4 |

Other lines are unconnected. NMI is unused by the PC side and is a
candidate entry for the meta interface.

## DMA channels

| Channel | Use | Phase |
|---|---|---|
| 1 | Sound Blaster 8-bit audio | 3 (round 30) |
| 4 | Cascade | 5 |

Other channels exist in the controller and have no device.
