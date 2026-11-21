/*
 * m86pipe.h: what a pipelined core would take, in cycles.
 *
 * This is not part of the model's behaviour. It is a count kept beside
 * it, for the plan in docs/cpu_c.md: how many clock cycles "design C"
 * would need for the instructions the model executes. M86_PIPE in the
 * environment turns it on; a line is printed every hundred million
 * instructions and (m86_pipe_report) at the end.
 *
 * The pipeline it counts for:
 *
 *      F   the decoded-instruction cache is read (and gives the index
 *          of the entry to read next: the one after, or a jump's
 *          target if the jump was taken last time)
 *      T   tag compared, micro-operation chosen
 *      R   registers read; the address added up
 *      M   data cache
 *      X   ALU; flags; jumps decided
 *      W   written
 *
 * One instruction enters each cycle. What holds it up:
 *
 *   - An address needs its registers in R. A register computed by the
 *     ALU is known after X, two stages on; one that was loaded, after
 *     M. So an instruction that addresses with the result of the one
 *     before waits two cycles (one, after a load), and one cycle less
 *     for the one before that. The stack pointer as PUSH, POP, CALL
 *     and RET move it is kept in R and costs nothing.
 *   - A jump that goes another way than the last time (or, for a
 *     return, than the call said; or an indirect one to another place)
 *     is found out in X, when four younger instructions have been
 *     fetched for nothing: four cycles.
 *   - An instruction not in the decoded-instruction cache: the decoder
 *     (M86_PIPE_MISS cycles, 10 if not given).
 *   - The kinds the pipeline does not do (segment loads, multiply,
 *     divide, string loops, I/O, the system instructions; shifts of
 *     a register, the double ones included, unless M86_PIPE_SHIFT=1)
 *     wait for the pipeline to empty and then
 *     take what design B takes: design B's count for the kind (a
 *     table here, only roughly right), times M86_PIPE_PH (1 if not
 *     given; 3 for a core that makes each of design B's cycles in
 *     three of its own), plus M86_PIPE_SER cycles (3 if not given).
 *   - A second micro-operation (PUSH and POP of memory, LEAVE, XCHG):
 *     one cycle.
 *
 * What it leaves out: the data cache's misses and the video memory
 * (the same for any core), interrupts, and faults.
 *
 * M86_PIPE=n counts from the n-th instruction on, and M86_PIPE_N=m for
 * m instructions, to look at one part of a run. M86_PIPE_DC=bits sets the cache's size (11: 2,048 entries).
 */
#ifndef M86PIPE_H
#define M86PIPE_H

enum { PK_PLAIN, PK_JCC, PK_JMP, PK_CALL, PK_RET, PK_IND, PK_SER };
enum { PS_BASE, PS_AGI, PS_MISP, PS_MISS, PS_SER, PS_UOP2, PS_N };

static struct {
    int      on;                /* -1: not asked yet */
    uint64_t from, n, cyc;
    uint64_t part[PS_N];        /* cycles by cause */
    uint64_t jumps, wrong, sers, misses, agis;
    uint64_t ser_op[512], ser_cyc[512];
    int      miss_cost, ser_cost, ser_mul, shift, dc_bits;
    uint32_t *tag, *tgt;        /* the cache: address, and where its jump went */
    uint8_t  *taken;
    uint32_t ras[8];
    int      ras_n;
    /* When each register can first be used in an address, as the cycle
     * its user may be in X. */
    uint64_t addr_ok[8];
    uint64_t x;                 /* the cycle the last instruction was in X */
    /* The instruction before this one. */
    struct { int v, kind, len, hit; uint32_t lin, eip, target; } p;
    uint64_t last_cyc;
} pp = { .on = -1 };

static uint8_t pipe_peek(m86 *c, uint32_t la)
{
    if (c->cr0 & 0x80000000u) {
        uint32_t pde = 0, pte = 0, a = (c->cr3 & ~0xFFFu) + ((la >> 22) << 2);
        for (int i = 0; i < 4; i++) pde |= (uint32_t)c->mem_read(c->bus, a + i) << (8 * i);
        if (!(pde & 1)) return 0x90;
        a = (pde & ~0xFFFu) + (((la >> 12) & 0x3FF) << 2);
        for (int i = 0; i < 4; i++) pte |= (uint32_t)c->mem_read(c->bus, a + i) << (8 * i);
        if (!(pte & 1)) return 0x90;
        la = (pte & ~0xFFFu) | (la & 0xFFF);
    }
    return c->mem_read(c->bus, la);
}

