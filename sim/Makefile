# Mach86 reference model. See docs/model.md.
CC      ?= cc
CFLAGS  ?= -O2 -g -std=gnu11 -Wall -Wextra
NASM    ?= nasm

OUT     = ../output/sim
VECTORS ?= ../output/vectors/80386
KNOWN   = ../tests/vectors/known_deviations.txt
KNOWN_B = ../tests/vectors/known_deviations_b.txt

BIOS    = ../output/bios/bios.bin
RTL     = ../rtl/cpu/m86_core.v ../rtl/cpu/m86_alu.v
RTLOUT  = ../output/rtl

all: $(OUT)/vectest $(OUT)/m86run $(OUT)/m86pc $(BIOS)

$(OUT)/vectest: vectest.c vectest_model.c vectest.h m86cpu.c m86.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ vectest.c vectest_model.c m86cpu.c

$(OUT)/m86run: m86run.c m86cpu.c m86.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ m86run.c m86cpu.c

$(OUT)/m86pc: m86pc.c pc.c vga.c sdcard.c m86cpu.c pc.h vga.h m86.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ m86pc.c pc.c vga.c sdcard.c m86cpu.c

# The DDR3 trainer: C for the 386 in real mode, a flat binary that the
# BIOS carries and runs from the text screen's memory.
TRAIN   = ../output/bios/train.bin
TRAINCC = gcc -m16 -march=i386 -Os -ffreestanding -fno-pic -fno-builtin \
          -fno-stack-protector -fno-asynchronous-unwind-tables \
          -mno-80387 -msoft-float -Wall
$(TRAIN): ../sw/train/ddr3_train.c ../sw/train/start.S ../sw/train/link.ld
	@mkdir -p $(dir $@)
	$(TRAINCC) -c ../sw/train/ddr3_train.c -o $(dir $@)ddr3_train.o
	gcc -m16 -c ../sw/train/start.S -o $(dir $@)train_start.o
	ld -m elf_i386 -T ../sw/train/link.ld -o $@ \
	    $(dir $@)train_start.o $(dir $@)ddr3_train.o
	@test `wc -c < $@` -le 3328 || (echo "train.bin: too big for the screen memory"; exit 1)

$(BIOS): ../sw/bios/bios.asm ../sw/bios/video.inc $(TRAIN) ../tools/mkvideo.py \
         ../sw/font/font8x8.mem
	@mkdir -p $(dir $@)
	python3 ../tools/mkvideo.py ../sw/font/font8x8.mem $(dir $@)
	$(NASM) -f bin -I $(dir $@) -I ../sw/bios/ -o $@ $<

$(OUT)/%.bin: ../tests/prog/%.asm
	@mkdir -p $(OUT)
	$(NASM) -f bin -o $@ $<

# Directed programs: run each and compare its output.
check: all $(OUT)/sieve.bin $(OUT)/boottest.bin
	$(OUT)/m86run $(OUT)/sieve.bin | diff - ../tests/prog/sieve.expect
	cp $(OUT)/boottest.bin $(OUT)/boottest.img
	$(OUT)/m86pc -bios $(BIOS) -disk $(OUT)/boottest.img -max 200000000 \
	  -expect "type something" -type "hello\r" -expect "boot test passed"
	@echo "sim: directed programs pass"

# The RTL core as the CPU of the machine, in lockstep with the model.
rtl-check: all $(RTLOUT)/rtlpc $(OUT)/boottest.bin
	cp $(OUT)/boottest.bin $(OUT)/boottest.img
	$(RTLOUT)/rtlpc -bios $(BIOS) -disk $(OUT)/boottest.img -max 200000000 \
	  -expect "type something" -type "hello\r" -expect "boot test passed"
	@echo "rtl: BIOS boot test passes in lockstep with the model"

# Print the instruction-class profile of a directed program.
profile: all $(OUT)/sieve.bin
	$(OUT)/m86run -p $(OUT)/sieve.bin

