# Reuse from Zeitlos

Zeitlos is the sister project and the one exception to the clean-room
rule ([cleanroom.md](cleanroom.md)). This is the list of what Mach86
has taken from it, at Zeitlos commit `ede46a8` unless a file says otherwise.

A file is copied when it is first needed, into
`rtl/ext/zeitlos/` (or the matching software directory), with the
Zeitlos commit recorded beside it. Copies are kept unmodified where
possible, so that fixes can move in both directions.

**Copied so far:** the DDR3 memory — controller, ECP5 PHY, clocks,
and the DRAM model and behavioural PHY for simulation — unchanged, in
`rtl/ext/zeitlos/` (the README there lists the files); the DDR3
training algorithm, adapted from RISC-V to real-mode x86, in
`sw/train/`; the DDR3 pins in `boards/sergei_ml2.lpf`; the font
(`sw/font/`); the USB HID host (third-party) in
`rtl/ext/usb_hid_host/`; the SDRAM controller and its model
(`sdram_kianv.v`, Apache 2.0, and `sdram_model.v`, for Lakritz); the 8 x 8 font; the S/PDIF transmitter
(`audio_spdif.v`, unchanged) and the optical output's pin; the HDMI
data islands with their encoder (`ddmi_island.v`, `tmds_encoder.v`,
unchanged) and the receiver model that checks them
(`tools/ddmi.py`, from `tools/ddmi/ddmi.py`).

## What is copied

`rtl/ext/zeitlos/README.md` lists every gateware file taken, where it
comes from in Zeitlos and what it is for. In software, the DDR3
training (`sw/train/ddr3_train.c`) is Zeitlos's algorithm compiled
for the 386 in real mode and run by our BIOS, and the two fonts in
`sw/font/` are Zeitlos's.

## Board files

`boards/sergei_ml2.lpf` is in: Zeitlos's ball assignments for the
clock, LED, UART, SD card, DDMI and PROGRAMN, trimmed to what is
used, and its DDR3 section whole and unchanged; `boards/lakritz.lpf` likewise for Lakritz. The
first SoC's UART and SPI port are new and small, not Zeitlos's
`uart.v` and `spim.v`: they sit on PC I/O ports, not on a Wishbone
bus. The PLL settings are from `ecppll`.

## Method

Not code, but taken from Zeitlos all the same:

- A from-scratch C model beside the RTL, and lockstep testbenches.
- Board features as defines, with a measured size and timing table
  per board.
- One document per subsystem, updated with the change.

## What is not reused

- The Zeitlos GPU, window system and operating system. A PC's video
  and software model are different things.
- The MTU and MPU. The 386 has its own memory management.
