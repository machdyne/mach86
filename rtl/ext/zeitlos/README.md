# Files from Zeitlos

Copied **unchanged** from Zeitlos (https://github.com/machdyne/zeitlos)
at commit `ede46a8`. Same licence as this repository; each file
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

Do not edit these. A fix belongs in Zeitlos first and is copied
again; that keeps "tested on Zeitlos's hardware" true of what is
here. Zeitlos's own account of the design is its `docs/ddr3.md`.

The trainer, `sw/train/ddr3_train.c`, is Zeitlos's too, adapted: its
header says how.
