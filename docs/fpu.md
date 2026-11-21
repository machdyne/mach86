# The floating-point unit

A 486DX has an x87 floating-point unit on the chip. Mach86's 45F boards
are to have one with design C ([cpu_c.md](cpu_c.md)); Lakritz stays a
486SX on design B. This document says what exists, how it was checked,
and what the hardware is.

**State (round 37): the FPU exists in the reference model, in the
BIOS, and in RTL, where it is complete and agrees with the model bit
for bit in simulation. It is in no bitstream: as written it is too
large for the 45F next to the rest of the machine (see "Size").**

## What is in the model

| Part | File | What it is |
|---|---|---|
| Arithmetic | `sim/m86fpu.c`, `m86fpu.h` | 80-bit add, subtract, multiply, divide, square root, round to integer, remainder (both kinds), scale, extract, compare; conversions to and from 32- and 64-bit reals, 16-, 32- and 64-bit integers and packed decimal; the constants; the transcendental functions |
| Instructions | `sim/m86x87.h` | every x87 instruction of a 486: the register stack and tags, control and status words, stack faults, the instruction and operand pointers, FLDENV/FNSTENV/FNSAVE/FRSTOR in all four layouts, exceptions |
| Constants | `sim/m86fconst.h`, made by `tools/mkfpuconst.py` | pi, the logarithms and the series' coefficients, worked out with integers to 300 bits |
| Test of the arithmetic | `sim/fputest.c` | against the x87 of the machine it runs on |
| Test of the instructions | `tests/prog/fputest.asm` | a boot image |

`m86pc -fpu` runs the PC with it (and reports a 486DX in EDX at
reset, 0430h, with CR0's ET bit set); without the option the model is the
486SX it was. `make check-fpu` runs both tests and is part of
`make check`.

The code is the project's own. Nothing was taken from another
emulator or a floating-point library.

## How it was checked

The arithmetic has one right answer, and a machine that knows it is at
hand: any x86. `fputest` does every operation twice, once with the
processor's own x87 instruction and once with the model's code, on
the same operands, for all four roundings and three precisions, and
compares the result and the status word bit for bit. The operands are
chosen to find corners: zeros, infinities, both kinds of NaN,
denormals, pseudo-denormals and the unsupported formats, exponents
near every limit of the three formats, significands with few bits or
nearly all, and pairs one bit apart. A quarter of the runs have some
exceptions unmasked.

90 million operations, 3 million of each kind, agree with no
difference. That covers add, subtract, multiply, divide, square root,
FRNDINT, FCOM, FUCOM, FIST to three sizes, FILD, FST and FLD of both
real sizes, FPREM, FPREM1, FSCALE, FXTRACT, FBSTP, FBLD and the seven
constants.

The comparison settled a number of things that manuals leave open or
that differ between generations of the chip. The model does what the
test machine (a current x86-64) does:

- Of two NaNs the quiet one is the result; of two of a kind, the one
  with the larger significand; of two equal, the positive one. (A 387
  goes by significand alone. The difference shows only when a
  signalling and a quiet NaN meet.)
- Underflow is judged after rounding: a result that rounds up to the
  smallest normal number has not underflowed.
- Not masked, overflow and underflow give the result with its exponent
  moved by 24576; underflow is then flagged whether or not the result
  is exact. A store to memory is not made at all.
- Not masked, an invalid operation, a denormal operand or a division
  by zero stop the instruction before it changes anything. The one
  exception is a load of a denormal number, which is made and flagged.
- Division by zero does not also flag a denormal dividend. FIST and
  FST do not flag a denormal operand.
- FSCALE rounds to 64 bits whatever the precision control says.
- FPREM returns a pseudo-denormal as the normal number it stands for.
- C1 is set when the result was rounded up, and read before the
  instruction that pops (which clears it).

## The transcendental functions

FSIN, FCOS, FSINCOS, FPTAN, FPATAN, F2XM1, FYL2X and FYL2XP1 have no
one right answer: every generation of the chip gives slightly
different last bits. So these are the project's own, with one rule:
**each is a fixed sequence of the arithmetic operations above** (to
nearest, 64 bits) **with fixed constants.** Hardware that runs the same
sequence through its own adder, multiplier and divider gets the same
bits as the model, and the lockstep comparison stays exact.

| Function | How |
|---|---|
| sin, cos | take the nearest multiple of pi/2 off (pi/2 in three parts of 32, 32 and 64 bits, so the first two products are exact); then the series to x^21 and x^22 |
| tan | sin / cos |
| atan | the smaller over the larger; atan(k/16) from a table of 17 and a series to u^15 for what is left; pi/2 and pi (each in two parts) for the other octants |
| 2^x - 1 | e^(x ln 2) - 1 by its series, 22 terms |
| y log2 x | x as m 2^e with m between root one-half and root two; ln m = 2 atanh((m-1)/(m+1)), 14 terms |
| y log2(1+x) | the same series with x/(2+x) |

Against the C library's long-double functions (sin, cos, tan) and the
test machine's own instructions (the rest), 3 million operands each,
the largest difference found is 2.9 units in the last place and the
usual one is under 1. A 387 promises about the same.

Two things are deliberately unlike a real chip. The real FSIN takes
multiples of a 66-bit pi off, and is far out near multiples of pi for
arguments of any size; this one uses 128 bits and is not. And an
operand of 2^63 or more sets C2 and is left alone, as on the real one.

## In the PC

A 486's FPU reports an exception that is not masked in one of two
ways, chosen by CR0's NE bit.

- **NE clear, as DOS has it.** The FERR line goes to the second
  interrupt controller's input 5: interrupt 13, vector 75h. The BIOS's
  handler writes port F0h (which lets the unit go on: IGNNE), ends the
  interrupt and executes INT 02h, where programs written for an 8087
  look. The model has the line, the port and the latch (`sim/pc.c`);
  the BIOS has the handler.
- **NE set.** The next FPU instruction or WAIT that looks is
  interrupted by exception 16. (Vector 16 is also INT 10h. A system
  that sets NE has its own table.)

With CR0's EM or TS set every FPU instruction is exception 7, as
before. WAIT follows MP and TS.

At start the BIOS executes FNINIT and FNSTSW. If a status word of zero
comes back there is an FPU: bit 1 of the equipment word (INT 11h) is
set, interrupt 13 is unmasked and vector 75h is given its handler.
Without an FPU the two instructions do nothing, as on a 486SX, and
nothing changes. The same BIOS serves both.

## The hardware

| Part | File | What it is |
|---|---|---|
| Arithmetic | `rtl/cpu/m86_fparith.v` | One operation at a time on 80-bit numbers: the 22 operations of the model's kernel that have one right answer. A state machine over one data path: a 67-bit register (significand, guard, round, sticky), a right shifter that keeps what falls off, a left shifter with a leading-zero count, an adder, a 32 by 32 multiplier used four times, and loops of a bit a cycle for division, square root, remainder and decimal |
| Registers and instructions | `rtl/cpu/m86_fpu.v` | The stack, tags, control and status words, pointers; every instruction's rules (stack faults, masked and unmasked exceptions, what is popped and pushed); the saved state in its four layouts; the transcendental functions as the model's sequences of steps on the arithmetic, with the model's constants (`tools/mkfpuconst_v.py` writes them into the file) |
| In the processor | `rtl/cpu/m86c_core.v`, parameter `FPU` | Design C's microcode does an instruction's memory accesses, with the segment and paging checks every access has, and tells the unit what to do: START, PUT a part of the operand, RUN, GET a part of the result, COMMIT. Nothing of the unit's state changes before COMMIT, so a page fault in the middle leaves it as it was. Exceptions 7 (CR0's EM, TS) and 16 (NE) are raised by the microcode on the unit's say |
| Microcode | `sw/ucode/m86b_ucode.py OUT fpu` | The escapes D8 to DF and WAIT, 37 words. Without `fpu` the microcode is what it was |
| In the machine | `rtl/soc/m86_soc.v`, parameter `CPU_FPU` | The unit's error line is interrupt 13, once each time it rises; port F0h says it has been seen |

