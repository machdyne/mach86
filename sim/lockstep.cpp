/*
 * Mach86 -- the RTL core in lockstep with the reference model.
 *
 * Two complete machines run side by side from the same BIOS and disk
 * image: one with the C CPU model, one with the RTL core
 * (rtl/cpu/m86_core.v) under Verilator in front of the same C device
 * models. After every step -- an instruction, a fault or an interrupt
 * -- the two CPUs' registers are compared, and the run stops at the
 * first difference (docs/verification.md, layer 3).
 *
 * Built into m86pc as `rtlpc`: the same command line and scripts.
 */
#include <cstdio>
#include <vector>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#ifdef CORE_B
/* Design B (rtl/cpu/m86b_core.v): one data bus with an I/O flag, and
 * its registers under other names. */
#ifdef CORE_C
/* Design C (rtl/cpu/m86c_core.v) has design B's ports and, so far, its
 * signals. */
#include "Vm86c_core.h"
#include "Vm86c_core___024root.h"
typedef Vm86c_core Vcore;
#define R(sig) top->rootp->m86c_core__DOT__##sig
#define RFLT R(flt_now_n)        /* (flt_now itself is a cut there) */
#else
#include "Vm86b_core.h"
#include "Vm86b_core___024root.h"
typedef Vm86b_core Vcore;
#define R(sig) top->rootp->m86b_core__DOT__##sig
#define RFLT R(flt_now)
#endif
#define GPR0(i) ((uint32_t)(R(rf0)[i] | R(rf1)[i] << 8 | R(rf2)[i] << 16 \
                           | (uint32_t)R(rf3)[i] << 24))
#ifdef CORE_C
/* (Design C keeps ESP in a register of its own.) */
/* (A write by the three-clock part is made a cycle after its tick:
 * until then it is in rfp_*.) */
static inline uint32_t gpr_c(Vcore *t, int i);
#define GPR(i) ((i) == 4 ? (uint32_t)R(esp_now) : gpr_c(top, (i)))
#else
#define GPR(i) GPR0(i)
#endif
#ifdef CORE_C
#define EIP() R(lk_eip)
#else
/* (A load whose data is still to come has moved on to the next
 * instruction already: it is where it began until then.) */
#define EIP() (R(lp_v) ? R(i_eip) : R(lk_eip))
#endif
#define SEL(i) R(seg_sel)[i]
#define STOPPED() 0
#else
#include "Vm86_core.h"
#include "Vm86_core___024root.h"
typedef Vm86_core Vcore;
#define R(sig) top->rootp->m86_core__DOT__##sig
#define GPR(i) R(gprs)[i]
#define EIP() R(eip)
#define SEL(i) ((R(ssel)[(i) / 2] >> (16 * ((i) % 2))) & 0xFFFF)
#define STOPPED() (top->shutdown || top->unsupported)
#endif
extern "C" {
#include "pc.h"
void lockstep_attach(pc *a, const char *bios, const char *disk);
void lockstep_run(pc *a, uint64_t n);
void lockstep_key(int ch);
void lockstep_report(void);
}

#ifdef CORE_FPU
#define FR(sig) top->rootp->m86c_core__DOT__gfp__DOT__fpu__DOT__##sig
#endif
static pc B;                    /* the devices behind the RTL core */
static Vcore *top;
#ifdef CORE_C
static inline uint32_t gpr_c(Vcore *t, int i)
{
    uint32_t v = GPR0(i);
    if (R(rfp_v) && !R(fast) && R(rfp_wa) == (unsigned)i) {
        uint32_t m = 0;
        for (int k = 0; k < 4; k++)
            if (R(rfp_lane) & (1 << k)) m |= 0xFFu << (8 * k);
        v = (v & ~m) | (R(rfp_wd) & m);
    }
    return v;
}
#endif
static unsigned long long cycles, steps_run, insns;
static int pending_inta;
#ifdef CORE_B
static unsigned long long st_decode, st_miss, st_flush, st_wrap;
static unsigned long long st_probe, st_probes, st_kill;
static unsigned st_gen;
#endif

static unsigned long long st_pipe;        /* design C: instructions through its pipeline */
static unsigned long long st_abort;       /* design C: cycles with an instruction in X that the pipeline gives up */
static unsigned long long st_pairs;       /* design B: two instructions ended in one cycle */
static unsigned long long st_withdrawn;   /* reads taken off the bus unanswered (M86B_WAIT) */


#if defined(CORE_B) && !defined(CORE_C)
/* ---- where the cycles go, by cause (LOCKSTEP_PROFILE) ----
 * Every cycle of design B is put in one class, from the core's
 * prof_st; and every uop that completes is looked at for what a
 * pipelined engine would have to wait for (docs/cpu_b.md, round 38). */
enum { C_RESET, C_HALT, C_FLUSH, C_PROBE, C_HOLD, C_PAGE, C_EVENT, C_JT, C_DECODE,
       C_ROMWAIT, C_STWAIT, C_LDWAIT, C_LDADDR, C_SHEXTRA, C_MULEXTRA, C_DIV,
       C_EXEC1, C_EXECROM, C_EXECINT, C_OTHER, C_N };
static const char *const c_name[C_N] = {
    "the reset microcode", "halted", "emptying the instruction cache",
    "looking for cached code beside a store", "the speed control and DMA",
    "the paging unit", "starting a fault or an interrupt", "a jump to a computed address",
    "decoding (the cache missed)", "waiting for the microcode ROM",
    "a store the memory is not ready for", "a load's data not there yet",
    "a load's first cycle (the address)", "a shift's two extra cycles",
    "a multiply's two extra cycles", "dividing",
    "running an instruction's first uop", "running a uop from the ROM",
    "running a uop of a fault's or interrupt's delivery", "other" };
static unsigned long long c_cyc[C_N];
static int c_on;
/* uops completed, by unit; and the dependences between neighbours. */
static unsigned long long u_n, u_unit_n[8], u_first;
static unsigned long long d_agi_x1, d_agi_x2, d_agi_l1;   /* a pipeline's address waits */
static unsigned long long d_ld, d_ld_dep;                 /* loads; ... whose next uop needs the result */
static unsigned long long o_n, o_multi, o_dep, o_ptr, o_wr, o_free, o_free2;
static struct { int dest, kind, mem2, flags; } u_p1 = {-1, 0, 0, 0}, u_p2 = {-1, 0, 0, 0};

