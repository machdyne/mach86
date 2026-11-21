# CPU design B

The first RTL core ([cpu.md](cpu.md)) is correct and 28,653 LUT4, more
than a whole Lakritz. Design B replaces it. This page describes the
design, what exists of it, and what has been measured.

**State: runs on a Sergei ML2.** It boots DOS and runs games there,
DOOM under DOS/4GW among them, at 33 MHz and 21.4 million
instructions a second on plain code, measured there (1.4 to 1.6 cycles an
instruction; DOS itself, with its calls and console output, is
nearer 2.6; DOOM is 1.95 in simulation since [round 32](#round-32),
which has not been on a board yet). It passes 1,758,646 instruction vectors captured from
a real 386 with 53 known deviations, and runs DOS and DOOM into its
demo (194 million instructions) in lockstep with the reference model
without a difference. It is a
486SX to software: the 486's instructions and AC flag, no FPU, no
`CPUID`. Protected mode is a 386's but for task switches: privilege
levels (round 28), paging and virtual 8086 mode (round 29), in
simulation so far ([pmode.md](pmode.md)).

A faster core for the larger boards is planned: [cpu_c.md](cpu_c.md).

The sections below were written as the design grew, and the older
ones give the figures of their time; [round 32](#round-32) has the
latest.

## The idea

Lakritz is short of LUTs and has block RAM and multipliers to spare.
The expensive part of x86 is decoding it. So:

- **Decode once.** The first time an instruction is met, slow
  microcode decodes it and writes the result to block RAM: its first
  micro-operation, its operands, its length.
- **Execute many.** Every later time, that entry is read and run
  directly. A common instruction is one micro-operation and takes one
  cycle. Games spend nearly all their time in loops, so nearly all
  instructions are executed this way.
- **Everything hard is microcode.** Instructions that need several
  steps continue in a microcode ROM, also block RAM. Protected mode
  becomes ROM contents, not logic.

| File | What it is |
|---|---|
| `rtl/cpu/m86b_core.v` | The skeleton |
| `rtl/cpu/m86_alu.v` | The ALU, shared with the first core |
| `sim/m86b_tb.v` | A test bench that runs a small pre-decoded program |
| `tools/m86b_demo.py` | Builds that program's cache image and the ROM images |

## How it works

```
        +--------------------+      +----------------+
 next   | decoded-instruction|      | microcode ROM  |
 EIP -->| cache (block RAM)  |--+   | (block RAM)    |
        +--------------------+  |   +-------+--------+
            hit: first uop,     |           | continuation uops
            operands, length    v           v
                              +----------------+
                              |  one uop/cycle |--> registers (LUT RAM)
                              |  ALU, shifter, |--> flags
                              |  address unit  |--> data bus
                              +-------+--------+
                                      |
                 next EIP = EIP + length, or the jump target
```

- **Decoded-instruction cache.** Indexed by the linear address of the
  instruction. An entry holds a tag, the length, a 48-bit
  micro-operation, the immediate, the displacement, and where the
  instruction continues in the ROM if it needs more than one step.
- **Next address in the same cycle.** The entry carries the length
  and the jump displacement, and conditions use the flags as already
  registered. So the address of the next instruction is known in the
  cycle the current one executes, and its entry arrives for the next
  cycle. A taken jump costs nothing extra.
- **Micro-operation.** One of: ALU on two registers, ALU with the
  immediate, load, load-and-operate, store, shift, multiply, or a
  special operation. The format is in the header of `m86b_core.v`.
- **Registers** are a 16-entry LUT RAM in four byte lanes, so 8-, 16-
  and 32-bit writes and the AH-style registers need no merging logic.
  Eight entries are the x86 registers; eight are microcode
  temporaries. Three read ports: base, index and store data.
- **Shifter.** A shift is a multiplication by a power of two, so the
  shifter is the multiplier: four of the FPGA's multiplier blocks and
  almost no LUTs. Registered on both sides, so shifts take three
  cycles.
- **Loads** take two cycles: address, then data. The address goes to
  the memory as it is worked out (`e_req`, `e_addr`), a cycle before
  the bus's registers, so that a cache can answer in the second cycle
  ([soc.md](soc.md#the-main-memory)). A stack-style access can update
  its pointer in the same micro-operation, so `PUSH` is one cycle; a
  string access moves its pointer the same way, up or down by the
  direction flag, and puts it back if the access faults.
- **A store** can store a register, the immediate, or one of the
  values microcode otherwise has to read into a temporary first: the
  return address, the flags, a segment selector. With that, `CALL`
  is one micro-operation: store the return address, move the stack
  pointer, jump.
- **Jumps that depend on a register:** to a register (`RET`, `JMP`
  and `CALL` through a register or memory), and `LOOP` and `JCXZ`,
  which test the count register itself and are one micro-operation.
- **Divide** is a divider beside the ALU: a quotient bit a cycle.
- **Limit checks** are made a cycle late, from registers, and cancel
  the bus request and the running micro-operation if they fail.
- **Self-modifying code.** A table of one bit for each 64-byte block
  of the first megabyte records which blocks hold cached
  instructions. A store into one is followed, between instructions,
  by a search for the cache entries of the instructions it overlaps,
  which are removed (about 20 cycles). If three such stores come at
  once the whole cache is cleared instead. When the search finds
  nothing near the store, the whole block is looked through (80
  cycles, once), and if it holds no cached instruction its mark is
  taken off: stores there are free from then on.

- **Decoder.** On a cache miss a small state machine reads the
  instruction's bytes over the data bus: prefixes, opcode, ModRM, SIB,
  displacement, immediate. An attribute ROM, indexed by the opcode and
  by whether the operand is memory, says what follows the opcode and
  where the instruction's microcode starts. Decoding costs 8 to 14
  cycles and happens once per instruction until the entry is replaced.
- **Microcode.** `sw/ucode/m86b_ucode.py` is the assembler and the
  microcode source. A ROM word is a micro-operation with selectors in
  place of register numbers ("the ModRM r/m register", "the operand
  size"). The selectors are resolved against the instruction when the
  word leaves the ROM, and the first resolved word is what the cache
  keeps. So one microcode routine serves `ADD`, `OR`, `ADC` and the
  rest in all their register forms, and the cached copy is specific.
- **Faults** are delivered by microcode: the stack pointer is put
  back to its value at the start of the instruction, then the vector
  is read and flags, CS and IP are pushed.

## What it has

**Instructions with microcode:**

- `MOV` in all its forms, including segment registers and the
  accumulator with a bare offset; `LEA`; `XCHG`; `MOVZX`, `MOVSX`;
  `CBW`/`CWDE`, `CWD`/`CDQ`; `XLAT`.
- The eight ALU operations in every form (opcodes 00 to 3F and 80 to
  83); `TEST` with a register; `INC` and `DEC` of a register or
  memory.
- `PUSH` and `POP` of registers, memory, immediates and segment
  registers; `PUSHF`, `POPF`, `LAHF`, `SAHF`; `LEAVE`.
- Conditional jumps short and near; `LOOP`, `LOOPE`, `LOOPNE`,
  `JCXZ`; `JMP` and `CALL` near, indirect and far; `RET` and `RETF`
  with and without a count; `INT n`, `INT3`, `INTO`, `IRET`.
- `LES`, `LDS`, `LSS`, `LFS`, `LGS`.
- Shifts and rotates by one, by CL and by an immediate, with the
  flags as hardware sets them; `RCL` and `RCR` as a microcode loop.
- `MUL`, `IMUL` in all forms, `DIV`, `IDIV`; `TEST` with an
  immediate, `NOT`, `NEG`; `SETcc`.
- `MOVS`, `STOS`, `LODS`, `CMPS`, `SCAS`, alone and with `REP`,
  `REPE`, `REPNE`.
- `NOP`, `HLT`, `CLC`, `STC`, `CMC`, `CLI`, `STI`, `CLD`, `STD`.

With operand-size, address-size, segment and `LOCK` prefixes, 16- and
32-bit addressing.

**Faults:** invalid opcode, including invalid `LOCK` and the invalid
forms of group opcodes; segment limit on data, stack and code;
instruction longer than 15 bytes; a jump, near or far, outside the
code segment; divide error.

- `IN`, `OUT`, `INS`, `OUTS`; `PUSHA`, `POPA`, `ENTER`.
- Hardware interrupts, with the one-instruction hold-off after `STI`
  and after a load of SS. Reset is a microcode sequence that leaves
  the registers as a 386 does.

- The decimal adjustments (`DAA`, `DAS`, `AAA`, `AAS`, `AAM`, `AAD`),
  `SALC`, `WAIT`, and the coprocessor escapes as no-operations (there
  is no coprocessor).

- Since round 24, the first part of protected mode: CR0, the table
  registers, segment loads from the GDT, unreal mode
  ([pmode.md](pmode.md)).

**Not there:** NMI, the single-step trap, `BOUND`, the bit
instructions (`BT` and relatives, `BSF`, `BSR`), `SHLD`/`SHRD`.
DOS has not needed them so far; it did need `AAM`, which
COMMAND.COM uses to print the date. Then the rest of protected mode
([pmode.md](pmode.md#what-is-not)), paging with a TLB, and the debug
registers.

The microcode is 894 words of 1,024. Byte and word forms of an opcode
share one copy; round 17's richer micro-operations made many
routines shorter.

## Measurements

### Against hardware

```
tools/fetch_vectors.sh
make vectors-b
```

Runs design B, under Verilator, against the hardware-captured vectors
([verification.md](verification.md)) for every opcode whose attribute
ROM entry is valid. `tools/m86b_vecfiles.py` makes the list from the
ROM image, so it grows with the microcode. Each test starts with an
empty cache, so every test goes through the decoder.

| | |
|---|---:|
| Vector files | 880 |
| Tests | 1,608,600 |
| Pass | 1,608,570 |
| Known deviations | 29 |
| Skipped (revoked by the vectors' authors) | 1 |
| Fail | 0 |

The 29 are the same 29 the model has ([model.md](model.md)). The
whole set is 941 files and 1.76 million tests. The same result holds
with every memory read answered a cycle late (`M86B_WAIT=1`), which
is how block RAM answers.

The vectors run every instruction once, through the decoder. They do
not run anything from the cache, and three bugs lived there until
lockstep found them: a constant from the microcode word was not kept
with a cached instruction; a first step's conditional microcode jump
was not taken when it came from the cache; and a cached step in
progress was dropped when the cache was emptied under it.

### In lockstep with the model

```
make check-b-boot     # the BIOS boot test; part of make check
make dos-b            # DOS; needs tools/fetch_dos.sh
```

The whole machine twice, once with the C model of the CPU and once
with design B under Verilator, with the registers compared after
every instruction, fault and interrupt
([verification.md](verification.md)). With `LOCKSTEP_MEM=1` memory is
compared as well.

| DOS boot, DOS test, keyboard input | Round 17 | Round 14 | Round 12 |
|---|---:|---:|---:|
| Steps compared | 40,120,000 | 40,120,000 | 40,019,484 |
| Differences | 0 | 0 | 0 |
| Clock cycles | 101 million | 137 million | 159 million |
| Cycles per instruction | 2.5 | 3.4 | 4.0 |
| Instructions that had to be decoded | 1.3% | 5.7% | 12.0% |
| Cycles spent decoding | 4% | 12% | 22% |
| Stores beside cached code | 431,790 | 432,253 | 430,303 |
| Cycles spent on them | 7% | 5% | 4% |

Memory answers at once in this bench, which since round 17 is what
the cache on the board does for a read that hits; before, the board
took a cycle more for every load than this table showed
([below](#round-17-where-the-cycles-went)).

Three things in that table:

- **A real kernel modifies its own code in its hot path.** The DOS
  kernel used here writes the interrupt number into an `INT`
  instruction about 400,000 times in this run. The first scheme,
  emptying the whole cache on such a store, gave 12.1 cycles per
  instruction with 94% of instructions decoded. The scheme now is
  exact: the entries of the instructions a store overlaps are found
  and removed, between instructions, in about 20 cycles.
- **Decoding was mostly conflicts.** With 1,024 entries 5.7% of
  instructions were decoded; with 2,048, 1.3%; with 4,096, 1.2%. The
  cache is 2,048 entries now.
- **The count is per instruction, and a `REP` is one instruction.**
  The boot reads the disk a byte at a time with `REP INSB`, so the
  figure overstates the cost of ordinary instructions.

`LOCKSTEP_PROFILE=1` adds a table of where the cycles went, by
opcode: count, cycles, cycles each. It is how round 17's list was
made.

### In simulation

```
make check-b
```

`tests/prog/bloop.asm` runs from the reset vector, through the decoder
the first time round and from the cache after that: a loop of `ADD`,
`PUSH`, `POP`, `CALL`, `ADD`, `RET`, `DEC`, `JNZ`, 1,000 times. The
bench checks the result and the instruction count.

| | Round 17 | Before |
|---|---:|---:|
| Instructions | 8,006 | 8,005 |
| Cycles | 11,157 | 15,121 |
| Cycles per instruction | 1.39 | 1.88 |

Eleven cycles for the eight instructions of the loop: `POP` is two
and `RET` three (a load, then the jump), the rest one each. `CALL`
was four and is one.

### Dhrystone

```
make dhry-b
```

Dhrystone 2.1, compiled with `gcc -m16 -O2`,
run on the RTL under Icarus with memory that answers at once. Design
B executes exactly the instructions the model does: 20,435 for 10
runs and 75,935 for 110.

| Per Dhrystone | Round 17 | Round 12 |
|---|---:|---:|
| Instructions | 555 | 555 |
| Cycles | 1,239 | 1,670 |
| Cycles per instruction | 2.23 | 3.01 |
| DMIPS/MHz | 0.459 | 0.341 |
| DMIPS at 31.5 MHz | 14.5 | 10.7 |

Round 12's 1,670 went: 255 to decoding (cache conflicts), about 290
to one `IDIV`, the rest mostly to calls, returns, pushes of memory
and `REP MOVS`. Round 17 took the divide to about 45 cycles with a
divider, the conflicts away with a larger cache, and three cycles off
every call.

### Round 17: where the cycles went

The question after the first board test was why a 31.5 MHz
machine did 6 to 8 million instructions a second. The profile of the
DOS boot and three measurements on the simulated SoC answered it.
In order of what each was worth:

| What was wrong | What it cost | Now |
|---|---|---|
| **A store into a block where code had once run** waited for a search, every time, for ever. DOS loads each program where the last one ran, so a program's own variables were in such blocks | 18 cycles a store. A plain loop with two stores a round ran at 3.9 cycles per instruction | The block is looked through once and its mark taken off. The same loop: 1.55 |
| **Every load took three cycles on the board,** not the two of the simulation benches: the cache began its lookup when the request reached the bus | A cycle on about a third of all instructions | The address goes to the cache as it is computed. Two cycles |
| **Decoded-instruction cache conflicts:** 1,024 entries for DOS, BIOS and a program | 12% of all cycles | 2,048 entries: 4% |
| **A wasted cycle** between the second and third micro-operation of any instruction whose first was a load | One cycle each on `RET n`, `ADD mem, imm` and the like | Gone |
| **Common instructions took microcode detours** to fetch a value into a temporary before storing it or jumping to it | `CALL` 4 cycles, `RET` 4, `PUSH` of a segment register, `PUSHF`, `PUSH imm`, `MOV mem, imm` 3 each, `LOOP` 3, `STOSB` 4, `REP MOVS` 6 an element, `PUSHA` 25, `INT` 18, `IRET` 13 | 1, 3, 1, 1, 3 (`MOVSB`; `STOSB` 1, `LODSB` 2), 4 an element (`REP STOS` 2), 12, 13, 10 |
| **Divide was a microcode loop,** six to eight micro-operations a bit | About 130 cycles for 16 bits, 290 for 32: several times a real 386 | A bit a cycle: about 30 and 45 |

The speed program on the disk image (`SPEED.COM`,
`tests/dos/speed.asm`: a round of twenty ordinary instructions with a
call, two stores and four loads) on the simulated SoC:

| | Round 16 | Round 17 |
|---|---:|---:|
| Cycles per instruction | 3.9 | 1.55 |
| Instructions a second at 31.5 MHz | 8.1 million | 20.3 million |

and the DOS boot and test on the same, which is mostly DOS calls and
console output: 3.9 cycles per instruction before, 2.6 now, or 8 and
12 million instructions a second.

What is left, in the order the profile gives it:

- **Loads are two cycles** and a third of instructions are loads.
  Starting the next micro-operation while a load's data is still on
  its way — a real pipeline stage — would make most of them one. It
  is the largest single item left and the largest change.
- **An instruction of more than one micro-operation loses a cycle**
  when its first is a single-cycle one, because the second comes
  from the microcode ROM through a register. Fewer such instructions
  is what this round did; the cycle itself is still there.
- Shifts are three cycles (the multiplier is registered on both
  sides); `POP` of a segment register and `MOV` to one three; `MUL`
  six; `POPA` eighteen.
- The DOS kernel's self-modifying `INT`: about 26 cycles a DOS call
  for the search and the decoding again.

### Size and clock, on Lakritz's FPGA

```
make synth-b            # Yosys, then nextpnr for an LFE5U-25F, speed grade 6
make synth-b SEED=2
```

| | Round 17 | Round 12 | Round 11 | Round 9 | First core |
|---|---:|---:|---:|---:|---:|
| LUT4 after synthesis | 4,464 | 3,772 | 3,182 | 2,903 | 28,653 |
| Packed logic cells (`TRELLIS_COMB`) | 5,784 of 24,288 (24%) | 4,908 | 4,184 | 3,885 | — |
| Flip-flops | 1,326 | 1,089 | 889 | 881 | 1,630 |
| Block RAMs | 29 of 56 | 19 | 18 | 18 | 0 |
| Multiplier blocks | 4 of 28 | 4 | 4 | 4 | 4 |
| Routed clock | 36.0 MHz (one seed) | 37.8 to 39.1 | 37.6 to 39.2 | 40.2 to 41.5 | about 19, unrouted |

Round 17's 880 cells are the divider (three 32-bit registers and a
subtractor), the two remembered string pointers, the search of a
whole block, and the side-by-side sums for the next instruction's
cache index. Its ten block RAMs are the second thousand entries of
the instruction cache and the second megabyte of the code-block map.

Placed and routed out of context (no pins) with Yosys 0.33 and
nextpnr 0.6, the versions Ubuntu ships. Zeitlos notes that this
nextpnr reports a lower clock than current versions for the same
design ([reuse.md](reuse.md) points at its toolchain notes), so the
clock figures are probably pessimistic. The ROMs hold the real
microcode and attribute table.

**The size pass.** Round 8's core was 5,944 cells. It is 3,885 now,
with half as much again of the instruction set in it. Two things did
that, found by synthesising the core with one part removed at a time:

| Change | Cells |
|---|---:|
| Synthesis settings: `-abc9 -nowidelut` | 5,944 to 4,443 |
| One shared check on instruction fetch (length and segment limit) in place of a copy at each of the decoder's twelve fetch points | 4,443 to 3,700 |
| This round's additions (segment selector choice, 16-bit stack access, far-jump check, the zero latch for `LOOP`) | 3,700 to 3,885 |

The first is free: Yosys's default for ECP5 builds wide multiplexers
out of paired LUTs, which this design is full of, and the other
mapper does better without them. The second was a mistake of mine in
round 8: a Verilog task containing two adders and a comparator,
called from twelve places.

What the same experiment says about the rest, in LUT4 before packing,
of about 2,900: the ALU 360, fault handling 350, the shifter's
surroundings 240, the special-register read path 220, the selector
resolver 170, address generation 160. Nothing else stands out.

This round's 720 cells are interrupts, the I/O flag, the reset
sequence, and above all the search for cache entries to remove, which
holds several 32-bit addresses.

### What limits the clock

The slowest path is still the one measured on the skeleton: block RAM
output (5.8 ns), choice between the cache's and the ROM's
micro-operation, register read, ALU, result selection, flags. (Round 26 shortened it and its neighbours: see [below](#round-26).) The
clock is no longer a target in itself:
a change is worth making if it raises instructions per second or
lowers cells, whatever it does to megahertz.

### Round 26

**The clock.** Sergei no longer made 33.16 MHz after protected
mode's first part (31 to 32.4 over five seeds). The slowest paths
were, by turns, the address of a load on its way to the data cache,
the ALU's sum on its way to the register file and the flags, and
the data cache's answer on its way back through the core. What was
done, none of it at a cost in cycles:

| | Was | Is |
|---|---|---|
| The linear address: base + register + index + displacement | Three carry chains one after another (and a fourth in the cache) | Reduced three-to-two twice, then one chain; with 16-bit addressing the upper half is the base's or the base's plus one (kept with the base), chosen by the carries at bit 16 |
| The ALU | An adder and a subtractor, a choice between them, then the choice among all results | One adder; its sum is chosen last for the register file, against everything else chosen before |
| Pointers that move with an access (push, pop, strings) | Through the ALU, whose controls therefore waited for the uop's kind | An adder of their own |
| The ALU's controls | Decoded from the uop each cycle, behind the cache's block RAM | Decoded when the uop is resolved and kept beside it: in the cache, in seven bits its block RAMs had spare |
| The segment limit check, the fetch limit check | An addition, then three comparisons | One comparison: the limit less the access's size is what is kept |
| The data cache's answer | Waited for the CPU's request, which waits for the limit check | Given without it; the CPU knows what it asked |
| One read of the segment selectors for two users | Two, merged by the tool behind six levels of logic | One, with the choice written out |

Sergei at 33.16 MHz: 33.7, 34.9 and 35.0 MHz on three seeds after
the first five rows, 35.1 on one after all seven. The core alone,
out of context on Lakritz's FPGA, 39 MHz, as before: there the
tool's own balancing hides the gain. Cycles per instruction on the
core's bench are what they were (1.39).

A simulation fault from round 24 was found on the way: the
microcode address was computed from a value assigned further down
the same block, which Icarus runs differently from Verilator and
from synthesis. `make check-b`, which uses Icarus, had been failing
since round 24 without anyone looking (it also had an input left
unconnected). Both are fixed; the hardware was never wrong.

**Instructions.** `SHLD`, `SHRD`; `BT`, `BTS`, `BTR`, `BTC`; `BSF`,
`BSR`; and a 486's `BSWAP`, `CMPXCHG`, `XADD`, `INVD`, `WBINVD`,
`INVLPG`, with the AC flag.

- The shifter gives "the other half" of a shift (the bits that
  leave the operand), which is what the second operand of a double
  shift contributes. A double shift was two shifts and an OR, about
  twelve cycles of shifting in a routine of twenty (one uop since
  [round 27](#round-27)). With 16-bit operands and more than 16 places the
  hardware's result is the source rotated, and so is ours.
- The ALU has three bit operations; a bit instruction on a register
  is one cycle. With a register for the bit number and memory for
  the operand, the one byte the bit is in is read and written, not
  the word around it. **A deviation:** at the very end of a segment
  a 386 faults where the word reaches past the limit and the byte
  does not. 24 of the vectors are such cases; they are listed in
  `tests/vectors/known_deviations_b.txt`.
- `BSF` and `BSR` are microcode loops, three cycles a bit: up to
  about a hundred cycles. A 386's are slow too.
- `BSWAP` is five shifts, sixteen cycles.

**Protected mode's second part** is in [pmode.md](pmode.md).

**The microcode ROM** holds 1,019 words of 1,024 (`LAR`, `LSL`,
`VERR` and `VERW` took the last nineteen). To make room, the
groups C6h, C7h, 8Fh and FEh lost their placeholder words for the
members that do not exist (the decoder refuses those itself), and
`RCL` and `RCR` share their loops between the three ways of giving
the count. The next additions need a larger ROM.

**The cache entry** is 189 bits, all of 21 block RAMs. A second,
coarse map of where cached code is (above 2 MB) takes one more
block RAM.

The vectors: 1,748,646 pass, none fail, 53 known deviations (the
model's 29 and the 24 above).

### Round 27

**The microcode ROM is 2,048 words.** Opcodes still start in the
lower 1,024 (the attribute ROM's entry field is ten bits); routines
that are only jumped to can go in the upper half, and the
microassembler has `upper()` and `lower()` for that. 895 words are
used below and 78 above. A jump target is eleven bits now (the
eleventh is ROM bit 85, which was free), and so is a constant. The
cache entry is still 189 bits: one of the bits decoded ahead ("with
carry", which is in no hurry) was given up for the continuation
address's eleventh.

**Block RAM** was paid for on Lakritz, which had none left
([boards.md](boards.md#lakritz-where-it-stands)): the ROM's five more
blocks came from the data cache's dirty bits, the coarse code map
(now a mark for each 32 KB, in LUT RAM), the AdLib's table ROM and
the two USB hosts' ROMs, all moved into logic. That costs about
2,800 LUTs there.

**SHLD and SHRD are one uop,** three cycles like any shift, where
round 26's were a routine of about twenty: a second multiplier
beside the shifter's makes the bits the second operand gives. DOOM
draws its floors with `SHLD`; on the model's count 2.8% of all the
instructions DOOM runs are double shifts, so this is worth roughly
a sixth of its time. How much faster DOOM is on a board has not
been measured.

### Round 28

**Privilege levels** ([pmode.md](pmode.md#privilege-levels)). The
core gained the current level, the checks on segment loads and far
transfers, error codes, stack switches through the task state
segment, call gates, `ARPL`, and the rights of each loaded segment.
The rules are one block of logic that the microcode consults; the
sequencing is microcode, 322 words more in the ROM's upper half
(899 below, 400 above, of 2,048). On the cached path the only
addition is the rights check on a memory access, which is folded
into the value the limit check already registers, so no path grew.

**A store that faults.** An instruction that ends with a store is
finished a cycle before the store is known to be allowed; if it is
not, the fault follows at once and is delivered with the
instruction's own address. The lockstep bench did not know this (no
earlier test ended an instruction on a faulting store) and now waits
for the fault's delivery before it compares.

### Round 29

**Paging, virtual 8086 mode and the I/O permission bitmap**
([pmode.md](pmode.md#paging)). One new unit in the core, a state
machine beside the execution path, does all three jobs that need
memory looked at before an access may go ahead: it translates the
address (a 32-entry buffer in LUT RAM, and the page walk when the
page is not in it), makes an access that lies across two pages a
byte at a time, and reads the task state segment's bitmap for a
port. A micro-operation that needs it is held, exactly as a store
is held when the memory is not ready for it, until the unit says
"ready" or raises the fault; the decoder's fetches wait for it the
same way. Because the operation has not begun, nothing has to be
undone and the microcode knows nothing of it: a page fault is an
ordinary fault raised before the access.

What the rest of the core gave up for it: with paging on, loads no
longer announce their address to the data cache a cycle early, and
the code map is kept by physical address (so a store through
another mapping of a code page still finds the cached instruction;
the search then ignores the entry's tag above the page offset and
may throw out a few entries too many).

An access across two pages is read by the unit into a register,
and the micro-operation then reads that register as if it were I/O
port 1E8h, which the machine around the core answers from the
core's own output. That keeps a multiplexer out of the path from
the data cache to the ALU, which is the longest in the design.

**Virtual 8086 mode** is mostly microcode: `IRET` into it, the
interrupt out of it, and a word each in `PUSHF`, `POPF`, `INT n`
and `IRET` to ask whether they fault. In the core it is one flag
that makes segment loads real mode's.

**The code map's marks are registered** a cycle after the cache
entry is written. The comparison that decides whether an
instruction spans two blocks had been the end of the longest path
since paging put a multiplexer in front of it.

**Found by the test suite** (verification.md), in the core as it was before:
`POPAD` on a 32-bit stack changed the upper half of ESP; `BOUND`
did not exist; call gates did not copy parameters. All three are
fixed, and 10,000 more of the instruction vectors pass (`BOUND`'s).

The microcode is 918 words below and about 480 above, of 2,048.

### Round 30

**A byte for someone else.** The Sound Blaster's samples are fetched
by the core ([sound.md](sound.md#the-sound-blaster)): `dma_req`
holds the next instruction back for the three or four cycles of one
byte read, the way the speed control's wait does, and the paging
unit's state machine makes the read. The first version let the
instruction cache's read port wander during the wait, and the
instruction after ran with another's operands; the lockstep bench
now has a request generator (`M86B_DMA=n`) that found it at once
and guards it.

### Round 32

**Fewer cycles an instruction, at the same clock.** DOOM was
profiled in lockstep (`LOCKSTEP_PROFILE=n`,
[verification.md](verification.md)); what the profile said, and what
was done about it:

| What the profile showed | Share of DOOM's cycles | Now |
|---|---:|---|
| **Decoding.** 4.7% of instructions are not in the cache when they are met (the game's code is larger than 2,048 entries can hold), and each cost 8.6 cycles in the decoder and two more to reach execution | 21% | 3.3 cycles in the decoder: [the window](#the-decoders-window) |
| `DIV` with 32 bits: 44 cycles, a bit of the quotient a cycle and twelve of microcode around it | 6% | 18: two bits a cycle, and a direct routine for the unsigned kind |
| `CMP` and `TEST` of memory with an immediate: a load, the operation, and for `CMP` a store of what was read | 4% | One load-and-operate with the immediate: two cycles from four |
| `INC` and `DEC` of memory, the ALU operations on memory with an immediate | 3% | Load-and-operate, then the store: three cycles from four |
| `MOVZX` and `MOVSX` from memory: six and eight cycles | 2% | Two and four: a load that fills the register from a byte |

The same 44 million instructions of DOOM (the end of one demo, a
level's load from the card, the start of the next) took 105.3
million cycles and take 86.1 million: **2.38 cycles an instruction
before, 1.95 now, 22% more speed.** A stretch of the demo's play
alone (31 million instructions) went from 2.12 to 1.80, 18% more:
less of it is decoding. Dhrystone went from 1,239 cycles
to 971 (0.459 to 0.586 DMIPS/MHz; 19.4 DMIPS at 33.16 MHz).

What is left in DOOM's profile, largest first: loads are two cycles
(a quarter of all cycles are instructions with a memory operand);
shifts are three, the double shifts included; a return is three; and
the decoder still has 8%. None of these has a cheap answer in this
design: they are what a pipeline is for ([cpu_c.md](cpu_c.md)).

#### The decoder's window

The decoder used to ask the bus for every field of an instruction:
the opcode, ModRM, SIB, the displacement, the immediate, each a
request and an answer, with a look at the attribute ROM between.
Now, when the eight bytes at the instruction's address may all be
read (they lie inside the code segment's limit and, with paging, in
one page), it reads them as two words into a window and takes the
fields from there:

- the opcode from the first word as it arrives, and the attribute
  ROM read in that same cycle, already for the right form (memory or
  register) by a look at the byte after the opcode;
- ModRM, SIB and displacement together in the next cycle, when the
  attribute word says there is a ModRM byte;
- the immediate in the cycle after, or in the same one if there is
  no ModRM byte.

A prefix moves the window down a byte and costs a cycle. A field
that is not in the window (an instruction longer than eight bytes),
a far pointer, and every instruction whose eight bytes may not all
be read go the old way, a field at a time, from where the window's
use ended; so nothing is read that a 386 would not be allowed to
read, and no fault can come from the window. The first fetch is
made in the cycle the cache misses, not the one after.

With the memory answering a cycle late, as the data cache on a
board does for the decoder's reads, a decode was 12 to 16 cycles and
is about 5.

**It costs about 600 LUTs,** and Lakritz does not have them: with
the window the design is 34 cells over the FPGA's 24,288. So the
window is a parameter (`WIN`, `CPU_WIN` on the SoC), 1 on the Sergei
boards and 0 on Lakritz, where the decoder is the old one less the
wait for the attribute ROM. `make check-b-nowin` runs the core
without it in lockstep.

#### A read-modify-write that faults

A new case in the paging test found a fault that had been there
since round 29: `ADD [mem], reg` and its kin are a load-and-operate
followed by a store, and with paging the page was looked up as for
a read at the first and as for a write only at the second. A write
to a read-only page therefore faulted after the flags had been
changed, and the handler saw the wrong flags (for `ADC` and `SBB`
the instruction, run again, would have used the wrong carry). The
load-and-operate of such an instruction is now looked up as a write,
as a plain load already was (`mark_rmw` in the microassembler marks
both kinds). `CMP` with memory, which never writes, no longer stores
back what it read.

#### The clock

The address of a micro-operation's memory access is the last thing
to arrive in the core's longest cycle, and on its way to the bus
register it passed one multiplexer for every other user of the bus
(the decoder, the paging unit, the DMA fetch): each was written
later in the Verilog block and so had priority. It is assigned last
now, since no other user is at work in a cycle a micro-operation
runs. Sergei routes at 34.6 MHz for the 33.16 MHz target (33.9 in
round 31).

### Round 38

**A profile by cause, to decide what to build next.** Design C is
slower than design B ([cpu_c.md](cpu_c.md)), so the question was
whether to go on with a pipeline at all, and in what form. The
lockstep bench now puts every cycle of design B in one class by what
it was spent on, and looks at every micro-operation for what a
pipelined engine would have to wait for
([verification.md](verification.md#where-the-cycles-go)). No change
to the design: two wires that only the simulation reads.

The measure is 89 million instructions of DOOM (demo play with a
level's load in it), 1.885 cycles an instruction, the memory
answering at once:

| What the cycle was spent on | Cycles an instruction | Share |
|---|---:|---:|
| Running an instruction's first micro-operation | 0.962 | 51.0% |
| A load's first cycle, the address (the data comes in the second) | 0.322 | 17.1% |
| Decoding: 3.8% of instructions are not in the cache | 0.168 | 8.9% |
| A shift's two extra cycles | 0.156 | 8.3% |
| Micro-operations after the first, from the ROM | 0.146 | 7.7% |
| Waiting for the ROM's first word | 0.058 | 3.1% |
| Dividing | 0.026 | 1.4% |
| Looking for cached code beside a store | 0.023 | 1.2% |
| A jump to a computed address (a return, mostly) | 0.018 | 1.0% |
| A multiply's two extra cycles | 0.007 | 0.4% |

An instruction is 1.11 micro-operations. A taken jump costs nothing
in this design (the cache is read at the target in the cycle the
jump is decided) and there are 0.12 of them an instruction.

**What other engines would take for the same instructions,** from
the same run:

| | Cycles an instruction | Against design B |
|---|---:|---:|
| Design B | 1.885 | |
| ... with the next micro-operation begun in a load's second cycle, unless it needs what is loaded (36% do) | 1.679 | 12% faster |
| ... and with shifts of one cycle | 1.523 | 24% faster |
| A pipeline (address, memory, ALU stages) with a jump predictor, three cycles lost by a wrong prediction | 1.48 | 27% faster at the same clock |
| The same with no predictor: every taken jump loses three cycles | 1.83 | 3% faster at the same clock |

The pipeline's figure keeps design B's cost for decoding, the ROM,
dividing and the search beside stores, takes away the load's and the
shift's extra cycles, and adds what a pipeline waits for: an address
made of what the micro-operation before computed (1.9% of
instructions, two cycles), or loaded (0.3%, one), or of what the one
before that computed (1.8%, one). The predictor is a two-bit counter
and a last target in each of the instruction cache's 2,048 entries
and a stack of eight return addresses: it is wrong for 3.9% of
conditional jumps, 1.3% of returns, 0.5% of all instructions. The
figure leaves out whatever else a real pipeline would stall on, so
it is a lower bound.

**What it says.**

1. **A pipeline would not need fewer cycles than design B can reach
   with two changes** (1.48 against 1.52). Everything a pipeline
   could add is in its clock: 45 to 50 MHz against 33 would be 40 to
   55% more than the improved design B, if that clock is reached.
2. **Without a jump predictor a pipeline gains nothing** over design
   B as it is: design B's free jumps are worth as much as its
   two-cycle loads cost.
3. **The two changes are the first things to do either way.** The
   load's overlap is a pipeline stage in all but name (a second
   write to the registers in one cycle, and the next micro-operation
   held when it needs the load): it is the first step of any
   pipeline and is useful without the rest.

The DOS boot and test (40 million instructions, 2.64 cycles an
instruction) is another kind of work: it is DOS calls, and an
instruction there is 1.64 micro-operations. Microcode after the
first micro-operation is 0.68 cycles an instruction, loads' first
cycles 0.52, the search beside stores 0.18, decoding 0.16. The
load's overlap would take it to 2.34 and a pipeline to 2.26: for
that kind of work the gain is in shorter microcode for `INT`,
`IRET`, `PUSHA`, `POPA` and the loads of segment registers, not in
the engine.

### Round 39

**The two changes round 38's profile pointed at, in a form that fits
Lakritz.** DOOM (the same 89 million instructions) went from 1.885
cycles an instruction to 1.719: **9.6% faster at the same clock.**
The DOS boot and test, which is mostly microcode, gained 2%.

**Shifts take two cycles, not three.** The shifter is the
multiplier, with a register before it and one after. A shift now
takes the product as it leaves the multiplier, in the cycle after
its operands were registered; a multiply still takes it from the
register a cycle later, because its result goes on through an adder
and a comparison. No logic was added and 64 flip-flops went. In
DOOM: 0.156 cycles an instruction down to 0.078.

**A load no longer holds up the instruction after it.** A load that
is a whole instruction (`MOV reg, mem`, `MOVZX`, `POP`, `LODS`) is
over in its first cycle as far as the order of instructions goes:
the address is on its way to the bus and the next instruction's
cache entry is being read. What is left, the data and its way into
the register, is kept in a few flip-flops (`lp_*`) and done in the
next cycle, beside the next instruction's first micro-operation.
That micro-operation waits a cycle, as before, when

- the data is not there yet (the cache missed);
- it reads the register being loaded;
- it would write a register in that cycle itself (a result, or a
  pointer it moves: the register file has one write port);
- it is the first of several and changes something in its first
  cycle, or loads a segment register.

Paging turns all of it off: with paging on a load is as it was.

In DOOM 0.202 instructions in every one are such loads, and for 44%
of them the instruction after can go ahead (of the rest: 16% need
the loaded value, 14% move a pointer, 14% write a result, 13% are
longer instructions). Chains of loads now run one a cycle.
Interrupts are taken a little differently: one that arrives during
a load's second cycle is taken after the instruction that has begun
beside it, not before.

Round 38's estimate for the two changes was 1.52 cycles an
instruction, and said it was an upper bound. What it did not count:
shifts in one cycle would need a shifter of some 400 LUTs beside the
multiplier, which Lakritz has not got, and the estimate let every
load go ahead that was not needed by its neighbour, where the one
write port stops a third of those, and it counted the loads inside
longer instructions and the load-and-operates (`ADD reg, mem`),
whose second cycle needs the ALU itself.

**What it costs.** On Lakritz 58 logic cells (23,603 of 24,288; 685
are left). The clock took the work. The first form put the memory's
answer, and a look at the next micro-operation's registers, in front
of everything a micro-operation does, and the Sergei build failed
its clock on two seeds of four. Three paths were taken out again:
the microcode's own address and jumps do not wait for a pending
load (there is none while microcode runs, but the tools cannot
know); the adder's sum is still the last thing chosen for the
register file; and a read is announced to the memory before it is
known whether the micro-operation must wait for the load (the memory
drops an announced read that does not come). With today's tools the
round 38 design routed at 33.9 MHz on the Sergei (one seed) and
36.8 on Lakritz; this one at 33.6 to 34.7 (three seeds) and 33.6 to
34.7 (three seeds), for 33.16. The builds use the best seed of
each. It is not more margin than there was, and on Lakritz it is
less: see [boards.md](boards.md#lakritz-where-it-stands).

**What is left in DOOM,** in cycles an instruction, of 1.719: 0.96
first micro-operations; 0.17 decoding; 0.15 microcode after the
first micro-operation; 0.12 first cycles of loads that are not whole
instructions or are load-and-operates; 0.12 waiting behind a load
for the reasons above; 0.08 shifts; 0.06 waiting for the ROM. An
experiment in the bench with other ways of choosing a cache entry
(the address's low bits XOR-ed with the bits above them) says they
would miss more often, not less (4.1% of instructions against
3.7%); 4,096 entries would miss 2.1%, and cost 21 block RAMs that
neither board has.

### Round 40

**Shifts in one cycle, and what is not needed for DOOM made a build
option.** DOOM's 89 million instructions take 1.661 cycles each
(1.885 in round 38, 1.719 in round 39): 13.5% faster than round 38
at the same clock. The larger gain of the round is outside the
core, in the memory ([soc.md](soc.md#the-main-memory)).

**The shifter is a shifter.** Until now a shift was a multiplication
by a power of two, in the multiplier, registered before and after
(three cycles; two in round 39, with the output register left out).
Now it is a rotation by 0 to 31 places in five layers of
multiplexers, with a mask that says which of its bits are the low
half of the old product and which the high half; everything after
that — which half a shift takes, the double shifts' second operand,
the flags — is as it was, so the results are the same by
construction, and the 386 vectors pass. What it took to make it
fit a cycle:

- **How far to rotate is worked out when the cache entry is made.**
  For a shift to the right it is 32 less the count, and that
  subtraction stood between the cache and the rotation. It is kept
  in bits 12-8 of the entry's immediate, which a shift does not use.
- **A count in a register is registered first:** `SHL reg, CL` and
  its kin take two cycles. They are 1% of DOOM's shifts.
- **The operand is not sign-extended before the rotation** for 8-
  and 16-bit arithmetic shifts; the sign is filled in after it, by
  the mask moved down.
- **The result joins the data for the register file one choice
  before the end,** not through the multiplexer of all the units'
  results.
- **The zero flag is found beside the result, not from it:** for
  each of the parts the result is put together from, whether it is
  zero (an OR is zero when both its sides are).

It costs about 450 logic cells and gives back four of the nine
multiplier blocks (the second multiplier, for the double shifts, is
gone). The multiplier is now the multiply's alone.

**The core's options** (parameters of `m86b_core`, set by the board
file):

| | | Lakritz | Sergei ML2 |
|---|---|---|---|
| `VMEM` | Paging, virtual 8086 mode and the I/O permission bitmap. Without: CR0's PG bit and EFLAGS' VM bit do nothing, and a port above the I/O privilege level is a general protection fault | **0** | 1 |
| `WIN` | The decoder's window ([round 32](#the-decoders-window)) | **1** (0 until now) | 1 |
| `OVL` | A load lets the next instruction start ([round 39](#round-39)) | 1 | 1 |

DOS, DOS/4GW and DOOM use none of what `VMEM` holds: DOOM ran in
round 26, before any of it existed, and runs in lockstep on the core
built without it (the whole 664 million steps to the end of the
profile's stretch). A memory manager like Jemm386 needs all of it,
so on Lakritz there is none; `make lakritz LAK_DEFS=-DM86_VMEM=1
-DM86_WIN=0` builds the old choice. Leaving it out is worth about
2,000 cells on Lakritz, which paid for the window and the shifter
and left room: see [boards.md](boards.md#lakritz-where-it-stands).

**The clock.** The shifter is now among the longest ways through
the core, beside the adder's: Lakritz routes at 33.8 to 35.1 MHz
over three seeds and the Sergei at 34.0, for 33.16. That is no more
margin than round 39 had, for all the room on Lakritz; round 38's
design, with its three-cycle shifts, made 36.8 on Lakritz on the one
seed it was built with.

**Where DOOM's cycles go now,** an instruction: 0.96 first
micro-operations; 0.17 decoding; 0.15 microcode after the first
micro-operation; 0.13 waiting behind a load; 0.12 first cycles of
loads that cannot be overlapped; 0.06 waiting for the ROM; 0.07
everything else.

## Known limits

1. **Lakritz has no paging, virtual 8086 mode or I/O permission
   bitmap** since round 40 (`VMEM = 0`): they were what filled it.
   All 56 block RAMs are still used, so anything that wants a block
   has to take it from something.
2. **Self-modifying code** is handled exactly, but two windows
   remain. A store takes effect on the cache at the end of the
   instruction that makes it, so an instruction that overwrites the
   one straight after it may see the old one run once; a real 386's
   prefetch queue behaves the same way. And a store that straddles
   two blocks of the code map is checked against the first only.
3. **An announced read must be followed by that read or by an idle
   bus cycle.** The cache relies on it to drop a read the CPU did not
   make after all (`rtl/soc/m86_dcache.v`); the core keeps to it, and
   anything else put on the core's bus must too.
4. **Bit instructions on memory** read and write one byte where a
   386 uses the whole operand ([round 26](#round-26)).
5. **Two simulators.** Twice a fault in the core's Verilog was run
   differently by Verilator and by Icarus. Both stay in `make check`
   for that reason.
6. No NMI and no single-step trap.
7. **Paging is slow** ([pmode.md](pmode.md#paging)): two or three
   cycles more for every memory access, and the instruction cache
   emptied whenever the mapping changes. Plain DOS pays nothing.
8. **Port 1E8h belongs to the core** when paging is on: whatever
   holds the core must answer a read of it with the core's `x_rd`
   output and ignore writes (`rtl/soc/m86_soc.v` and the lockstep
   bench do).
9. **A fault in the middle of a stack switch** (the new stack's page
   not present, say) is delivered with the new stack segment already
   loaded. Systems keep their level-0 stacks present, so this should
   not arise; it is not what a 386 does.
