# Reference model

`sim/` holds the C model that the RTL will be checked against
([verification.md](verification.md)). This page describes what exists
today.

## What is there

| File | What it is |
|---|---|
| `sim/m86.h`, `sim/m86cpu.c` | The CPU model |
| `sim/pc.h`, `sim/pc.c` | The PC around it: memory, A20, interrupt controllers, timer, keyboard controller, clock, text screen, SPI port |
| `sim/sdcard.c` | An SD card in SPI mode, backed by an image file |
| `sim/m86pc.c` | The whole machine: BIOS image, disk image, scripted or interactive |
| `sim/vectest.c`, `sim/vectest_model.c` | Runs a CPU against hardware-captured instruction vectors; the model is one back end, the RTL core the other ([cpu.md](cpu.md#verification)) |
| `sim/m86run.c` | Runs a ROM image on the bare CPU model, with a debug console |
| `tests/prog/` | Directed programs: `sieve.asm` (bare CPU), `boottest.asm` (BIOS services) |
| `tests/dos/` | DOS-level tests: `dostest.asm` and the two `CONFIG.SYS` files |
| `tests/vectors/known_deviations.txt` | The vectors the model is known not to match, with reasons |
| `tests/vectors/known_deviations_b.txt` | The same list plus the vectors design B alone does not match (24: bit instructions at a segment's very end, [cpu_b.md](cpu_b.md#round-26)) |
| `tools/fetch_vectors.sh`, `tools/fetch_dos.sh` | Fetch the vectors and the third-party DOS files (not committed) |
| `tools/fatimg.py` | Adds files to a FAT12 or FAT16 disk image |

The BIOS has its own page: [bios.md](bios.md).

## The CPU model

It implements the 486SX instruction set as it behaves in real mode,
with 16- and 32-bit operands and addresses, and as much of protected
mode as [pmode.md](pmode.md) lists.

- Segment limits are enforced, and violations raise the general
  protection or stack fault, as on a real 386 in real mode.
- Faults are precise: the instruction's register changes are undone
  before the handler is entered. Where the hardware is not precise,
  the model copies the hardware (see below).
- Interrupts, NMI, single-step, HLT and the one-instruction interrupt
  delay after `MOV SS`, `POP SS` and `STI` are modelled.
- There is no coprocessor. Escape opcodes do nothing, or raise the
  device-not-available fault when `CR0.EM` or `CR0.TS` is set.
- Protected mode is whole, as far as a 386 without debug registers
  goes (round 28): the four privilege levels with every check on
  segment loads, far transfers, gates and flags, and the faults and
  error codes those raise; stack switches through the task state
  segment; call gates with their parameters; task switches, 286 and
  386, by jump, call, gate, interrupt and `IRET`; virtual 8086 mode
  with the I/O permission bitmap; paging, with the accessed and dirty
  bits, CR0.WP and page faults; double faults and shutdown. The core
  has less ([pmode.md](pmode.md)): where the two differ, software
  that needs the missing part runs on the model only.

The model observes the clean-room rule ([cleanroom.md](cleanroom.md)):
it is written from the Intel manuals, and corrected against
hardware-captured vectors, which are observed behaviour.

## Instruction vectors

The vectors are 1,758,700 single-instruction tests captured from a
real 386EX in real mode: 941 files, one per opcode and prefix
combination. Each gives the registers and memory before and after.

```
tools/fetch_vectors.sh          # once; about 580 MB into output/vectors
make -C sim vectors
```

Result at this round:

| | Tests |
|---|---:|
| Pass | 1,758,670 |
| Known deviations | 29 |
| Skipped (revoked by the suite's authors) | 1 |
| Fail | 0 |

The run takes about 20 seconds.

Flags that the suite's own metadata marks as undefined for an opcode
are not compared. `vectest` exits non-zero if any test fails, and also
if a test on the known-deviations list passes, so the list cannot go
stale.

### Known deviations

| Tests | What | Why it is left |
|---:|---|---|
| 10 | `AAM` with a zero divisor: the flags image pushed by the divide fault | The manual leaves the flags undefined; the hardware's values follow no rule we found |
| 9 | `IDIV` with a byte divisor returns a quotient of 80h where the manual calls for a divide fault | Not understood. Software cannot rely on it |
| 6 | `IN` from an empty port | The capture rig's bus floated to a value other than all ones |
| 4 | `REP MOVS`/`STOS` overwriting its own instruction and the following `HLT` | The hardware runs bytes already in its prefetch queue; the model has none. The RTL pipeline will have to decide this case deliberately |

### What the vectors do not cover

They cannot show what was not captured. Not exercised: interrupts and
single-step, values read from ports, the system instructions (`SGDT`,
`LGDT`, `SMSW`, `LMSW`, moves to and from control and debug
registers), coprocessor escapes, and anything outside real mode. Those
parts of the model rest on the manuals alone until directed tests are
written for them.

## What the vectors taught

The first run passed 93.4%. These are the behaviours the manuals do
not state, or state loosely, that the hardware has and the model now
copies. The RTL has to match them too.

- **Segment registers on the stack with a 32-bit operand.** The slot
  is four bytes, but only two are written or read.
- **`PUSHA`** writes its frame from the lowest address upwards. If a
  write faults part-way, the registers already stored stay stored.
- **`POPA`**: registers popped before a faulting pop keep their new
  values. With a 32-bit operand, the half of `ESP` above `SP` takes
  the value from the stack image.
- **`POP r/m` and `MOV r/m, imm`** with a non-zero `reg` field raise
  the invalid-opcode fault.
- **Two-part memory operands** (far pointers, `BOUND` limits,
  descriptor-table operands): with 16-bit addressing the second part's
  offset wraps within 64 KB.
- **`SHR` by more than one**: the overflow flag is the bit below the
  sign bit of the result.
- **Byte shifts by 16 or 24**: the carry flag is what a count of 8
  would give.
- **`SHLD`/`SHRD` on 16-bit operands with a count above 16**: the
  source operand supplies bits a second time.
- **A SIB byte with a scale but no index** (not a documented
  encoding): the base register is scaled.
- **`DAS`**: the carry flag includes the borrow from the low-digit
  adjustment.

## The PC model

`sim/pc.c` models the hardware of phase 3 in
[hwmap.md](hwmap.md), as far as software can see it through ports and
memory:

- 16 MB of RAM, the BIOS image read-only at the top of the first
  megabyte, text memory at B8000h, and the A20 gate (off at reset).
- Both interrupt controllers, the three timer channels, the keyboard
  controller, the CMOS clock and memory, the CRT controller's cursor
  registers, and system control ports 61h and 92h.
- The SPI port and an SD card behind it. The card is a block-addressed
  card that understands reset, initialisation, size, and single-block
  read and write.

Time is counted in instructions: the timer advances one tick every 16
instructions, which is 19 million instructions a second against the timer's
1.193 MHz. The
clock always starts at noon on 1 January 1990. Runs are therefore
reproducible to the instruction.

Not modelled: graphics, sound, DMA, serial ports, and a diskette
controller (Mach86 has none; see below).

## Running the machine

```
make -C sim                     # builds the model and the BIOS
output/sim/m86pc -bios output/bios/bios.bin -disk disk.img -i
```

`-i` shows the screen in the terminal and takes keys from it; Ctrl-]
quits. Without it, the machine is driven by a script on the command
line:

```
m86pc -bios bios.bin -disk disk.img \
      -expect "A>" -type "dir\r" -expect "bytes free"
```

A ROM of up to 128 KB can be given to `-bios` (it ends at FFFFFh;
the machines themselves have 64 KB): test suites that replace the
BIOS come that size. Four things in the environment help with them
and with protected-mode programs: `M86_POST=1` prints every byte
written to the diagnostic port 190h; `M86_E9=1` sends bytes written
to port E9h to standard output; `M86_FAULTS=n` prints the first n
faults taken with PE set (vector, error code, level, address and
bytes); `M86_BREAK=offset` (hexadecimal) prints the sixteen
instructions before execution first reaches that offset.

`-expect` runs until the text appears on a screen row that changed
since the previous step, and the exit status says whether every
expectation was met. `-screen` prints the final screen, `-where` the
CPU state, `-profile` the instruction profile, and `-debug` sends the
BIOS's console copy to standard error.

## DOS

```
tools/fetch_dos.sh      # once: third-party files into output/dos
make dos
```

This builds two hard disk images and boots each in the model.

1. **Our own DOS test.** A FreeDOS kernel with `tests/dos/dostest.asm`
   as its shell. The program checks the DOS version, memory
   allocation, creating, writing, reading back, finding and deleting a
   file, the date, and keyboard input through DOS.
2. **A session at the prompt.** The same kernel with the MS-DOS 2.0
   `COMMAND.COM` that Microsoft published under the MIT licence. The
   script answers the date and time prompts and runs `ver`, a
   directory listing, `CHKDSK`, and a redirect to a file and back.

Both pass. This is a FreeDOS kernel under a 1983 shell, a stopgap
pairing with one known oddity: a plain `dir` reports "File not
found", while `dir c*.*` lists files. Reading one file back, `CHKDSK`
and our own test all see the directory correctly, so this looks like
the old shell and the new kernel disagreeing about a wildcard search
that meets the volume label first. It has not been proved to be that.

### What did not work, and why

- **MS-DOS 4.00 has no binaries.** Microsoft published its source and
  the DOS-hosted tools that build it, but nothing bootable. Building
  it needs a DOS to run those tools in.
- **The multitasking MS-DOS 4.0 beta does have a boot diskette**, and
  it is MIT-licensed. On the model it loads through our BIOS, starts
  its kernel and prints the `COMMAND.COM` banner. It then stops: its
  own diskette driver talks to the diskette controller chip directly,
  and Mach86 has no such chip. It is not pursued.

## Running bare programs

`m86run` loads a ROM image at the top of the first megabyte, as a BIOS
sits, and starts at the reset vector. A byte written to port E0h goes
to standard output ([hwmap.md](hwmap.md#io-ports)).

```
make -C sim check       # builds, runs tests/prog/sieve.asm, compares output
make -C sim profile     # the same program with its instruction profile
```

## Profiles

`m86run -p` and `m86pc -profile` print how many instructions fell in
each of ten classes (register to register, load, store, taken
jump and so on), the base
cycles per instruction those counts imply, and which opcodes make up
the slow path.

Two limits: a `REP` string instruction counts once however many times
it repeats, and a program waiting at a prompt polls the keyboard, so a
profile taken across idle time mostly measures that polling.

**Finding what a program wanted.** `M86_FAULTS=n` in the environment
makes the model print where the first n faults taken in protected
mode were, with the instruction's bytes. That is how DOOM's need of
`LAR` was found in one run.
