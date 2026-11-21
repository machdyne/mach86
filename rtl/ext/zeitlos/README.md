# Files from Zeitlos

Copied from Zeitlos (https://github.com/machdyne/zeitlos) at commit
`ede46a8`, **unchanged but for one addition** to `ddr3_ctrl.v` and
`ddr3.v` that is meant to go back to Zeitlos (below). Same licence as this repository; each file
carries its own header. Zeitlos is the one exception to Mach86's
clean-room rule ([docs/cleanroom.md](../../../docs/cleanroom.md),
[docs/reuse.md](../../../docs/reuse.md)).

| File here | In Zeitlos | What it is |
|---|---|---|
| `ddr3.v` | `rtl/mem/ddr3.v` | The DDR3 memory: controller, PHY and the three registers the trainer uses |
| `ddr3_ctrl.v` | `rtl/mem/ddr3_ctrl.v` | The controller: initialisation, refresh, block reads and writes |
| `ddr3_phy_ecp5.v` | `rtl/mem/ddr3_phy_ecp5.v` | The ECP5 I/O |
| `ddr3_rdasm.v` | `rtl/mem/ddr3_rdasm.v` | Putting a read burst together from what the pins captured |
| `ddr3_clk.v` | `rtl/mem/ddr3_clk.v` | The memory's clocks: 96 MHz, and 48 MHz for the controller |
| `ddr3_phy_init.v` | `rtl/mem/ddr3_phy_init.v` | Bringing the PHY's delay hardware up |
| `pll2.v` | `rtl/clk/pll2.v` | The PLL for those clocks. Needs `OSC48` defined |
| `sdram_kianv.v` | `rtl/mem/sdram_kianv.v` | The SDRAM controller (Hirosh Dabui's, Apache 2.0, as Zeitlos has it), for Lakritz (round 23) |
| `sdram_model.v` | `rtl/tb/sdram_model.v` | Zeitlos's model of the SDRAM part, for `sim/m86_lakritz_tb.v` |
| `audio_out.v` | `rtl/audio_out.v` | For its sigma-delta modulator, `audio_sd` (round 21); the rest of the file is not used |
| `audio_spdif.v` | `rtl/audio_spdif.v` | The S/PDIF transmitter (round 20: the PC speaker's way out on Sergei) |
| `ddmi_island.v` | `rtl/gpu/ddmi_island.v` | The HDMI data islands: sound, clock regeneration, InfoFrames (round 25) |
| `tmds_encoder.v` | `rtl/gpu/tmds_encoder.v` | The TMDS encoder that goes with it (Hirosh Dabui's, ISC-style licence, with Zeitlos's island characters) |
| `ddr3_model.v` | `rtl/tb/ddr3_model.v` | Simulation: a DRAM that checks the protocol and timing |
| `ddr3_phy_sim.v` | `rtl/tb/ddr3_phy_sim.v` | Simulation: a PHY without the FPGA's cells |

## The one change: the block register shown (round 40)

`zeitlos-ddr3-block-register.patch` in this directory is the whole
of it, as a patch against Zeitlos's `rtl/mem/`: two outputs,
`blk_dat_o` and `blk_ok_o`, that show the controller's sixteen-byte
block register and whether it holds a whole block. Nothing else in
the controller changes, and a master that ignores the two outputs
sees the bus it saw before.

What it is for: a line fill is four word reads, of which the last
three are answered from the block register, each still a bus cycle
of its own. A master that can take a line at once reads the first
word and, with `blk_ok_o` high in the cycle of its acknowledge,
takes all sixteen bytes and asks for nothing more. Here
(`rtl/soc/m86_xline.v`, where each word had also to cross between
two clocks) a line read went from 41 to 47 of the machine's cycles
to 22 ([docs/soc.md](../../../docs/soc.md#the-main-memory)). In Zeitlos
itself, on one clock, the gain would be the three bus cycles.

It has run in simulation only (`sim/m86_ddr3_tb.v`, against
Zeitlos's DRAM model): **not on hardware.** `-DM86_XLINE=0` builds
the Sergei as before, without using it.

What it does not do is write a block: a changed line still goes
back as four word stores, each a DRAM write of the whole block.
`WCOMBINE = 1` makes them one, and is not used here because its
logic misses the controller's clock on some placements of this
build. A block write port would be the companion to this patch.

Do not edit these otherwise. A fix belongs in Zeitlos first and is copied
again; that keeps "tested on Zeitlos's hardware" true of what is
here. Zeitlos's own account of the design is its `docs/ddr3.md`.

The trainer, `sw/train/ddr3_train.c`, is Zeitlos's too, adapted: its
header says how.
