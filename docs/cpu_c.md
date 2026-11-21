# CPU design C: a plan

**This page is a plan, three steps in.** The model counts the cycles
the pipeline would take ([what the count says](#what-the-count-says)),
and a design C core exists in simulation
([where the RTL is](#where-the-rtl-is)): design B's logic re-timed
for a faster clock, and beside it a first form of the pipeline,
which runs half of DOS's instructions. It is correct in lockstep
with the model. It is not fast yet, and its clock has fallen with
the pipeline's first form. Nothing is on a board. Design B
([cpu_b.md](cpu_b.md)) is the CPU on every board today and stays the
CPU of Lakritz. Design C is to be a second, faster core for the
boards with a 45F FPGA (Sergei ML2). **The target is a 486DX2/50**
(Lakritz stays a 486SX/33): the count says 1.5 to 1.6 times design
B is in reach, which is a DX/40 to DX2/50 on Dhrystone.

## Why a new core

Design B does all of an instruction's work in one clock cycle: the
decoded-instruction cache's block RAM gives the micro-operation, the
registers are read, the ALU or the address adder runs, the result is
written and the next instruction's cache address goes out. That
cycle is about 30 ns on the slowest ECP5 (speed grade 6, which is
what we must support): 10 ns of logic and 20 ns of wiring, with
nearly 6 ns gone before the block RAM's output has left it. No
tuning makes that 15 ns. A faster clock means doing the same work in
several shorter steps, with several instructions under way at once:
a pipeline.

## The goal in numbers

| | Clock | Cycles per instruction (DOOM) | Dhrystone 2.1 |
|---|---:|---:|---:|
| Design B, round 31 | 33 MHz | 2.4 | 15.2 DMIPS |
| Design B, round 32 | 33 MHz | 1.95 | 19.4 DMIPS |
| A 486DX/33 (Intel's figure) | 33 MHz | | 27 |
| A 486DX2/66 (Intel's figure) | 66 MHz | | 54 |
| Design C, counted by the model | 50 MHz | 1.8, and 1.7 with multiply and divide in the pipeline | 32 |

Two things about this table:

- Intel's figures are Dhrystone 1.1 with the compilers of the time;
  ours are Dhrystone 2.1 with `gcc -m16 -O2`. They are comparable
  only roughly.
- The cycles are the model's count (below), with a
  decoded-instruction cache of 4,096 entries. The clock is what the
  first RTL reaches, the core alone.
- **The DX2/66 was the goal this page began with; the count and
  the first RTL say it is out of reach** (below). A 486DX/40 to
  DX2/50 is what to expect.

## What is kept

Everything that makes design B trustworthy is reused:

- **The decoded-instruction cache.** An instruction is still decoded
  once, by the same decoder, into the same entry. The pipeline is
  fed finished micro-operations, so it has no x86 decoding in it.
- **The microcode ROM and its assembler,** word for word. Protected
  mode, paging's faults, interrupts and the rare instructions stay
  microcode.
- **The reference model, the lockstep bench, the 386 vectors,
  test386, the DOS and DOOM runs.** Design C is compared with the
  model after every instruction exactly as design B is.
- **The machine around the core.** Design C has design B's ports, so
  a board chooses its core with a parameter.

## The pipeline

Six steps for the common micro-operations:

```
F1  next address  -> decoded-instruction cache (block RAM address)
F2  the entry arrives; tag check; micro-operation chosen
R   registers read (with forwarding); address = base + index*scale + disp + segment base
M   data cache looked up
X   ALU on register or memory operand; flags; jumps decided
W   register and flags written; a store goes to the cache's write queue
```

- **Memory before the ALU.** `ADD EAX, [EBX+4]` flows through
  without a pause, and so does a load followed by a use of what it
  loaded. This is the largest single gain over design B, where
  every load is a second cycle: a third of DOOM's instructions.
- **The price is the address step.** An address needs its registers
  in R; if the instruction just before computes one of them, it is
  not known until X, two steps later. Then the later instruction
  waits (a 486 and a Pentium wait here too).
- **Jumps are decided in X,** four steps after F1. So the next
  address is predicted: each cache entry keeps whether its jump was
  taken last time, and the target comes from the entry itself (the
  displacement is in it). A wrong guess costs four cycles; returns
  get a small stack of return addresses.
- **Nothing changes the machine before W.** A fault, an interrupt or
  a wrong guess throws away the younger steps and nothing has to be
  undone, which design B needs special care for (string pointers,
  the stack pointer).
- **Stores into code** are found as now, with the code map, and
  empty the pipeline as well as the cache entries.

## The rest runs one at a time

About a dozen kinds of micro-operation flow down the pipeline one
behind the other: ALU with a register or the immediate, load,
load-and-operate (with the store after it), store, `LEA`, push and
pop, the conditional and unconditional jumps, call and return, and
(the count below says they must) the shifts of a register, double
shifts included, which need a real shifter in X where design B
borrows the multiplier.

Everything else (segment loads, the descriptor checks, the system
registers, multiply, divide, the string instructions' loops, I/O,
the paging unit) **goes through the same stages alone:** nothing
younger enters until it has finished. That keeps the hard, rare
part of x86 as it is in design B (the same microcode, the same
descriptor and paging logic) and makes only the common path fast.
Later steps can let more kinds overlap, one at a time, each checked
in lockstep.

**How they go alone: design B's logic, in three clock cycles for
each of its one.** nextpnr has, as far as I know, no way to say that
a path may take two cycles, so "a 30 ns step in two cycles of 15"
cannot simply be declared: every path would be reported against one
cycle and timing margin could not be checked. Instead the long
paths are cut with real registers
([where the RTL is](#where-the-rtl-is)), which the tool checks like
any others. The price is that a rare kind costs three times design
B's cycles, not the same number, and the count below has to say so.

## What the count says

`M86_PIPE` ([model.md](model.md#looking-at-what-a-program-does))
makes the model count this pipeline's cycles for whatever it runs:
one a cycle, plus the waits listed above, ten cycles for an
instruction not in the cache, and for a kind that goes alone
design B's cycles for it and three more.

DOOM's play, 60 million instructions of the first demo:

| | Cycles an instruction |
|---|---:|
| Design B, round 32 (lockstep, a like stretch) | 1.80 |
| Design C, shifts going alone, 2,048 entries | 2.20 |
| Design C, shifts in the pipeline, 2,048 entries | 1.62 |
| ... 4,096 entries | 1.49 |
| ... 8,192 entries | 1.39 |
| ... 16,384 entries | 1.30 |

Where the 1.49 comes from: 1.00 for the instructions themselves,
0.25 for those not in the cache (2.5% of them), 0.15 for the kinds
that go alone (1.8%: divide, multiply, segment loads, `PUSHA`), 0.05
for jumps guessed wrong (one in ten, with one bit a jump) and 0.04
for addresses that wait.

Dhrystone: 749 cycles with 4,096 entries (971 on design B), which
is 38 DMIPS at 50 MHz and 50 at 66 MHz.

The table above charges the kinds that go alone design B's cycles
at the new clock, which is what was hoped for before the RTL
existed. Charged three clock cycles for each of design B's, as the
core now does them, and twelve for an instruction not in the cache:

| | Cycles an instruction |
|---|---:|
| Shifts in the pipeline, 4,096 entries | 1.78 |
| ... 8,192 entries | 1.65 |

Of the 1.78, 0.39 is the kinds that go alone, though they are
under 2% of instructions: divide and multiply (0.4% and 0.3% of
instructions, 34 and 18 cycles), segment loads, `PUSHA` and `POPA`.
Design B is at 1.80. So at 50 MHz this is 1.5 times design B on
DOOM, not 1.8, until multiply and divide are in the pipeline too
(with them about 1.7, or 1.6 times design B).

**That is a 486DX/40 to DX2/50, not a DX2/66,** and I do not see
this design reaching the DX2/66 on this FPGA: it would need about
1.25 cycles an instruction at 66 MHz, and both numbers are out of
reach here. What is in reach is not quite twice round 31's speed.

What the count decided:

- **Shifts must be in the pipeline.** DOOM's play is one shift in
  nine instructions (its fixed-point arithmetic); going alone they
  would make design C slower per instruction than design B.
- **The cache must be larger: 4,096 entries,** twice design B's.
  That is 21 more block RAMs, and Sergei ML2 has 11 free. Its video
  memory is in block RAM today; it moves to the DDR3, where Lakritz
  already keeps its own (in the SDRAM), and frees more than enough.
- **Not in the cache is still the largest loss,** so the decoder's
  window comes along, and the ten cycles are worth shortening.
- **Multiply and divide belong in the pipeline next,** after the
  shifts: they are most of what the kinds that go alone cost.

The count is a model: the table of design B's cycles in it is
rough, and it leaves out the data cache's misses, which cost any
core the same time and so weigh more on the faster one.

## Where the RTL is

`rtl/cpu/m86c_core.v` (round 34) began as a copy of design B's core
(`tools/mkc_core.py` made it; it is a source of its own from here).
It is step 2 in its first form:

- **Design B's cycle is three cycles of a faster clock** (`PH`).
  Every register of design B is written only in the last of them,
  the tick, so between ticks the machine is design B's, standing
  still.
- **Its long paths are cut:** a wire in the middle of one gets a
  register that is clocked every cycle. Such a register holds what
  the wire would have settled to, a cycle late; as long as no path
  passes more than two of them, everything has settled when the
  tick comes and the machine does what design B does. Cut so far:
  the micro-operation after its selection from the cache or the
  ROM, the cache's hit, the operands read from the registers, the
  address, the attribute ROM's word, the decoder's data and limit
  check, the fault signal, and the bus's answer.
- **The bus is design B's, for a machine at the fast clock:** a
  request is made once and its answer kept until the tick; what may
  change at any time (the interrupt line) is looked at once a
  cycle of design B's.

**It is right:** in lockstep with the model it runs the BIOS and
DOS tests (40 million instructions, with late memory, held writes
and DMA requests), the protected-mode, paging and 486 tests, and
the 386 vectors; and its clock count is exactly three times design
B's, which is what "the same machine" predicts.

**Its clock:** the core alone, placed and routed for the slowest
45F (`make fmax-c`), reaches 49 to 53 MHz from run to run, against
36.5 MHz for the same core with no cuts. Four fifths of the
longest path is wiring, not logic, so more cuts will raise it only
a little; I take 50 MHz as what this design runs at.

**That machine alone is slow:** three clock cycles for each of
design B's is design B at 17 MHz.

### The pipeline (round 35)

Beside that machine, in the same file, is the pipeline of the plan,
in its first form:

```
T   the cache's entry is here: the instruction wanted? a kind the pipeline does?
R   the registers of its address are read, the address added up
M1  the memory is told the address; limit and code-map checks
M2  the memory's answer; the operation's registers are read (or forwarded from X)
X   ALU, flags, the register or the memory written, a jump decided
```

- **What goes through it:** instructions of one micro-operation of
  these kinds: the ALU operations on registers, with an immediate
  and with a memory operand; loads and stores; `PUSH` and `POP` of
  a register, `PUSH` of an immediate; the relative jumps, `CALL`
  and `RET` (which became one micro-operation for this, in both
  cores). Not yet: anything of two micro-operations (an operation
  into memory), shifts, `LEA`, the segment registers, and with
  paging on, nothing.
- **How the two share the machine:** while the pipeline runs,
  design B's machine stands still at the start of a step. The
  pipeline starts when that machine is between instructions with
  nothing else to do and the next instruction is its kind; it stops
  at the first that is not, lets what is under way finish, and
  leaves the machine pointing at that one with its cache entry
  read.
- **Nothing in X can fault.** An access outside its segment and a
  store into a block that holds cached instructions are found in
  M1; such an instruction is dropped when it reaches X, with all
  behind it, and design B's machine runs it, fault, cache search
  and all.
- **The stack pointer** as `PUSH`, `POP`, `CALL` and `RET` move it
  is kept in R, ahead of the register, so one stack instruction
  after another does not wait. (ESP is a register of its own in
  this core, not in the register file: a `POP` writes two
  registers and the file has one write a cycle.)
- **An address waits** for a register that an instruction ahead of
  it has yet to write, until that one has left X.
- **Jumps are taken to be not taken;** a taken one drops the four
  instructions behind it. There is no prediction yet.
- **An interrupt request is honoured at once:** the instruction in
  X in the cycle the request arrives is not done. (The lockstep
  bench needs that exactness; the hardware gets short latency.)

**It is right, as far as tested:** the BIOS and DOS tests (40
million instructions, with late memory, held writes and DMA
requests), the protected-mode test and the 486 test, all in
lockstep with the model; the paging test too, where the pipeline
stands aside once paging is on. The 386 vectors and test386 have
not been run on this form.

**It is not fast yet.** In the DOS test 51% of instructions go
through the pipeline, and the run is 1% shorter for it: runs of
pipeline instructions are short there (DOS calls are full of
segment-register pushes and pops, `INT` and `IRET`), each taken
jump costs four cycles, and starting and stopping cost about five.
What will make it fast, in the order I expect to do it: the kinds
still missing (two-operation instructions, shifts, `LEA`, the
segment pushes and pops), the guessed jumps, then a quicker
hand-over.

**Its clock fell** to 43 MHz for the core alone with the pipeline in
(it was 49 to 53). Round 36, below, is about getting it back.

### The clock (round 36)

The pipeline's first stage was what held the clock at 41 to 46 MHz:
the cache is block RAM, whose output arrives 5.8 ns into the cycle,
and everything that depended on "is this entry the instruction" was
behind it. Four changes, none of which alters what is computed:

- **Whether an entry is the pipeline's kind is a bit of the entry,**
  worked out when it is filled.
- **The hit is looked at in R, not T.** T passes its entry on and
  reads the next one without waiting; R compares the tag it was
  given. A wrong entry is dropped there, the fetch goes back to it,
  the cache's output is read again and design B's machine takes over
  from that. Only the entry's length is used in T, for the next
  address.
- **Starting is decided from a registered copy** of the hit and of
  "design B's machine is idle", and the pipeline's registers do not
  wait for the decision where loading them does no harm.
- **After a dropped instruction or a taken jump the new address is
  read a cycle later,** from a register. The cache's address lines
  run to 34 block RAMs and were the longest wires in the design. A
  taken jump now costs five instructions' time, not four; this is the
  price, and guessing jumps (still to do) removes most of it.

Place and route of the core alone now reports 45.5 to 49.8 MHz over
three seeds (49.5 and 49.8 for two of them). **That is not yet a
proven 50 MHz, and the machine around the core has not been built at
this clock at all.** In all three runs the slowest path reported is
in design B's three-clock logic, where it has two or three clocks,
which the tool cannot be told; the pipeline's own paths are shorter
than those. The next step is to show that with a number: more cut
registers in the three-clock part until the tool's worst path is a
real one.

The cost in cycles, on the tests that run so far (lockstep, clock
cycles per instruction): the boot test 8.7 to 9.1, the protected-mode
loop test 3.4 to 3.9, the DOS test 11.4 to 11.7.

The DOS test (40 million instructions, with late memory, stores made
to wait and a DMA request every 97 clocks; 53% of instructions through
the pipeline), the boot test, pm3test, pgtest and i486test pass in
lockstep with these changes. (With a DMA request every 3 clocks the
DOS test also passes, and the pipeline never starts: a request is
always waiting.) The instruction vectors, test386 and DOOM
have not been rerun on design C this round.

### Into the machine (round 37)

Design C is now an option of the SoC (`CPU_C`), has a Sergei ML2
build (`make sergei_ml2_c`), and boots DOS in simulation of the whole
machine (`make -C sim check-soc-c`: the BIOS boot test and a DOS
session with the DOS test program). **It has not run on a board.**

**Round 38 stopped here.** Design B was profiled by cause to see
what a pipeline could gain at all ([cpu_b.md](cpu_b.md#round-38)):
in DOOM a pipeline needs about as many cycles an instruction as
design B would with two changes of its own (1.48 against 1.52), so
those two changes come first, in design B, for both boards. Design C
stays in the tree, builds and passes its checks; what a faster clock
could add is a question for after that.

**It is slower than design B today, and the bitstream is for seeing
that it works, not for speed.** On the SoC it takes 9.3 clocks an
instruction through a DOS session, at 39.4 MHz: about 4 million
instructions a second, against design B's 13 or so (2.5 clocks at
33 MHz). The reason is in the numbers above: half the instructions
still go through the three-clock part, which takes three clocks for
each of design B's cycles, and every change between it and the
pipeline costs clocks. With the SoC's cache answering a cycle later
(below) the pipeline gains nothing at all yet: the same session
without it (`CPU_FAST = 0`) takes 9.1. The speed comes when the
pipeline does the instructions that are still missing and guesses
jumps; nothing in this round changes that.

**The clock is 39.4 MHz, not 48.5.** What was found on the way:

- The interrupt controller's request went through the core to the
  bus and the SoC's decoding in one cycle: design C gets it a cycle
  later (`irq_q`).
- The SoC's memory cache decided everything from its tags in the
  cycle they come out of block RAM. With `LATE` (used with design C)
  the hit is registered and every access takes a cycle longer.
- In the core: the three-clock part's register writes and its cache
  read address are now registered (`rfp_*`, `dc_ra_q`).
- After these the tool reports 41 to 43 MHz for the SoC at any of the
  settings tried, including four clocks for the slow part's cycle
  (`PH = 4`, 41.9) and the cache's tags in LUT RAM (which made the
  design too full to route). The slowest paths are of two kinds: the
  three-clock part's, which have two or three clocks that the tool
  cannot be told about, and real ones from the core's bus through the
  SoC's cache, about 24 ns. The second kind is the work that remains
  for 48.5 MHz: the bus between core and cache needs a register stage,
  which changes the pipeline's memory timing.
- The core alone is at 49.6 MHz by the tool.

**Two faults that only the SoC showed**, both in the pipeline, both
fixed, both now in the lockstep tests:

- *A read taken back.* When an instruction was dropped (a taken jump,
  an interrupt) while its read was on the bus unanswered, the
  pipeline took the read off. The SoC's cache had begun on it and
  gave its answer to the next read. DOS did not boot. Now the read
  stays on the bus until it is answered (`fo_*`). The lockstep
  bench's memory answered at once and could not show this; its
  late-memory mode (`M86B_WAIT=n`) now waits up to n cycles and
  reports any read that leaves the bus unanswered.
- *An instruction given up, for ever.* The pipeline gives an
  instruction to the three-clock part when it will not do it (a store
  into a block that holds code, a segment limit). It then started
  again before that part had run the instruction, found it again and
  gave it up again. No lockstep test had ever made the pipeline give
  one up; DOS on the SoC does at once. Now the pipeline waits until
  the other part has run an instruction (`f_bown`), and
  `M86C_ABORT=n` makes the bench force such cases at random.

Also fixed: the three-clock part's writes were on the bus for three
clocks, which wrote a port three times (seen as tripled characters on
the serial console).

A known risk, not fixed: the three-clock part can put a read on the
bus in its first clock from a signal that is not settled until the
second (a segment-limit fault found late). The read is then not
wanted, and if it misses the cache it is an instance of the first
fault above. It needs a faulting access to happen and has not been
seen.

## What it costs

| | Design B (round 32) | Design C (estimate) |
|---|---:|---:|
| LUT4 after synthesis, core alone | 9,000 | 13,000 to 15,000 |
| Block RAM | 34 for cache, ROM and maps | 55: the cache is twice as large |

Lakritz cannot hold it (about 700 logic cells are free there). The 45F
boards can: Sergei ML2 is at 60% of its LUTs.

The machine around the core must run at the new clock too. The DDR3
bridge, the data cache and the video memory were written for 33 MHz;
the data cache's lookup in particular becomes the pipeline's M step
and has to be reworked with it. That work is part of this plan and
is not small.

## Steps

Each ends with something that runs and is measured.

1. **A model of the timing. Done** (round 33, above).
2. **Design B's logic at the new clock. Done in simulation**
   (round 34, above). Still to do here: the decoder out of the
   three-cycle scheme (its steps are short and can run at the full
   clock).
3. **The pipeline. Begun** (round 35, above): it runs and is right;
   the missing kinds, the guessed jumps and its clock are still to
   do, and test386 and DOOM in lockstep. From here the cycle count
   should approach the model's.
4. **The clock.** Place and route on the 45F; shorten what is slow.
5. **The machine at the new clock;** a Sergei ML2 bitstream.
6. **Then, in the order the measurements say:** more kinds in the
   pipeline, two micro-operations per cache entry, a larger cache.

The FPU, for "DX" in the full sense, is in the model and the BIOS
since round 36 and not yet in RTL: [fpu.md](fpu.md).