/* Design B's cycles for the kinds that do not go down the pipeline. */
static int pipe_ser_cost(m86 *c, int op2, int op, int reg, int rep, int os)
{
    int pm = (c->cr0 & 1) && !(c->s.eflags & 0x20000);
    uint32_t n = rep ? c->s.r[1] : 1;
    if (rep && !c->s.seg[M86_CS].d) n &= 0xFFFF;
    (void)os;
    if (n > 100000) n = 100000;
    if (!op2) {
        if (op >= 0xA4 && op <= 0xA5) return rep ? 4 + 2 * (int)n : 3;      /* MOVS */
        if (op >= 0xAA && op <= 0xAB) return rep ? 4 + (int)n : 2;          /* STOS */
        if (op >= 0xAC && op <= 0xAD) return rep ? 4 + 2 * (int)n : 3;      /* LODS */
        if ((op >= 0xA6 && op <= 0xA7) || (op >= 0xAE && op <= 0xAF))
            return rep ? 4 + 3 * (int)n : 4;                                /* CMPS, SCAS: an upper bound */
        if (op >= 0x6C && op <= 0x6F) return rep ? 4 + 4 * (int)n : 5;      /* INS, OUTS */
        if (op == 0xC0 || op == 0xC1 || (op >= 0xD0 && op <= 0xD3)) return 3;
        if (op == 0x69 || op == 0x6B) return 5;
        if (op == 0xF6 || op == 0xF7)
            return reg >= 6 ? (op == 0xF6 ? 14 : os == 2 ? 14 : (reg == 7 ? 34 : 18)) : 5;
        if (op == 0x8E || op == 0x07 || op == 0x17 || op == 0x1F) return pm ? 15 : 3;
        if (op == 0x8C || op == 0x06 || op == 0x0E || op == 0x16 || op == 0x1E) return 2;
        if (op == 0xC4 || op == 0xC5) return pm ? 18 : 6;
        if (op >= 0xE4 && op <= 0xE7) return 4;
        if (op >= 0xEC && op <= 0xEF) return 4;
        if (op == 0xCD || op == 0xCC || op == 0xCE) return pm ? 60 : 20;
        if (op == 0xCF) return pm ? 40 : 14;
        if (op == 0x9A || op == 0xEA) return pm ? 40 : 8;
        if (op == 0xCA || op == 0xCB) return pm ? 40 : 8;
        if (op == 0x9C) return 3;
        if (op == 0x9D) return 4;
        if (op == 0x60 || op == 0x61) return 12;
        if (op == 0xC8) return 12;
        if (op == 0xFA || op == 0xFB || op == 0xFC || op == 0xFD || op == 0xF8 || op == 0xF9 || op == 0xF5)
            return 1;
        if (op == 0x9E || op == 0x9F || op == 0x98 || op == 0x99 || op == 0xD7) return 2;
        if (op == 0xFF) return pm ? 40 : 10;                                /* far CALL, JMP through memory */
        return 5;
    }
    if (op == 0xAF) return 5;                                               /* IMUL */
    if (op == 0xA4 || op == 0xA5 || op == 0xAC || op == 0xAD) return 3;     /* SHLD, SHRD */
    if (op >= 0x90 && op <= 0x9F) return 2;                                 /* SETcc */
    if (op == 0xA3 || op == 0xAB || op == 0xB3 || op == 0xBB || op == 0xBA) return 4;
    if (op == 0xBC || op == 0xBD) return 20;
    if (op == 0xA1 || op == 0xA9) return pm ? 15 : 3;
    if (op == 0xA0 || op == 0xA8) return 2;
    if (op == 0xB2 || op == 0xB4 || op == 0xB5) return pm ? 18 : 6;
    return 8;
}

