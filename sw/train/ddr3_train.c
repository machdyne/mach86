/*
 * Mach86 BIOS -- DDR3 read-path training.
 *
 * This is Zeitlos's trainer, sw/bios/bios.c at commit ede46a8, lines
 * 539 to 822, with as little changed as possible: it was hard to get
 * right on the hardware, and it is right. Zeitlos runs it on its
 * RISC-V CPU with the DDR3 registers and the memory mapped into its
 * address space. Here it runs on the x86 CPU in real mode, compiled
 * with gcc -m16, and reaches both through the SoC's memory port
 * (ports E4h, E8h, ECh; rtl/soc/m86_soc.v), which goes straight to
 * the controller, past the cache. So:
 *
 *   reg_ddr3_status, _tune, _ctrl   became  reg_rd(), reg_wr()
 *   m[i]                            became  mem_rd(i), mem_wr(i, v)
 *
 * and the comments are Zeitlos's. The two places where the code
 * itself differs are marked "Mach86".
 *
 * There is no RAM yet when this runs. The BIOS copies this program
 * into the text screen's memory, B800:0000, and calls it there, with
 * the stack at the top of the same 4 KB (sw/bios/bios.asm). It
 * returns 1 if the memory is usable.
 */
typedef unsigned char uint8_t;
typedef unsigned int uint32_t;

static inline void outb(uint8_t v, unsigned short port)
{
	__asm__ volatile ("outb %0, %1" : : "a"(v), "Nd"(port));
}

static inline uint8_t inb(unsigned short port)
{
	uint8_t v;
	__asm__ volatile ("inb %1, %0" : "=a"(v) : "Nd"(port));
	return v;
}

static inline void outl(uint32_t v, unsigned short port)
{
	__asm__ volatile ("outl %0, %1" : : "a"(v), "Nd"(port));
}

static inline uint32_t inl(unsigned short port)
{
	uint32_t v;
	__asm__ volatile ("inl %1, %0" : "=a"(v) : "Nd"(port));
	return v;
}

// The memory port. A command byte: bit 0 write, bit 1 a controller
// register and not a word of memory. Bit 7 read back: busy.
#define MP_CMD  0xE4
#define MP_ADDR 0xE8
#define MP_DATA 0xEC

static uint32_t mp_read(uint8_t what, uint32_t a)
{
	outl(a, MP_ADDR);
	outb(what, MP_CMD);
	while (inb(MP_CMD) & 0x80) ;
	return inl(MP_DATA);
}

static void mp_write(uint8_t what, uint32_t a, uint32_t v)
{
	outl(a, MP_ADDR);
	outl(v, MP_DATA);
	outb(what | 1, MP_CMD);
	while (inb(MP_CMD) & 0x80) ;
}

#define REG_STATUS 0
#define REG_TUNE   1
#define REG_CTRL   2
#define reg_rd(r)     mp_read(2, (r))
#define reg_wr(r, v)  mp_write(2, (r), (v))
#define mem_rd(i)     mp_read(0, (i))
#define mem_wr(i, v)  mp_write(0, (i), (v))

// The console (port E0h: bit 7 read back, no room).
static void print(const char *s)
{
	for (; *s; s++) {
		if (*s == '\n') {
			while (inb(0xE0) & 0x80) ;
			outb('\r', 0xE0);
		}
		while (inb(0xE0) & 0x80) ;
		outb(*s, 0xE0);
	}
}

static void print_hex(uint32_t v, int digits)
{
	char s[2] = { 0, 0 };
	int i;
	for (i = digits - 1; i >= 0; i--) {
		s[0] = "0123456789abcdef"[(v >> (4 * i)) & 15];
		print(s);
	}
}

// ---- from here on, Zeitlos's trainer ----------------------------

#define CTRL_HOLD_REFRESH 1
#define CTRL_TRAIN_WRITES 4
#define CTRL_RDBUF_OFF    8

// Every training access goes to the DRAM. The first hardware scan
// forgot the controller's own block register: the training write left
// the block in it, every training read was answered from it, and every
// setting passed -- the map was all 'f', sixteen offsets working
// everywhere, while the real read path had never delivered a burst.
#define CTRL_TRAINING (CTRL_TRAIN_WRITES | CTRL_RDBUF_OFF)

// Every byte of the block different, so a beat, a byte or a lane in
// the wrong place cannot pass. (A pattern whose halves match hides a
// one-beat shift -- which is how two cancelling errors survived in
// the controller's testbench.)
static const uint32_t ddr3_pat[4] = {
	0x04030201, 0x08070605, 0x0c0b0a09, 0x100f0e0d
};

// Per lane, per read phase, per gate: the offset that assembled the
// lane correctly, 0xff for none, or 0xfe for MORE THAN ONE.
//
// A real read path assembles a lane at exactly one offset -- the
// assembly testbench proves it. Two offsets passing in one cell means
// the reads are not coming from the DRAM at all, so such a cell is
// shown as '*' and never chosen. The trainer checks that its own
// measurement reaches the hardware, instead of trusting it.
static uint8_t ddr3_tbl[2][8][8];