static void prof_cycle(uint32_t st, uint64_t uop)
{
    int c;
    int unit = (int)((uop >> 23) & 7);
    if (st & (1u << 24)) c = C_RESET;
    else if (st & 1u) c = C_HALT;
    else if (st & 2u) c = C_FLUSH;
    else if (st & 4u) c = C_PROBE;
    else if (st & 8u) c = C_HOLD;
    else if (st & 0x10u) c = C_PAGE;
    else if (st & 0x20u) c = C_EVENT;
    else if (st & 0x40u) c = C_JT;
    else if (st & (1u << 29)) c = C_LDWAIT;
    else if (st & 0x80u) c = C_DECODE;
    else if (!(st & 0x100u)) c = (st & (1u << 16)) ? C_ROMWAIT : C_OTHER;
    else if (st & 0x200u) c = C_STWAIT;
    else if (st & 0x800u) c = C_LDWAIT;
    else if (st & 0x1000u) c = (st & 0x2000u) ? (unit == 6 ? C_MULEXTRA : C_SHEXTRA) : C_LDADDR;
    else if (st & 0x4000u) c = C_DIV;
    else if (st & (1u << 25)) c = C_PAGE;
    else if (!(st & 0x400u)) c = C_OTHER;
    else if (st & 0x8000u) c = C_EXEC1;
    else c = (st & (1u << 17)) ? C_EXECINT : C_EXECROM;
    c_cyc[c]++;
    if (!((st & 0x400u) && !(st & (1u << 18))))
        return;
    /* A uop completes. */
    int a = (int)(uop & 15), b = (int)((uop >> 4) & 15), cr = (int)((uop >> 8) & 15);
    int d = (int)((uop >> 12) & 15), dwe = (int)((uop >> 16) & 1);
    int aop = (int)((uop >> 26) & 15), fm = (int)((uop >> 30) & 3);
    int br = (int)((uop >> 40) & 7), cc = (int)((uop >> 43) & 15), idx = (int)((uop >> 47) & 1);
    int is_mem = (st >> 19) & 1, is_lea = (st >> 20) & 1;
    u_n++; u_unit_n[unit]++;
    if (st & 0x8000u) u_first++;
    int ar[2] = {-1, -1}, dr[3] = {-1, -1, -1};
    if (is_mem || is_lea) { ar[0] = a; if (idx) ar[1] = b; }
    switch (unit) {
    case 0: dr[0] = a; dr[1] = b; break;
    case 1: dr[0] = a; break;
    case 3: dr[0] = cr; break;
    case 4: if ((aop & 3) == 0) dr[0] = cr; break;
    case 5: dr[0] = a; dr[1] = b; dr[2] = cr; break;
    case 6: dr[0] = a; dr[1] = b; break;
    case 7: if (!is_lea) { dr[0] = a; dr[1] = b; dr[2] = cr; } break;
    }
    if (br == 7 && (cc & 3) == 0) dr[2] = cr;
    int uses_fl = (br == 1) || ((st >> 22) & 1);
    /* A pipeline with the address a stage before the memory and the
     * ALU a stage after it: an address made of what the uop before
     * computed waits two cycles, of what it loaded one, of what the
     * uop before that computed one. */
    int w = 0;
    for (int k = 0; k < 2; k++) {
        int r = ar[k];
        if (r < 0 || r == 8) continue;
        if (r == u_p1.dest) w = std::max(w, u_p1.kind == 2 ? 3 : u_p1.kind == 1 ? 1 : 0);
        else if (r == u_p2.dest && u_p2.kind == 2) w = std::max(w, 2);
    }
    if (w == 3) d_agi_x1++; else if (w == 2) d_agi_x2++; else if (w == 1) d_agi_l1++;
    /* Design B with the next uop begun while a load's data is on its
     * way: not if that uop needs what is loaded. */
    if (u_p1.mem2) {
        int dep = 0;
        for (int k = 0; k < 2; k++) if (ar[k] >= 0 && ar[k] != 8 && ar[k] == u_p1.dest) dep = 1;
        for (int k = 0; k < 3; k++) if (dr[k] >= 0 && dr[k] != 8 && dr[k] == u_p1.dest) dep = 1;
        if (u_p1.flags && uses_fl) dep = 1;
        d_ld++;
        if (dep) d_ld_dep++;
    }
    /* After a load that is a whole instruction: could the next
     * instruction's uop run in the load's second cycle? Not if it is
     * not a one-uop instruction from the cache (A), needs what is
     * loaded (B), or writes a register in its own first cycle, when
     * the load's data is written (C: a pointer it moves; D: a result). */
    {
        static int el = 0, el_dest = -1;
        if (el) {
            int single = (st & 0x8000u) && (st & (1u << 23));
            int dep = 0;
            for (int k = 0; k < 2; k++) if (ar[k] >= 0 && ar[k] != 8 && ar[k] == el_dest) dep = 1;
            for (int k = 0; k < 3; k++) if (dr[k] >= 0 && dr[k] != 8 && dr[k] == el_dest) dep = 1;
            int aupd = (int)((uop >> 39) & 1);
            int two = (unit == 2 || unit == 3 || unit == 5 || unit == 6);
            o_n++;
            if (!single) o_multi++;
            else if (dep) o_dep++;
            else if ((unit == 2 || unit == 3 || unit == 4) && aupd) o_ptr++;
            else if (!two && unit != 4 && dwe && d != 8) o_wr++;
            else { o_free++; if (two) o_free2++; }
        }
        el = (st & 0x8000u) && (st & (1u << 23)) && unit == 2 && br == 0 && fm == 0 &&
             ((uop >> 32) & 7) != 7;
        el_dest = (dwe && d != 8) ? d : -1;
    }
    u_p2 = u_p1;
    u_p1.dest = (dwe && unit != 4 && d != 8) ? d : -1;
    u_p1.kind = is_lea ? 0 : unit == 2 ? 1 : 2;     /* 0: known with the address, 1: loaded, 2: computed */
    u_p1.mem2 = (unit == 2 || unit == 3);
    u_p1.flags = (unit == 3) && fm != 0;
}

/* ---- what a branch predictor would get wrong ----
 * One entry for each entry of the instruction cache (2,048, by the
 * low bits of the address): a two-bit counter for a conditional jump,
 * the last target for a jump through a register or memory; and a
 * stack of eight return addresses. */
static struct { uint32_t tag, tgt; uint8_t v, ctr; } bp_t[2048];
static uint32_t bp_ras[8];
static int bp_sp;
static unsigned long long bp_cond, bp_cond_tk, bp_cond_mp, bp_dir, bp_ret, bp_ret_mp, bp_ind, bp_ind_mp;
/* The instruction cache with other ways of choosing an entry: how
 * often each would miss (stores into code not counted). 0: as it is,
 * the low 11 bits of the address; 1: those XOR the 11 above them;
 * 2: 4,096 entries by the low 12 bits; 3: XOR bits 11-21 and 22-31. */
