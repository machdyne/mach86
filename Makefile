# Mach86 -- top-level Makefile.
#
# `make help` lists the targets.

.PHONY: lakritz help check check-docs check-sim check-rtl check-b vectors \
        rtl-vectors vectors-b dos rtl-dos dos-b check-b-boot synth synth-b dhry dhry-b check-tb check-soc check-pm check-gfx check-gfx2 check-nobram check-spk check-opl check-mouse check-soc-train check-soc-main card check-card soc-dos check-gate gate-dos sergei_ml2 sdcard

help:
	@echo "Mach86 targets:"
	@echo "  make check        everything CI runs on each push"
	@echo "  make check-docs   verify links and anchors in *.md"
	@echo "  make check-sim    build the model and BIOS, run directed programs"
	@echo "  make check-rtl    boot the BIOS test on the RTL core, in lockstep"
	@echo "  make vectors      the model against the 386 instruction vectors"
	@echo "  make rtl-vectors  the RTL core against the same vectors"
	@echo "                    (fetch them first: tools/fetch_vectors.sh)"
	@echo "  make dos          boot DOS in the model and run a session"
	@echo "  make dos-b        boot DOS on CPU design B, in lockstep"
	@echo "  make rtl-dos      boot DOS on the RTL core, in lockstep"
	@echo "                    (fetch the DOS files first: tools/fetch_dos.sh)"
	@echo "  make check-b      run a test program on CPU design B, in simulation"
	@echo "  make vectors-b    design B against the vectors it has microcode for"
	@echo "  make synth        synthesise the first core for ECP5, report its size"
	@echo "  make dhry         Dhrystone on the model: instructions per run"
	@echo "  make dhry-b       Dhrystone on design B in RTL simulation: cycles, DMIPS/MHz"
	@echo "  make check-soc    the BIOS boot test on the simulated SoC"
	@echo "  make check-gfx    the graphics modes: the SoC's display against the model's pictures"
	@echo "  make check-gfx2   640 x 480 and 640 x 350, with video memory outside the SoC"
	@echo "  make check-pm     protected mode's first part: model, lockstep, SoC"
	@echo "  make check-nobram the SoC as Lakritz builds it: all video memory outside"
	@echo "  make check-spk    the PC speaker on the simulated SoC: tone, silence, the bell"
	@echo "  make check-opl    the AdLib's synthesiser: RTL against the reference model"
	@echo "  make check-mouse  the mouse port, on the model and the simulated SoC"
	@echo "  make check-tb     the cache, the DDR3 path and the DVI encoder alone"
	@echo "  make check-soc-train  the BIOS trains the memory, then the boot test"
	@echo "  make check-soc-main   boot test and DOS with the memory behind the cache"
	@echo "  make soc-dos      DOS on the simulated SoC"
	@echo "  make check-gate   the BIOS boot test on the SoC after synthesis"
	@echo "  make check-486    double shifts, bit instructions, 486 instructions (model, lockstep)"
	@echo "  make check-pg     paging: page faults, pages apart, accessed and dirty bits (model, lockstep, SoC)"
	@echo "  make check-pm3    protected mode: privilege levels, stack switches, call gates (model, lockstep, SoC)"
	@echo "  make check-pm2    protected mode: 32-bit segments, gates, faults (model, lockstep, SoC)"
	@echo "  make gate-dos     DOS on the SoC after synthesis (slow)"
	@echo "  make lakritz      a bitstream for Lakritz (not run on a board)"
	@echo "  make sergei_ml2   a bitstream for Sergei ML2 (docs/running.md)"
	@echo "  make lakritz      ... for Lakritz"
	@echo "  make konfekt, mozart_ml0, mozart_ml1, mozart_ml2   ... for those (never built: docs/boards.md)"
	@echo "  make sdcard       a DOS disk image to write to its microSD card"
	@echo "  make synth-b      synthesise, place and route CPU design B"
	@echo "                    for Lakritz's FPGA; report size and clock"

check: check-docs check-sim check-rtl check-b check-b-boot check-tb check-soc check-486 check-pm check-pm2 check-pm3 check-pg check-gfx check-gfx2 check-nobram check-spk check-opl check-mouse check-soc-train