static uint32_t ddr3_tune_of(uint32_t wd, uint32_t rs, uint32_t g,
	uint32_t o)
{
	return wd | (g << 4) | (g << 8) | (rs << 12) | (rs << 16)
		| (o << 20) | (o << 24);
}

// Written through the training mode, which skips the read that
// read-modify-write would otherwise need: four words in sequence
// leave the block exactly right whatever the read path is doing.
// Refresh runs while it happens, which also bounds how long refresh
// is ever held -- DDR3 keeps data for 64ms without it.
static void ddr3_write_pat(void)
{
	int i;
	reg_wr(REG_CTRL, CTRL_TRAINING);
	for (i = 0; i < 4; i++) mem_wr(i, ddr3_pat[i]);
	reg_wr(REG_CTRL, CTRL_TRAINING | CTRL_HOLD_REFRESH);
}

// Both lanes scored separately, on their own bytes, so one lane
// working is visible while the other is not. And twice: a value that
// comes back identical is repeatable, which a stale capture that
// happens to be right once is not.
static uint32_t ddr3_score(void)
{
	uint32_t ok = 3, a, b;
	int i;
	for (i = 0; i < 4; i++) {
		a = mem_rd(i);
		b = mem_rd(i);
		if (a != b) return 0;
		if ((a & 0x00ff00ff) != (ddr3_pat[i] & 0x00ff00ff)) ok &= ~1;
		if ((a & 0xff00ff00) != (ddr3_pat[i] & 0xff00ff00)) ok &= ~2;
	}
	return ok;
}

// Does the same offset work one read phase away? READCLKSEL is CIRCULAR:
// stepping from phase 7 to phase 0 moves a whole cycle, and the gate
// compensates by one. The first hardware map showed exactly that --
// lane 1 working at r6 and r7 with gate 2, and at r0 with gate 3, same
// offset -- so r7 was the centre of its window, while a test that only
// looked at r6 and a nonexistent r8 called it an edge.
static int ddr3_nb(int lane, int rs, int g, uint8_t v)
{
	if (rs < 0) { rs = 7; g--; }
	if (rs > 7) { rs = 0; g++; }
	if (g < 0 || g > 7) return 0;
	return ddr3_tbl[lane][rs][g] == v;
}

// The cell with the most working neighbours in phase: 2 = centred.
static int ddr3_pick(int lane, uint32_t *rs_o, uint32_t *g_o,
	uint32_t *o_o)
{
	int rs, g, sc, best = -1;
	uint8_t v;
	for (rs = 0; rs < 8; rs++)
		for (g = 0; g < 8; g++) {
			v = ddr3_tbl[lane][rs][g];
			if (v >= 0xfe) continue;
			sc = ddr3_nb(lane, rs - 1, g, v) + ddr3_nb(lane, rs + 1, g, v);
			if (sc > best) {
				best = sc;
				*rs_o = rs; *g_o = g; *o_o = v;
			}
		}
	return best + 1;       // 0 none, 1 edge-only, 2 one side, 3 centred
}

// One lane's map: a row per read phase, a column per gate, the offset
// that worked there or '.'.
static void ddr3_map(int lane)
{
	int rs, g;
	uint8_t v;
	for (rs = 0; rs < 8; rs++) {
		print(lane ? " L1 r" : " L0 r");
		print_hex(rs, 1);
		print(" ");
		for (g = 0; g < 8; g++) {
			v = ddr3_tbl[lane][rs][g];
			if (v == 0xff) print(".");
			else if (v == 0xfe) print("*");
			else print_hex(v, 1);
		}
		print("\n");
	}
}

// Where does the read gate catch the strobe?
//
// BURSTDET is set by each lane's DQSBUFM when the read gate catches a
// DQS burst. It depends only on the READ command and the gate --
// not on the data, and not on whether any write ever landed -- so it
// answers the first question independently of every other one: is the
// DRAM answering reads at all, and when?
//
// One read per cell; the PHY clears BURSTDET as each read is issued.
// Each cell prints the lanes that saw a burst: 1 = lane 0, 2 = lane 1,
// 3 = both. (Every read completes now -- data is captured a fixed time
// after the command, as in LiteDRAM, not when DATAVALID says so -- so
// completion no longer tells anything and is not shown.)
static void ddr3_gatescan(void)
{
	uint32_t rs, g, st, d;

	print("gate scan: burstdet, 1=L0 2=L1 3=both, row=rdclksel col=gate\n");
	reg_wr(REG_CTRL, CTRL_TRAINING | CTRL_HOLD_REFRESH);
	for (rs = 0; rs < 8; rs++) {
		print(" r");
		print_hex(rs, 1);
		print(" ");
		for (g = 0; g < 8; g++) {
			reg_wr(REG_TUNE, ddr3_tune_of(3, rs, g, 4));
			d = mem_rd(0);
			(void)d;
			st = reg_rd(REG_STATUS);
			print_hex((st >> 4) & 3, 1);
		}
		print("\n");
	}
	reg_wr(REG_CTRL, CTRL_TRAINING);
}

