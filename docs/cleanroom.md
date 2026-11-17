# Clean-room policy

Mach86 is written from public specifications of how the hardware and
firmware interfaces behave, not from other people's implementations of
them.

## The rule

A Mach86 source file may be derived from:

1. **Manufacturer documentation**: datasheets, programmer's reference
   manuals, application notes, published standards.
2. **Descriptions of interfaces**: what a BIOS call takes and returns,
   what a register bit does.
3. **Observed behaviour**: what a real machine or a test vector
   captured from real hardware shows, and what an existing emulator
   does when run as a program.
4. **Zeitlos**, which is ours ([reuse.md](reuse.md)).
5. **Permissively licensed code**, when it is vendored openly with its
   licence ([software.md](software.md)). That is reuse, not clean-room
   work, and it is labelled as such.

A Mach86 source file may not be derived from:

- The source of another x86 core, in any language.
- The source of a PC emulator.
- The source or a disassembly of a BIOS, video BIOS or option ROM.
  This includes the BIOS listings printed in IBM's technical reference
  manuals; the hardware chapters of those manuals are fine.
- Microcode or internal tables extracted from a real chip, where a
  documented behaviour would do.

Running an emulator to compare results is allowed. Reading its source
to find out why it differs is not; the answer has to come from a
specification or from hardware-captured vectors.

## Provenance in each file

Every RTL, model and firmware source file begins with a comment that
names the documents it was written from, by the short names in the
table below, for example:

```
// Sources: I386-PRM ch. 17 (instruction set), I386-DS (reset state).
```

A file copied from Zeitlos says so and gives the Zeitlos commit.

## Sources

Short names used in file headers. Editions are added to this table as
each document is first used.

| Short name | Document | Used for |
|---|---|---|
| I86-UM | Intel, *iAPX 86/88, 186/188 User's Manual* | 16-bit instruction set |
| I286-PRM | Intel, *80286 Programmer's Reference Manual* | 286 additions, 16-bit protected mode |
| I386-PRM | Intel, *80386 Programmer's Reference Manual* (1986) | 386 architecture and instruction set |
| I386-DS | Intel, *80386* data sheet | Reset state, identification |
| I486-PRM | Intel, *i486 Programmer's Reference Manual* | 486 instructions |
| I8259 | Intel 8259A data sheet | Interrupt controller |
| I8254 | Intel 8254 data sheet | Timer |
| I8237 | Intel 8237A data sheet | DMA controller |
| I8042 | Intel 8042 data sheet and the AT keyboard interface description | Keyboard controller |
| MC146818 | Motorola MC146818 data sheet | Real-time clock |
| NS16550 | National Semiconductor 16550 data sheet | Serial port |
| VGA-REG | Published VGA register and mode descriptions | VGA |
| YM3812 | Yamaha YM3812 data sheet and application manual | OPL2 |
| SB-HW | Creative Labs, *Sound Blaster Series Hardware Programming Guide* | Sound Blaster |
| BIOS-IF | Published descriptions of the PC BIOS interrupt interface and data area | BIOS |
| XMS | *eXtended Memory Specification* | Extended memory driver |
| SST-386 | SingleStepTests, *80386* real-mode test suite (hardware-captured; data in the public domain) | Observed behaviour of a 386 |
| MOO-SPEC | *MOO File Format Specification*, version 1.1 | Reading the test suite |
| SD-PHY | SD Association, *Physical Layer Simplified Specification* | SD card in SPI mode |

## Patents and names

The 386 was introduced in 1985 and the 486 in 1989. Patents of that
age have expired. "Mach86" is our own name; Intel's product names are
used only to say what Mach86 is compatible with.

## A limit worth stating

Part of this project is written with an AI model. Such a model is
trained on public text, which can include open-source x86 cores and
emulators. The work follows the rule above and cites its sources file
by file, but that is a working discipline, not the legally certified
separation that "clean room" means in a contract. If that distinction
ever matters commercially, it needs legal advice.
