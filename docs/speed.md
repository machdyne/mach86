# The speed control

Some DOS programs fail on a machine that is too fast for them: they
time a loop against the clock to find out how fast the machine is,
and the answer does not fit where they put it. The usual signs are
"divide error", "Runtime error 200", Microsoft C's "R6003 integer
divide by 0", or a game that runs absurdly fast. PCs had a turbo
button for this. Mach86 has `SLOW`.

| | |
|---|---|
| `SLOW n` | The CPU waits *n* clock cycles (0 to 255) after every instruction |
| `SLOW 0`, `SLOW OFF` | Full speed |
| `SLOW` | Says what is set |

It stays set until changed or the machine is reset. Start with
`SLOW 3` and go up until the program works.

What *n* is like, roughly. An instruction takes about 2.5 cycles at
full speed, so it takes about 2.5 + *n* with the control on; the PC
names are for orientation only, since PCs differed among themselves
and this machine's instructions do not cost what theirs did:

| *n* | Instructions a second, millions | Something like |
|---:|---:|---|
| 0 | 12 to 21 | a 486 at 33 to 66 MHz |
| 3 | 6 | a fast 386 |
| 8 | 3 | a 386SX, a fast 286 |
| 30 | 1 | an 8 MHz AT |
| 100 | 0.3 | a 4.77 MHz PC |

A `REP` string instruction is one instruction however long it runs,
so block copies and fills stay fast; that is as well, since programs
do not time those.

**How.** Port 1E0h holds *n* (ours, not a PC's). The core counts
*n* cycles before it starts the next instruction
(`rtl/cpu/m86b_core.v`, `slow`). Nothing else changes: the timer,
the display and sound run at their own rates.

**Test.** The BIOS boot test, DOS and the protected-mode test run in
lockstep with the model with the control at 3 and at 7
(`M86B_SLOW=7 make -C sim dos-b`): 40 million instructions, the same
results, 9.5 cycles an instruction where there were 2.6.
`make check-card` sets and clears it under DOS on the simulated SoC.
