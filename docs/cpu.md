# The first CPU core

`rtl/cpu/m86_core.v` is the first Mach86 CPU core in Verilog: a
sequencer that executes every instruction, one step at a time. It is
correct and much too large, and has been replaced as the way forward
by design B ([cpu_b.md](cpu_b.md)). It remains the reference in RTL.

| File | What it is |
|---|---|
| `rtl/cpu/m86_core.v` | The core: decode, sequencer, registers, bus |
| `rtl/cpu/m86_alu.v` | The arithmetic and logic unit |
| `sim/vectest_rtl.cpp` | Runs the core against the instruction vectors, under Verilator |
| `sim/lockstep.cpp` | Runs the core as the CPU of the whole machine, in lockstep with the model |

## State of it

| | |
|---|---|
| Instruction set | The 386 in real mode, 16- and 32-bit operands and addresses: no protected mode |
| Instruction vectors | 1,758,670 of 1,758,699 pass. The 29 that do not are the same 29 the model does not match ([model.md](model.md#known-deviations)) |
| Lockstep with the model | A DOS boot and our DOS test, 40 million steps, and a session at the DOS prompt, 46 million steps: no difference |
| Speed, as it is | 13 clock cycles per instruction on the DOS runs: about 3.6 million instructions per second at 48 MHz |
| Size, as it is | 28,653 LUT4 and 1,630 flip-flops for ECP5 (Yosys 0.33). **More than a whole Lakritz** |
| Clock, as it is | About 19 MHz against a 48 MHz target, from one placement estimate on an 85F; not a routed result |

The core is correct and far too big. **It will not be shrunk; it is
replaced by design B ([cpu_b.md](cpu_b.md)).** It stays as the
functional reference in RTL: design B is checked against it as well as
against the model.

## How it works

One instruction at a time, as a state machine:

1. **Boundary.** Take a pending interrupt if there is one; otherwise
   start fetching.
2. **Decode.** Prefixes and opcode a byte at a time, then ModRM, SIB,
   displacement and immediate. A table says what each opcode needs.
   Invalid encodings and a misplaced `LOCK` are reported as soon as
   they can be known, before the rest is fetched.
3. **Operand.** If the instruction reads its r/m operand, read it.
4. **Execute.** A short sequence of steps per instruction, each at
   most one bus access. Shared sub-steps do the common work: one bus
   access, one ALU operation, one push, a shift a bit at a time, a
   divide a bit at a time, interrupt delivery.
5. **Commit.** Registers are written only when the instruction can no
   longer fault, so a fault needs nothing undone. Where the hardware
   itself commits early (`PUSHA`, `POPA`), the core does the same.

Things worth knowing:

- **The bus** takes one request at a time: 1, 2 or 4 bytes at any
  alignment. Splitting and aligning is left to the bus unit outside,
  which does not exist yet.
- **Limits** are checked on every access, as in real mode on a 386.
  All limits are FFFFh and constant until protected mode.
- **Interrupts** are acknowledged with a handshake: the core raises
  `inta` and takes the vector the cycle after.
- **`REP` string instructions** can be interrupted between iterations
  and resume, as on the real chip.
- **Multiply** uses one 33x33 multiplier, registered. **Divide** and
  **shifts** take a cycle per bit.
- **Not there:** protected mode (asking for it stops the core and
  raises `unsupported`); debug registers (moves to them are accepted
  and ignored).

## Verification

Three things are run against the core, all with Verilator.

**Instruction vectors.** `make rtl-vectors` runs the same 1.76 million
hardware-captured tests as the model, through the same runner
(`sim/vectest.c` with a different back end). About 30 seconds. The
first full run passed all but ten; those were one mistake, the order
in which an over-long instruction and an invalid `LOCK` are reported.

**Lockstep.** `sim/lockstep.cpp` builds two whole machines from the
same BIOS and disk image, one with the C CPU model and one with the
RTL core in front of the same C device models. After every step (an
instruction, a fault or an interrupt) it compares all registers,
flags, segment registers and the halt state, and stops at the first
difference. The result is `rtlpc`, which takes the same command line
and scripts as `m86pc`.

- `make check` boots the BIOS test diskette this way: 190,000 steps.
- `make rtl-dos` boots DOS and runs our DOS test this way: 40 million
  steps in about two minutes.

Lockstep covers what the vectors cannot: interrupts, port I/O, the
timer and keyboard, `HLT`, and long sequences of real code.

**What neither covers yet:** single-step (the trap flag), NMI, the
system instructions (`LGDT`, `SMSW` and the control-register moves),
and coprocessor escapes with `CR0.EM` set. DOS does not use them in
these runs. They need directed tests.

## Size

```
make synth      # Yosys, ECP5; prints the cell counts
```

| Cells | Count |
|---|---:|
| LUT4 | 28,653 |
| PFUMX, L6MUX21 (wide multiplexers) | 10,069 |
| Carry cells | 967 |
| Flip-flops | 1,630 |
| 18x18 multipliers | 4 |

The budget for the finished core on Lakritz is 12,500 LUTs
([boards.md](boards.md#lakritz-budget)), and Lakritz has 24,288 in
all.

**Clock.** One out-of-context run of nextpnr on an 85F reported about
19 MHz after placement; the run was not left to finish routing. The
same wide multiplexers are in the critical paths, so this number
should move with the size. It is recorded as a starting point only.

Where the area goes is not a mystery. The core is written as one large
state machine in which each instruction step states its own data
expressions: its own stack-pointer arithmetic, its own register
selection, its own address. Synthesis therefore builds each of those
separately and then a very wide multiplexer in front of every shared
register. The ten thousand multiplexer cells are that. The flip-flop
count, 1,630, is modest: the state itself is small.

## What comes next

Not a size pass on this core. Halving it would still not fit Lakritz
with the rest of the SoC. The way forward is a different design, in
which decoding is done once and kept in block RAM: [cpu_b.md](cpu_b.md).
