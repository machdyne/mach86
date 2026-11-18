# Software and licences

## Policy

1. **Our own code** is under the Zeitlos licence
   ([LICENSE.md](../LICENSE.md)).
2. **Vendored code** must be MIT, BSD or similarly permissive, and is
   a last resort. It lives in its own directory with its licence file.
3. **No GPL or LGPL code in the repository.** GPL tools may be used
   to build (a compiler, an assembler); GPL programs may be run as
   tests; neither is committed.
4. **Test software** is shareware or public domain. It is fetched by
   script or supplied by the user, and not committed.

Code that Zeitlos already vendors under a permissive licence may be
copied along with the Zeitlos files that use it
([reuse.md](reuse.md)).

Vendored so far: `rtl/ext/usb_hid_host/` (Apache 2.0, nand2mario's
USB HID host, as Zeitlos carries it). `rtl/ext/zeitlos/` is Zeitlos's
own code under the Zeitlos licence.

Fetched and never committed (`tools/fetch_dos.sh`): the FreeDOS
kernel in two builds (GPL), the MS-DOS 2.0 shell and CHKDSK (MIT),
FreeCOM (GPL), a SvarDOS boot disk image, and the source of the
SHSUCD suite (zlib), from which the CD tools on the boot disk are
assembled ([card.md](card.md)).

## The reference DOS

**MS-DOS 4.00**, published by Microsoft and IBM under the MIT licence
at `github.com/microsoft/MS-DOS`.

## Firmware we write ourselves

| Item | Why ours |
|---|---|
| BIOS and video BIOS | No permissive one fits; designed with the hardware |
| Extended memory (XMS) driver | Small, specified publicly, and games need one |
| Mouse driver (interrupt 33h) | The common free one is GPL |

## Build tools

| Tool | Use |
|---|---|
| Yosys, nextpnr-ecp5, Project Trellis | Gateware, as for Zeitlos |
| Icarus Verilog, Verilator | Simulation |
| NASM | BIOS and test programs |
| A C compiler for the host | Reference model |

GPL tools on the build machine are fine.

## Test software register

Every program used as a test is listed here with its licence status
before it is used. "To confirm" means the terms have not yet been read
and recorded; that is done when the entry is first needed.

| Program | Needs | Phase | Licence status |
|---|---|---|---|
| MS-DOS 4.00 | Real mode | when built | MIT. Source and build tools only; no binaries |
| MS-DOS 2.0 `COMMAND.COM`, `CHKDSK.COM` | Real mode | 1 | MIT (Microsoft's MS-DOS repository). Fetched, not committed |
| FreeDOS kernel 2043, 8086 build | Real mode | 1 | GPL. Fetched from its GitHub release for testing, not committed |
| SvarDOS empty boot image (`boot-svardos.img`) | — | 1 | Boot code derived from FreeDOS (GPL). Fetched as a formatted, bootable blank disk, not committed. To be replaced by our own formatter |
| Hardware-captured 386 real-mode instruction vectors (SingleStepTests/80386) | — | 1–2 | Confirmed: data public domain, software MIT. Fetched, not committed |
| `mach86-dos.img` (`make sdcard`) | The disk for a board's SD card: SvarDOS's blank boot image, the FreeDOS kernel, MS-DOS 2.0 COMMAND.COM and CHKDSK, our DOS test | 3 | A build product made from the fetched files above, each under its own licence (the kernel is GPL). Not committed; delivered beside the repository for a hardware test |
| Dhrystone 2.1 (C source) | Benchmark: instructions per run on the model, later cycles on the RTL | 2 | No licence statement in the source; widely redistributed. Fetched by `tools/dhry.sh`, not committed. Our support code in `tests/dhry/` is ours |
| Commander Keen 1 | EGA, real mode | 4 | Shareware; to confirm |
| Wolfenstein 3D (shareware episode) | VGA, 286 instructions, AdLib, Sound Blaster | 4–5 | Shareware; to confirm |
| Doom (shareware episode) | 386 protected mode, DOS extender, VGA, Sound Blaster | 6 | Shareware; to confirm |
| Second Reality | 386, VGA, sound | 7 | Reported released to the public domain by its authors; to confirm |
| Jemm386 5.8x (github.com/Baron-von-Riedesel/Jemm) | An expanded-memory manager: virtual 8086 mode, paging, VCPI | 3 (round 29) | Artistic License in part (its `Readme.txt`, section 9). Source fetched and built with JWasm and JWlink (same author, also fetched); nothing committed |
| test386.asm (github.com/barotto/test386.asm) | A test ROM for 386 emulators: all of protected mode | 3 (rounds 28, 29) | GPL 3. Fetched and assembled for testing; nothing committed |
| A DPMI host | Paging, level 3 | 7 | To choose; permissive or freely redistributable |
| Windows 3.x | Protected mode stress test, optional | 6–7 | Proprietary; user-supplied, never fetched |

Games listed here are examples that mark a level of the machine, not a
compatibility promise. The register grows as phases are reached.