check-docs:
	python3 tools/checkdocs.py

check-sim:
	$(MAKE) -C sim check

check-rtl:
	$(MAKE) -C sim rtl-check

vectors:
	$(MAKE) -C sim vectors

rtl-vectors:
	$(MAKE) -C sim rtl-vectors

dos:
	$(MAKE) -C sim dos

rtl-dos:
	$(MAKE) -C sim rtl-dos

# Design B: the BIOS boot test, and DOS, in lockstep with the model.
# LOCKSTEP_MEM=1 in the environment also compares memory at every step.
check-b-boot:
	$(MAKE) -C sim check-b-boot

dos-b:
	$(MAKE) -C sim dos-b

# Size of the CPU core, before place and route. Takes a few minutes.
synth:
	@mkdir -p output/syn
	yosys -q -l output/syn/core.log -p "read_verilog rtl/cpu/m86_alu.v \
	  rtl/cpu/m86_core.v; synth_ecp5 -top m86_core -json output/syn/core.json; stat"
	@grep -E "LUT4|TRELLIS_FF|PFUMX|L6MUX21|CCU2C|MULT18X18D|DP16KD" output/syn/core.log | tail -n 7

# Design B (docs/cpu_b.md): a test program from reset, in simulation.
check-b:
	@mkdir -p output/b
	python3 sw/ucode/m86b_ucode.py output/b
	nasm -f bin -o output/b/bloop.bin tests/prog/bloop.asm
	od -An -v -tx1 -w1 output/b/bloop.bin > output/b/bloop.hex
	cd output/b && iverilog -g2005 -o m86b_tb ../../sim/m86b_tb.v \
	  ../../rtl/cpu/m86b_core.v ../../rtl/cpu/m86_alu.v && vvp -n m86b_tb | tail -n 4

# Design B against the instruction vectors, for the opcodes it has
# microcode for.
vectors-b:
	$(MAKE) -C sim vectors-b

# Dhrystone 2.1 on the reference model: instructions per run, from the
# difference between a 10-run and a 110-run build. Fetches the source.
dhry:
	tools/dhry.sh 10 110 > /dev/null
	$(MAKE) -C sim all > /dev/null
	@a=`output/sim/m86run -p output/dhry/dhry10.rom 2>&1 | awk '$$1 == "instructions" {print $$2}'`; \
	 b=`output/sim/m86run -p output/dhry/dhry110.rom 2>&1 | awk '$$1 == "instructions" {print $$2}'`; \
	 echo "instructions per Dhrystone: $$(( (b - a) / 100 ))"; \
	 echo "DMIPS/MHz = 1000000 / (1757 * that * cycles per instruction)"

# Dhrystone 2.1 on design B, in RTL simulation: cycles per run, from the
# same two builds. The instruction counts must equal the model's.
dhry-b: check-b
	tools/dhry.sh 10 110 > /dev/null
	@for r in 10 110; do \
	  od -An -v -tx1 -w1 output/dhry/dhry$$r.rom > output/b/dhry$$r.hex; \
	  (cd output/b && vvp -n m86b_tb +rom=dhry$$r.hex +max=4000000 | head -n 1 > dhry$$r.txt); \
	  cat output/b/dhry$$r.txt; \
	done
	@awk 'FNR == 1 { gsub(",", ""); i[NR] = $$2; c[NR] = $$4 } \
	  END { n = (i[2] - i[1]) / 100; k = (c[2] - c[1]) / 100; \
	    printf "instructions per Dhrystone: %d\ncycles per Dhrystone: %d\n", n, k; \
	    printf "cycles per instruction: %.2f\nDMIPS/MHz: %.3f\n", k / n, 1000000 / (1757 * k) }' \
	  output/b/dhry10.txt output/b/dhry110.txt

# The SoC in simulation: the BIOS boot test, and DOS, through its serial
# console and SD card pins.
check-soc:
	$(MAKE) -C sim check-soc

# The test benches of the parts (cache, DDR3 path, DVI), and the BIOS
# training the memory on the simulated SoC.
check-tb:
	$(MAKE) -C sim check-tb

check-gfx:
	$(MAKE) -C sim check-gfx

