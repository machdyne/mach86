# CPU design B

The first RTL core ([cpu.md](cpu.md)) is correct and 28,653 LUT4, more
than a whole Lakritz. Design B replaces it. This page describes the
design, what exists of it, and what has been measured.

**State: runs on a Sergei ML2.** It boots DOS and runs games there,
DOOM under DOS/4GW among them, at 33 MHz and 21.4 million
instructions a second on plain code, measured there (1.4 to 1.6 cycles an
instruction; DOS itself, with its calls and console output, is
nearer 2.6). It passes 1,748,646 instruction vectors captured from
a real 386 with 53 known deviations, and runs DOS and DOOM's start
in lockstep with the reference model without a difference. It is a
486SX to software: the 486's instructions and AC flag, no FPU, no
`CPUID`. Protected mode is partial ([pmode.md](pmode.md)).

The sections below were written as the design grew, and the older
ones give the figures of their time; [round 26](#round-26) has the
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
  shift contributes. A double shift is two shifts and an OR, about
  twelve cycles. With 16-bit operands and more than 16 places the
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

## Known limits

1. **Microcode ROM space.** 1,019 of 1,024 words are used. Anything
   more needs the ROM to grow to 2,048 words, which costs five block
   RAMs and a wider jump field; Lakritz has none to spare.
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
