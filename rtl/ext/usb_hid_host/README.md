# usb_hid_host

A USB HID host in gateware, by nand2mario (based on work by hi631):
https://github.com/nand2mario/usb_hid_host. **Apache License 2.0**
(`LICENSE` here) — third-party, not under this repository's licence.
`README-upstream.txt` is its own README (its links point into the upstream repository).

This copy is the one Zeitlos carries (`rtl/ext/usb_hid_host/src/` at
Zeitlos commit `ede46a8`, which asks the device for the boot protocol
where upstream does not), with one change of ours: two array
declarations, `regs [7]` and `dat[8]`, written as `[0:6]` and `[0:7]`
so that the file is plain Verilog like the rest of the repository.

| File | |
|---|---|
| `usb_hid_host.v` | The host: a small microcoded engine that enumerates one low-speed device and polls it |
| `usb_hid_host_rom.v`, `usb_hid_host_rom.hex` | Its program. The `.hex` is read from the directory the tool runs in: the build copies it there |

What it does and does not do, as it matters to Mach86:

- One device per port, **low speed only** (1.5 Mbit/s). Most plain
  keyboards are; many gaming and some newer keyboards are full speed
  and will not be seen. No hubs.
- Keyboards in boot protocol: the modifier byte and the first four
  keys held. Mice and gamepads are decoded too; Mach86 does not use
  them yet.
- It needs a 12 MHz clock and 15 kΩ pull-downs on D+ and D−.
- It cannot send anything to the keyboard, so the lock lights stay
  dark.

It is not simulated here beyond being compiled: there is no USB
device model in the repository. What turns its reports into PC
scancodes, `rtl/soc/m86_usbkbd.v`, is ours and is tested.