static uint32_t ic_tag[4][4096];
static unsigned long long ic_miss[4];
static void ic_step(uint32_t lin, int count)
{
    unsigned idx[4] = { lin & 2047, (lin ^ (lin >> 11)) & 2047, lin & 4095,
                        (lin ^ (lin >> 11) ^ (lin >> 22)) & 2047 };
    for (int k = 0; k < 4; k++) {
        if (ic_tag[k][idx[k]] != lin + 1) {
            ic_tag[k][idx[k]] = lin + 1;
            if (count) ic_miss[k]++;
        }
    }
}
/* The data cache in front of the main memory (rtl/soc/m86_dcache.v:
 * direct-mapped, lines of 16 bytes), in five sizes, and one of two
 * ways: how often each would miss, and how often the line it puts
 * out had been written. Video memory and the ROMs are not behind it. */
#define MC_N 6
static const unsigned mc_lines[MC_N] = { 1024, 2048, 4096, 8192, 16384, 2048 };
static struct { uint32_t tag[2]; uint8_t dirty[2], lru; } mc_t[MC_N][16384];
static unsigned long long mc_acc, mc_miss[MC_N], mc_dirty[MC_N];
static int mc_on;
static void mc_line(uint32_t line, int wr, int count)
{
    for (int k = 0; k < MC_N; k++) {
        if (k == MC_N - 1) {
            unsigned i = line & 1023;       /* two ways of 1,024 */
            int w = mc_t[k][i].tag[0] == line + 1 ? 0 : mc_t[k][i].tag[1] == line + 1 ? 1 : -1;
            if (w < 0) {
                w = mc_t[k][i].lru;
                if (count) { mc_miss[k]++; if (mc_t[k][i].dirty[w]) mc_dirty[k]++; }
                mc_t[k][i].tag[w] = line + 1; mc_t[k][i].dirty[w] = 0;
            }
            mc_t[k][i].lru = !w;
            if (wr) mc_t[k][i].dirty[w] = 1;
        } else {
            unsigned i = line & (mc_lines[k] - 1);
            if (mc_t[k][i].tag[0] != line + 1) {
                if (count) { mc_miss[k]++; if (mc_t[k][i].dirty[0]) mc_dirty[k]++; }
                mc_t[k][i].tag[0] = line + 1; mc_t[k][i].dirty[0] = 0;
            }
            if (wr) mc_t[k][i].dirty[0] = 1;
        }
    }
}
static void mc_access(uint32_t addr, int n, int wr, int count)
{
    if (addr >= 0xA0000 && addr < 0x100000) return;
    if (count) mc_acc++;
    mc_line(addr >> 4, wr, count);
    if (((addr + n - 1) >> 4) != (addr >> 4))
        mc_line((addr + n - 1) >> 4, wr, count);
}
static int bp_kind, bp_os32;
static uint32_t bp_at, bp_seq;
static void bp_step(pc *a, int count)
{
    if (!bp_kind) return;
    uint32_t now = a->cpu.s.seg[M86_CS].base + a->cpu.s.eip;
    unsigned i = bp_at & 2047;
    int hit = bp_t[i].v && bp_t[i].tag == bp_at;
    if (bp_kind == 1) {
        int taken = now != bp_seq;
        int pred = hit && bp_t[i].ctr >= 2;
        if (count) { bp_cond++; bp_cond_tk += taken; if (pred != taken) bp_cond_mp++; }
        if (!hit) { bp_t[i].v = 1; bp_t[i].tag = bp_at; bp_t[i].ctr = taken ? 2 : 1; }
        else if (taken && bp_t[i].ctr < 3) bp_t[i].ctr++;
        else if (!taken && bp_t[i].ctr > 0) bp_t[i].ctr--;
    } else if (bp_kind == 2 || bp_kind == 3) {
        if (count) bp_dir++;
    } else if (bp_kind == 4) {
        uint32_t top_ = bp_ras[(bp_sp + 7) & 7];
        bp_sp = (bp_sp + 7) & 7;
        if (count) { bp_ret++; if (top_ != now) bp_ret_mp++; }
    } else {
        if (count) { bp_ind++; if (!(hit && bp_t[i].tgt == now)) bp_ind_mp++; }
        bp_t[i].v = 1; bp_t[i].tag = bp_at; bp_t[i].tgt = now;
    }
    if (bp_kind == 3 || bp_kind == 6) {
        /* A call: what it pushed is where its return will go. */
        uint32_t sp = a->cpu.s.seg[M86_SS].base +
                      (a->cpu.s.seg[M86_SS].d ? a->cpu.s.r[4] : (a->cpu.s.r[4] & 0xFFFF));
        uint32_t ra = 0;
        for (int k = 0; k < (bp_os32 ? 4 : 2); k++)
            ra |= (uint32_t)a->cpu.mem_read(a, sp + k) << (8 * k);
        bp_ras[bp_sp] = a->cpu.s.seg[M86_CS].base + ra;
        bp_sp = (bp_sp + 1) & 7;
    }
}
#endif