// When training finds nothing: what DOES come back? The first gate
// where both lanes saw a burst, every offset, all four words -- the
// shape of the wrong data says more than a pass/fail map can.
static void ddr3_dump(void)
{
	uint32_t rs, g, o, i;

	reg_wr(REG_CTRL, CTRL_TRAINING | CTRL_HOLD_REFRESH);
	for (rs = 0; rs < 8; rs++)
		for (g = 0; g < 8; g++) {
			reg_wr(REG_TUNE, ddr3_tune_of(4, rs, g, 4));
			(void)mem_rd(0);
			if (((reg_rd(REG_STATUS) >> 4) & 3) == 3) goto found;
		}
	print("no cell with a burst on both lanes\n");
	reg_wr(REG_CTRL, 0);
	return;
found:
	// Write delay 4: LiteDRAM's position, and the only one that has
	// worked here. The dump used 3, i.e. showed data written wrongly.
	reg_wr(REG_TUNE, ddr3_tune_of(4, rs, g, 4));
	print("dump (wd4) at r");
	print_hex(rs, 1);
	print(" g");
	print_hex(g, 1);
	print(", want 04030201 08070605 0c0b0a09 100f0e0d\n");
	ddr3_write_pat();
	for (o = 0; o < 16; o++) {
		reg_wr(REG_TUNE, ddr3_tune_of(4, rs, g, o));
		print(" o");
		print_hex(o, 1);
		for (i = 0; i < 4; i++) {
			print(" ");
			print_hex(mem_rd(i), 8);
		}
		print("\n");
	}
	reg_wr(REG_CTRL, 0);
}

static int ddr3_train(void)
{
	uint32_t wd, rs, g, o, sc, n;
	uint32_t rs0, g0, o0, rs1, g1, o1;
	int p0, p1;

	// (Zeitlos turns its data cache off here. Mach86's memory port
	// goes past the cache by construction.)

	print("ddr3 ");
	for (n = 0; n < 2000000 && !(reg_rd(REG_STATUS) & 1); n++) ;
	print_hex(reg_rd(REG_STATUS), 8);
	if (!(reg_rd(REG_STATUS) & 1)) {
		print(" init timeout\n");
		return 0;
	}
	print("\n");

	// Always, before training: it is informative whether or not
	// training then succeeds.
	ddr3_gatescan();

	for (wd = 0; wd < 8; wd++) {
		for (rs = 0; rs < 8; rs++) {
			reg_wr(REG_TUNE, ddr3_tune_of(wd, 0, 0, 0));
			ddr3_write_pat();
			for (g = 0; g < 8; g++) {
				ddr3_tbl[0][rs][g] = 0xff;
				ddr3_tbl[1][rs][g] = 0xff;
				for (o = 0; o < 16; o++) {
					reg_wr(REG_TUNE, ddr3_tune_of(wd, rs, g, o));
					sc = ddr3_score();
					if (sc & 1) ddr3_tbl[0][rs][g] =
						ddr3_tbl[0][rs][g] == 0xff ? o : 0xfe;
					if (sc & 2) ddr3_tbl[1][rs][g] =
						ddr3_tbl[1][rs][g] == 0xff ? o : 0xfe;
				}
			}
		}
		p0 = ddr3_pick(0, &rs0, &g0, &o0);
		p1 = ddr3_pick(1, &rs1, &g1, &o1);
		if (p0 || p1) {
			print("wd");
			print_hex(wd, 1);
			print("\n");
			ddr3_map(0);
			ddr3_map(1);
		}
		if (p0 && p1) break;
	}

	reg_wr(REG_CTRL, 0);
	if (wd == 8) {
		print("ddr3 training FAILED\n");
		ddr3_dump();
		return 0;
	}

	reg_wr(REG_TUNE, wd | (g0 << 4) | (g1 << 8) | (rs0 << 12)
		| (rs1 << 16) | (o0 << 20) | (o1 << 24));
	print("ddr3 tune ");
	print_hex(reg_rd(REG_TUNE), 8);
	// Per lane: C = centred (works one phase either side), e = edge.
	print(p0 == 3 ? " L0:C" : " L0:e");
	print(p1 == 3 ? " L1:C\n" : " L1:e\n");

	// Now through the normal path: read-modify-write, refresh on,
	// a block the training never touched, a word and a single byte.
	mem_wr(64, 0xa5c3a5c3);
	mem_wr(65, 0x5a3c5a3c);
	// (Zeitlos also stores a single byte here. Mach86 only ever
	// writes whole words to the controller, so that is left out.)
	print("ddr3 check ");
	print_hex(mem_rd(64), 8);
	print(" ");
	print_hex(mem_rd(65), 8);
	if (mem_rd(64) != 0xa5c3a5c3 || mem_rd(65) != 0x5a3c5a3c) {
		print(" FAILED\n");
		return 0;
	}
	print(" ok\n");
	return 1;
}

int main(void)
{
	return ddr3_train();
}