check-gfx2:
	$(MAKE) -C sim check-gfx2

check-nobram:
	$(MAKE) -C sim check-nobram

check-pm:
	$(MAKE) -C sim check-pm

check-486:
	$(MAKE) -C sim check-486

check-pm2:
	$(MAKE) -C sim check-pm2

check-pm3:
	$(MAKE) -C sim check-pm3

check-pg:
	$(MAKE) -C sim check-pg

check-spk:
	$(MAKE) -C sim check-spk

check-opl:
	$(MAKE) -C sim check-opl

check-mouse:
	$(MAKE) -C sim check-mouse

check-soc-train:
	$(MAKE) -C sim check-soc-train

# The SoC with its memory outside, behind the cache: boot test and DOS.
check-soc-main:
	$(MAKE) -C sim check-soc-main

# The card with a FAT32 partition and a CD image (docs/card.md):
# output/card/mach86-boot.img and a 64 MB test card; and the test.
card:
	$(MAKE) -C sim card

check-card:
	$(MAKE) -C sim check-card

soc-dos:
	$(MAKE) -C sim soc-dos

# The SoC after synthesis, in simulation (sim/Makefile says how).
check-gate:
	$(MAKE) -C sim check-gate

gate-dos:
	$(MAKE) -C sim gate-dos

# The DOS disk image for a board's SD card: output/sdcard/mach86-dos.img.
sdcard:
	$(MAKE) -C sim all sdcard