static void cycle(void)
{
    top->clk = 0;
    top->irq = B.cpu.irq;
    {
        /* M86B_SLOW=n: the speed control, to see that waiting between
         * instructions changes nothing but the time. */
        static int slow = -1;
        if (slow < 0)
            slow = getenv("M86B_SLOW") ? atoi(getenv("M86B_SLOW")) : 0;
#ifdef CORE_B
        top->slow = slow;
        /* M86B_DMA=n: ask the core for a byte of memory every n cycles,
         * as the Sound Blaster does. Nothing may change but the time. */
        static int dma = -1, dma_n = 0;
        if (dma < 0)
            dma = getenv("M86B_DMA") ? atoi(getenv("M86B_DMA")) : 0;
        if (top->dma_ack)
            top->dma_req = 0;
        else if (dma && ++dma_n >= dma) {
            dma_n = 0;
            top->dma_req = 1;
            top->dma_addr = 0x5000 + (rand() & 0xFFF);
        }
#else
        (void)slow;         /* the first core has no speed control */
#endif
    }
#ifdef CORE_C
    {
        /* M86C_ABORT=n: one cycle in n, at random, the pipeline is made
         * to give up the instruction in its M1 stage, as it does for a
         * store into a block that holds code. */
        static int ab = -1;
        if (ab < 0)
            ab = getenv("M86C_ABORT") ? atoi(getenv("M86C_ABORT")) : 0;
        R(tst_abort) = ab && (rand() % ab) == 0;
    }
#endif
    top->eval();
    if (pending_inta) {
        top->irq_vec = (uint8_t)B.cpu.irq_ack(&B);
        pending_inta = 0;
    }
#ifdef CORE_B
    top->d_ack = 1;
    /* With M86B_STRDY set, the memory is not ready for a write about a
     * third of the time, at random, as a cache with a full queue. */
    {
        static int rdy_mode = -1;
        static unsigned lfsr = 0xACE1u;
        if (rdy_mode < 0)
            rdy_mode = getenv("M86B_STRDY") != NULL;
        lfsr = (lfsr >> 1) ^ (-(lfsr & 1u) & 0xB400u);
        top->d_st_rdy = rdy_mode ? (lfsr % 3 != 0) : 1;
    }
    /* With M86B_WAIT set, a read is answered a cycle late, with
     * rubbish on the data lines until then, as a synchronous memory
     * would. Writes take one cycle either way. */
    {
        static int wait_mode = -1, waited;
        if (wait_mode < 0)
            wait_mode = getenv("M86B_WAIT") ? atoi(getenv("M86B_WAIT")) : 0;
        /* A memory that has begun on a read gives its answer to
         * whatever read is on the bus when it is ready: so a read that
         * has been on the bus unanswered must stay there, the same,
         * until it is answered. (The SoC's cache is such a memory;
         * design C's pipeline once took reads back.) With M86B_WAIT=n,
         * n over 1, the wait is 1 to n cycles, at random. */
        static int pend, left;
        static uint32_t p_addr;
        static int p_size, p_io;
        int rd = top->d_req && !top->d_wr;
        if (pend && !(rd && top->d_addr == p_addr && top->d_size == p_size && top->d_io == p_io)) {
            if (st_withdrawn++ < 5)
                fprintf(stderr, "lockstep: a read of %08x was taken off the bus unanswered "
                        "(cycle %llu, now %s %08x)\n", p_addr, cycles,
                        rd ? "a read of" : top->d_req ? "a write to" : "nothing,", top->d_addr);
            pend = 0;
        }
        (void)waited;
        if (wait_mode && rd && !pend) {
            pend = 1;
            left = wait_mode > 1 ? 1 + rand() % wait_mode : 1;
            p_addr = top->d_addr; p_size = top->d_size; p_io = top->d_io;
        }
        if (pend && left > 0) {
            left--;
            top->d_ack = 0;
            top->d_rdata = 0xDEADBEEFu;
            goto clock;
        }
        pend = 0;
    }
    if (top->d_req && top->d_io && (uint16_t)top->d_addr == 0x1E8) {
        /* The paging unit's own port: what it read a byte at a time. */
        if (!top->d_wr)
            top->d_rdata = top->x_rd;
    } else if (top->d_req && top->d_io) {
        if (top->d_wr)
            B.cpu.io_write(&B, (uint16_t)top->d_addr, 1 << top->d_size, top->d_wdata);
        else
            top->d_rdata = B.cpu.io_read(&B, (uint16_t)top->d_addr, 1 << top->d_size);
    } else if (top->d_req) {
        int n = 1 << top->d_size;
#if defined(CORE_B) && !defined(CORE_C)
        if (mc_on)
            mc_access(top->d_addr, n, top->d_wr, c_on);
#endif
        if (top->d_wr) {
            for (int i = 0; i < n; i++)
                B.cpu.mem_write(&B, top->d_addr + i,
                                (uint8_t)(top->d_wdata >> (8 * i)));
        } else {
            uint32_t v = 0;
            for (int i = 0; i < n; i++)
                v |= (uint32_t)B.cpu.mem_read(&B, top->d_addr + i) << (8 * i);
            top->d_rdata = v;
        }
    }
#else
    top->mem_ack = 1;
    top->io_ack = 1;
    if (top->mem_req) {
        if (top->mem_wr) {
            for (int i = 0; i < top->mem_size; i++)
                B.cpu.mem_write(&B, top->mem_addr + i,
                                (uint8_t)(top->mem_wdata >> (8 * i)));
        } else {
            uint32_t v = 0;
            for (int i = 0; i < top->mem_size; i++)
                v |= (uint32_t)B.cpu.mem_read(&B, top->mem_addr + i) << (8 * i);
            top->mem_rdata = v;
        }
    }
    if (top->io_req) {
        if (top->io_wr)
            B.cpu.io_write(&B, top->io_addr, top->io_size, top->io_wdata);
        else
            top->io_rdata = B.cpu.io_read(&B, top->io_addr, top->io_size);
    }
#endif
#ifdef CORE_B
clock:
#endif
    top->eval();
#if defined(CORE_B) && !defined(CORE_C)
    if (c_on)
        prof_cycle(R(prof_st), R(prof_uop));
    {
        /* LOCKSTEP_TRACE=n: a line for every cycle from step n on. */
        static long long tr = -2;
        if (tr == -2)
            tr = getenv("LOCKSTEP_TRACE") ? atoll(getenv("LOCKSTEP_TRACE")) : -1;
        if (tr >= 0 && (long long)steps_run >= tr)
            fprintf(stderr, "trace: step %llu cycle %llu irq %d st %08x unit %d lk_eip %08x i_eip %08x "
                            "lp_v %d cyc2 %d d_req %d d_wr %d d_addr %08x ack %d\n",
                    steps_run, cycles, (int)top->irq, (unsigned)R(prof_st),
                    (int)((R(prof_uop) >> 23) & 7), (unsigned)R(lk_eip), (unsigned)R(i_eip),
                    (int)R(lp_v), (int)R(cyc2), (int)top->d_req, (int)top->d_wr,
                    (unsigned)top->d_addr, (int)top->d_ack);
    }
#endif
    top->clk = 1;
    top->eval();
    if (top->inta)
        pending_inta = 1;
#if defined(CORE_B) && !defined(CORE_C)
    if (top->step_done)
        insns += top->step_two;
#endif
#ifdef CORE_B
    if (top->step_done)
#else
    if (top->insn_done)
#endif
        insns++;
    cycles++;
#ifdef CORE_B
    /* Where the cycles go. */
    if (R(ds) != 0)
        st_decode++;
#ifdef CORE_C
    if (R(f_sd))
        st_pipe++;
    if (R(fx_v) && R(fx_bad))
        st_abort++;
#endif
    if (R(probing))
        st_probe++;
    if (R(probe_take))
        st_probes++;
    if (R(p_kill))
        st_kill++;
    if (R(miss))
        st_miss++;
    if (R(gen) != st_gen) {
        st_gen = R(gen);
        st_flush++;
    }
    if (R(flushing) && R(fl_idx) == 0)
        st_wrap++;
#endif
}

static void rtl_reset(void)
{
    top->rst = 1;
    cycle();
    cycle();
    top->rst = 0;
#ifdef CORE_B
    /* Reset continues in microcode. */
    for (int i = 0; i < 200 && R(rst_seq); i++)
        cycle();
#endif
    pending_inta = 0;
}

