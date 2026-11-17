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
