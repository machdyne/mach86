# Mach86 documentation

| Document | What it answers |
|---|---|
| [running.md](running.md) | How to build it, put it on a board, and what should happen |
| [boards.md](boards.md) | Lakritz and Sergei ML2: what they have and what Mach86 uses |
| [cpu_b.md](cpu_b.md) | The CPU: decode once into block RAM, execute from there. Design, measurements |
| [cpu_c.md](cpu_c.md) | Design C, a second core for the 45F boards: the plan, what the model's count says, the RTL, and where it stands (boots DOS in simulation of the SoC; slower than design B so far) |
| [fpu.md](fpu.md) | The floating-point unit: the model, checked against a real x87; the RTL, checked against the model; and why no board has it yet |
| [pmode.md](pmode.md) | Protected mode: what is there, what is not |
| [soc.md](soc.md) | The machine around the CPU, and how it is tested down to the synthesised netlist |
| [hwmap.md](hwmap.md) | Memory map, I/O ports, interrupt lines |
| [bios.md](bios.md) | The BIOS: what it provides and what it does not |
| [video.md](video.md) | The VGA: modes, memory, what is tested |
| [sound.md](sound.md) | PC speaker, AdLib, and the three ways out |
| [mouse.md](mouse.md) | The USB mouse and its DOS driver |
| [card.md](card.md) | The SD card: partitions, CD images |
| [speed.md](speed.md) | The speed control |
| [model.md](model.md) | The C reference model: what it covers, how it is tested |
| [verification.md](verification.md) | How the CPU and the machine are tested |
| [cpu.md](cpu.md) | The first CPU core: correct, verified, far too big. Kept as a reference |
| [cleanroom.md](cleanroom.md) | Which sources may be read, which may not |
| [software.md](software.md) | Licence policy, the DOS we boot, the test software |
| [reuse.md](reuse.md) | What is copied from Zeitlos |

These pages were written as the work went, a round at a time, and
say so ("round 17", "round 26"): a round is one step of development,
in order. Where a page describes a plan and not what exists, it says
that too. A "phase" is a stage of the original plan: 1 the
reference model, 2 the CPU, 3 the machine around it.