void lockstep_attach(pc *a, const char *bios, const char *disk)
{
    (void)a;
    pc_init(&B);
    B.conv_size = a->conv_size;
    if (pc_load_bios(&B, bios)) {
        fprintf(stderr, "lockstep: cannot load BIOS\n");
        exit(2);
    }
    if (disk) {
        /* The second machine writes to its own copy of the disk. */
        char copy[1024], cmd[2200];
        snprintf(copy, sizeof copy, "%s.rtl", disk);
        snprintf(cmd, sizeof cmd, "cp '%s' '%s'", disk, copy);
        if (system(cmd) || pc_attach_disk(&B, copy)) {
            fprintf(stderr, "lockstep: cannot copy the disk image\n");
            exit(2);
        }
        B.sd.sectors = a->sd.sectors;   /* as -card may have set it */
    }
    top = new Vcore;
#ifndef CORE_B
    top->nmi = 0;
    /* The first core is a 386 and says so; the model is a 486SX now. */
    a->cpu.s.r[M86_EDX] = 0x0300;
#endif
    top->irq = 0;
    top->irq_vec = 0;
    rtl_reset();
}

void lockstep_key(int ch)
{
    pc_key_ascii(&B, ch);
}

static void mismatch(const pc *a, const char *what, uint32_t model, uint32_t rtl)
{
    static const int order[8] = { 0, 3, 1, 2, 6, 7, 5, 4 };
    static const char *const name[8] = { "eax", "ecx", "edx", "ebx",
                                         "esp", "ebp", "esi", "edi" };
    fprintf(stderr, "\nlockstep: after step %llu, %s differs: "
                    "model %08x, RTL %08x\n", steps_run, what, model, rtl);
    fprintf(stderr, "  model: %04x:%08x flags=%05x",
            a->cpu.s.seg[M86_CS].sel, a->cpu.s.eip, a->cpu.s.eflags);
    for (int i = 0; i < 8; i++)
        fprintf(stderr, " %s=%08x", name[order[i]], a->cpu.s.r[order[i]]);
    fprintf(stderr, "\n  RTL:   %04x:%08x flags=%05x",
            SEL(1), EIP(), R(fl));
    for (int i = 0; i < 8; i++)
        fprintf(stderr, " %s=%08x", name[order[i]], GPR(order[i]));
#ifdef CORE_B
    fprintf(stderr, "\n  RTL's last fault: %02x (ff: none)", top->last_exc);
    fprintf(stderr, "; last bus address %08x, data read %08x; ss %04x; "
                    "cache generation %x",
            top->d_addr, top->d_rdata, SEL(2), R(gen));
#endif
    fprintf(stderr, "\n  the instruction before, at %04x:%08x:",
            a->cpu.snap.seg[M86_CS].sel, a->cpu.snap.eip);
    for (int i = 0; i < 12; i++)
        fprintf(stderr, " %02x",
                a->cpu.mem_read((void *)a, a->cpu.snap.seg[M86_CS].base
                                           + a->cpu.snap.eip + (uint32_t)i));
    fprintf(stderr, "\n");
    exit(1);
}

static void compare(const pc *a)
{
    static const char *const name[8] = { "eax", "ecx", "edx", "ebx",
                                         "esp", "ebp", "esi", "edi" };
    static const char *const sname[6] = { "es", "cs", "ss", "ds", "fs", "gs" };
    const m86 *c = &a->cpu;
    for (int i = 0; i < 8; i++)
        if (c->s.r[i] != GPR(i))
            mismatch(a, name[i], c->s.r[i], GPR(i));
    if (c->s.eip != EIP())
        mismatch(a, "eip", c->s.eip, EIP());
    if ((c->s.eflags & 0x77FD7) != (R(fl) & 0x77FD7))
        mismatch(a, "eflags", c->s.eflags, R(fl));
    for (int i = 0; i < 6; i++) {
        uint32_t sel = SEL(i);
        if (c->s.seg[i].sel != sel)
            mismatch(a, sname[i], c->s.seg[i].sel, sel);
    }
#ifdef CORE_FPU
    /* The floating-point unit: control and status words, which
     * registers are empty, and the registers. */
    {
        if (c->fp.cw != FR(cw))
            mismatch(a, "the FPU's control word", c->fp.cw, FR(cw));
        if (c->fp.sw != FR(sw))
            mismatch(a, "the FPU's status word", c->fp.sw, FR(sw));
        if (c->fp.empty != FR(empty))
            mismatch(a, "the FPU's empty registers", c->fp.empty, FR(empty));
        if (c->fp.fip != FR(fip))
            mismatch(a, "the FPU's instruction pointer", c->fp.fip, FR(fip));
        if (c->fp.fdp != FR(fdp))
            mismatch(a, "the FPU's operand pointer", c->fp.fdp, FR(fdp));
        if (c->fp.fcs != FR(fcs) || c->fp.fds != FR(fds))
            mismatch(a, "the FPU's pointers' segments (CS, DS)", (uint32_t)c->fp.fcs << 16 | c->fp.fds,
                     (uint32_t)FR(fcs) << 16 | FR(fds));
        if (c->fp.fop != FR(fop))
            mismatch(a, "the FPU's opcode", c->fp.fop, FR(fop));
        for (int i = 0; i < 8; i++) {
            uint64_t m = FR(st)[i][0] | ((uint64_t)FR(st)[i][1] << 32);
            unsigned se = FR(st)[i][2] & 0xFFFF;
            if (c->fp.st[i].m != m || c->fp.st[i].se != se) {
                fprintf(stderr, "\nlockstep: FPU register %d: model %04x %016llx, RTL %04x %016llx",
                        i, c->fp.st[i].se, (unsigned long long)c->fp.st[i].m, se, (unsigned long long)m);
                mismatch(a, "an FPU register (its exponent word)", c->fp.st[i].se, se);
            }
        }
    }
#endif
#ifdef CORE_B
    /* What a segment load leaves behind, and the system registers. */
    for (int i = 0; i < 6; i++) {
        if (c->s.seg[i].base != R(seg_base)[i])
            mismatch(a, "a segment base", c->s.seg[i].base, R(seg_base)[i]);
        if (i == 1 && c->s.seg[i].d != R(cs_d))
            mismatch(a, "the code segment's D bit", c->s.seg[i].d, R(cs_d));
        if (i == 2 && c->s.seg[i].d != R(ss_b))
            mismatch(a, "the stack segment's B bit", c->s.seg[i].d, R(ss_b));
        if (c->s.seg[i].limit != R(seg_lim)[i])
            mismatch(a, "a segment limit", c->s.seg[i].limit, R(seg_lim)[i]);
    }
    if (c->cr0 != R(cr0))
        mismatch(a, "CR0", c->cr0, R(cr0));
    if (c->s.cpl != R(cpl))
        mismatch(a, "the privilege level", c->s.cpl, R(cpl));
    if (c->gdtr.base != R(gdt_base) || c->gdtr.limit != R(gdt_lim))
        mismatch(a, "GDTR", c->gdtr.base, R(gdt_base));
    if (c->idtr.base != R(idt_base) || c->idtr.limit != R(idt_lim))
        mismatch(a, "IDTR", c->idtr.base, R(idt_base));
#endif
    if ((c->halted != 0) != (top->halted != 0))
        mismatch(a, "halted", (uint32_t)c->halted, top->halted);
    /* With LOCKSTEP_MEM set, the low megabyte of memory is compared
     * too, after every step. Slow, and it finds a wrong store at once. */
    static int mem_check = -1;
    if (mem_check < 0)
        mem_check = getenv("LOCKSTEP_MEM") != NULL;
    if (mem_check && memcmp(a->ram, B.ram, 0xA0000)) {
        uint32_t i = 0;
        while (a->ram[i] == B.ram[i])
            i++;
        fprintf(stderr, "\nlockstep: memory differs at %05x\n", i);
        mismatch(a, "memory", a->ram[i], B.ram[i]);
    }
}

