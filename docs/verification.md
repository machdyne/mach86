# Verification

A CPU that is nearly right boots DOS and then fails in a game three
weeks later. The plan is to find those faults in simulation, one
instruction at a time, before they reach a board.

## Layers

| Layer | What it checks | Runs on |
|---|---|---|
| 1. Instruction vectors | One instruction: registers, flags and memory before and after | Reference model, then RTL |
| 2. Directed programs | Our own assembly tests for things vectors do not reach: interrupts, exceptions, prefixes, mode switches | Model and RTL |
| 3. Lockstep | RTL and model run the same program; every retired instruction's state is compared | RTL simulation |
| 4. Device tests | Each PC device against its data sheet, in isolation | RTL simulation |
| 5. Boot ladder | BIOS, then DOS, then programs | Model, RTL simulation, board |
| 6. Games | The test register in [software.md](software.md) | Board |

Lockstep is the method Zeitlos uses between its two CPU cores. Here
the second party is the C model.

The lockstep bench can make the memory behind the RTL core awkward,
which nothing may change but the time: `M86B_WAIT=n` answers reads up
to n cycles late (and reports a read that leaves the bus unanswered,
which the SoC's cache cannot take), `M86B_STRDY=1` makes stores wait
at random, `M86B_DMA=n` asks for a byte every n cycles, and for
design C `M86C_ABORT=n` makes its pipeline give an instruction up one
cycle in n. Design C's two faults of round 37 ([cpu_c.md](cpu_c.md))
were of kinds the bench could not show before the first and last of
these.

The RTL floating-point unit is compared with the model's in the same
lockstep, its registers and status after every instruction
(`make check-fpu-rtl`, [fpu.md](fpu.md)).

The model's floating-point unit has a check of its own kind: its
arithmetic is compared, bit for bit, with the x87 of the machine the
tests run on (`make check-fpu`, [fpu.md](fpu.md)).

Layers 1, 3 and 5 run on the RTL core today ([cpu.md](cpu.md#verification)).
Layer 2 is thin: the directed programs do not yet cover single-step,
NMI or the system instructions. Layer 4 waits for the PC hardware in
RTL.

## The reference model

`sim/` holds a C model of the CPU and the PC, written from the same
specifications as the RTL and under the same clean-room rule. It is:

- the first thing that runs the BIOS and DOS, months before the RTL
  can;
- the oracle for lockstep;
- fast enough to boot DOS in seconds, so BIOS work is not held up by
  simulation speed.

The model also counts instructions by class and applies the cycle
targets of the design, so the speed estimate
can be recomputed from real programs before the RTL exists, and the
fast path is filled in the order the profiles give.

A fault shared by the model and the RTL is invisible to lockstep.
Layer 1 exists to catch those: its expected results come from real
chips, not from us.

### A protected-mode test suite for the model

The vectors are real mode. For protected mode the model is checked
against **test386.asm** (github.com/barotto/test386.asm), a test ROM
for 80386 emulators: rings, virtual 8086 mode, task switches, paging
and page faults, segment faults, and the instruction set. It is
GPL, so it is fetched when wanted and stays out of the repository.
The model passes all of it (round 28). To run it:

```
git clone https://github.com/barotto/test386.asm ext/test386
cd ext/test386
# in src/configuration.asm: OUT_PORT equ 0xE9; ROM128 equ 1 for the
# task-switch tests (a 128 KB ROM)
nasm -i./src/ -f bin src/test386.asm -w-all -o test386.bin
M86_POST=1 M86_E9=1 output/sim/m86pc -bios test386.bin -max 100000000 > ee.txt
diff ee.txt test386-EE-reference.txt
```

The last diagnostic code printed must be `ff`, and the output must
equal the reference file (44,926 lines of arithmetic results and
flags).

Since round 29 the core runs it too, in lockstep with the model
(the 64 KB ROM: the 128 KB one adds task switches, which the core
lacks):

```
make -C sim ../output/b/rtlpcb
M86_POST=1 output/b/rtlpcb -bios test386.bin -max 100000000
```

It ends with "no difference" after 79.7 million instructions, about
ten minutes. A build with `VDEF=+define+M86_DBG` prints every fault
the core takes, which is how the suite's failures were found.

### Where the cycles go

`LOCKSTEP_PROFILE=1` in the environment makes the lockstep bench end
with a table by opcode: how often, how many cycles, cycles each with
and without the decoder's, and a histogram of cycles an instruction.
`LOCKSTEP_PROFILE=n` starts the table (and the bench's own counts)
after n steps, to look at one part of a run: a game's play and not
its start, say. Round 32's list was made with it
([cpu_b.md](cpu_b.md#round-32)):

```
LOCKSTEP_PROFILE=620000000 output/b/rtlpcb -bios output/bios/bios.bin \
  -disk card.img -expect "C:\>" -type "d:\r" -type "doom -nosound\r" \
  -run 620000000
```

For design B the table is followed by the same cycles sorted by
cause (a load's first cycle, a shift's extra cycles, decoding,
micro-operations from the ROM and so on: the classes add up to the
run's cycles), the micro-operations by kind, and three estimates
made from the run: design B with the next micro-operation begun
under a load's second cycle, the same with one-cycle shifts, and a
pipelined engine with and without a jump predictor (the bench keeps
a predictor's tables beside the model and counts what it would get
wrong). The core gives the bench what it needs in two wires,
`prof_st` and `prof_uop`, that nothing in the design uses. Round
38's decision was made with it ([cpu_b.md](cpu_b.md#round-38)).

The profile also carries a model of the data cache in front of the
main memory, in five sizes and one of two ways, fed with every
access the core makes to main memory, and says how often each would
miss and how often the line it puts out had been written
([soc.md](soc.md#the-main-memory) has round 40's figures); and of the
instruction cache with other ways of choosing an entry.

`LOCKSTEP_TRACE=n` prints a line for every clock cycle from step n
on (the interrupt line, the cycle's class, both instruction
pointers, the bus): for finding out what the core was doing when a
long run stops at a difference.

**Two instructions in one cycle.** Since round 39 design B can end
a load and the instruction after it in the same clock cycle
([cpu_b.md](cpu_b.md#round-39)), and the bench cannot look between
them. The core says so (`step_two`); the bench then runs the model
two steps and compares after the second. An interrupt cannot come
between the two in the core, so the bench holds the model's off for
that one step; it does the same when the instruction after a load
has begun beside it without ending (or its decoding has), since the
core will finish that instruction before it takes an interrupt. The
instruction pointer compared is the one the pending load left
behind. DOOM found both cases, 43 and 125 million instructions in:
neither was a fault in the core.

### The core's options

The core has three build options ([cpu_b.md](cpu_b.md#round-40)), and
each side of each is run in lockstep:

- `make check-b-boot` and the rest: all on, as Sergei builds it.
- `make check-b-lak`: without paging, virtual 8086 mode and the I/O
  permission bitmap (`VMEM = 0`), as Lakritz builds it
  (`output/b/rtlpcbl`): the BIOS boot test, the 486 test and the two
  protected-mode tests that need none of the three. DOOM was run on
  it by hand, with the profile's command above.
- `make check-b-nowin`: without the decoder's window and without the
  load that lets the next instruction start (`WIN = 0`, `OVL = 0`:
  `output/b/rtlpcb0`), the BIOS boot test.
- `make check-nobram` runs the SoC as Lakritz builds it.

All three are part of `make check`.

### Design C

Design C's core ([cpu_c.md](cpu_c.md)) has design B's ports and is
checked by the same benches: `make -C sim check-c-boot` (the BIOS
test in lockstep; `output/b/rtlpcc` is the bench, used like
`rtlpcb`) and `make -C sim vectors-c VECTORS=...`. `CPARAM=-GPH=4`
builds it with four clock cycles for each of design B's, one more
than it needs: a difference from the model that goes away with it
means a path passes too many cut registers. `make fmax-c` places and
routes the core alone and prints its clock (`FMAX_MHZ`, `FMAX_PH`).

The bench says how many instructions went through design C's
pipeline, and with `LOCKSTEP_PROFILE=1` which opcodes did not, most
frequent first: the list of what to teach the pipeline next.
`CPARAM=-GFAST=0` builds the core without the pipeline.

### Requests from outside

`M86B_DMA=n` in the environment makes the lockstep bench ask the
core for a byte of memory every n cycles, as the Sound Blaster
does. The model knows nothing of it, so any difference is a fault
in how the core takes the request. Run with it: a DOS boot, the
protected-mode and paging tests, and the 386 test suite.

### A memory manager

Jemm386 (github.com/Baron-von-Riedesel/Jemm; it needs JWasm and
JWlink from the same author, which build on Linux with GCC) puts
DOS into virtual 8086 mode with paging. With `JEMM386.EXE` on the
card's D: drive (`tools/mkcard.py`):

```
output/b/rtlpcb -bios output/bios/bios.bin -max 900000000 -disk card.img \
    -dexpect 'C:\>' -type 'd:\r' -dexpect 'D:\>' -type 'jemm386 load\r' \
    -run 40000000 -type 'c:\speed\r' -run 60000000
```

## Instruction vectors

Hardware-captured single-instruction test sets exist for the 8088,
the 286 and the 386. The 386 set, which is the one used, releases its
data into the public domain and its software under the MIT licence. Each test gives
a starting state, the instruction bytes and the final state, including
flags the manuals leave undefined.

- The model passes the 386 real-mode set today
  ([model.md](model.md#instruction-vectors)).
- The 386 set covers real mode today. Its protected-mode and V86
  parts are announced but not yet published, so layers 2 and 3 carry
  more of the weight in phases 6 and 7.
- These sets are large. They are fetched by a script and not
  committed.
- Only the 386 set is used. The model is a 386 from the start, so
  the 8088 and 286 sets, which differ in details (`PUSH SP`, shift
  counts, undefined flags), are not needed.

Before any third-party test set is used, its licence is recorded in
[software.md](software.md).

## Simulation tools

- **Icarus Verilog** for unit tests and lockstep of short programs,
  as in Zeitlos.
- **Verilator** for anything that boots: Icarus is too slow to reach
  a DOS prompt in RTL. This is a new tool relative to Zeitlos. So far
  everything on the RTL core runs under Verilator.
- The C model for everything that does not need RTL.

## Boot ladder

Each rung must pass in the model before it is tried in RTL, and in
RTL simulation before it is tried on a board.

1. Boot block copies the BIOS and jumps to it.
2. BIOS self-test completes and prints over the serial port.
3. BIOS reads the boot sector from the SD model.
4. DOS reaches a prompt.
5. A batch of DOS commands and a compiler run produce byte-identical
   output on model and RTL.
6. Per phase: the programs named as that phase's exit milestone.

In the model, rungs 1 to 4 are reached, with the BIOS loaded directly
(no boot block yet) and a stopgap DOS ([model.md](model.md#dos)).
Rung 5 has nothing to compare against until there is RTL.

## Continuous integration

`make check` is what CI runs. Each phase adds to it:

| Phase | Added to `make check` |
|---|---|
| 0 | Documentation links |
| 1 | Model and BIOS build; directed programs and the BIOS boot test pass (every push); DOS boots and runs a session (weekly, with the vectors) |
| 2 | The BIOS boot test on the RTL core in lockstep (every push, done); the vectors and the DOS test on the RTL core, and its size (weekly, done). Design B: a test program from reset under Icarus, and the BIOS boot test in lockstep (every push, done); the SoC booting the BIOS test through its pins (every push, done), and DOS, and the same on the synthesised netlist ([soc.md](soc.md#how-it-is-tested); weekly, done); DOS in lockstep (weekly, done); the vectors for the opcodes it has microcode for, under Verilator, and its size (weekly, done). To come with the fast path: lockstep with it on and off; pipeline tests (self-modifying code, faults behind jumps, interrupts at every stage) |
| 3 | Device tests; synthesis for both boards with size and timing recorded |

The vector suite is too large to fetch on every push. A scheduled job
runs it weekly and it can be started by hand. Long boots will go the
same way.