static void pipe_line(const char *what, uint64_t n, uint64_t cyc)
{
    fprintf(stderr, "pipe: %s: %llu instructions, %llu cycles, %.3f an instruction\n", what,
            (unsigned long long)n, (unsigned long long)cyc, n ? (double)cyc / (double)n : 0.0);
}

void m86_pipe_report(void)
{
    static const char *name[PS_N] = { "one each", "address waits", "wrong guesses", "not in the cache",
                                      "kinds outside the pipeline", "second micro-operations" };
    if (pp.on <= 0 || !pp.n)
        return;
    pipe_line("in all", pp.n, pp.cyc);
    for (int i = 0; i < PS_N; i++)
        fprintf(stderr, "pipe:   %-28s %6.3f\n", name[i], (double)pp.part[i] / (double)pp.n);
    fprintf(stderr, "pipe: jumps %.1f%% of instructions, %.1f%% of them guessed wrong; %.2f%% not in the cache; "
                    "%.1f%% outside the pipeline; %.1f%% wait for an address\n",
            100.0 * pp.jumps / pp.n, pp.jumps ? 100.0 * pp.wrong / pp.jumps : 0.0, 100.0 * pp.misses / pp.n,
            100.0 * pp.sers / pp.n, 100.0 * pp.agis / pp.n);
    fprintf(stderr, "pipe: outside the pipeline, by opcode (count, cycles each):");
    for (int k = 0; k < 12; k++) {
        int b = 0;
        for (int i = 0; i < 512; i++)
            if (pp.ser_cyc[i] > pp.ser_cyc[b]) b = i;
        if (!pp.ser_cyc[b]) break;
        fprintf(stderr, " %s%02x: %.1f%% x %.1f", b & 256 ? "0f " : "", b & 255,
                100.0 * pp.ser_op[b] / pp.n, (double)pp.ser_cyc[b] / pp.ser_op[b]);
        pp.ser_cyc[b] = 0;
    }
    fprintf(stderr, "\n");
}