/* ---- where the cycles go, by instruction (LOCKSTEP_PROFILE=1) ----
 * The key: the opcode after its prefixes (100h more for the 0Fh map),
 * the ModRM reg field for the group opcodes, and whether the operand
 * is memory. REP is kept apart. */
static int prof_on = -1;
static struct { unsigned long long n, cyc, dec; } prof[2][2][0x200][9];
static unsigned long long prof_from, prof_hist[40];
static int prof_rep, prof_mem, prof_op, prof_sub;
#ifdef CORE_C
/* Design C: instructions that did not go through the pipeline, by opcode. */
static unsigned long long slow_n[2][0x200][9], slow_all;
#endif

static void prof_key(pc *a)
{
    uint32_t at = a->cpu.s.seg[M86_CS].base + a->cpu.s.eip;
    uint8_t b = a->cpu.mem_read(a, at);
    prof_rep = 0;
    int pfx66 = 0;
    for (int k = 0; k < 8; k++) {
        if (b == 0x66) pfx66 = 1;
        if (b == 0xF2 || b == 0xF3) prof_rep = 1;
        else if (!(b == 0x26 || b == 0x2E || b == 0x36 || b == 0x3E || b == 0x64 ||
                   b == 0x65 || b == 0x66 || b == 0x67 || b == 0xF0))
            break;
        b = a->cpu.mem_read(a, ++at);
    }
    prof_op = b;
    if (b == 0x0F) {
        b = a->cpu.mem_read(a, ++at);
        prof_op = 0x100 + b;
    }
    uint8_t modrm = a->cpu.mem_read(a, at + 1);
    int o = prof_op;
    int has_modrm = (o < 0x40 && (o & 7) < 4) || (o >= 0x62 && o <= 0x63) ||
                    o == 0x69 || o == 0x6B || (o >= 0x80 && o <= 0x8F) ||
                    o == 0xC0 || o == 0xC1 || o == 0xC4 || o == 0xC5 || o == 0xC6 ||
                    o == 0xC7 || (o >= 0xD0 && o <= 0xD3) || (o >= 0xD8 && o <= 0xDF) ||
                    o == 0xF6 || o == 0xF7 || o == 0xFE || o == 0xFF ||
                    (o >= 0x100 && !(o >= 0x180 && o <= 0x18F) && o != 0x1A0 &&
                     o != 0x1A1 && o != 0x1A8 && o != 0x1A9);
    int group = (o >= 0x80 && o <= 0x83) || o == 0xC0 || o == 0xC1 ||
                (o >= 0xD0 && o <= 0xD3) || o == 0xF6 || o == 0xF7 || o == 0xFE ||
                o == 0xFF;
    prof_mem = has_modrm && (modrm >> 6) != 3;
    prof_sub = group ? ((modrm >> 3) & 7) : 8;
#if defined(CORE_B) && !defined(CORE_C)
    {
        uint32_t start = a->cpu.s.seg[M86_CS].base + a->cpu.s.eip;
        int os32 = a->cpu.s.seg[M86_CS].d ^ pfx66;
        int r = (modrm >> 3) & 7;
        bp_at = start; bp_os32 = os32; bp_kind = 0;
        ic_step(start, steps_run >= prof_from);
        if ((o >= 0x70 && o <= 0x7F) || (o >= 0xE0 && o <= 0xE3)) {
            bp_kind = 1; bp_seq = at + 2;
        } else if (o >= 0x180 && o <= 0x18F) {
            bp_kind = 1; bp_seq = at + 1 + (os32 ? 4 : 2);
        } else if (o == 0xEB || o == 0xE9) bp_kind = 2;
        else if (o == 0xE8) bp_kind = 3;
        else if (o == 0xC3 || o == 0xC2) bp_kind = 4;
        else if (o == 0xFF && r == 4) bp_kind = 5;
        else if (o == 0xFF && r == 2) bp_kind = 6;
    }
#endif
}

