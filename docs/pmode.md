# Protected mode

Where it stands. Round 24 built the first part: enough for memory
above 1 MB to be used from DOS. Round 26 built the second: 32-bit
code and stack segments, interrupts and faults through an IDT of
gates, the local descriptor table. That is protected mode **at one
privilege level and without checks**. It is enough for DOS/4GW and
DOOM's shareware episode on the model, and in lockstep as far as
that has been run ([Tests](#tests)), **and on a Sergei ML2, where
DOOM runs**. What is still missing is listed below.

## What is there

| | |
|---|---|
| CR0 | `MOV` to and from CR0, `SMSW`, `LMSW`, `CLTS`. PE switches segment loads to the descriptor tables; the other bits are kept. CR2 and CR3 are kept too; paging is not there |
| The table registers | `LGDT`, `LIDT`, `SGDT`, `SIDT`. In real mode interrupts go through the table `LIDT` names, as on a 386 |
| Segment loads with PE set | Every instruction that loads a segment register (`MOV`, `POP`, `LES` and its kin, far `JMP`, `CALL`, `RET`, `IRET`, an interrupt) takes base and limit from the selector's descriptor, granularity bit included; from the local table if the selector says so |
| Segment loads with PE clear | The base is the selector times 16 and **the limit stays what it was**: after a visit to protected mode a real-mode program reaches all of memory with 32-bit addresses ("unreal mode"), which is how DOS memory managers copy to and from extended memory |
| 32-bit code (round 26) | A code segment whose descriptor has the D bit runs with 32-bit operands and addresses by default; the 66h and 67h prefixes then choose 16 bits |
| 32-bit stack (round 26) | A stack segment whose descriptor has the B bit uses ESP: pushes, pops, calls, `ENTER`, `LEAVE`, `PUSHA`, interrupts |
| Interrupts and faults with PE set (round 26) | Through the IDT's gates: 32-bit and 16-bit interrupt and trap gates, to a handler **at the same privilege level**. An interrupt gate clears IF. Faults 8 and 10 to 14 push an error code, which is always zero. `IRET` returns |
| The local table and the task register (round 26) | `LLDT`, `SLDT`, `LTR`, `STR`. The task register only keeps its selector: there are no tasks |
| Looking at descriptors (round 26) | `LAR`, `LSL`, `VERR`, `VERW`. A selector that is null or outside its table is refused (ZF clear); privilege is not looked at, nor the descriptor's type for `LAR` and `LSL`. DOS/4GW uses `LAR` as soon as it is in protected mode |
| BIOS | INT 15h function 88h says how much memory is above 1 MB (64,512 KB on Sergei, 31,488 on Lakritz); function 87h moves a block anywhere in memory |
| DOS | The boot disk loads HimemX, the FreeDOS XMS driver, and DOS itself into the high memory area; `XMSTEST` takes a megabyte of extended memory, copies into it and back, and compares |

## What is not

With PE set there are still **no checks**: no descriptor type,
present bit or privilege level is looked at, and no table limit. A
program that is right runs; one that relies on a fault for a bad
selector does not get it. The faults that are raised are the ones
real mode has (a segment's limit, an invalid opcode, a divide
error), now delivered through gates. Not there:

- **privilege levels**: everything runs as if at level 0. No stack
  switch through the TSS when an interrupt goes to an inner level,
  no `IRET` to an outer one, no call gates, no task gates or task
  switches. An extender that runs its program at level 3 does not
  work;
- `ARPL` (invalid opcode);
- **paging and virtual 8086 mode** (EMM386 and its kin, and any
  extender under one, need both);
- the accessed bit in descriptors, the busy bit of a TSS;
- error codes other than zero.

**The decoded-instruction cache.** An entry is good for the default
sizes it was decoded under, and is marked with the code segment's D
bit. While the code segment and the stack segment disagree about
16 or 32 bits (in the middle of a mode switch, as a rule) the cache
is not used and every instruction is decoded afresh, ten or so
cycles each. An extender whose 16-bit code runs for long on a
32-bit stack, or the other way round, will be slow there.

**Code above 2 MB** (round 26). Below 2 MB the map that says where
cached instructions are has a mark for each 64 bytes
([cpu_b.md](cpu_b.md)). Above, it has one for each 4 KB, of 64 MB
(addresses 64 MB apart share a mark). A store into a marked page is
followed by the search for the cached instructions it overlaps,
about twenty cycles, every time: the page is never found clean. So
data in pages of its own costs nothing, self-modifying code works,
and a page that holds code and data both is slow to write to.

## How segment loads are done

The microcode loads a segment register with one micro-operation,
`SETSEG`, in over a dozen places. Rather than give each a protected-mode
twin, the core catches `SETSEG` when PE is set and sends the
microcode to one routine of four words (`pmseg`), which reads the
descriptor's two halves from the GDT and ends with a `SETSEG` of its
own; that one does the load and goes back to where the first would
have gone on, or ends the instruction if the first was its last
word. Real mode pays nothing for it.

## Tests

- `make check-pm` (`tests/prog/pmtest.asm`), the first part: the
  table registers stored and read back; into protected mode,
  segments loaded from a GDT (one with a base of 1 MB), a far jump
  through a code descriptor, memory written through them, and out;
  unreal mode at 2 and 3 MB with `REP MOVSD`; the BIOS's two calls.
- `make check-pm2` (`tests/prog/pm2test.asm`), the second: 32-bit
  code on a 32-bit stack above 64 KB, with and without prefixes; a
  routine copied to 3 MB, run, overwritten and run again; `INT n`
  through a 32-bit interrupt gate, a 32-bit trap gate and a 16-bit
  gate into 16-bit code; an invalid opcode, a limit violation (with
  its error code) and a divide error, each stepped over by its
  handler; the timer's interrupt taken in 32-bit code; `LLDT`,
  a segment from the local table, `SLDT`, `LTR`, `STR`; and back to
  real mode.
- Both run three ways: on the model; **in lockstep**, the RTL core
  against the model after every instruction, with segment bases and
  limits, the D and B bits, CR0 and both table registers among the
  things compared; and on the SoC with memory above 1 MB.
- DOS with HimemX and `XMSTEST`: on the model and on the SoC in
  `make check-card`.
- The instruction vectors still pass (they are real mode).
- **DOOM** (shareware 1.9, with DOS/4GW bound into it; a user's
  files, not in the repository). On the model it starts, loads and
  plays its demo. In lockstep the RTL core agreed with the model on
  all 66 million instructions from the DOS prompt through DOS/4GW's
  start and DOOM's initialisation as far as `R_Init`. From there
  into the game it has run on the model only, and the lockstep
  compares the CPU, not the display. **On a Sergei ML2 it runs**
  (as reported: about ten frames a second by eye, started
  without sound). The first try found what was missing: `LAR`.
- The model was written from the manual by the same hand as the
  core, so the two agreeing says less here than it does in real
  mode, where the vectors come from a real 386. A real extender
  running is the better evidence, and there is one so far.

## Plan for the rest

1. More real extenders on the model (DOS/32A,
   PMODE/W, CWSDPMI) to see what they ask for. That decides the
   order of the rest.
2. Privilege levels: the TSS's stack on the way in, `IRET` on the
   way out; `ARPL`.
3. The checks on segment loads and the faults they raise, with real
   error codes.
4. Paging and virtual 8086 mode, if a memory manager is wanted.

The microcode ROM has 5 words left of 1,024
([cpu_b.md](cpu_b.md#round-26)), so steps 2 and 3 need it to grow,
and Lakritz has no block RAM left to grow it in
([boards.md](boards.md#lakritz-where-it-stands)): something there
has to give first.