/* Called before each instruction is executed. */
static void pipe_step(m86 *c)
{
    if (pp.on < 0) {
        const char *e = getenv("M86_PIPE");
        pp.on = e != NULL;
        if (!pp.on)
            return;
        pp.from = strtoull(e, NULL, 0);
        pp.miss_cost = getenv("M86_PIPE_MISS") ? atoi(getenv("M86_PIPE_MISS")) : 10;
        pp.ser_cost = getenv("M86_PIPE_SER") ? atoi(getenv("M86_PIPE_SER")) : 3;
        pp.ser_mul = getenv("M86_PIPE_PH") ? atoi(getenv("M86_PIPE_PH")) : 1;
        pp.shift = getenv("M86_PIPE_SHIFT") ? atoi(getenv("M86_PIPE_SHIFT")) : 0;
        pp.dc_bits = getenv("M86_PIPE_DC") ? atoi(getenv("M86_PIPE_DC")) : 11;
        pp.tag = calloc((size_t)1 << pp.dc_bits, sizeof(uint32_t));
        pp.tgt = calloc((size_t)1 << pp.dc_bits, sizeof(uint32_t));
        pp.taken = calloc((size_t)1 << pp.dc_bits, 1);
        atexit(m86_pipe_report);
    }
    if (!pp.on)
        return;

    uint32_t eip = c->s.eip, lin = c->s.seg[M86_CS].base + eip;

    /* The jump before this instruction: was it guessed? */
    if (pp.p.v && pp.p.kind != PK_PLAIN && pp.p.kind != PK_SER) {
        uint32_t i = pp.p.lin & (((uint32_t)1 << pp.dc_bits) - 1);
        int went = (eip != pp.p.eip + (uint32_t)pp.p.len), wrong;
        pp.jumps++;
        if (pp.p.kind == PK_RET) {
            wrong = !(pp.ras_n > 0 && pp.ras[--pp.ras_n & 7] == eip);
            if (pp.ras_n < 0) pp.ras_n = 0;
        } else {
            /* (An entry just decoded knows nothing: it guesses "not taken".) */
            int guess = pp.p.hit && pp.taken[i];
            wrong = (guess != went) || (went && pp.p.kind == PK_IND && pp.tgt[i] != eip);
            pp.taken[i] = (uint8_t)went;
            pp.tgt[i] = eip;
            if (pp.p.kind == PK_CALL || (pp.p.kind == PK_IND && pp.p.target))
                pp.ras[pp.ras_n++ & 7] = pp.p.eip + (uint32_t)pp.p.len;
        }
        if (wrong) {
            pp.wrong++;
            pp.x += 4;
            pp.cyc += 4;
            pp.part[PS_MISP] += 4;
        }
    }
    pp.p.v = 0;
    if (c->halted)
        return;
    if (c->icount < pp.from)
        return;

    /* Look at the instruction. */
    int os = c->s.seg[M86_CS].d ? 4 : 2, as32 = c->s.seg[M86_CS].d, rep = 0, op2 = 0, len = 0, op;
    for (;;) {
        op = pipe_peek(c, lin + (uint32_t)len++);
        if (op == 0x66) os = 6 - os;
        else if (op == 0x67) as32 = !as32;
        else if (op == 0xF2 || op == 0xF3) rep = 1;
        else if (op == 0x26 || op == 0x2E || op == 0x36 || op == 0x3E || op == 0x64 || op == 0x65 || op == 0xF0) ;
        else break;
        if (len > 14) break;
    }
    if (op == 0x0F) {
        op2 = 1;
        op = pipe_peek(c, lin + (uint32_t)len++);
    }
    /* Does it have a ModRM byte? (Enough of the opcode map for this.) */
    int has_m;
    if (!op2)
        has_m = (op < 0x40 && (op & 7) < 4) || op == 0x62 || op == 0x63 || op == 0x69 || op == 0x6B ||
                (op >= 0x80 && op <= 0x8F) || op == 0xC0 || op == 0xC1 || op == 0xC4 || op == 0xC5 ||
                op == 0xC6 || op == 0xC7 || (op >= 0xD0 && op <= 0xD3) || (op >= 0xD8 && op <= 0xDF) ||
                op == 0xF6 || op == 0xF7 || op == 0xFE || op == 0xFF;
    else
        has_m = !(op >= 0x80 && op <= 0x8F) && op != 0xA0 && op != 0xA1 && op != 0xA8 && op != 0xA9 &&
                op != 0x06 && op != 0x08 && op != 0x09 && op != 0xA2 && !(op >= 0xC8 && op <= 0xCF);
    int mod = 3, reg = 0, rm = 0, base = -1, index = -1, mem = 0;
    if (has_m) {
        int m = pipe_peek(c, lin + (uint32_t)len++);
        mod = m >> 6; reg = (m >> 3) & 7; rm = m & 7;
        if (mod != 3) {
            mem = 1;
            if (as32) {
                if (rm == 4) {
                    int sib = pipe_peek(c, lin + (uint32_t)len++);
                    base = sib & 7;
                    index = (sib >> 3) & 7;
                    if (index == 4) index = -1;
                    if (base == 5 && mod == 0) { base = -1; len += 4; }
                } else if (rm == 5 && mod == 0) {
                    len += 4;
                } else
                    base = rm;
                len += mod == 1 ? 1 : mod == 2 ? 4 : 0;
            } else {
                static const signed char b16[8] = { 3, 3, 5, 5, 6, 7, 5, 3 }, i16[8] = { 6, 7, 6, 7, -1, -1, -1, -1 };
                base = b16[rm];
                index = i16[rm];
                if (rm == 6 && mod == 0) { base = -1; len += 2; }
                len += mod == 1 ? 1 : mod == 2 ? 2 : 0;
            }
        }
    }
    int osb = os;       /* the immediate's size for "Iz" */

    /* What kind it is; which registers it writes, and whether by a load;
     * whether it uses the stack pointer as an address. */
    int kind = PK_PLAIN, uops = 1, wr = -1, wr2 = -1, load = 0, stack = 0, sp_calc = 0, is_call = 0;
#define SER() (kind = PK_SER)
    if (!op2) {
        if (op < 0x40 && (op & 7) < 6) {                /* ALU */
            if ((op & 7) >= 4) { wr = 0; len += (op & 1) ? osb : 1; }
            else if (op & 2) wr = reg;
            else if (!mem) wr = rm;
            if ((op & 0x38) == 0x38) wr = -1;           /* CMP */
            if (!(op & 1) && wr >= 4 && (op & 7) < 4) wr &= 3;
        } else if (op < 0x40 && (op & 7) >= 6) {
            if (op == 0x26 || op == 0x2E || op == 0x36 || op == 0x3E) ;
            else if (op == 0x27 || op == 0x2F || op == 0x37 || op == 0x3F) SER();
            else SER();                                 /* PUSH, POP of a segment register */
        } else if (op < 0x50) wr = op & 7;              /* INC, DEC */
        else if (op < 0x58) { stack = 1; }              /* PUSH */
        else if (op < 0x60) { stack = 1; wr = op & 7; load = 1; }
        else if (op == 0x68) { stack = 1; len += osb; }
        else if (op == 0x6A) { stack = 1; len += 1; }
        else if (op >= 0x70 && op <= 0x7F) { kind = PK_JCC; len += 1; }
        else if (op >= 0x80 && op <= 0x83) {
            len += op == 0x81 ? osb : 1;
            if (!mem && reg != 7) wr = (op & 1) ? rm : rm & 3;
        } else if (op == 0x84 || op == 0x85) ;
        else if (op == 0x86 || op == 0x87) { wr = reg; if (!mem) wr2 = rm; else uops = 2; }
        else if (op == 0x88 || op == 0x89) { if (!mem) wr = (op & 1) ? rm : rm & 3; }
        else if (op == 0x8A || op == 0x8B) { wr = (op & 1) ? reg : reg & 3; load = mem; }
        else if (op == 0x8D) { wr = reg; load = 1; }    /* LEA: known as early as a load */
        else if (op == 0x8F) { stack = 1; uops = 2; if (!mem) { wr = rm; load = 1; uops = 1; } }
        else if (op == 0x90 || op == 0x9E || op == 0x9F || op == 0xF5 || op == 0xF8 || op == 0xF9 ||
                 op == 0xFC || op == 0xFD) ;
        else if (op == 0x98) wr = 0;
        else if (op == 0x99) wr = 2;
        else if (op >= 0x91 && op <= 0x97) { wr = 0; wr2 = op & 7; }
        else if (op >= 0xA0 && op <= 0xA3) { len += as32 ? 4 : 2; if (op < 0xA2) { wr = 0; load = 1; } }
        else if (op == 0xA8) len += 1;
        else if (op == 0xA9) len += osb;
        else if (op >= 0xB0 && op <= 0xB7) { wr = op & 3; len += 1; }
        else if (op >= 0xB8 && op <= 0xBF) { wr = op & 7; len += osb; }
        else if (op == 0xC0 || op == 0xC1 || (op >= 0xD0 && op <= 0xD3)) {
            if (op <= 0xC1) len += 1;
            if (!mem) wr = (op & 1) ? rm : rm & 3;
            /* The plain shifts may be in the pipeline; the rotates through
             * carry and everything in memory are not. */
            if (!(pp.shift && !mem && reg != 2 && reg != 3)) SER();
        } else if (op == 0xC2) { kind = PK_RET; stack = 1; len += 2; sp_calc = 1; }
        else if (op == 0xC3) { kind = PK_RET; stack = 1; }
        else if (op == 0xC6) len += 1;
        else if (op == 0xC7) len += osb;
        else if (op == 0xC9) { stack = 1; uops = 2; wr = 5; load = 1; sp_calc = 1; }
        else if (op == 0xE8) { kind = PK_CALL; stack = 1; len += osb; is_call = 1; }
        else if (op == 0xE9) { kind = PK_JMP; len += osb; }
        else if (op == 0xEB) { kind = PK_JMP; len += 1; }
        else if (op >= 0xE0 && op <= 0xE3) { kind = PK_JCC; len += 1; if (op != 0xE3) { wr = 1; uops = 2; } }
        else if (op == 0xF6 || op == 0xF7) {
            if (reg < 2) len += op == 0xF6 ? 1 : osb;
            if (reg >= 4) SER();
            else if (reg >= 2 && !mem) wr = (op & 1) ? rm : rm & 3;
        } else if (op == 0xFE || (op == 0xFF && reg < 2)) { if (!mem) wr = (op & 1) ? rm : rm & 3; }
        else if (op == 0xFF && (reg == 2 || reg == 4)) { kind = PK_IND; if (reg == 2) { stack = 1; is_call = 1; } }
        else if (op == 0xFF && reg == 6) { stack = 1; if (mem) uops = 2; }
        else SER();
    } else {
        if (op >= 0x80 && op <= 0x8F) { kind = PK_JCC; len += osb; }
        else if (op == 0xB6 || op == 0xB7 || op == 0xBE || op == 0xBF) { wr = reg; load = mem; }
        else if (pp.shift && !mem && (op == 0xA4 || op == 0xA5 || op == 0xAC || op == 0xAD)) wr = rm;
        else SER();
        if (op == 0xA4 || op == 0xAC || op == 0xBA) len += 1;
    }
    if (rep && kind != PK_SER) rep = 0;

    /* The cycle it is in X: the one after the instruction before it,
     * or later. */
    uint64_t x0 = pp.x + 1, x = x0;
    uint32_t i = lin & (((uint32_t)1 << pp.dc_bits) - 1);
    int hit = pp.tag[i] == lin + 1;
    if (!hit) {
        pp.tag[i] = lin + 1;
        pp.taken[i] = 0;
        pp.misses++;
        x += (uint64_t)pp.miss_cost;
        pp.part[PS_MISS] += (uint64_t)pp.miss_cost;
    }
    if (kind == PK_SER) {
        int b = pipe_ser_cost(c, op2, op, reg, rep, os), k = (op2 ? 256 : 0) | op;
        uint64_t add = (uint64_t)(b * pp.ser_mul + pp.ser_cost - 1);
        x += add;
        pp.part[PS_SER] += add;
        pp.sers++;
        pp.ser_op[k]++;
        pp.ser_cyc[k] += (uint64_t)(b * pp.ser_mul + pp.ser_cost);
        /* Whatever it wrote is known by the time the pipeline fills again. */
        for (int r = 0; r < 8; r++)
            if (pp.addr_ok[r] > x) pp.addr_ok[r] = x;
    } else {
        uint64_t need = x;
        if (mem && base >= 0 && pp.addr_ok[base] > need) need = pp.addr_ok[base];
        if (mem && index >= 0 && pp.addr_ok[index] > need) need = pp.addr_ok[index];
        if (stack && pp.addr_ok[4] > need) need = pp.addr_ok[4];
        if (need > x) {
            pp.part[PS_AGI] += need - x;
            pp.agis++;
            x = need;
        }
        if (uops > 1) {
            x += (uint64_t)(uops - 1);
            pp.part[PS_UOP2] += (uint64_t)(uops - 1);
        }
        /* What it writes may be used in an address: by an instruction in
         * X three cycles later if the ALU made it, two if it was loaded. */
        if (wr >= 0) pp.addr_ok[wr] = x + (load ? 2 : 3);
        if (wr2 >= 0) pp.addr_ok[wr2] = x + 3;
        if (sp_calc) pp.addr_ok[4] = x + 3;
    }
    pp.part[PS_BASE] += 1;
    pp.cyc += x - pp.x;
    pp.x = x;
    pp.n++;
    pp.p.v = 1; pp.p.kind = kind; pp.p.len = len; pp.p.hit = hit;
    pp.p.lin = lin; pp.p.eip = eip; pp.p.target = (uint32_t)is_call;

    if (getenv("M86_PIPE_N") && pp.n >= strtoull(getenv("M86_PIPE_N"), NULL, 0)) {
        m86_pipe_report();              /* that part of the run only */
        pp.on = 0;
        return;
    }
    if (pp.n % 100000000 == 0) {
        pipe_line("the last hundred million", 100000000, pp.cyc - pp.last_cyc);
        pp.last_cyc = pp.cyc;
    }
#undef SER
}

#endif