static void prof_report(void)
{
    struct row { int rep, mem, op, sub; unsigned long long n, cyc, dec; };
    std::vector<row> rows;
    unsigned long long total = 0, count = 0;
    for (int r = 0; r < 2; r++)
        for (int m = 0; m < 2; m++)
            for (int o = 0; o < 0x200; o++)
                for (int g = 0; g < 9; g++)
                    if (prof[r][m][o][g].n) {
                        rows.push_back({r, m, o, g, prof[r][m][o][g].n, prof[r][m][o][g].cyc, prof[r][m][o][g].dec});
                        total += prof[r][m][o][g].cyc;
                        count += prof[r][m][o][g].n;
                    }
    std::sort(rows.begin(), rows.end(),
              [](const row &x, const row &y) { return x.cyc > y.cyc; });
    fprintf(stderr, "profile: %llu instructions, %llu cycles\n"
                    "  opcode        count  share  cycles  share  each  each without decoding\n", count, total);
    for (size_t k = 0; k < rows.size() && k < 60; k++) {
        const row &x = rows[k];
        char name[32];
        snprintf(name, sizeof name, "%s%s%02x%s%c %s", x.rep ? "rep " : "",
                 x.op >= 0x100 ? "0f " : "", x.op & 0xFF, x.sub < 8 ? "/" : "",
                 x.sub < 8 ? '0' + x.sub : ' ', x.mem ? "m" : "");
        fprintf(stderr, "  %-12s %9llu %5.1f%% %9llu %5.1f%% %5.1f %5.2f\n", name, x.n,
                100.0 * (double)x.n / (double)count, x.cyc,
                100.0 * (double)x.cyc / (double)total, (double)x.cyc / (double)x.n,
                (double)(x.cyc - x.dec) / (double)x.n);
    }
    fprintf(stderr, "cycles per instruction, histogram:");
    for (int k = 1; k < 40; k++)
        if (prof_hist[k])
            fprintf(stderr, " %d%s:%.1f%%", k, k == 39 ? "+" : "",
                    100.0 * (double)prof_hist[k] / (double)count);
    fprintf(stderr, "\n");
#if defined(CORE_B) && !defined(CORE_C)
    {
        unsigned long long all = 0;
        for (int c = 0; c < C_N; c++) all += c_cyc[c];
        double n = (double)count;
        fprintf(stderr, "cycles by what they were spent on (%llu):\n", all);
        for (int c = 0; c < C_N; c++)
            if (c_cyc[c])
                fprintf(stderr, "  %-52s %10llu %5.1f%%  %.3f an instruction\n", c_name[c], c_cyc[c],
                        100.0 * (double)c_cyc[c] / (double)all, (double)c_cyc[c] / n);
        static const char *const un[8] = {"ALU", "ALU with immediate", "load", "load-and-operate",
                                          "store", "shift", "multiply", "special"};
        fprintf(stderr, "uops completed: %llu (%.2f an instruction), %llu of them an instruction's first from the cache\n",
                u_n, (double)u_n / n, u_first);
        for (int k = 0; k < 8; k++)
            fprintf(stderr, "  %-20s %10llu %5.1f%%\n", un[k], u_unit_n[k], 100.0 * (double)u_unit_n[k] / (double)u_n);
        fprintf(stderr, "loads whose next uop needs what they load: %llu of %llu (%.0f%%)\n",
                d_ld_dep, d_ld, d_ld ? 100.0 * (double)d_ld_dep / (double)d_ld : 0.0);
        fprintf(stderr, "one-uop loads from the cache: %llu (%.3f an instruction). The uop after: not a one-uop "
                        "instruction from the cache %.1f%%, needs the load %.1f%%, moves a pointer %.1f%%, "
                        "writes a result %.1f%%, none of these %.1f%% (%.1f%% of them two-cycle uops)\n",
                o_n, (double)o_n / n, 100.0 * o_multi / (double)o_n, 100.0 * o_dep / (double)o_n,
                100.0 * o_ptr / (double)o_n, 100.0 * o_wr / (double)o_n, 100.0 * o_free / (double)o_n,
                o_free ? 100.0 * o_free2 / (double)o_free : 0.0);
        fprintf(stderr, "the instruction cache would miss: as it is %.2f%% of instructions; by the low bits XOR the "
                        "next eleven %.2f%%; with 4,096 entries %.2f%%; XOR all the upper bits %.2f%%\n",
                100.0 * ic_miss[0] / n, 100.0 * ic_miss[1] / n, 100.0 * ic_miss[2] / n, 100.0 * ic_miss[3] / n);
        fprintf(stderr, "the data cache: %llu accesses to main memory (%.2f an instruction)\n", mc_acc, mc_acc / n);
        for (int k = 0; k < MC_N; k++)
            fprintf(stderr, "  %3u KB%s: %9llu misses (%.3f%% of accesses, %.5f an instruction), %llu of them put a written line back (%.0f%%)\n",
                    mc_lines[k] * 16 / 1024, k == MC_N - 1 ? ", two ways" : "", mc_miss[k],
                    100.0 * mc_miss[k] / (double)mc_acc, mc_miss[k] / n, mc_dirty[k],
                    mc_miss[k] ? 100.0 * mc_dirty[k] / (double)mc_miss[k] : 0.0);
        fprintf(stderr, "addresses made of the uop before's result: computed %llu, loaded %llu; "
                        "of the one before that, computed: %llu\n", d_agi_x1, d_agi_l1, d_agi_x2);
        unsigned long long tk = bp_cond_tk + bp_dir + bp_ret + bp_ind;
        fprintf(stderr, "jumps: conditional %llu (%.1f%% of instructions; %.0f%% taken; predicted wrong %llu, %.1f%%); "
                        "direct %llu; returns %llu (wrong %llu); through a register or memory %llu (wrong %llu)\n",
                bp_cond, 100.0 * (double)bp_cond / n,
                bp_cond ? 100.0 * (double)bp_cond_tk / (double)bp_cond : 0.0, bp_cond_mp,
                bp_cond ? 100.0 * (double)bp_cond_mp / (double)bp_cond : 0.0,
                bp_dir, bp_ret, bp_ret_mp, bp_ind, bp_ind_mp);
        /* What other engines would take for the same work. */
        unsigned long long mp = bp_cond_mp + bp_ret_mp + bp_ind_mp;
        unsigned long long keep = all - c_cyc[C_HALT] - c_cyc[C_RESET];
        unsigned long long same = keep - c_cyc[C_LDADDR] - c_cyc[C_SHEXTRA];
        fprintf(stderr, "design B, not counting halted cycles: %.3f cycles an instruction\n", (double)keep / n);
        fprintf(stderr, "  ... with the next uop begun under a load's second cycle: %.3f\n",
                (double)(keep - (d_ld - d_ld_dep)) / n);
        fprintf(stderr, "  ... with one-cycle shifts as well: %.3f\n",
                (double)(keep - (d_ld - d_ld_dep) - c_cyc[C_SHEXTRA]) / n);
        for (int pen = 2; pen <= 4; pen++) {
            unsigned long long wait = 2 * d_agi_x1 + d_agi_x2 + d_agi_l1;
            fprintf(stderr, "a pipeline (address, memory, ALU), %d cycles lost by a jump predicted wrong: "
                            "%.3f with the predictor, %.3f with none (every taken jump)\n", pen,
                    (double)(same + wait + pen * mp) / n, (double)(same + wait + pen * tk) / n);
        }
    }
#endif
}

