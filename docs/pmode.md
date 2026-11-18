# Protected mode

Where it stands. Round 24 built the first part: enough for memory
above 1 MB to be used from DOS. Round 26 built the second: 32-bit
code and stack segments, interrupts and faults through an IDT of
gates, the local descriptor table. Round 28 built the third,
**privilege levels**: the four rings, the checks on segment loads
and far transfers with the faults and error codes they raise, stack
switches through the task state segment, call gates. Round 29 built
the fourth: **paging** and **virtual 8086 mode**, with the I/O
permission bitmap.

That is a 386's protected mode but for task switches and a few
smaller things ([What is not](#what-is-not)). The evidence, all in
simulation so far: an open test suite for 386 emulators passes on
the core, in lockstep with the model, to its last test; a real
memory manager of the EMM386 kind (Jemm386) loads and runs DOS
programs under it, in lockstep; and DOS/4GW and DOOM run as before
([Tests](#tests)). **On a board, only round 26's part has been seen
to work** (DOOM on a Sergei ML2).

## What is there

| | |
|---|---|
| CR0 | `MOV` to and from CR0, `SMSW`, `LMSW`, `CLTS`. PE switches segment loads to the descriptor tables; PG turns paging on; WP makes level 0 respect read-only pages; the other bits are kept |
| The table registers | `LGDT`, `LIDT`, `SGDT`, `SIDT`. In real mode interrupts go through the table `LIDT` names, as on a 386 |
| Segment loads with PE set | Every instruction that loads a segment register (`MOV`, `POP`, `LES` and its kin, far `JMP`, `CALL`, `RET`, `IRET`, an interrupt) takes base and limit from the selector's descriptor, granularity bit included; from the local table if the selector says so |
| Segment loads with PE clear | The base is the selector times 16 and **the limit stays what it was**: after a visit to protected mode a real-mode program reaches all of memory with 32-bit addresses ("unreal mode"), which is how DOS memory managers copy to and from extended memory |
| 32-bit code (round 26) | A code segment whose descriptor has the D bit runs with 32-bit operands and addresses by default; the 66h and 67h prefixes then choose 16 bits |
| 32-bit stack (round 26) | A stack segment whose descriptor has the B bit uses ESP: pushes, pops, calls, `ENTER`, `LEAVE`, `PUSHA`, interrupts |
| Interrupts and faults with PE set (rounds 26, 28) | Through the IDT's gates: 32-bit and 16-bit interrupt and trap gates, to a handler at the same level or an inner one. An interrupt gate clears IF. Faults 8 and 10 to 14 push their error code. `IRET` returns |
| The local table and the task register (rounds 26, 28) | `LLDT`, `SLDT`, `LTR`, `STR`. `LTR` marks the task state segment busy and notes where it is and whether it is a 286's or a 386's; the inner levels' stacks are read from it. There are no task switches |
| Looking at descriptors (rounds 26, 28) | `LAR`, `LSL`, `VERR`, `VERW`: a selector that is null, outside its table, of the wrong kind or not visible from the current level is refused (ZF clear). `ARPL`. DOS/4GW uses `LAR` as soon as it is in protected mode |
| Privilege levels (round 28) | The current level is the code segment's. See [Privilege levels](#privilege-levels) below |
| BIOS | INT 15h function 88h says how much memory is above 1 MB (64,512 KB on Sergei, 31,488 on Lakritz); function 87h moves a block anywhere in memory |
| DOS | The boot disk loads HimemX, the FreeDOS XMS driver, and DOS itself into the high memory area; `XMSTEST` takes a megabyte of extended memory, copies into it and back, and compares |

## Privilege levels

Round 28. What the core checks and does with PE set:

| | |
|---|---|
| Loading DS, ES, FS, GS | The descriptor must be data or readable code, and visible: its level not inside the current level or the selector's (conforming code excepted). Else general protection, error code the selector; not present: fault 11. A null selector loads, and the segment then cannot be used |
| Loading SS | Writable data at exactly the current level; else general protection (stack fault if not present). Never null |
| Using a segment | A write to a segment that is not writable, a read from execute-only code, any use of one loaded with a null selector: general protection, error code 0. (In real mode none of this is looked at) |
| Far `JMP` and `CALL` | To code at the current level, or conforming code at or inside it; or through a **call gate**, 286's or 386's. A call through a gate to an inner level changes to that level's stack, from the task state segment, and pushes the old stack pointer, the parameters the gate counts (copied from the old stack) and the return address there. The offset is checked against the new segment's limit before anything changes |
| `RETF`, `IRET` | To the same level or an outer one. Outward the stack pointer is taken from the stack too, and DS, ES, FS and GS are emptied if the outer level could not have loaded them |
| Interrupts and faults | Through a gate to the same level or an inner one, with the stack switch. `INT n` needs the gate's level to allow the caller (error code: the vector times 8, plus 2). Error codes carry the "external" bit for hardware interrupts and faults |
| Flags | `POPF` and `IRET` change IF only at or inside the I/O privilege level, and that level only at level 0. `CLI` and `STI` outside it: general protection |
| I/O | `IN`, `OUT`, `INS`, `OUTS` outside the I/O privilege level: allowed or refused port by port by the task state segment's permission bitmap |
| Level 0 only | `HLT`, `LGDT`, `LIDT`, `LLDT`, `LTR`, `LMSW`, `CLTS`, `MOV` to and from control and debug registers, `INVD`, `WBINVD`, `INVLPG`: general protection elsewhere |
| Descriptors | The accessed bit is set when a segment is loaded; `LTR` sets the busy bit |

**How.** Three small registers carry it: the current level, the
level a transfer in progress is going to, and the error code for
the fault being raised. Each segment register keeps five bits of
its descriptor (null, not writable, not readable, level, and
whether an outer level loses it). The rules themselves are in the
core as one block of logic, "look at this descriptor as a ...", which the
microcode asks with the descriptor's second half in a register and
then branches on what was found (passed, present, accessed, a
system descriptor, a change of level). The microcode does the
sequencing: about 480 words by round 29, all in the ROM's upper half.
Privileged instructions are never put in the decoded-instruction
cache, so that the level is looked at each time they are decoded;
everything else costs the cached path nothing but the rights check
on memory accesses, which goes into the limit check's register.

## Paging

Round 29. With CR0.PG set every address goes through the page
tables: 4 KB pages, a directory and tables as CR3 names them.

| | |
|---|---|
| Translation | A buffer of 32 entries, one for each value of address bits 16 to 12, holds the pages last used. A page not in it is looked up by a walk of the tables, done by the core's own state machine while the micro-operation that wanted it waits; nothing of the instruction is lost or repeated |
| Protection | User and supervisor pages (a level-3 access to a supervisor page faults); read-only pages (level 3 always; levels 0 to 2 only with CR0.WP, as on a 486) |
| Accessed and dirty | Set in the directory entry and the table entry by the walk, the dirty bit at the first write. A write to a page whose buffered entry is not yet dirty walks again |
| Page faults | Fault 14 with the address in CR2 and the error code's three bits (present, write, user). The instruction can be run again: the stack pointer and string pointers are put back as for any fault, and an instruction that reads, modifies and writes one place asks for the write when it reads, so that it cannot fault after it has changed the flags. `INS` and `ENTER` look at the page they will write before they do what cannot be undone |
| Across two pages | An access that lies across a page boundary has both pages looked up first; the core then makes it a byte at a time, since the frames need not be neighbours |
| Flushing | A write to CR3 or CR0, and `INVLPG`, empty the buffer |
| The core's own accesses | Descriptor tables, the IDT and the task state segment are read through the page tables too, as level 0 |

**What it costs.** Nothing with paging off: one more term in the
signal that holds a micro-operation back. With paging on, each
memory access of a micro-operation takes two cycles more (one to
register the address, one to look it up), and loads no longer tell
the data cache their address a cycle early, which is another. That
is a lot: on the simulated SoC the speed test's loop of ordinary
instructions ran at **54% of its speed** once Jemm386 had put DOS
into virtual 8086 mode under paging (8,412 against 15,480 thousand
instructions a second at the simulation's 24 MHz). An entry missing
from the buffer costs the walk on top, eight to twelve cycles; the
buffer is small and direct-mapped, and a program that works on more
than 32 pages at a time, or on pages 128 KB apart, walks often. One
of the two cycles can probably be had back (the buffer's answer is
ready early enough to let the access start in the cycle it is
looked up); that has not been tried.

**The decoded-instruction cache under paging.** Its entries are
found by linear address, so when the mapping changes (CR3, CR0,
`INVLPG`) the whole cache is emptied, which takes 2,048 cycles and
leaves everything to be decoded again. A system that reloads CR3
at every task switch pays that each time. Stores are compared with
where instructions are in memory (physical addresses), so code
modified through another mapping of its page is still caught.

## Virtual 8086 mode

Round 29. EFLAGS.VM with PE set: the level is 3, segment loads are
real mode's, and what a real-mode program does that the system must
see faults to the monitor.

| | |
|---|---|
| Into it | `IRET` at level 0 with VM set in the flags image: the stack pointer and all six segment registers come off the stack |
| Out of it | Any interrupt or fault, through a gate to level 0: on the level-0 stack go GS, FS, DS, ES, then SS, ESP, the flags (with VM), CS and EIP; the four data segment registers are emptied |
| Sensitive instructions | `CLI`, `STI`, `PUSHF`, `POPF`, `INT n` and `IRET` raise general protection unless the I/O privilege level is 3; with 3 they do what they do in real mode. `HLT` and the other level-0 instructions always fault; `LLDT` and its kin, `ARPL`, `LAR`, `LSL`, `VERR`, `VERW` are invalid opcodes, as in real mode |
| Ports | By the **I/O permission bitmap** of the task state segment, whatever the I/O privilege level: a set bit, or a map that is not there, faults. The same bitmap decides for protected-mode code outside the I/O privilege level |

## What is not

Not in the core (the model has all of these):

- **task switches**: a far jump or call to a task state segment or
  a task gate, a task gate in the IDT, `IRET` with NT set. They
  raise general protection. (Systems of the time use one task and
  switch stacks themselves; a few use a task gate for the double
  fault);
- **expand-down** segments (the limit is checked as if expand-up);
- the debug registers do nothing; no `CPUID`, no alignment check;
- checks the core leaves out: the IDT's limit, the descriptor's
  type on `LTR` and `LLDT`, and double faults (a fault while
  delivering a fault is simply delivered);
- a fault part of the way through a stack switch leaves the new
  stack segment loaded.

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
microcode to one routine (`pmseg`), which reads the descriptor's
two halves from its table, has the core look at them by the rule of
the register being loaded, raises the fault if they will not do,
sets the accessed bit, and ends with a `SETSEG` of its own; that one
does the load and goes back to where the first would have gone on,
or ends the instruction if the first was its last word. Real mode
pays nothing for it. CS is the exception: the far transfers look at
the descriptor themselves, each by its own rule and before they
push anything, and `pmseg` only loads it.

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
- `make check-pm3` (`tests/prog/pm3test.asm`), the third: down to
  level 3 with `IRETD`; ten faults for what level 3 may not do, each
  with its error code, taken at level 0 on the task state segment's
  stack; `POPFD` leaving IF and the I/O privilege level alone; `INT`
  through a level-3 gate and back; a call gate to level 0 and `RETF`
  back out; conforming code; `ARPL`, and `LAR`, `LSL`, `VERR`, `VERW`
  from level 3; a 286 task state segment with a 16-bit gate; the
  timer's interrupt taken at level 3; and out.
- `make check-pg` (`tests/prog/pgtest.asm`), paging: an identity
  map switched on under the running program; a doubleword written,
  read and added to across the boundary of two pages whose frames
  are 64 KB apart; an instruction lying across that boundary, run,
  changed through the frame's own address and run again; a page
  not present, mapped by the fault's handler and the instruction
  run again; the accessed and dirty bits; a read-only page written
  by level 0, and refused once CR0.WP is set; `INVLPG`; `REP MOVSD`
  running into a page not present, and finishing after the handler.
- All four run three ways: on the model; **in lockstep**, the RTL core
  against the model after every instruction, with segment bases and
  limits, the D and B bits, the privilege level, CR0 and both table
  registers among the things compared; and on the SoC with memory above 1 MB.
- DOS with HimemX and `XMSTEST`: on the model and on the SoC in
  `make check-card`.
- The instruction vectors still pass (they are real mode).
- **DOOM** (shareware 1.9, with DOS/4GW bound into it; a user's
  files, not in the repository). On the model it starts, loads and
  plays its demo. In lockstep the RTL core agreed with the model on
  all 66 million instructions from the DOS prompt through DOS/4GW's
  start and DOOM's initialisation as far as `R_Init`. From there
  into the game it has run on the model only, and the lockstep
  compares the CPU, not the display. With round 28's checks in
  both, the lockstep was run again and further: 194 million
  instructions, into the demo, no difference. **On a Sergei ML2 it runs**
  (as reported: about ten frames a second by eye, started
  without sound). The first try found what was missing: `LAR`.
- **test386.asm** (an open test suite for 80386 emulators, GPL, so
  fetched when wanted and never in the repository): it replaces the
  BIOS, turns paging on as it enters protected mode, and works
  through rings, virtual 8086 mode, task switches, page faults,
  segment faults and the instruction set. **The model passes all of
  it**, the 128 KB variant with the task-switch tests included, and
  its arithmetic results match the suite's reference file line for
  line. **The core passes the 64 KB suite in lockstep with the
  model**: 79.7 million instructions to the last diagnostic code,
  no difference. (The 128 KB variant adds task switches, which the
  core does not have.) On the way it found three faults in the core
  that nothing else had: `POPAD` on a 32-bit stack changed the upper
  half of ESP; `BOUND` was missing altogether; and call gates did
  not copy parameters. How to run it: [verification.md](verification.md).
- **Jemm386** (a free memory manager of the EMM386 kind: it puts DOS
  into virtual 8086 mode under paging and traps what it must;
  fetched and built when wanted, not in the repository). Loaded
  from the DOS prompt (`JEMM386 LOAD`), with the speed test run
  under it afterwards: on the model, and **in lockstep with the
  core, 145 million instructions, no difference**. Then DOOM under
  it, which makes DOS/4GW a client of the memory manager, switching
  between its own page tables and the manager's thousands of times:
  on the model into the demo, and **in lockstep 336 million
  instructions, no difference**. On the simulated SoC, DOS with
  Jemm386 loaded runs the speed test.
- The model was written from the manual by the same hand as the
  core, so the two agreeing says less here than it does in real
  mode, where the vectors come from a real 386. The test suite
  (written by others, for other emulators, against real hardware's
  behaviour) and real system software running are the better
  evidence.
- **None of round 28 or 29 has run on a board yet.**

## Plan for the rest

1. Boards: privilege levels, paging and virtual 8086 mode have only
   been simulated.
2. More real software on the model and in lockstep: other memory
   managers, DPMI hosts (CWSDPMI and DJGPP programs), other
   extenders.
3. Speed under paging: the two cycles an access, and the emptying
   of the instruction cache when the mapping changes.
4. Task switches; expand-down segments.

The microcode ROM has room (about 540 words of the upper half are
free). Lakritz's logic is the limit to watch: see
[boards.md](boards.md).