### How it was checked

- **The arithmetic alone** against the model's, the same operands to
  both (`sim/fparith_tb.cpp`): 22 operations, all roundings and
  precisions, masked and not; 16 million operations before the last
  six were added and 2.2 million of all 22 since, no difference.
- **In design C, in lockstep with the model.** After every instruction
  the bench compares, besides the processor's registers, the unit's
  eight registers, control and status words, tags and pointers.
  - The FPU's test program, all of it but the interrupt 13 step
    (`tests/prog/fpu1test.asm`, made from `fputest.asm`).
  - Instructions at random (`tests/prog/fpurand.asm`): a control word,
    two operands and one of 34 instruction sequences at random, the
    results stored in every format. 6,000 rounds in the regression;
    60,000 once, with memory answering late, stores made to wait and
    the pipeline made to give instructions up. No difference.
- **On the SoC** (`soc_tb_cf`): the whole test program, with the
  exception that reaches its handler through interrupt 13, the BIOS's
  handler and port F0h.

`make check-fpu-rtl` runs these; it is part of `make check`.

### Size

Synthesised for the ECP5, the unit is 15,900 LUT4, 3,800 flip-flops and
4 multipliers: 6,900 LUT4 for the arithmetic and 9,000 for the rest.
Sergei ML2 with design C is 23,000 LUT4 without it; with the unit's
first form (18,650 LUT4) it came to 41,600, which does not fit a 45F,
and 2,750 less does not change that. **So there is no bitstream with
the FPU.**

The first reduction (round 37) put the transcendental functions'
working registers into LUT RAM with two read ports and made each step
name its operands instead of multiplexing their values. What is left
to do: the eight registers of the stack are flip-flops with three
readers and three writers; the constants are two tables of logic and
belong in one block RAM; the arithmetic has a 134-bit shifter where 67
bits and a sticky bit do, and separate subtractors for division,
square root and remainder. The aim is 6,000 LUT4 for all of it.

### Speed

Not measured on a board. In simulation, in clocks: add 9, multiply 13,
divide 67, square root 38 for the arithmetic alone; an instruction
with a memory operand adds the microcode's accesses, about a dozen
clocks a part. Division and the square root are a bit a clock. A
486DX's divide is about 70 clocks, so this is the same class.

### What is not as the model

- **Waiting for the interrupt.** With CR0's NE clear and an exception
  pending that is not masked, a 486 holds the next FPU instruction
  until an interrupt comes. The RTL goes on. With interrupts enabled
  the difference cannot be seen, because interrupt 13 arrives first;
  with them disabled the real machine would stop, and this one does
  not.
- A page fault in the middle of FRSTOR leaves the registers already
  read in place (they are read again when the instruction is
  restarted).

## Not there

- An FPU on a board: see "Size".
- Design B and Lakritz: a 486SX, and stay so.
- The exact last bits of any real chip's transcendental functions.
