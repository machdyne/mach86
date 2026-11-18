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
#include "Vm86b_core.h"
#include "Vm86b_core___024root.h"
typedef Vm86b_core Vcore;
#define R(sig) top->rootp->m86b_core__DOT__##sig
#define GPR(i) ((uint32_t)(R(rf0)[i] | R(rf1)[i] << 8 | R(rf2)[i] << 16 \
                           | (uint32_t)R(rf3)[i] << 24))
#define EIP() R(lk_eip)
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

static pc B;                    /* the devices behind the RTL core */
static Vcore *top;
static unsigned long long cycles, steps_run, insns;
static int pending_inta;
#ifdef CORE_B
static unsigned long long st_decode, st_miss, st_flush, st_wrap;
static unsigned long long st_probe, st_probes, st_kill;
static unsigned st_gen;
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
            wait_mode = getenv("M86B_WAIT") != NULL;
        if (wait_mode && top->d_req && !top->d_wr && !waited) {
            waited = 1;
            top->d_ack = 0;
            top->d_rdata = 0xDEADBEEFu;
            goto clock;
        }
        waited = 0;
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
    top->clk = 1;
    top->eval();
    if (top->inta)
        pending_inta = 1;
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
static struct { unsigned long long n, cyc; } prof[2][2][0x200][9];
static int prof_rep, prof_mem, prof_op, prof_sub;

static void prof_key(pc *a)
{
    uint32_t at = a->cpu.s.seg[M86_CS].base + a->cpu.s.eip;
    uint8_t b = a->cpu.mem_read(a, at);
    prof_rep = 0;
    for (int k = 0; k < 8; k++) {
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
}

static void prof_report(void)
{
    struct row { int rep, mem, op, sub; unsigned long long n, cyc; };
    std::vector<row> rows;
    unsigned long long total = 0, count = 0;
    for (int r = 0; r < 2; r++)
        for (int m = 0; m < 2; m++)
            for (int o = 0; o < 0x200; o++)
                for (int g = 0; g < 9; g++)
                    if (prof[r][m][o][g].n) {
                        rows.push_back({r, m, o, g, prof[r][m][o][g].n, prof[r][m][o][g].cyc});
                        total += prof[r][m][o][g].cyc;
                        count += prof[r][m][o][g].n;
                    }
    std::sort(rows.begin(), rows.end(),
              [](const row &x, const row &y) { return x.cyc > y.cyc; });
    fprintf(stderr, "profile: %llu instructions, %llu cycles\n"
                    "  opcode        count  share  cycles  share  each\n", count, total);
    for (size_t k = 0; k < rows.size() && k < 60; k++) {
        const row &x = rows[k];
        char name[32];
        snprintf(name, sizeof name, "%s%s%02x%s%c %s", x.rep ? "rep " : "",
                 x.op >= 0x100 ? "0f " : "", x.op & 0xFF, x.sub < 8 ? "/" : "",
                 x.sub < 8 ? '0' + x.sub : ' ', x.mem ? "m" : "");
        fprintf(stderr, "  %-12s %9llu %5.1f%% %9llu %5.1f%% %5.1f\n", name, x.n,
                100.0 * (double)x.n / (double)count, x.cyc,
                100.0 * (double)x.cyc / (double)total, (double)x.cyc / (double)x.n);
    }
}

void lockstep_run(pc *a, uint64_t n)
{
    if (prof_on < 0)
        prof_on = getenv("LOCKSTEP_PROFILE") != NULL;
    while (n > 0 && !pc_stopped(a)) {
        /* The model's machine: one step of pc_run. */
        int a_idle = a->cpu.halted && !a->cpu.irq;
        if (a_idle && !(a->cpu.s.eflags & M86_IF) && !pc_keys_pending(a))
            return;
        if (prof_on)
            prof_key(a);
        unsigned long long cyc0 = cycles;
        pc_run(a, 1);

        /* The RTL's machine: the same step. */
        if (B.reset_request) {
            pc_reset(&B);
            rtl_reset();
        }
        uint32_t steps = 1;
        if (top->halted && !B.cpu.irq) {
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
#ifdef CORE_B
            /* An instruction that ends with a store is done a cycle
             * before the store is known to be allowed. If it is not,
             * the fault is being raised now, and its delivery is the
             * step. */
            top->eval();
            if (R(flt_now)) {
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
#endif
        }
        if (prof_on && cycles != cyc0) {
            prof[prof_rep][prof_mem][prof_op][prof_sub].n++;
            prof[prof_rep][prof_mem][prof_op][prof_sub].cyc += cycles - cyc0;
        }
        pc_devices(&B, steps);
        steps_run++;
        compare(a);
        n = n > steps ? n - steps : 0;
    }
}

void lockstep_report(void)
{
    if (prof_on > 0)
        prof_report();
    fprintf(stderr, "lockstep: %llu steps compared, no difference; "
                    "%llu instructions in %llu clock cycles (%.1f per instruction)\n",
            steps_run, insns, cycles, insns ? (double)cycles / (double)insns : 0.0);
#ifdef CORE_B
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
