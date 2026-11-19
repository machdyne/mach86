# CPU design C: a plan

**This page is a plan. Nothing of it exists.** Design B
([cpu_b.md](cpu_b.md)) is the CPU on every board today and stays the
CPU of Lakritz. Design C is to be a second, faster core for the
boards with a 45F FPGA (Sergei ML2), with the speed of a 486DX2/66
as its goal.

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
| Design C, first target | 50 MHz | 1.4 | about 40 |
| Design C, the goal | 60 to 66 MHz | 1.25 | about 54 |

Two things about this table:

- Intel's figures are Dhrystone 1.1 with the compilers of the time;
  ours are Dhrystone 2.1 with `gcc -m16 -O2`. They are comparable
  only roughly.
- The goal needs both a clock twice design B's and fewer than
  1.3 cycles an instruction. Other soft cores on this FPGA family
  at this speed grade run at 50 to 60 MHz, so 50 MHz is what I
  expect to reach and 66 MHz is what the design should aim at. The
  first target is honest; the goal is not promised.

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

## The rest runs as design B does

Only about a dozen kinds of micro-operation go down the pipeline:
ALU with a register or the immediate, load, load-and-operate, store,
`LEA`, push and pop, the conditional and unconditional jumps, call
and return. On DOOM they are about nine in ten of what is executed;
shifts are most of the rest, and would be the first kind to add.

Everything else (segment loads, the descriptor checks, the system
registers, multiply, divide, the string instructions' loops, I/O,
the paging unit) **waits until the pipeline is empty and then runs
one micro-operation at a time,** as in design B, on the same logic.
That is the main decision of this plan: the hard, rare part of x86
is not re-implemented, only the common path is made fast. Later
steps can move more kinds into the pipeline, one at a time, each
checked in lockstep.

## What it costs

| | Design B (round 32) | Design C (estimate) |
|---|---:|---:|
| LUT4 after synthesis, core alone | 9,000 | 13,000 to 15,000 |
| Block RAM | 29 for cache, ROM and maps | the same, plus what a second micro-operation per entry needs if that proves worth it |

Lakritz cannot hold it (about 700 logic cells are free there). The 45F
boards can: Sergei ML2 is at 60% of its LUTs.

The machine around the core must run at the new clock too. The DDR3
bridge, the data cache and the video memory were written for 33 MHz;
the data cache's lookup in particular becomes the pipeline's M step
and has to be reworked with it. That work is part of this plan and
is not small.

## Steps

Each ends with something that runs and is measured.

1. **A model of the timing.** The C model gains a cycle count for
   this pipeline (interlocks, wrong guesses, the serialised kinds),
   run on DOOM, DOS and Dhrystone. It says whether 1.4 cycles an
   instruction is real before any RTL is written, and which kinds
   must be in the pipeline to get there.
2. **The pipeline alone,** in simulation, running cached
   register-only code against the model; then loads and stores.
3. **The serialised path,** by joining design B's execution logic to
   it. From here the core runs everything: vectors, test386, DOS,
   DOOM, all in lockstep.
4. **The clock.** Place and route on the 45F; shorten what is slow.
5. **The machine at the new clock;** a Sergei ML2 bitstream.
6. **Then, in the order the measurements say:** more kinds in the
   pipeline, two micro-operations per cache entry, a larger cache.

An FPU, for "DX" in the full sense, is separate work and comes after
this.