# The hardware-captured vectors. Fetch them first:
#   tools/fetch_vectors.sh
vectors: $(OUT)/vectest
	@test -d $(VECTORS)/v1_ex_real_mode || \
	  { echo "no vectors in $(VECTORS): run tools/fetch_vectors.sh"; exit 1; }
	$(OUT)/vectest -n 5 -r $(VECTORS)/revocation_list.txt \
	  -c $(VECTORS)/80386.csv -k $(KNOWN) \
	  $(VECTORS)/v1_ex_real_mode/*.MOO.gz | tail -n 1

# The RTL core against the same vectors, under Verilator.

$(RTLOUT)/rtlvec: $(RTL) vectest.c vectest_rtl.cpp vectest.h
	@mkdir -p $(RTLOUT)
	$(CC) $(CFLAGS) -c -o $(RTLOUT)/vectest.o vectest.c
	@rm -f $(RTLOUT)/obj/../rtlvec		# so that it is always linked afresh
	verilator --language 1364-2005 --cc --exe --build -j 2 -O3 --top-module m86_core \
	  -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-BLKSEQ -Wno-UNUSED \
	  -Wno-CASEOVERLAP -Wno-UNOPTFLAT \
	  -CFLAGS "-O2 -I$(CURDIR)" --Mdir $(RTLOUT)/obj -o ../rtlvec \
	  $(RTL) $(CURDIR)/$(RTLOUT)/vectest.o $(CURDIR)/vectest_rtl.cpp

# The whole machine with the RTL core, in lockstep with the model.
$(RTLOUT)/rtlpc: $(RTL) m86pc.c pc.c vga.c sdcard.c m86cpu.c lockstep.cpp pc.h vga.h m86.h
	@mkdir -p $(RTLOUT)
	$(CC) $(CFLAGS) -DLOCKSTEP -c -o $(RTLOUT)/m86pc.o m86pc.c
	$(CC) $(CFLAGS) -c -o $(RTLOUT)/pc.o pc.c
	$(CC) $(CFLAGS) -c -o $(RTLOUT)/vga.o vga.c
	$(CC) $(CFLAGS) -c -o $(RTLOUT)/sdcard.o sdcard.c
	$(CC) $(CFLAGS) -c -o $(RTLOUT)/m86cpu.o m86cpu.c
	@rm -f $(RTLOUT)/obj_pc/../rtlpc		# so that it is always linked afresh
	verilator --language 1364-2005 --cc --exe --build -j 2 -O3 --top-module m86_core \
	  -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-BLKSEQ -Wno-UNUSED \
	  -Wno-CASEOVERLAP -Wno-UNOPTFLAT \
	  -CFLAGS "-O2 -I$(CURDIR)" --Mdir $(RTLOUT)/obj_pc -o ../rtlpc \
	  $(RTL) $(CURDIR)/$(RTLOUT)/m86pc.o $(CURDIR)/$(RTLOUT)/pc.o $(CURDIR)/$(RTLOUT)/vga.o \
	  $(CURDIR)/$(RTLOUT)/sdcard.o $(CURDIR)/$(RTLOUT)/m86cpu.o \
	  $(CURDIR)/lockstep.cpp

# Design B against the vectors. Only the opcodes that have microcode
# can pass; BFILES names the vector files to run.
BOUT    = ../output/b
RTLB    = ../rtl/cpu/m86b_core.v ../rtl/cpu/m86_alu.v
UCODE   = ../sw/ucode/m86b_ucode.py

$(BOUT)/ucode.hex: $(UCODE)
	@mkdir -p $(BOUT)
	python3 $(UCODE) $(BOUT)

$(BOUT)/rtlvecb: $(RTLB) $(BOUT)/ucode.hex vectest.c vectest_rtlb.cpp vectest.h
	$(CC) $(CFLAGS) -c -o $(BOUT)/vectest.o vectest.c
	@rm -f $(BOUT)/obj/../rtlvecb		# so that it is always linked afresh
	verilator --language 1364-2005 --cc --exe --build -j 2 -O3 --top-module m86b_core \
	  -GUCODE='"$(CURDIR)/$(BOUT)/ucode.hex"' -GATTR='"$(CURDIR)/$(BOUT)/attr.hex"' \
	  -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-BLKSEQ -Wno-UNUSED \
	  -Wno-CASEOVERLAP -Wno-UNOPTFLAT -Wno-LATCH -Wno-MULTIDRIVEN \
	  -CFLAGS "-O2 -I$(CURDIR)" --Mdir $(BOUT)/obj -o ../rtlvecb \
	  $(RTLB) $(CURDIR)/$(BOUT)/vectest.o $(CURDIR)/vectest_rtlb.cpp

# The whole machine with design B, in lockstep with the model.
# BPARAM: parameters of the core to try, as -GDC_AW=11.
BPARAM ?=
$(BOUT)/rtlpcb: $(RTLB) $(BOUT)/ucode.hex m86pc.c pc.c vga.c sdcard.c m86cpu.c lockstep.cpp pc.h vga.h m86.h
	$(CC) $(CFLAGS) -DLOCKSTEP -c -o $(BOUT)/m86pc.o m86pc.c
	$(CC) $(CFLAGS) -c -o $(BOUT)/pc.o pc.c
	$(CC) $(CFLAGS) -c -o $(BOUT)/vga.o vga.c
	$(CC) $(CFLAGS) -c -o $(BOUT)/sdcard.o sdcard.c
	$(CC) $(CFLAGS) -c -o $(BOUT)/m86cpu.o m86cpu.c
	@rm -f $(BOUT)/obj_pc/../rtlpcb		# so that it is always linked afresh
	verilator --language 1364-2005 --cc --exe --build -j 2 -O3 --top-module m86b_core $(VDEF) $(BPARAM) \
	  -GUCODE='"$(CURDIR)/$(BOUT)/ucode.hex"' -GATTR='"$(CURDIR)/$(BOUT)/attr.hex"' \
	  -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-BLKSEQ -Wno-UNUSED \
	  -Wno-CASEOVERLAP -Wno-UNOPTFLAT -Wno-LATCH -Wno-MULTIDRIVEN \
	  -CFLAGS "-O2 -DCORE_B -I$(CURDIR)" --Mdir $(BOUT)/obj_pc -o ../rtlpcb \
	  $(RTLB) $(CURDIR)/$(BOUT)/m86pc.o $(CURDIR)/$(BOUT)/pc.o $(CURDIR)/$(BOUT)/vga.o \
	  $(CURDIR)/$(BOUT)/sdcard.o $(CURDIR)/$(BOUT)/m86cpu.o \
	  $(CURDIR)/lockstep.cpp

# Design B boots the BIOS test in lockstep with the model.
check-b-boot: all $(BOUT)/rtlpcb $(OUT)/boottest.bin
	cp $(OUT)/boottest.bin $(OUT)/boottest.img
	$(BOUT)/rtlpcb -bios $(BIOS) -disk $(OUT)/boottest.img -max 200000000 \
	  -expect "type something" -type "hello\r" -expect "boot test passed"
	@echo "design B: BIOS boot test passes in lockstep with the model"

# Design B boots DOS in lockstep with the model.
dos-b: all $(BOUT)/rtlpcb $(OUT)/dostest.com
	@test -f $(DOS)/KERNEL.SYS || \
	  { echo "no DOS files in $(DOS): run tools/fetch_dos.sh"; exit 1; }
	cp $(DOS)/boot-svardos.img $(OUT)/dostest.img
	$(FATIMG) $(OUT)/dostest.img $(DOS)/KERNEL.SYS \
	  ../tests/dos/dostest.cfg=CONFIG.SYS $(OUT)/dostest.com=DOSTEST.COM
	$(BOUT)/rtlpcb -bios $(BIOS) -disk $(OUT)/dostest.img -max 900000000 \
	  -expect "type something" -type "hello\r" -expect "dos test passed"
	@echo "design B: DOS boots and runs in lockstep with the model"

# A session at the DOS prompt, typed on the serial console. Each
# command waits for the prompt before it: typing is not held back while
# the machine is busy, and the BIOS keeps only fifteen keys.
SESSION = -expect "new date" -type "\r" -expect "new time" -type "\r" \
	  -expect "C>" -type "ver\r" -expect "Version" \
	  -expect "C>" -type "dir c*.*\r" -expect "File(s)" \
	  -expect "C>" -type "chkdsk\r" -expect "total memory" \
	  -expect "C>" -type "echo hello >t.txt\r" \
	  -expect "C>" -type "type t.txt\r" -expect "hello" \
	  -expect "C>" -type "dostest\r" -expect "type something" -type "abc\r" \
	  -expect "dos test passed" -expect "C>"

# The SoC as it goes on a board, seen through its serial console and
# SD card pins (soc_tb.cpp).
SOCOUT = ../output/soc
RTLSOC = $(wildcard ../rtl/soc/*.v) $(RTLB)
$(SOCOUT)/soc_tb: $(RTLSOC) $(BIOS) soc_tb.cpp sdcard.c pc.h ../sw/ucode/m86b_ucode.py ../tools/lanes.py ../tools/mkfont.py
	@mkdir -p $(SOCOUT)
	python3 ../sw/ucode/m86b_ucode.py $(SOCOUT) > /dev/null
	python3 ../tools/lanes.py $(BIOS) $(SOCOUT)/rom 0x4000 16
	python3 ../tools/mkfont.py ../sw/font/font16.mem $(SOCOUT)/font.hex
	$(CC) $(CFLAGS) -c -o $(SOCOUT)/sdcard.o sdcard.c
	@rm -f $(SOCOUT)/soc_tb
	verilator --language 1364-2005 --cc --exe --build -j 2 -O3 --top-module m86_soc $(VDEF) \
	  -GUCODE='"$(CURDIR)/$(SOCOUT)/ucode.hex"' -GATTR='"$(CURDIR)/$(SOCOUT)/attr.hex"' \
	  -GROM0='"$(CURDIR)/$(SOCOUT)/rom0.hex"' -GROM1='"$(CURDIR)/$(SOCOUT)/rom1.hex"' \
	  -GROM2='"$(CURDIR)/$(SOCOUT)/rom2.hex"' -GROM3='"$(CURDIR)/$(SOCOUT)/rom3.hex"' \
	  -GFONT='"$(CURDIR)/$(SOCOUT)/font.hex"' \
	  -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-BLKSEQ -Wno-UNUSED \
	  -Wno-CASEOVERLAP -Wno-UNOPTFLAT -Wno-LATCH -Wno-MULTIDRIVEN -Wno-PINMISSING \
	  -CFLAGS "-O2 -DSOC_RTL -I$(CURDIR)" --Mdir $(SOCOUT)/obj -o ../soc_tb \
	  $(RTLSOC) $(CURDIR)/$(SOCOUT)/sdcard.o $(CURDIR)/soc_tb.cpp

# Graphics: the test program draws in each mode and waits; the model's
# picture and the one off the SoC's display pins must be the same,
# pixel for pixel (tests/prog/gfxtest.asm, docs/video.md).
GFXOUT = ../output/gfx
GFXMODES = m13 m0d m04 m06 m03
check-gfx: all $(SOCOUT)/soc_tb $(OUT)/gfxtest.bin
	@mkdir -p $(GFXOUT)
	cp $(OUT)/gfxtest.bin $(GFXOUT)/gfxtest.img
	$(OUT)/m86pc -bios $(BIOS) -disk $(GFXOUT)/gfxtest.img -max 400000000 \
	  -font $(SOCOUT)/font.hex \
	  -dexpect "mode 13h 02 ready" -snap $(GFXOUT)/m13.model.ppm -type " " \
	  -dexpect "mode 0Dh F0F00F0FF009 ready" -snap $(GFXOUT)/m0d.model.ppm -type " " \
	  -dexpect "mode 04h ready" -snap $(GFXOUT)/m04.model.ppm -type " " \
	  -dexpect "mode 06h ready" -snap $(GFXOUT)/m06.model.ppm -type " " \
	  -dexpect "graphics test done" -snap $(GFXOUT)/m03.model.ppm > /dev/null
	$(SOCOUT)/soc_tb -quiet -disk $(GFXOUT)/gfxtest.img -max 2000000000 \
	  -expect "mode 13h 02 ready" -snap $(GFXOUT)/m13.soc.ppm -type " " \
	  -expect "mode 0Dh F0F00F0FF009 ready" -snap $(GFXOUT)/m0d.soc.ppm -type " " \
	  -expect "mode 04h ready" -snap $(GFXOUT)/m04.soc.ppm -type " " \
	  -expect "mode 06h ready" -snap $(GFXOUT)/m06.soc.ppm -type " " \
	  -expect "graphics test done" -snap $(GFXOUT)/m03.soc.ppm
	@for m in $(GFXMODES); do \
	  cmp $(GFXOUT)/$$m.model.ppm $(GFXOUT)/$$m.soc.ppm || exit 1; done
	@echo "gfx: the SoC's display shows the model's pictures in five modes"

# The modes with more than 200 lines (640 x 480, 640 x 350), whose
# video memory goes past the SoC's own 64 KB: on the SoC built with
# its memory outside, where the bench stands in for the board's video
# memory and line buffer. Pictures compared with the model's.
check-gfx2: all $(SOCOUT)/soc_tb_main $(OUT)/gfxtest2.bin
	@mkdir -p $(GFXOUT)
	cp $(OUT)/gfxtest2.bin $(GFXOUT)/gfxtest2.img
	$(OUT)/m86pc -bios $(BIOS) -disk $(GFXOUT)/gfxtest2.img -max 900000000 \
	  -font $(SOCOUT)/font.hex \
	  -dexpect "mode 12h FFFFFFFF 0F0F01 ready" -snap $(GFXOUT)/m12.model.ppm -type " " \
	  -dexpect "mode 10h FFFFFFFF 0F0F01 ready" -snap $(GFXOUT)/m10.model.ppm -type " " \
	  -dexpect "graphics test 2 done" > /dev/null
	$(SOCOUT)/soc_tb_main -quiet -disk $(GFXOUT)/gfxtest2.img -max 2000000000 \
	  -expect "mode 12h FFFFFFFF 0F0F01 ready" -snap $(GFXOUT)/m12.soc.ppm -type " " \
	  -expect "mode 10h FFFFFFFF 0F0F01 ready" -snap $(GFXOUT)/m10.soc.ppm -type " " \
	  -expect "graphics test 2 done"
	cmp $(GFXOUT)/m12.model.ppm $(GFXOUT)/m12.soc.ppm
	cmp $(GFXOUT)/m10.model.ppm $(GFXOUT)/m10.soc.ppm
	@echo "gfx2: 640 x 480 and 640 x 350 on the SoC are the model's pictures"

# The SoC as Lakritz builds it, with all video memory outside: the
# text screen read back from the display's pins, and every picture of
# check-gfx and check-gfx2 again.
check-nobram: check-gfx check-gfx2 $(SOCOUT)/soc_tb_nobram $(OUT)/boottest.bin
	cp $(OUT)/boottest.bin $(SOCOUT)/boottest_nb.img
	$(SOCOUT)/soc_tb_nobram -quiet -disk $(SOCOUT)/boottest_nb.img -max 400000000 \
	  -frame $(SOCOUT)/boottest_nb.ppm \
	  -expect "type something" -type "hello\r" -expect "boot test passed"
	python3 ../tools/readscreen.py $(SOCOUT)/boottest_nb.ppm $(SOCOUT)/font.hex \
	  > $(SOCOUT)/boottest_nb.txt
	grep -q "boot test passed" $(SOCOUT)/boottest_nb.txt
	$(SOCOUT)/soc_tb_nobram -quiet -disk $(GFXOUT)/gfxtest.img -max 2000000000 \
	  -expect "mode 13h 02 ready" -snap $(GFXOUT)/m13.nb.ppm -type " " \
	  -expect "mode 0Dh F0F00F0FF009 ready" -snap $(GFXOUT)/m0d.nb.ppm -type " " \
	  -expect "mode 04h ready" -snap $(GFXOUT)/m04.nb.ppm -type " " \
	  -expect "mode 06h ready" -snap $(GFXOUT)/m06.nb.ppm -type " " \
	  -expect "graphics test done" -snap $(GFXOUT)/m03.nb.ppm
	$(SOCOUT)/soc_tb_nobram -quiet -disk $(GFXOUT)/gfxtest2.img -max 2000000000 \
	  -expect "mode 12h FFFFFFFF 0F0F01 ready" -snap $(GFXOUT)/m12.nb.ppm -type " " \
	  -expect "mode 10h FFFFFFFF 0F0F01 ready" -snap $(GFXOUT)/m10.nb.ppm -type " " \
	  -expect "graphics test 2 done"
	@for m in $(GFXMODES) m12 m10; do \
	  cmp $(GFXOUT)/$$m.model.ppm $(GFXOUT)/$$m.nb.ppm || exit 1; done
	@echo "nobram: with all video memory outside, text and seven modes are the model's pictures"

# Protected mode, the first part (docs/pmode.md): the test program on
# the model, then in lockstep (the RTL core against the model at every
# instruction, segment bases and limits and the system registers
# compared too), then on the SoC with memory above 1 MB.
check-pm: all $(BOUT)/rtlpcb $(SOCOUT)/soc_tb_main $(OUT)/pmtest.bin
	cp $(OUT)/pmtest.bin $(SOCOUT)/pmtest.img
	$(OUT)/m86pc -bios $(BIOS) -disk $(SOCOUT)/pmtest.img -max 50000000 \
	  -dexpect "pm test passed" > /dev/null
	$(BOUT)/rtlpcb -bios $(BIOS) -disk $(SOCOUT)/pmtest.img -max 200000000 \
	  -expect "pm test passed"
	$(SOCOUT)/soc_tb_main -quiet -disk $(SOCOUT)/pmtest.img -max 400000000 \
	  -expect "pm test passed"
	@echo "pm: protected mode's first part passes on the model, in lockstep, and on the SoC"

# Protected mode's second part: 32-bit segments, interrupts and faults
# through gates, the local table. On the model, in lockstep, on the SoC.
check-pm2: all $(BOUT)/rtlpcb $(SOCOUT)/soc_tb_main $(OUT)/pm2test.bin
	cp $(OUT)/pm2test.bin $(SOCOUT)/pm2test.img
	$(OUT)/m86pc -bios $(BIOS) -disk $(SOCOUT)/pm2test.img -max 50000000 \
	  -dexpect "pm2 test passed" > /dev/null
	$(BOUT)/rtlpcb -bios $(BIOS) -disk $(SOCOUT)/pm2test.img -max 200000000 \
	  -expect "pm2 test passed"
	$(SOCOUT)/soc_tb_main -quiet -disk $(SOCOUT)/pm2test.img -max 400000000 \
	  -expect "pm2 test passed"
	@echo "pm2: protected mode's second part passes on the model, in lockstep, and on the SoC"

check-pm3: all $(BOUT)/rtlpcb $(SOCOUT)/soc_tb_main $(OUT)/pm3test.bin
	cp $(OUT)/pm3test.bin $(SOCOUT)/pm3test.img
	$(OUT)/m86pc -bios $(BIOS) -disk $(SOCOUT)/pm3test.img -max 50000000 \
	  -dexpect "pm3 test passed" > /dev/null
	$(BOUT)/rtlpcb -bios $(BIOS) -disk $(SOCOUT)/pm3test.img -max 200000000 \
	  -expect "pm3 test passed"
	$(SOCOUT)/soc_tb_main -quiet -disk $(SOCOUT)/pm3test.img -max 400000000 \
	  -expect "pm3 test passed"
	@echo "pm3: protected mode's third part (privilege levels) passes on the model, in lockstep, and on the SoC"

check-pg: all $(BOUT)/rtlpcb $(SOCOUT)/soc_tb_main $(OUT)/pgtest.bin
	cp $(OUT)/pgtest.bin $(SOCOUT)/pgtest.img
	$(OUT)/m86pc -bios $(BIOS) -disk $(SOCOUT)/pgtest.img -max 50000000 \
	  -dexpect "pg test passed" > /dev/null
	$(BOUT)/rtlpcb -bios $(BIOS) -disk $(SOCOUT)/pgtest.img -max 200000000 \
	  -expect "pg test passed"
	$(SOCOUT)/soc_tb_main -quiet -disk $(SOCOUT)/pgtest.img -max 400000000 \
	  -expect "pg test passed"
	@echo "pg: paging passes on the model, in lockstep, and on the SoC"

# The double shifts, the bit instructions and a 486's own, on the model
# and in lockstep.
check-486: all $(BOUT)/rtlpcb $(OUT)/i486test.bin
	cp $(OUT)/i486test.bin $(SOCOUT)/i486test.img
	$(OUT)/m86pc -bios $(BIOS) -disk $(SOCOUT)/i486test.img -max 50000000 \
	  -dexpect "486 test passed" > /dev/null
	$(BOUT)/rtlpcb -bios $(BIOS) -disk $(SOCOUT)/i486test.img -max 200000000 \
	  -expect "486 test passed"
	@echo "486: the double shifts, bit instructions and 486 instructions pass on the model and in lockstep"

# Sound: the PC speaker's bit on the SoC is the tone the program asked
# for, is silent when it should be, and the BIOS's bell rings and ends
# (also on the model, where only its ending can be seen).
check-spk: all $(SOCOUT)/soc_tb $(OUT)/spktest.bin
	cp $(OUT)/spktest.bin $(SOCOUT)/spktest.img
	$(OUT)/m86pc -bios $(BIOS) -disk $(SOCOUT)/spktest.img -max 400000000 \
	  -dexpect "tone on" -type " " -dexpect "tone off" -type " " \
	  -dexpect "gate only" -type " " -dexpect "speaker test done" > /dev/null
	$(SOCOUT)/soc_tb -quiet -disk $(SOCOUT)/spktest.img -max 400000000 \
	  -expect "tone on" -tone 1000 -type " " \
	  -expect "tone off" -tone 0 -type " " \
	  -expect "gate only" -tone 0 -type " " \
	  -expect "bell" -tone 896 -expect "speaker test done" -tone 0
	@echo "spk: the speaker sounds what the timer is set to, and the bell rings"

# The mouse port: reports become interrupt 12 and three bytes, on the
# model and on the SoC (where they arrive as the USB host gives them),
# more movement than one reading holds included.
check-mouse: all $(SOCOUT)/soc_tb $(OUT)/mousetest.bin
	cp $(OUT)/mousetest.bin $(SOCOUT)/mousetest.img
	$(OUT)/m86pc -bios $(BIOS) -disk $(SOCOUT)/mousetest.img -max 400000000 \
	  -dexpect "mouse ready" -mouse 5,-3,1 -dexpect "m 81 05 FD" \
	  -mouse -200,2,2 -dexpect "m C2 80 02" -dexpect "m 82 B8 00" > /dev/null
	$(SOCOUT)/soc_tb -quiet -disk $(SOCOUT)/mousetest.img -max 400000000 \
	  -expect "mouse ready" -mouse 5,-3,1 -expect "m 81 05 FD" \
	  -mouse -100,2,2 -expect "m 82 9C 02" -mouse 127,0,0 -expect "m 80 7F 00"
	@echo "mouse: reports reach the program, on the model and the SoC"

# The FM synthesiser: the RTL against the reference model, sample for
# sample, over a script of random instruments and notes on all nine
# voices; and the model plays a note whose pitch is checked (440 Hz).
OPLOUT = ../output/opl
check-opl:
	@mkdir -p $(OPLOUT)
	python3 ../tools/mkopl.py $(OPLOUT)/opl_rom.hex
	$(CC) -O2 -Wall -Wextra -o $(OPLOUT)/oplref oplref.c opl2.c
	$(OPLOUT)/oplref $(OPLOUT)/opl_rom.hex ../tests/opl/a440.txt -freq 2000 22000 \
	  -wav $(OPLOUT)/a440.wav | tee $(OPLOUT)/a440.log
	grep -Eq "^freq (439|440|441) " $(OPLOUT)/a440.log
	python3 oplscript.py $(OPLOUT)/script.txt
	$(OPLOUT)/oplref $(OPLOUT)/opl_rom.hex $(OPLOUT)/script.txt \
	  -hex $(OPLOUT)/expect.hex -wav $(OPLOUT)/script.wav
	iverilog -g2005 -o $(OPLOUT)/opl_tb m86_opl2_tb.v ../rtl/soc/m86_opl2.v
	vvp -n $(OPLOUT)/opl_tb +script=$(OPLOUT)/script.txt +expect=$(OPLOUT)/expect.hex \
	  | tee $(OPLOUT)/opl_tb.log | tail -n 2
	grep -q "opl: pass" $(OPLOUT)/opl_tb.log

# The same with the main memory outside, behind the cache (MAIN_MEM = 1);
# the test bench is the memory.
$(SOCOUT)/soc_tb_main: $(RTLSOC) $(BIOS) soc_tb.cpp sdcard.c pc.h ../sw/ucode/m86b_ucode.py ../tools/lanes.py ../tools/mkfont.py
	@mkdir -p $(SOCOUT)
	python3 ../sw/ucode/m86b_ucode.py $(SOCOUT) > /dev/null
	python3 ../tools/lanes.py $(BIOS) $(SOCOUT)/rom 0x4000 16
	python3 ../tools/mkfont.py ../sw/font/font16.mem $(SOCOUT)/font.hex
	$(CC) $(CFLAGS) -c -o $(SOCOUT)/sdcard.o sdcard.c
	@rm -f $(SOCOUT)/soc_tb_main
	verilator --language 1364-2005 --cc --exe --build -j 2 -O3 --top-module m86_soc $(VDEF) -GMAIN_MEM=1 -GEXT_KB=15360 -GVGA_EXT=1 \
	  -GUCODE='"$(CURDIR)/$(SOCOUT)/ucode.hex"' -GATTR='"$(CURDIR)/$(SOCOUT)/attr.hex"' \
	  -GROM0='"$(CURDIR)/$(SOCOUT)/rom0.hex"' -GROM1='"$(CURDIR)/$(SOCOUT)/rom1.hex"' \
	  -GROM2='"$(CURDIR)/$(SOCOUT)/rom2.hex"' -GROM3='"$(CURDIR)/$(SOCOUT)/rom3.hex"' \
	  -GFONT='"$(CURDIR)/$(SOCOUT)/font.hex"' \
	  -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-BLKSEQ -Wno-UNUSED \
	  -Wno-CASEOVERLAP -Wno-UNOPTFLAT -Wno-LATCH -Wno-MULTIDRIVEN -Wno-PINMISSING \
	  -CFLAGS "-O2 -DSOC_RTL -I$(CURDIR)" --Mdir $(SOCOUT)/obj_main -o ../soc_tb_main \
	  $(RTLSOC) $(CURDIR)/$(SOCOUT)/sdcard.o $(CURDIR)/soc_tb.cpp

# And with no video memory in block RAM at all (VGA_BRAM = 0), as a
# board without the blocks builds it: Lakritz.
$(SOCOUT)/soc_tb_nobram: $(RTLSOC) $(BIOS) soc_tb.cpp sdcard.c pc.h ../sw/ucode/m86b_ucode.py ../tools/lanes.py ../tools/mkfont.py
	@mkdir -p $(SOCOUT)
	python3 ../sw/ucode/m86b_ucode.py $(SOCOUT) > /dev/null
	python3 ../tools/lanes.py $(BIOS) $(SOCOUT)/rom 0x4000 16
	python3 ../tools/mkfont.py ../sw/font/font16.mem $(SOCOUT)/font.hex
	$(CC) $(CFLAGS) -c -o $(SOCOUT)/sdcard.o sdcard.c
	@rm -f $(SOCOUT)/soc_tb_nobram
	verilator --language 1364-2005 --cc --exe --build -j 2 -O3 --top-module m86_soc -GMAIN_MEM=1 -GEXT_KB=15360 -GVGA_EXT=1 -GVGA_BRAM=0 \
	  -GUCODE='"$(CURDIR)/$(SOCOUT)/ucode.hex"' -GATTR='"$(CURDIR)/$(SOCOUT)/attr.hex"' \
	  -GROM0='"$(CURDIR)/$(SOCOUT)/rom0.hex"' -GROM1='"$(CURDIR)/$(SOCOUT)/rom1.hex"' \
	  -GROM2='"$(CURDIR)/$(SOCOUT)/rom2.hex"' -GROM3='"$(CURDIR)/$(SOCOUT)/rom3.hex"' \
	  -GFONT='"$(CURDIR)/$(SOCOUT)/font.hex"' \
	  -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-BLKSEQ -Wno-UNUSED \
	  -Wno-CASEOVERLAP -Wno-UNOPTFLAT -Wno-LATCH -Wno-MULTIDRIVEN -Wno-PINMISSING \
	  -CFLAGS "-O2 -DSOC_RTL -I$(CURDIR)" --Mdir $(SOCOUT)/obj_nobram -o ../soc_tb_nobram \
	  $(RTLSOC) $(CURDIR)/$(SOCOUT)/sdcard.o $(CURDIR)/soc_tb.cpp

# And with a main memory that the BIOS has to train first (MEM_TRAIN = 1):
# the test bench stands in for the DDR3 controller's registers and for a
# read path that only works at the right settings.
$(SOCOUT)/soc_tb_train: $(RTLSOC) $(BIOS) soc_tb.cpp sdcard.c pc.h ../sw/ucode/m86b_ucode.py ../tools/lanes.py ../tools/mkfont.py
	@mkdir -p $(SOCOUT)
	python3 ../sw/ucode/m86b_ucode.py $(SOCOUT) > /dev/null
	python3 ../tools/lanes.py $(BIOS) $(SOCOUT)/rom 0x4000 16
	python3 ../tools/mkfont.py ../sw/font/font16.mem $(SOCOUT)/font.hex
	$(CC) $(CFLAGS) -c -o $(SOCOUT)/sdcard.o sdcard.c
	@rm -f $(SOCOUT)/soc_tb_train
	verilator --language 1364-2005 --cc --exe --build -j 2 -O3 --top-module m86_soc -GMAIN_MEM=1 -GMEM_TRAIN=1 -GEXT_KB=15360 \
	  -GUCODE='"$(CURDIR)/$(SOCOUT)/ucode.hex"' -GATTR='"$(CURDIR)/$(SOCOUT)/attr.hex"' \
	  -GROM0='"$(CURDIR)/$(SOCOUT)/rom0.hex"' -GROM1='"$(CURDIR)/$(SOCOUT)/rom1.hex"' \
	  -GROM2='"$(CURDIR)/$(SOCOUT)/rom2.hex"' -GROM3='"$(CURDIR)/$(SOCOUT)/rom3.hex"' \
	  -GFONT='"$(CURDIR)/$(SOCOUT)/font.hex"' \
	  -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-BLKSEQ -Wno-UNUSED \
	  -Wno-CASEOVERLAP -Wno-UNOPTFLAT -Wno-LATCH -Wno-MULTIDRIVEN -Wno-PINMISSING \
	  -CFLAGS "-O2 -DSOC_RTL -DSOC_TRAIN -I$(CURDIR)" --Mdir $(SOCOUT)/obj_train -o ../soc_tb_train \
	  $(RTLSOC) $(CURDIR)/$(SOCOUT)/sdcard.o $(CURDIR)/soc_tb.cpp

# The small test benches, under Icarus: the cache alone; the cache, the
# clock crossing and Zeitlos's DDR3 controller against its DRAM model;
# the DVI encoder.
ZL = ../rtl/ext/zeitlos
check-tb:
	@mkdir -p $(SOCOUT)
	iverilog -g2005 -o $(SOCOUT)/dcache_tb m86_dcache_tb.v ../rtl/soc/m86_dcache.v
	vvp -n $(SOCOUT)/dcache_tb | tee $(SOCOUT)/dcache_tb.log | tail -n 2
	grep -q "dcache: pass" $(SOCOUT)/dcache_tb.log
	iverilog -g2005 -o $(SOCOUT)/ddr3_tb m86_ddr3_tb.v ddr3_phy_ecp5_sim.v \
	  ../rtl/soc/m86_dcache.v ../rtl/soc/m86_xclk.v $(ZL)/ddr3.v \
	  $(ZL)/ddr3_ctrl.v $(ZL)/ddr3_phy_sim.v $(ZL)/ddr3_model.v
	vvp -n $(SOCOUT)/ddr3_tb | tee $(SOCOUT)/ddr3_tb.log | tail -n 2
	grep -q "ddr3: pass" $(SOCOUT)/ddr3_tb.log
	iverilog -g2005 -o $(SOCOUT)/usbkbd_tb m86_usbkbd_tb.v ../rtl/soc/m86_usbkbd.v
	vvp -n $(SOCOUT)/usbkbd_tb | tee $(SOCOUT)/usbkbd_tb.log | tail -n 2
	grep -q "usbkbd: pass" $(SOCOUT)/usbkbd_tb.log
	iverilog -g2005 -o $(SOCOUT)/spk_tb m86_spk_tb.v ../rtl/soc/m86_spk.v $(ZL)/audio_spdif.v
	vvp -n $(SOCOUT)/spk_tb | tee $(SOCOUT)/spk_tb.log | tail -n 1
	grep -q "spk: pass" $(SOCOUT)/spk_tb.log
	@mkdir -p $(OPLOUT)
	python3 ../tools/mkopl.py $(OPLOUT)/opl_rom.hex
	iverilog -g2005 -o $(SOCOUT)/audio_tb m86_audio_tb.v ../rtl/soc/m86_audio.v \
	  ../rtl/soc/m86_spk.v ../rtl/soc/m86_opl2.v $(ZL)/audio_out.v
	vvp -n $(SOCOUT)/audio_tb | tee $(SOCOUT)/audio_tb.log | tail -n 1
	grep -q "audio: pass" $(SOCOUT)/audio_tb.log
	iverilog -g2005 -o $(SOCOUT)/vfetch_tb m86_vfetch_tb.v ../rtl/soc/m86_vfetch.v
	vvp -n $(SOCOUT)/vfetch_tb | tee $(SOCOUT)/vfetch_tb.log | tail -n 1
	grep -q "vfetch: pass" $(SOCOUT)/vfetch_tb.log
	iverilog -g2005 -o $(SOCOUT)/lakritz_tb m86_lakritz_tb.v ../rtl/soc/m86_vfetch.v \
	  $(ZL)/sdram_kianv.v $(ZL)/sdram_model.v
	vvp -n $(SOCOUT)/lakritz_tb | tee $(SOCOUT)/lakritz_tb.log | tail -n 2 | head -n 1
	grep -q "lakritz: pass" $(SOCOUT)/lakritz_tb.log
	iverilog -g2005 -o $(SOCOUT)/dvi_tb m86_dvi_tb.v ../rtl/soc/m86_dvi.v
	vvp -n $(SOCOUT)/dvi_tb | tee $(SOCOUT)/dvi_tb.log | tail -n 1
	grep -q "dvi: pass" $(SOCOUT)/dvi_tb.log
	iverilog -g2005 -o $(SOCOUT)/pt8211_tb m86_pt8211_tb.v ../rtl/soc/m86_pt8211.v
	vvp -n $(SOCOUT)/pt8211_tb | tee $(SOCOUT)/pt8211_tb.log | tail -n 2 | head -n 1
	grep -q "pt8211: pass" $(SOCOUT)/pt8211_tb.log
	iverilog -g2005 -o $(SOCOUT)/hdmi_tb m86_hdmi_tb.v ../rtl/soc/m86_hdmi.v \
	  $(ZL)/ddmi_island.v $(ZL)/tmds_encoder.v
	vvp -n $(SOCOUT)/hdmi_tb +out=$(SOCOUT)/hdmi0.txt +hdmi=0 | tail -n 1
	python3 ../tools/ddmi.py $(SOCOUT)/hdmi0.txt --expect dvi | tail -n 1
	vvp -n $(SOCOUT)/hdmi_tb +out=$(SOCOUT)/hdmi1.txt +hdmi=1 | tail -n 1
	python3 ../tools/ddmi.py $(SOCOUT)/hdmi1.txt --expect hdmi --audio-seq --audio-hz 48000 | tail -n 1

# The SoC boots the BIOS test from its card, and takes typing.
check-soc: all $(SOCOUT)/soc_tb $(OUT)/boottest.bin
	cp $(OUT)/boottest.bin $(SOCOUT)/boottest.img
	$(SOCOUT)/soc_tb -quiet -disk $(SOCOUT)/boottest.img -max 400000000 \
	  -frame $(SOCOUT)/boottest.ppm \
	  -expect "type something" -type "hello\r" -expect "boot test passed"
	@# The same must be on the display: read the picture back as text.
	python3 ../tools/readscreen.py $(SOCOUT)/boottest.ppm $(SOCOUT)/font.hex \
	  > $(SOCOUT)/boottest.txt
	grep -q "boot test passed" $(SOCOUT)/boottest.txt
	@# The same typed on a USB keyboard: HID reports in, with Shift.
	$(SOCOUT)/soc_tb -quiet -disk $(SOCOUT)/boottest.img -max 400000000 \
	  -expect "type something" -usb "Hello, USB: 1+2=3?\r" \
	  -expect "Hello, USB: 1+2=3?" -expect "boot test passed"
	@echo "soc: BIOS boot test passes on the SoC"

# The SoC with its main memory outside: the BIOS boot test and DOS.
check-soc-main: all $(SOCOUT)/soc_tb_main $(OUT)/boottest.bin sdcard
	cp $(OUT)/boottest.bin $(SOCOUT)/boottest_main.img
	$(SOCOUT)/soc_tb_main -quiet -disk $(SOCOUT)/boottest_main.img -max 400000000 \
	  -expect "640 KB memory" \
	  -expect "type something" -type "hello\r" -expect "boot test passed"
	cp $(SDIMG) $(SOCOUT)/session_main.img
	$(SOCOUT)/soc_tb_main -quiet -disk $(SOCOUT)/session_main.img -max 6000000000 \
	  $(SESSION)
	@echo "soc: BIOS boot test and DOS pass with the main memory behind the cache"

# The BIOS trains the memory (against the test bench's stand-in), finds
# the one right setting, and then boots as usual.
check-soc-train: all $(SOCOUT)/soc_tb_train $(OUT)/boottest.bin
	cp $(OUT)/boottest.bin $(SOCOUT)/boottest_train.img
	$(SOCOUT)/soc_tb_train -quiet -disk $(SOCOUT)/boottest_train.img -max 2000000000 \
	  -expect "ddr3 tune 09573231 L0:C L1:C" -expect "ddr3 check a5c3a5c3 5a3c5a3c ok" \
	  -expect "640 KB memory" \
	  -expect "type something" -type "hello\r" -expect "boot test passed"
	@# And a memory that cannot be trained: the report, and a halt.
	TRAIN_WD=9 $(SOCOUT)/soc_tb_train -quiet -disk $(SOCOUT)/boottest_train.img \
	  -max 100000000 -expect "ddr3 training FAILED" \
	  -expect "Memory training failed. System halted."
	@echo "soc: the BIOS trains the memory and boots"

# The SoC boots DOS from its card.
soc-dos: all $(SOCOUT)/soc_tb $(OUT)/dostest.com
	@test -f $(DOS)/KERNEL.SYS || \
	  { echo "no DOS files in $(DOS): run tools/fetch_dos.sh"; exit 1; }
	cp $(DOS)/boot-svardos.img $(SOCOUT)/dostest.img
	$(FATIMG) $(SOCOUT)/dostest.img $(DOS)/KERNEL.SYS \
	  ../tests/dos/dostest.cfg=CONFIG.SYS $(OUT)/dostest.com=DOSTEST.COM
	$(SOCOUT)/soc_tb -quiet -disk $(SOCOUT)/dostest.img -max 3000000000 \
	  -expect "type something" -type "hello\r" -expect "dos test passed"
	@# A session at the prompt, on a copy of the image made for the card.
	$(MAKE) sdcard
	cp $(SDIMG) $(SOCOUT)/session.img
	$(SOCOUT)/soc_tb -quiet -disk $(SOCOUT)/session.img -max 6000000000 \
	  $(SESSION)
	@echo "soc: DOS boots and runs on the SoC"

# The SoC after synthesis: Yosys's netlist of ECP5 cells, simulated with
# models of the block RAM and multiplier (tools/ecp5_*_sim.py), on the
# same test bench. Finds what RTL simulation cannot: a register driven
# from two places, a memory that did not map as meant.
GATEOUT = ../output/gate
YOSYS_ECP5 = /usr/share/yosys/ecp5
$(GATEOUT)/soc_gate: $(RTLSOC) $(BIOS) soc_tb.cpp sdcard.c pc.h ../sw/ucode/m86b_ucode.py
	@mkdir -p $(GATEOUT)
	python3 ../sw/ucode/m86b_ucode.py $(GATEOUT) > /dev/null
	python3 ../tools/lanes.py $(BIOS) $(GATEOUT)/rom 0x4000 16
	python3 ../tools/mkfont.py ../sw/font/font16.mem $(GATEOUT)/font.hex
	python3 ../tools/mkopl.py $(GATEOUT)/opl_rom.hex
	cd $(GATEOUT) && yosys -q -l syn.log -p "read_verilog $(addprefix ../,$(RTLSOC)); \
	  synth_ecp5 -top m86_soc -abc9 -nowidelut; write_verilog -noattr soc_syn.v"
	@! grep -i "conflict" $(GATEOUT)/syn.log
	python3 ../tools/ecp5_bram_sim.py $(GATEOUT)/bram_sim.v
	python3 ../tools/ecp5_mult_sim.py $(YOSYS_ECP5)/cells_bb.v $(GATEOUT)/mult_sim.v
	awk '/^module DP16KD\(/{skip=1} skip&&/^endmodule/{skip=0; next} !skip' \
	  $(YOSYS_ECP5)/cells_sim.v | grep -v "^(\* blackbox \*)" > $(GATEOUT)/cells.v
	$(CC) $(CFLAGS) -c -o $(GATEOUT)/sdcard.o sdcard.c
	@rm -f $(GATEOUT)/soc_gate
	verilator --cc --exe --build -j 2 -O3 --top-module m86_soc \
	  -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-BLKSEQ -Wno-UNUSED \
	  -Wno-CASEOVERLAP -Wno-UNOPTFLAT -Wno-LATCH -Wno-MULTIDRIVEN -Wno-PINMISSING \
	  -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-INITIALDLY -Wno-COMBDLY -Wno-STMTDLY \
	  -Wno-MODDUP -Wno-DECLFILENAME -Wno-BLKANDNBLK -Wno-SELRANGE \
	  -I$(YOSYS_ECP5) -CFLAGS "-O1 -I$(CURDIR)" --Mdir $(GATEOUT)/obj -o ../soc_gate \
	  $(CURDIR)/$(GATEOUT)/soc_syn.v $(CURDIR)/$(GATEOUT)/cells.v \
	  $(CURDIR)/$(GATEOUT)/bram_sim.v $(CURDIR)/$(GATEOUT)/mult_sim.v \
	  $(CURDIR)/$(GATEOUT)/sdcard.o $(CURDIR)/soc_tb.cpp

# The synthesised SoC boots the BIOS test.
check-gate: all $(GATEOUT)/soc_gate $(OUT)/boottest.bin
	cp $(OUT)/boottest.bin $(GATEOUT)/boottest.img
	$(GATEOUT)/soc_gate -quiet -disk $(GATEOUT)/boottest.img -max 100000000 \
	  -expect "type something" -type "hello\r" -expect "boot test passed"
	@echo "gate: BIOS boot test passes on the synthesised SoC"

# The synthesised SoC boots DOS to a prompt and runs the DOS test.
# About a quarter of an hour.
gate-dos: all $(GATEOUT)/soc_gate sdcard
	cp $(SDIMG) $(GATEOUT)/session.img
	$(GATEOUT)/soc_gate -quiet -disk $(GATEOUT)/session.img -max 3000000000 \
	  $(SESSION)
	@echo "gate: DOS boots and runs on the synthesised SoC"

# The disk image for a board's SD card: DOS, a command prompt and the
# DOS test. Write it to the card as it is (docs/running.md). Built from
# fetched files (tools/fetch_dos.sh); see docs/software.md for what
# they are and their licences.
SDIMG = ../output/sdcard/mach86-dos.img
sdcard: $(OUT)/dostest.com $(OUT)/speed.com $(OUT)/gfx.com $(OUT)/tune.com $(OUT)/adlib.com $(OUT)/mouse.com $(OUT)/mouset.com $(OUT)/gfx2.com
	@test -f $(DOS)/KERNEL.SYS || \
	  { echo "no DOS files in $(DOS): run tools/fetch_dos.sh"; exit 1; }
	@mkdir -p ../output/sdcard
	cp $(DOS)/boot-svardos.img $(SDIMG)
	$(FATIMG) $(SDIMG) $(DOS)/KERNEL.SYS \
	  ../tests/dos/command.cfg=CONFIG.SYS $(DOS)/COMMAND.COM $(DOS)/CHKDSK.COM \
	  $(OUT)/dostest.com=DOSTEST.COM $(OUT)/speed.com=SPEED.COM \
	  $(OUT)/gfx.com=GFX.COM $(OUT)/tune.com=TUNE.COM $(OUT)/adlib.com=ADLIB.COM \
	  $(OUT)/mouse.com=MOUSE.COM $(OUT)/mouset.com=MOUSET.COM $(OUT)/gfx2.com=GFX2.COM
	@ls -l $(SDIMG)

# A card as docs/card.md describes it, for the tests and to try: the
# boot disk with the FAT32 kernel, FreeCOM and the CD tools as partition
# 1, and 60 MB of FAT32 with a small CD image on it as partition 2.
DOS    ?= ../output/dos
CARDOUT = ../output/card
CARDIMG = $(CARDOUT)/mach86-card.img
BOOTIMG = $(CARDOUT)/mach86-boot.img
SHSU    = $(DOS)/shsucd
NASMOLD = $(NASM) -w-all -O9 -Di8086 -I$(SHSU)/

# The CD redirector, and the driver that makes a CD of an image file,
# from their source. The driver's makefile links it with ALINK; here it
# is assembled flat and given a header (tools/mkexe.py).
$(CARDOUT)/shsucdx.com: $(SHSU)/shsucdx.nsm
	@mkdir -p $(CARDOUT)
	$(NASMOLD) -f bin -o $@ $<
$(CARDOUT)/shsucdhd.exe: $(SHSU)/shsucdhd.nsm ../tools/mkexe.py
	@mkdir -p $(CARDOUT)
	sed -e 's/^\.\.start/mz_start:/' -e '/^group dgroup text bss/,$$d' $< \
	  > $(CARDOUT)/shsucdhd_flat.nsm
	printf 'section .bss\nmz_bss_end:\nsection .text\n\tdw mz_bss_end, mz_start\n' \
	  >> $(CARDOUT)/shsucdhd_flat.nsm
	$(NASMOLD) -f bin -o $(CARDOUT)/shsucdhd.bin $(CARDOUT)/shsucdhd_flat.nsm
	python3 ../tools/mkexe.py $(CARDOUT)/shsucdhd.bin $@

$(BOOTIMG): $(OUT)/dostest.com $(OUT)/speed.com $(OUT)/gfx.com $(OUT)/tune.com $(OUT)/adlib.com $(OUT)/mouse.com $(OUT)/mouset.com $(OUT)/gfx2.com $(OUT)/xmstest.com $(OUT)/slow.com $(OUT)/hdmi.com $(OUT)/sbtest.com $(CARDOUT)/shsucdx.com \
            $(CARDOUT)/shsucdhd.exe ../tests/dos/card.cfg \
            ../tests/dos/autoexec.bat ../tests/dos/mount.bat
	@test -f $(DOS)/KERNEL32.SYS -a -f $(DOS)/HIMEMX.EXE || \
	  { echo "no DOS files in $(DOS): run tools/fetch_dos.sh"; exit 1; }
	cp $(DOS)/boot-svardos.img $@
	$(FATIMG) $@ $(DOS)/KERNEL32.SYS=KERNEL.SYS \
	  ../tests/dos/card.cfg=CONFIG.SYS ../tests/dos/autoexec.bat=AUTOEXEC.BAT \
	  $(DOS)/FREECOM.COM=COMMAND.COM $(DOS)/HIMEMX.EXE=HIMEMX.EXE \
	  $(OUT)/xmstest.com=XMSTEST.COM $(OUT)/slow.com=SLOW.COM $(OUT)/hdmi.com=HDMI.COM $(OUT)/sbtest.com=SBTEST.COM \
	  $(CARDOUT)/shsucdx.com=SHSUCDX.COM \
	  $(CARDOUT)/shsucdhd.exe=SHSUCDHD.EXE ../tests/dos/mount.bat=MOUNT.BAT \
	  $(OUT)/dostest.com=DOSTEST.COM $(OUT)/speed.com=SPEED.COM \
	  $(OUT)/gfx.com=GFX.COM $(OUT)/tune.com=TUNE.COM $(OUT)/adlib.com=ADLIB.COM \
	  $(OUT)/mouse.com=MOUSE.COM $(OUT)/mouset.com=MOUSET.COM $(OUT)/gfx2.com=GFX2.COM

$(CARDOUT)/test.iso: ../tests/card/HELLO.TXT $(OUT)/speed.com
	@mkdir -p $(CARDOUT)/cd
	cp ../tests/card/HELLO.TXT $(CARDOUT)/cd/HELLO.TXT
	cp $(OUT)/speed.com $(CARDOUT)/cd/SPEED.COM
	genisoimage -quiet -V MACH86TEST -o $@ $(CARDOUT)/cd

card: all $(BOOTIMG) $(CARDOUT)/test.iso
	python3 ../tools/mkcard.py $(CARDIMG) $(BOOTIMG) -size 64 $(CARDOUT)/test.iso
	@ls -l $(BOOTIMG) $(CARDIMG)

# The card on the reference model: both partitions, a CD image mounted
# and mounted again, a file read and a program run from it.
# (An -expect is met by a screen row that changed since the step before,
# so a prompt that appeared together with the text just matched cannot
# be waited for: a pause stands in.)
CARDSESSION = -expect 'C:\>' -type 'dir d:\r' -expect 'TEST     ISO' \
	  -run 3000000 -type 'mount d:\test.iso\r' -expect 'is on E:' \
	  -run 3000000 -type 'dir e:\r' -expect 'HELLO    TXT' \
	  -run 3000000 -type 'type e:\hello.txt\r' -expect 'on the test CD image' \
	  -run 3000000 -type 'mount test.iso\r' -expect 'is on E:' \
	  -run 3000000 -type 'e:speed\r' -expect 'a second: ' \
	  -run 3000000 -type 'gfx\r' -dexpect "mode 13h 02 ready" -type " " \
	  -dexpect "mode 0Dh F0F00F0FF009 ready" -type " " \
	  -dexpect "mode 04h ready" -type " " -dexpect "mode 06h ready" -type " " \
	  -dexpect "graphics test done" -run 3000000 \
	  -type 'tune\r' -dexpect "bell" -dexpect "done" \
	  -run 3000000 -type 'adlib\r' -dexpect "AdLib found" -dexpect "chord" -dexpect "done" \
	  -run 3000000 -type 'xmstest\r' -dexpect "KB free" -dexpect "XMS test passed" \
	  -run 3000000 -type 'sbtest\r' -dexpect "SB test passed" \
	  -run 3000000 -type 'mouse\r' -dexpect "Mach86 mouse driver" \
	  -run 3000000 -type 'mouset\r' -dexpect "mouse driver ok" -dexpect "x=320 y=99 b=0" \
	  -mouse 10,6,0 -dexpect "x=330 y=102 b=0" \
	  -mouse -300,-1,1 -dexpect "x=30 y=101 b=1" \
	  -mouse -100,7,0 -dexpect "x=0 y=105 b=0" \
	  -type ' ' -dexpect "events=3"
check-card: card
	cp $(CARDIMG) $(CARDOUT)/check.img
	$(OUT)/m86pc -bios $(BIOS) -max 4000000000 -disk $(CARDOUT)/check.img $(CARDSESSION)
	@# And on the SoC's RTL, through its pins.
	$(MAKE) $(SOCOUT)/soc_tb_main
	cp $(CARDIMG) $(CARDOUT)/check.img
	$(SOCOUT)/soc_tb_main -quiet -disk $(CARDOUT)/check.img -max 12000000000 \
	  -expect 'C:\>' -type 'dir d:\r' -expect 'TEST     ISO' \
	  -expect 'C:\>' -type 'mount d:\test.iso\r' -expect 'is on E:' \
	  -expect 'C:\>' -type 'dir e:\r' -expect 'HELLO    TXT' \
	  -expect 'C:\>' -type 'type e:\hello.txt\r' -expect 'on the test CD image' \
	  -expect 'C:\>' -type 'xmstest\r' -expect 'XMS test passed' \
	  -expect 'C:\>' -type 'sbtest\r' -expect 'SB test passed' \
	  -expect 'C:\>' -type 'slow 4\r' -expect 'speed control: 4 ' \
	  -expect 'C:\>' -type 'slow off\r' -expect 'speed control: 0 ' \
	  -expect 'C:\>' -type 'hdmi on\r' -expect 'HDMI with sound' \
	  -expect 'C:\>' -type 'hdmi off\r' -expect 'DVI, no sound' \
	  -expect 'C:\>'
	@echo "card: DOS reads the FAT32 partition and a CD image on it"

vectors-b: $(BOUT)/rtlvecb
	@test -d $(VECTORS)/v1_ex_real_mode || \
	  { echo "no vectors in $(VECTORS): run tools/fetch_vectors.sh"; exit 1; }
	cd $(VECTORS)/v1_ex_real_mode && $(CURDIR)/$(BOUT)/rtlvecb -n 5 \
	  -r ../revocation_list.txt -c ../80386.csv -k $(CURDIR)/$(KNOWN_B) \
	  `python3 $(CURDIR)/../tools/m86b_vecfiles.py $(CURDIR)/$(BOUT)/attr.hex .` \
	  | tail -n 1

rtl-vectors: $(RTLOUT)/rtlvec
	@test -d $(VECTORS)/v1_ex_real_mode || \
	  { echo "no vectors in $(VECTORS): run tools/fetch_vectors.sh"; exit 1; }
	$(RTLOUT)/rtlvec -n 5 -r $(VECTORS)/revocation_list.txt \
	  -c $(VECTORS)/80386.csv -k $(KNOWN) \
	  $(VECTORS)/v1_ex_real_mode/*.MOO.gz | tail -n 1

# DOS on the model. Fetch the third-party pieces first:
#   tools/fetch_dos.sh
DOS    ?= ../output/dos
FATIMG  = python3 ../tools/fatimg.py
PC      = $(OUT)/m86pc -bios $(BIOS) -max 900000000

$(OUT)/dostest.com: ../tests/dos/dostest.asm
	@mkdir -p $(OUT)
	$(NASM) -f bin -o $@ $<

$(OUT)/speed.com: ../tests/dos/speed.asm
	@mkdir -p $(OUT)
	$(NASM) -f bin -o $@ $<

$(OUT)/tune.com: ../tests/dos/tune.asm
	@mkdir -p $(OUT)
	$(NASM) -f bin -o $@ $<

$(OUT)/adlib.com: ../tests/dos/adlib.asm
	@mkdir -p $(OUT)
	$(NASM) -f bin -o $@ $<

$(OUT)/mouse.com: ../tests/dos/mouse.asm
	@mkdir -p $(OUT)
	$(NASM) -f bin -o $@ $<

$(OUT)/mouset.com: ../tests/dos/mouset.asm
	@mkdir -p $(OUT)
	$(NASM) -f bin -o $@ $<

$(OUT)/gfx2.com: ../tests/prog/gfxtest2.asm
	@mkdir -p $(OUT)
	$(NASM) -f bin -DDOSCOM -o $@ $<

$(OUT)/xmstest.com: ../tests/dos/xmstest.asm
	@mkdir -p $(OUT)
	$(NASM) -f bin -o $@ $<

$(OUT)/sbtest.com: ../tests/dos/sbtest.asm
	@mkdir -p $(OUT)
	$(NASM) -f bin -o $@ $<

$(OUT)/hdmi.com: ../tests/dos/hdmi.asm
	@mkdir -p $(OUT)
	$(NASM) -f bin -o $@ $<

$(OUT)/slow.com: ../tests/dos/slow.asm
	@mkdir -p $(OUT)
	$(NASM) -f bin -o $@ $<

# The graphics test as a DOS program, for a board.
$(OUT)/gfx.com: ../tests/prog/gfxtest.asm
	@mkdir -p $(OUT)
	$(NASM) -f bin -DDOSCOM -o $@ $<

dos: all $(OUT)/dostest.com
	@test -f $(DOS)/KERNEL.SYS || \
	  { echo "no DOS files in $(DOS): run tools/fetch_dos.sh"; exit 1; }
	@# Our own test program as the shell.
	cp $(DOS)/boot-svardos.img $(OUT)/dostest.img
	$(FATIMG) $(OUT)/dostest.img $(DOS)/KERNEL.SYS \
	  ../tests/dos/dostest.cfg=CONFIG.SYS $(OUT)/dostest.com=DOSTEST.COM
	$(PC) -disk $(OUT)/dostest.img \
	  -expect "type something" -type "hello\r" -expect "dos test passed"
	@# A session at the prompt.
	cp $(DOS)/boot-svardos.img $(OUT)/command.img
	$(FATIMG) $(OUT)/command.img $(DOS)/KERNEL.SYS \
	  ../tests/dos/command.cfg=CONFIG.SYS $(DOS)/COMMAND.COM $(DOS)/CHKDSK.COM
	$(PC) -disk $(OUT)/command.img \
	  -expect "new date" -type "\r" -expect "new time" -type "\r" \
	  -expect ">" -type "ver\r" -expect "Version" \
	  -type "dir c*.*\r" -expect "File(s)" \
	  -type "chkdsk\r" -expect "bytes free" \
	  -type "echo hello >t.txt\r" -expect ">" \
	  -type "type t.txt\r" -expect "hello"
	@echo "sim: DOS boots and runs"

# The DOS test on the RTL core, in lockstep. About two minutes.
rtl-dos: all $(RTLOUT)/rtlpc $(OUT)/dostest.com
	@test -f $(DOS)/KERNEL.SYS || \
	  { echo "no DOS files in $(DOS): run tools/fetch_dos.sh"; exit 1; }
	cp $(DOS)/boot-svardos.img $(OUT)/dostest.img
	$(FATIMG) $(OUT)/dostest.img $(DOS)/KERNEL.SYS \
	  ../tests/dos/dostest.cfg=CONFIG.SYS $(OUT)/dostest.com=DOSTEST.COM
	$(RTLOUT)/rtlpc -bios $(BIOS) -disk $(OUT)/dostest.img -max 900000000 \
	  -expect "type something" -type "hello\r" -expect "dos test passed"
	@echo "rtl: DOS boots and runs in lockstep with the model"

clean:
	rm -rf $(OUT) $(RTLOUT) $(BOUT)

.PHONY: all check rtl-check profile vectors rtl-vectors vectors-b check-b-boot dos-b check-tb check-soc check-soc-main check-soc-train check-card check-pm check-gfx check-gfx2 check-nobram check-spk check-opl check-mouse card soc-dos check-gate gate-dos sdcard dos rtl-dos clean