# A bitstream for Sergei with the Sechzig ML2 module (docs/running.md):
# output/sergei_ml2/mach86.bit. Needs Yosys, nextpnr-ecp5 and ecppack.
# The design is elaborated, written out and read back before synthesis:
# newer Yosys (0.69) otherwise elaborates the top again when it meets
# the DDR3 PHY's parameterised I/O cells late in synth_ecp5, after the
# other modules are gone, and fails (Zeitlos's Makefile has the story).
BOARD_OUT = output/sergei_ml2
RTL_BOARD = rtl/cpu/m86_alu.v rtl/cpu/m86b_core.v $(wildcard rtl/soc/*.v) \
            $(addprefix rtl/ext/zeitlos/,pll2.v ddr3.v ddr3_ctrl.v \
              ddr3_phy_ecp5.v ddr3_rdasm.v ddr3_clk.v ddr3_phy_init.v audio_spdif.v audio_out.v \
              ddmi_island.v tmds_encoder.v) \
            rtl/ext/usb_hid_host/usb_hid_host.v rtl/ext/usb_hid_host/usb_hid_host_rom.v
# Synthesis of the board design. Yosys 0.69 has crashed in this now and
# then (a segmentation fault, not the same place twice, gone on the next
# run), so the rule below tries twice.
# The placement seed: of four tried in round 19 (31.2 to 32.9 MHz for
# 31.5; one fails) this was the best.
BOARD_SEED ?= 1
# The placer is told to weigh timing three times as heavily as it does by
# itself: on the Sergei that is worth about 1 MHz of the CPU clock.
PNR_OPT ?= --placer-heap-timingweight 30

# The USB host's little ROM (third-party, not edited) is kept out of
# block RAM, which Lakritz has none to spare of: about 330 LUTs a port.
USB_ROM_IN_LOGIC = setattr -set rom_style \"logic\" usb_hid_host_rom/m:mem;

define SYNTH_BOARD
yosys -q -l syn.log -p "read_verilog -DOSC48 \
  $(addprefix ../../,$(RTL_BOARD)) ../../rtl/boards/sergei_ml2.v; \
  $(USB_ROM_IN_LOGIC) \
  hierarchy -top sergei_ml2; write_rtlil elab.il; design -reset; \
  read_rtlil elab.il; \
  synth_ecp5 -top sergei_ml2 -abc9 -nowidelut -json mach86.json; stat"
endef

# A bitstream for Lakritz (LFE5U-25F, SDRAM): output/lakritz/mach86.bit.
# Not run on a board (docs/boards.md).
LAK_OUT = output/lakritz
RTL_LAK = rtl/cpu/m86_alu.v rtl/cpu/m86b_core.v $(wildcard rtl/soc/*.v) \
          $(addprefix rtl/ext/zeitlos/,sdram_kianv.v audio_out.v ddmi_island.v tmds_encoder.v) \
          rtl/ext/usb_hid_host/usb_hid_host.v rtl/ext/usb_hid_host/usb_hid_host_rom.v
LAK_SEED ?= 3
define SYNTH_LAK
yosys -q -l syn.log -p "read_verilog \
  $(addprefix ../../,$(RTL_LAK)) ../../rtl/boards/lakritz.v; \
  $(USB_ROM_IN_LOGIC) \
  synth_ecp5 -top lakritz -abc9 -nowidelut -json mach86.json; stat"
endef

lakritz:
	@mkdir -p $(LAK_OUT)
	$(MAKE) -C sim ../output/bios/bios.bin
	python3 sw/ucode/m86b_ucode.py $(LAK_OUT) > /dev/null
	python3 tools/lanes.py output/bios/bios.bin $(LAK_OUT)/rom 0x4000 16
	python3 tools/mkfont.py sw/font/font16.mem $(LAK_OUT)/font.hex
	python3 tools/mkopl.py $(LAK_OUT)/opl_rom.hex
	cp rtl/ext/usb_hid_host/usb_hid_host_rom.hex $(LAK_OUT)/
	cd $(LAK_OUT) && { $(SYNTH_LAK) || { echo "yosys failed: once more"; $(SYNTH_LAK); }; }
	@grep -E "LUT4|TRELLIS_FF|DP16KD|MULT18X18D|TRELLIS_DPR16X4" $(LAK_OUT)/syn.log | tail -n 5
	cd $(LAK_OUT) && nextpnr-ecp5 --25k --package CABGA256 --speed 6 $(PNR_OPT) \
	  --lpf ../../boards/lakritz.lpf --json mach86.json \
	  --textcfg mach86.config --seed $(LAK_SEED) > pnr.log 2>&1
	@grep -E "TRELLIS_COMB|DP16KD:" $(LAK_OUT)/pnr.log | tail -n 2
	@grep -E "Max frequency" $(LAK_OUT)/pnr.log | tail -n 2
	cd $(LAK_OUT) && ecppack --compress --freq 2.4 mach86.config --bit mach86.bit
	@ls -l $(LAK_OUT)/mach86.bit

sergei_ml2:
	@mkdir -p $(BOARD_OUT)
	$(MAKE) -C sim ../output/bios/bios.bin
	python3 sw/ucode/m86b_ucode.py $(BOARD_OUT) > /dev/null
	python3 tools/lanes.py output/bios/bios.bin $(BOARD_OUT)/rom 0x4000 16
	python3 tools/mkfont.py sw/font/font16.mem $(BOARD_OUT)/font.hex
	python3 tools/mkopl.py $(BOARD_OUT)/opl_rom.hex
	cp rtl/ext/usb_hid_host/usb_hid_host_rom.hex $(BOARD_OUT)/
	cd $(BOARD_OUT) && { $(SYNTH_BOARD) || { echo "yosys failed: once more"; $(SYNTH_BOARD); }; }
	@grep -E "LUT4|TRELLIS_FF|DP16KD|MULT18X18D|TRELLIS_DPR16X4" $(BOARD_OUT)/syn.log | tail -n 5
	cd $(BOARD_OUT) && nextpnr-ecp5 --45k --package CABGA256 --speed 6 $(PNR_OPT) \
	  --lpf ../../boards/sergei_ml2.lpf --json mach86.json \
	  --textcfg mach86.config --seed $(BOARD_SEED) > pnr.log 2>&1
	@grep -E "TRELLIS_COMB|DP16KD:" $(BOARD_OUT)/pnr.log | tail -n 2
	@grep -E "Max frequency" $(BOARD_OUT)/pnr.log | tail -n 2
	cd $(BOARD_OUT) && ecppack --compress --freq 2.4 mach86.config --bit mach86.bit
	@ls -l $(BOARD_OUT)/mach86.bit

# The other boards. Each is one of the two builds above with another
# constraint file and a few defines (rtl/boards/lakritz.v and
# sergei_ml2.v say which). NONE OF THESE HAS BEEN BUILT OR RUN
# (docs/boards.md): the rules are here so that they can be.
#
#   $(call OTHER_BOARD,name,sdram|ddr3,nextpnr device,constraints,defines)
define OTHER_BOARD
.PHONY: $(1)
$(1):
	@mkdir -p output/$(1)
	$$(MAKE) -C sim ../output/bios/bios.bin
	python3 sw/ucode/m86b_ucode.py output/$(1) > /dev/null
	python3 tools/lanes.py output/bios/bios.bin output/$(1)/rom 0x4000 16
	python3 tools/mkfont.py sw/font/font16.mem output/$(1)/font.hex
	python3 tools/mkopl.py output/$(1)/opl_rom.hex
	cp rtl/ext/usb_hid_host/usb_hid_host_rom.hex output/$(1)/
	cd output/$(1) && yosys -q -l syn.log -p "read_verilog -DM86_TOP=$(1) $(5) \
	  $(if $(filter ddr3,$(2)),-DOSC48 $$(addprefix ../../,$$(RTL_BOARD)) ../../rtl/boards/sergei_ml2.v; \
	    $$(USB_ROM_IN_LOGIC) hierarchy -top $(1); write_rtlil elab.il; design -reset; read_rtlil elab.il,\
	    $$(addprefix ../../,$$(RTL_LAK)) ../../rtl/boards/lakritz.v; $$(USB_ROM_IN_LOGIC)); \
	  synth_ecp5 -top $(1) -abc9 -nowidelut -json mach86.json; stat"
	@grep -E "LUT4|TRELLIS_FF|DP16KD|MULT18X18D|TRELLIS_DPR16X4" output/$(1)/syn.log | tail -n 5
	cd output/$(1) && nextpnr-ecp5 $(3) --package CABGA256 --speed 6 $(PNR_OPT) \
	  --lpf ../../boards/$(4) --json mach86.json \
	  --textcfg mach86.config --seed $$(SEED) > pnr.log 2>&1
	@grep -E "TRELLIS_COMB|DP16KD:" output/$(1)/pnr.log | tail -n 2
	@grep -E "Max frequency" output/$(1)/pnr.log | tail -n 2
	cd output/$(1) && ecppack --compress --freq 2.4 mach86.config --bit mach86.bit
	@ls -l output/$(1)/mach86.bit
endef
$(eval $(call OTHER_BOARD,konfekt,sdram,--12k,konfekt.lpf,-DM86_NO_SDDAT))
$(eval $(call OTHER_BOARD,mozart_ml0,sdram,--25k,mozart_ml1.lpf,-DM86_NO_SDDAT -DM86_UART -DM86_PT8211))
$(eval $(call OTHER_BOARD,mozart_ml1,sdram,--45k,mozart_ml1.lpf,-DM86_NO_SDDAT -DM86_UART -DM86_PT8211))
$(eval $(call OTHER_BOARD,mozart_ml2,ddr3,--45k,mozart_ml2.lpf,-DM86_NO_SDDAT -DM86_PT8211))

# Design B: size, and routed clock on an LFE5U-25F. nextpnr exits with
# an error when the clock target is missed; the figures are printed
# either way.
SEED ?= 1
FREQ ?= 40
synth-b:
	@mkdir -p output/bsyn
	python3 sw/ucode/m86b_ucode.py output/bsyn
	cd output/bsyn && yosys -q -l syn.log -p "read_verilog -DOSC48 \
	  ../../rtl/cpu/m86_alu.v ../../rtl/cpu/m86b_core.v; \
	  synth_ecp5 -top m86b_core -abc9 -nowidelut -json m86b.json; stat"
	@grep -E "LUT4|TRELLIS_FF|DP16KD|MULT18X18D|TRELLIS_DPR16X4" output/bsyn/syn.log | tail -n 5
	-cd output/bsyn && nextpnr-ecp5 --25k --package CABGA256 --speed 6 \
	  --json m86b.json --out-of-context --freq $(FREQ) --seed $(SEED) > pnr.log 2>&1
	@grep -E "TRELLIS_COMB" output/bsyn/pnr.log | tail -n 1
	@grep -E "Max frequency" output/bsyn/pnr.log | tail -n 1