void lockstep_run(pc *a, uint64_t n)
{
    if (prof_on < 0) {
        prof_on = getenv("LOCKSTEP_PROFILE") != NULL;
        /* LOCKSTEP_PROFILE=n: the profile and the counts start after n
         * steps, to look at one part of a run. */
        prof_from = prof_on ? strtoull(getenv("LOCKSTEP_PROFILE"), NULL, 0) : 0;
#if defined(CORE_B) && !defined(CORE_C)
        mc_on = prof_on;
#endif
    }
    while (n > 0 && !pc_stopped(a)) {
        /* The model's machine: one step of pc_run. */
        int a_idle = a->cpu.halted && !a->cpu.irq;
        if (a_idle && !(a->cpu.s.eflags & M86_IF) && !pc_keys_pending(a))
            return;
        if (prof_on)
            prof_key(a);
#ifdef CORE_B
        if (prof_on && prof_from > 1 && steps_run == prof_from)
            cycles = insns = st_decode = st_miss = st_probe = st_probes = st_kill = 0;
        unsigned long long dec0 = st_decode;
#else
        unsigned long long dec0 = 0, st_decode = 0;
#endif
        unsigned long long cyc0 = cycles;
#if defined(CORE_B) && !defined(CORE_C)
        /* The second of two instructions that design B ended in one
         * cycle (a load, and the instruction after it beside the
         * load's second cycle): no interrupt could come between them
         * there, so none may here. */
        /* The same when the step before was a load and the instruction
         * after it has begun beside the load's second cycle, though it
         * has not ended: it will, before any interrupt is taken. */
        static int pair, begun;
        int second = pair;
        pair = 0;
        if (second || begun)
            a->cpu.irq_inhibit = 1;
        begun = 0;
#else
        const int second = 0;
        int pair = 0;
#endif
        pc_run(a, 1);
#if defined(CORE_B) && !defined(CORE_C)
        if (prof_on) {
            bp_step(a, steps_run >= prof_from);
            c_on = steps_run >= prof_from;
        }
#endif

        /* The RTL's machine: the same step. */
        if (B.reset_request) {
            pc_reset(&B);
            rtl_reset();
        }
        uint32_t steps = 1;
        if (second) {
            /* (Done already, with the step before.) */
        } else if (top->halted && !B.cpu.irq) {
            steps = B.insn_per_tick;
        } else {
            int guard = 0;
            do {
                cycle();
                if (++guard > 5000000 || STOPPED()) {
                    fprintf(stderr, "lockstep: the RTL core stopped or hung "
                                    "at step %llu\n", steps_run);
                    exit(1);
                }
            } while (!top->step_done);
#if defined(CORE_B) && !defined(CORE_C)
            pair = top->step_two;
#endif
#ifdef CORE_B
            /* An instruction that ends with a store is done a cycle
             * before the store is known to be allowed. If it is not,
             * the fault is being raised now, and its delivery is the
             * step. */
            top->eval();
            if (RFLT) {
                do {
                    cycle();
                    if (++guard > 5000000 || STOPPED()) {
                        fprintf(stderr, "lockstep: the RTL core stopped or hung "
                                        "at step %llu\n", steps_run);
                        exit(1);
                    }
                } while (!top->step_done);
            }
            /* An instruction that ends with a store has asked for it
             * but the bus cycle is the next one. Do the memory write
             * now so that memory can be compared; doing it again in
             * the next cycle changes nothing. */
            top->eval();
            if (top->d_req && top->d_wr && !top->d_io)
                for (int i = 0; i < (1 << top->d_size); i++)
                    B.cpu.mem_write(&B, top->d_addr + i,
                                    (uint8_t)(top->d_wdata >> (8 * i)));
#ifndef CORE_C
            /* (Or its decoding has: in_rom.) */
            begun = R(lp_v) || R(cyc2) || R(cyc3) || R(in_rom);
#endif
#endif
        }
#ifdef CORE_C
        if (prof_on && cycles != cyc0 && steps_run >= prof_from && !R(f_sd)) {
            slow_n[prof_mem][prof_op][prof_sub]++;
            slow_all++;
        }
#endif
        if (prof_on && (cycles != cyc0 || second) && steps_run >= prof_from) {
            prof[prof_rep][prof_mem][prof_op][prof_sub].n++;
            prof[prof_rep][prof_mem][prof_op][prof_sub].cyc += cycles - cyc0;
            prof[prof_rep][prof_mem][prof_op][prof_sub].dec += st_decode - dec0;
            unsigned long long k = cycles - cyc0 - (st_decode - dec0);
            prof_hist[k > 39 ? 39 : k]++;
        }
        pc_devices(&B, steps);
        steps_run++;
        if (!pair)
            compare(a);
        else
            st_pairs++;
        n = n > steps ? n - steps : 0;
    }
}

void lockstep_report(void)
{
    if (st_withdrawn)
        fprintf(stderr, "lockstep: %llu reads were taken off the bus unanswered\n", st_withdrawn);
    if (prof_on > 0)
        prof_report();
    fprintf(stderr, "lockstep: %llu steps compared, no difference; "
                    "%llu instructions in %llu clock cycles (%.1f per instruction)\n",
            steps_run, insns, cycles, insns ? (double)cycles / (double)insns : 0.0);
#ifdef CORE_B
    #ifdef CORE_C
        fprintf(stderr, "design C: %llu instructions were given up by the pipeline for the three-clock part\n", st_abort);
        fprintf(stderr, "design C: %llu of %llu instructions went through the pipeline (%.0f%%)\n",
                st_pipe, insns, insns ? 100.0 * (double)st_pipe / (double)insns : 0.0);
        if (slow_all) {
            fprintf(stderr, "design C: not through the pipeline, by opcode (m: memory form; /n: ModRM reg):");
            for (int k = 0; k < 24; k++) {
                int bm = 0, bo = 0, bs = 0;
                for (int m = 0; m < 2; m++)
                    for (int o = 0; o < 0x200; o++)
                        for (int g = 0; g < 9; g++)
                            if (slow_n[m][o][g] > slow_n[bm][bo][bs]) { bm = m; bo = o; bs = g; }
                if (!slow_n[bm][bo][bs]) break;
                fprintf(stderr, " %s%02x", bo & 0x100 ? "0f " : "", bo & 0xFF);
                if (bs < 8) fprintf(stderr, "/%d", bs);
                fprintf(stderr, "%s %.1f%%", bm ? " m" : "", 100.0 * (double)slow_n[bm][bo][bs] / (double)insns);
                slow_n[bm][bo][bs] = 0;
            }
            fprintf(stderr, "\n");
        }
#endif
        fprintf(stderr, "design B: %llu loads ended in the same cycle as the instruction after them\n", st_pairs);
        fprintf(stderr, "design B: %llu instructions decoded (%.1f%% of those run), "
                    "%llu cycles decoding (%.0f%%); the cache was emptied %llu times, "
                    "%llu of them by clearing it\n",
            st_miss, insns ? 100.0 * (double)st_miss / (double)insns : 0.0,
            st_decode, cycles ? 100.0 * (double)st_decode / (double)cycles : 0.0,
            st_flush, st_wrap);
    fprintf(stderr, "design B: %llu stores beside cached code looked for entries "
                    "to remove (%llu cycles, %.0f%%) and removed %llu\n",
            st_probes, st_probe, cycles ? 100.0 * (double)st_probe / (double)cycles : 0.0,
            st_kill);
#endif
}

double sc_time_stamp(void)
{
    return 0;
}
