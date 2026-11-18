/*
 * Mach86 reference model -- CPU, 386 instruction set in real mode.
 *
 * Sources: I386-PRM ch. 14 (real mode), ch. 17 (instruction set),
 * ch. 9 (exceptions); I86-UM. Behaviour the manuals leave undefined
 * follows the hardware-captured 386 vectors (docs/verification.md).
 */
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include "m86.h"

#define R(i)        (c->s.r[i])
#define FLAGS       (c->s.eflags)
#define MASK(sz)    ((sz) == 1 ? 0xFFu : (sz) == 2 ? 0xFFFFu : 0xFFFFFFFFu)
#define MSB(sz)     ((sz) == 1 ? 0x80u : (sz) == 2 ? 0x8000u : 0x80000000u)

/* Bits of EFLAGS that exist on a 386. Bit 1 always reads as one. */
#define EFLAGS_MASK 0x00077FD5u     /* with AC, bit 18: a 486's */

enum { EXC_DE = 0, EXC_DB = 1, EXC_BP = 3, EXC_OF = 4, EXC_BR = 5,
       EXC_UD = 6, EXC_NM = 7, EXC_DF = 8, EXC_TS = 10, EXC_NP = 11,
       EXC_SS = 12, EXC_GP = 13, EXC_PF = 14 };

const char *const m86_class_name[M86_CL_COUNT] = {
    "register to register", "load", "arithmetic with memory source",
    "store", "read-modify-write", "conditional jump, taken",
    "conditional jump, not taken", "push/pop", "call/return/jump",
    "slow path"
};

/* Cycle targets by instruction class (docs/model.md). */
const double m86_class_cycles[M86_CL_COUNT] = {
    1, 1, 2, 1, 3, 3, 1, 1, 3, 8
};

/* ---- faults ---------------------------------------------------- */

static void fault_e(m86 *c, int vec, uint32_t err)
{
    c->err = err;
    longjmp(c->fault_jmp, vec + 1);
}

static void fault(m86 *c, int vec)
{
    fault_e(c, vec, 0);
}

/* ---- memory ---------------------------------------------------- */

#define PMODE_CHECKS ((c->cr0 & 1) && !(c->s.eflags & M86_VM))

/* A linear address through the page tables. `user` is an access made
 * at level 3; the tables of the processor itself are read as level 0.
 * A level-0 write ignores read-only pages unless CR0.WP is set. */
static uint32_t translate(m86 *c, uint32_t la, int write, int user)
{
    uint32_t pa = (c->cr3 & 0xFFFFF000u) + ((la >> 22) << 2);
    uint32_t pde = 0, pte = 0, ta = 0;
    int present = 0;
    for (int i = 0; i < 4; i++)
        pde |= (uint32_t)c->mem_read(c->bus, pa + i) << (8 * i);
    if (pde & 1) {
        ta = (pde & 0xFFFFF000u) + (((la >> 12) & 0x3FF) << 2);
        for (int i = 0; i < 4; i++)
            pte |= (uint32_t)c->mem_read(c->bus, ta + i) << (8 * i);
        present = pte & 1;
    }
    uint32_t both = pde & pte;
    if (!present || (user && !(both & 4)) ||
        (write && !(both & 2) && (user || (c->cr0 & 0x10000u)))) {
        c->cr2 = la;
        fault_e(c, EXC_PF, (uint32_t)(present | (write << 1) | (user << 2)));
    }
    if (!(pde & 0x20))
        c->mem_write(c->bus, pa, (uint8_t)(pde | 0x20));
    if ((pte & 0x20) == 0 || (write && !(pte & 0x40)))
        c->mem_write(c->bus, ta, (uint8_t)(pte | 0x20 | (write ? 0x40 : 0)));
    return (pte & 0xFFFFF000u) | (la & 0xFFF);
}

static uint32_t lin_rd(m86 *c, uint32_t a, int size, int user)
{
    uint32_t v = 0;
    if (c->cr0 & 0x80000000u) {
        if ((a & 0xFFF) + (uint32_t)size <= 0x1000) {
            a = translate(c, a, 0, user);
        } else {
            for (int i = 0; i < size; i++)
                v |= (uint32_t)c->mem_read(c->bus, translate(c, a + i, 0, user)) << (8 * i);
            return v;
        }
    }
    for (int i = 0; i < size; i++)
        v |= (uint32_t)c->mem_read(c->bus, a + i) << (8 * i);
    return v;
}

static void lin_wr(m86 *c, uint32_t a, int size, uint32_t v, int user)
{
    if (c->cr0 & 0x80000000u) {
        if ((a & 0xFFF) + (uint32_t)size <= 0x1000) {
            a = translate(c, a, 1, user);
        } else {
            /* Both pages are checked before either is written. */
            translate(c, a, 1, user);
            translate(c, a + (uint32_t)size - 1, 1, user);
            for (int i = 0; i < size; i++)
                c->mem_write(c->bus, translate(c, a + i, 1, user), (uint8_t)(v >> (8 * i)));
            return;
        }
    }
    for (int i = 0; i < size; i++)
        c->mem_write(c->bus, a + i, (uint8_t)(v >> (8 * i)));
}

/* The processor's own reads and writes: descriptor tables, the TSS. */
#define phys_rd(c, a, n)    lin_rd(c, a, n, 0)
#define phys_wr(c, a, n, v) lin_wr(c, a, n, v, 0)

/* Segment and offset to a linear address, with the checks. how: 0
 * read, 1 write, 2 fetch. */
static uint32_t linear(m86 *c, int seg, uint32_t off, int size, int how)
{
    const m86_seg *s = &c->s.seg[seg];
    uint32_t last = off + (uint32_t)size - 1;
    int vec = seg == M86_SS ? EXC_SS : EXC_GP;
    if (PMODE_CHECKS) {
        if (s->null || (how == 1 && s->nw) || (how == 0 && s->nr))
            fault_e(c, EXC_GP, 0);
        if (s->ed) {
            uint32_t top = s->d ? 0xFFFFFFFFu : 0xFFFFu;
            if (off <= s->limit || last > top || last < off)
                fault_e(c, vec, 0);
            return s->base + off;
        }
    }
    if (off > s->limit || last > s->limit || last < off)
        fault_e(c, vec, 0);
    return s->base + off;
}

static uint32_t rd_mem(m86 *c, int seg, uint32_t off, int size)
{
    return lin_rd(c, linear(c, seg, off, size, 0), size, c->s.cpl == 3);
}

static void wr_mem(m86 *c, int seg, uint32_t off, int size, uint32_t v)
{
    lin_wr(c, linear(c, seg, off, size, 1), size, v, c->s.cpl == 3);
}

/* ---- instruction fetch ----------------------------------------- */

static uint8_t fetch8(m86 *c)
{
    if (++c->len > 15)
        fault(c, EXC_GP);
    uint8_t v = (uint8_t)lin_rd(c, linear(c, M86_CS, c->s.eip, 1, 2), 1, c->s.cpl == 3);
    c->s.eip++;
    return v;
}

static uint32_t fetch(m86 *c, int size)
{
    uint32_t v = 0;
    for (int i = 0; i < size; i++)
        v |= (uint32_t)fetch8(c) << (8 * i);
    return v;
}

static int32_t fetch_s(m86 *c, int size)
{
    uint32_t v = fetch(c, size);
    return size == 1 ? (int8_t)v : size == 2 ? (int16_t)v : (int32_t)v;
}

/* ---- registers ------------------------------------------------- */

static uint32_t rd_reg(m86 *c, int size, int i)
{
    if (size == 1)
        return (i < 4 ? R(i) : R(i - 4) >> 8) & 0xFF;
    return R(i) & MASK(size);
}

static void wr_reg(m86 *c, int size, int i, uint32_t v)
{
    if (size == 1) {
        if (i < 4)
            R(i) = (R(i) & ~0xFFu) | (v & 0xFF);
        else
            R(i - 4) = (R(i - 4) & ~0xFF00u) | ((v & 0xFF) << 8);
    } else if (size == 2) {
        R(i) = (R(i) & ~0xFFFFu) | (v & 0xFFFF);
    } else {
        R(i) = v;
    }
}

void m86_set_seg_real(m86 *c, int seg, uint16_t sel)
{
    m86_seg *s = &c->s.seg[seg];
    s->sel = sel;
    s->base = (uint32_t)sel << 4;
    s->nw = s->nr = s->ed = s->cc = s->null = 0;
    s->dpl = (c->cr0 & 1) ? 3 : 0;
}

/* ---- ModRM ----------------------------------------------------- */

static void decode_modrm(m86 *c)
{
    uint8_t b = fetch8(c);
    c->mod = b >> 6;
    c->reg = (b >> 3) & 7;
    c->rm = b & 7;
    if (c->mod == 3)
        return;

    int seg = M86_DS;
    uint32_t off = 0;

    if (!c->as32) {
        switch (c->rm) {
        case 0: off = R(M86_EBX) + R(M86_ESI); break;
        case 1: off = R(M86_EBX) + R(M86_EDI); break;
        case 2: off = R(M86_EBP) + R(M86_ESI); seg = M86_SS; break;
        case 3: off = R(M86_EBP) + R(M86_EDI); seg = M86_SS; break;
        case 4: off = R(M86_ESI); break;
        case 5: off = R(M86_EDI); break;
        case 6:
            if (c->mod == 0) {
                off = fetch(c, 2);
            } else {
                off = R(M86_EBP);
                seg = M86_SS;
            }
            break;
        case 7: off = R(M86_EBX); break;
        }
        if (c->mod == 1)
            off += (uint32_t)fetch_s(c, 1);
        else if (c->mod == 2)
            off += fetch(c, 2);
        off &= 0xFFFF;
    } else {
        if (c->rm == 4) {
            uint8_t sib = fetch8(c);
            int scale = sib >> 6, index = (sib >> 3) & 7, base = sib & 7;
            uint32_t disp32 = 0;
            int has_base = !(base == 5 && c->mod == 0);
            if (has_base) {
                off = R(base);
                if (base == M86_ESP || base == M86_EBP)
                    seg = M86_SS;
            } else {
                disp32 = fetch(c, 4);
            }
            if (index != 4)
                off += R(index) << scale;
            else
                /* No index but a scale: not a documented encoding. The
                 * hardware scales the base, and the vectors expect it. */
                off <<= scale;
            off += disp32;
        } else if (c->rm == 5 && c->mod == 0) {
            off = fetch(c, 4);
        } else {
            off = R(c->rm);
            if (c->rm == M86_EBP)
                seg = M86_SS;
        }
        if (c->mod == 1)
            off += (uint32_t)fetch_s(c, 1);
        else if (c->mod == 2)
            off += fetch(c, 4);
    }
    c->ea_seg = c->seg_ovr >= 0 ? c->seg_ovr : seg;
    c->ea_off = off;
}

/* Offset of the second part of a two-part memory operand. With 16-bit
 * addressing it wraps within 64K. */
static uint32_t ea_plus(const m86 *c, int n)
{
    uint32_t off = c->ea_off + (uint32_t)n;
    return c->as32 ? off : (off & 0xFFFF);
}

static uint32_t rd_rm(m86 *c, int size)
{
    if (c->mod == 3)
        return rd_reg(c, size, c->rm);
    return rd_mem(c, c->ea_seg, c->ea_off, size);
}

static void wr_rm(m86 *c, int size, uint32_t v)
{
    if (c->mod == 3)
        wr_reg(c, size, c->rm, v);
    else
        wr_mem(c, c->ea_seg, c->ea_off, size, v);
}

/* ---- stack ----------------------------------------------------- */

/* Real mode: the stack pointer is SP. */
/* The stack pointer is SP or ESP, as the stack segment's descriptor said. */
#define SP_MASK (c->s.seg[M86_SS].d ? 0xFFFFFFFFu : 0xFFFFu)

static void push(m86 *c, int size, uint32_t v)
{
    uint32_t sp = (R(M86_ESP) - (uint32_t)size) & SP_MASK;
    wr_mem(c, M86_SS, sp, size, v);
    R(M86_ESP) = (R(M86_ESP) & ~SP_MASK) | sp;
}

static uint32_t pop(m86 *c, int size)
{
    uint32_t sp = R(M86_ESP) & SP_MASK;
    uint32_t v = rd_mem(c, M86_SS, sp, size);
    R(M86_ESP) = (R(M86_ESP) & ~SP_MASK) | ((sp + (uint32_t)size) & SP_MASK);
    return v;
}

/* A segment register on the stack takes an operand-sized slot, but
 * only the 16-bit selector is written or read. */
static void push_seg(m86 *c, int seg)
{
    uint32_t sp = (R(M86_ESP) - (uint32_t)c->os) & SP_MASK;
    wr_mem(c, M86_SS, sp, 2, c->s.seg[seg].sel);
    R(M86_ESP) = (R(M86_ESP) & ~SP_MASK) | sp;
}

static uint16_t pop_seg(m86 *c)
{
    uint32_t sp = R(M86_ESP) & SP_MASK;
    uint32_t v = rd_mem(c, M86_SS, sp, 2);
    R(M86_ESP) = (R(M86_ESP) & ~SP_MASK) | ((sp + (uint32_t)c->os) & SP_MASK);
    return (uint16_t)v;
}

/* ---- flags ----------------------------------------------------- */

static void set_flag(m86 *c, uint32_t f, int on)
{
    if (on)
        FLAGS |= f;
    else
        FLAGS &= ~f;
}

static int parity(uint32_t v)
{
    v &= 0xFF;
    v ^= v >> 4;
    v ^= v >> 2;
    v ^= v >> 1;
    return !(v & 1);
}

static void set_szp(m86 *c, uint32_t r, int size)
{
    r &= MASK(size);
    set_flag(c, M86_ZF, r == 0);
    set_flag(c, M86_SF, (r & MSB(size)) != 0);
    set_flag(c, M86_PF, parity(r));
}

static void write_flags(m86 *c, uint32_t v, uint32_t change)
{
    FLAGS = ((FLAGS & ~change) | (v & change)) & EFLAGS_MASK;
    FLAGS |= 2;
}

/* op: 0 ADD, 1 OR, 2 ADC, 3 SBB, 4 AND, 5 SUB, 6 XOR, 7 CMP */
static uint32_t alu(m86 *c, int op, uint32_t a, uint32_t b, int size)
{
    uint32_t m = MASK(size), s = MSB(size), r, cf = FLAGS & M86_CF;
    uint64_t w;
    a &= m;
    b &= m;
    switch (op) {
    case 0: case 2:
        if (op == 0)
            cf = 0;
        w = (uint64_t)a + b + cf;
        r = (uint32_t)w & m;
        set_flag(c, M86_CF, (w >> (8 * size)) & 1);
        set_flag(c, M86_OF, ((a ^ r) & (b ^ r) & s) != 0);
        set_flag(c, M86_AF, ((a ^ b ^ r) & 0x10) != 0);
        break;
    case 3: case 5: case 7:
        if (op != 3)
            cf = 0;
        w = (uint64_t)a - b - cf;
        r = (uint32_t)w & m;
        set_flag(c, M86_CF, (w >> (8 * size)) & 1);
        set_flag(c, M86_OF, ((a ^ b) & (a ^ r) & s) != 0);
        set_flag(c, M86_AF, ((a ^ b ^ r) & 0x10) != 0);
        break;
    default:
        r = op == 1 ? (a | b) : op == 4 ? (a & b) : (a ^ b);
        FLAGS &= ~(M86_CF | M86_OF | M86_AF);
        break;
    }
    set_szp(c, r, size);
    return r;
}

static uint32_t incdec(m86 *c, uint32_t a, int dec, int size)
{
    uint32_t cf = FLAGS & M86_CF;
    uint32_t r = alu(c, dec ? 5 : 0, a, 1, size);
    FLAGS = (FLAGS & ~M86_CF) | cf;
    return r;
}

/* op: 0 ROL, 1 ROR, 2 RCL, 3 RCR, 4 SHL, 5 SHR, 6 SHL, 7 SAR */
static uint32_t shift(m86 *c, int op, uint32_t v, uint32_t cnt, int size)
{
    int bits = 8 * size;
    uint32_t m = MASK(size), s = MSB(size), r, cf = FLAGS & M86_CF;
    uint32_t n;
    v &= m;
    cnt &= 31;
    if (cnt == 0)
        return v;

    switch (op) {
    case 0:
        n = cnt % (uint32_t)bits;
        r = n ? ((v << n) | (v >> (bits - n))) & m : v;
        cf = r & 1;
        set_flag(c, M86_OF, ((r & s) != 0) ^ cf);
        set_flag(c, M86_CF, cf);
        return r;
    case 1:
        n = cnt % (uint32_t)bits;
        r = n ? ((v >> n) | (v << (bits - n))) & m : v;
        set_flag(c, M86_CF, (r & s) != 0);
        set_flag(c, M86_OF, ((r & s) != 0) ^ ((r & (s >> 1)) != 0));
        return r;
    case 2:
        n = cnt % (uint32_t)(bits + 1);
        r = v;
        for (uint32_t i = 0; i < n; i++) {
            uint32_t out = (r & s) != 0;
            r = ((r << 1) | cf) & m;
            cf = out;
        }
        set_flag(c, M86_CF, cf);
        set_flag(c, M86_OF, ((r & s) != 0) ^ cf);
        return r;
    case 3:
        n = cnt % (uint32_t)(bits + 1);
        r = v;
        for (uint32_t i = 0; i < n; i++) {
            uint32_t out = r & 1;
            r = (r >> 1) | (cf ? s : 0);
            cf = out;
        }
        set_flag(c, M86_CF, cf);
        set_flag(c, M86_OF, ((r & s) != 0) ^ ((r & (s >> 1)) != 0));
        return r;
    case 4: case 6: {
        uint64_t w = (uint64_t)v << cnt;
        r = (uint32_t)w & m;
        cf = (w >> bits) & 1;
        /* Byte operand, count of 16 or 24: the hardware reports the
         * carry of a count of 8. */
        if (size == 1 && (cnt == 16 || cnt == 24))
            cf = v & 1;
        set_flag(c, M86_CF, cf);
        set_flag(c, M86_OF, ((r & s) != 0) ^ cf);
        break;
    }
    case 5:
        set_flag(c, M86_CF, ((uint64_t)v >> (cnt - 1)) & 1);
        if (size == 1 && (cnt == 16 || cnt == 24))
            set_flag(c, M86_CF, (v & s) != 0);
        r = v >> cnt;
        /* For a count of one this is the old sign bit, as documented. */
        set_flag(c, M86_OF, ((r & (s >> 1)) != 0));
        break;
    default: {
        int64_t sv = size == 1 ? (int8_t)v : size == 2 ? (int16_t)v : (int32_t)v;
        set_flag(c, M86_CF, (sv >> (cnt - 1)) & 1);
        r = (uint32_t)(sv >> cnt) & m;
        set_flag(c, M86_OF, 0);
        break;
    }
    }
    set_szp(c, r, size);
    FLAGS &= ~M86_AF;
    return r;
}

static int cond(m86 *c, int cc)
{
    uint32_t f = FLAGS;
    int r;
    switch (cc >> 1) {
    case 0: r = (f & M86_OF) != 0; break;
    case 1: r = (f & M86_CF) != 0; break;
    case 2: r = (f & M86_ZF) != 0; break;
    case 3: r = (f & (M86_CF | M86_ZF)) != 0; break;
    case 4: r = (f & M86_SF) != 0; break;
    case 5: r = (f & M86_PF) != 0; break;
    case 6: r = ((f & M86_SF) != 0) != ((f & M86_OF) != 0); break;
    default:
        r = (f & M86_ZF) || (((f & M86_SF) != 0) != ((f & M86_OF) != 0));
        break;
    }
    return r ^ (cc & 1);
}

/* ---- protection ------------------------------------------------- */

/* Protected mode proper: PE set and not in virtual 8086 mode. */
#define PMODE   ((c->cr0 & 1) && !(FLAGS & M86_VM))
#define IOPL    ((int)((FLAGS >> 12) & 3))
#define SELX(s) ((uint32_t)(s) & 0xFFFCu)

static uint32_t desc_addr(m86 *c, uint16_t sel)
{
    return ((sel & 4) ? c->ldtr.base : c->gdtr.base) + (sel & 0xFFF8u);
}

static uint32_t desc_base(uint32_t lo, uint32_t hi)
{
    return (hi & 0xFF000000u) | ((hi & 0xFFu) << 16) | (lo >> 16);
}

static uint32_t desc_limit(uint32_t lo, uint32_t hi)
{
    uint32_t lim = (hi & 0x000F0000u) | (lo & 0xFFFFu);
    if (hi & 0x00800000u)
        lim = (lim << 12) | 0xFFFu;
    return lim;
}

/* The two halves of the descriptor a selector names; 0 if it names
 * none (the null selector, or one outside its table). */
static int descriptor(m86 *c, uint16_t sel, uint32_t *lo, uint32_t *hi)
{
    uint32_t lim = (sel & 4) ? c->ldtr.limit : c->gdtr.limit;
    uint32_t a = desc_addr(c, sel);
    if ((sel & 0xFFFCu) == 0 || (uint32_t)(sel | 7) > lim)
        return 0;
    *lo = phys_rd(c, a, 4);
    *hi = phys_rd(c, a + 4, 4);
    return 1;
}

static void mark_accessed(m86 *c, uint16_t sel, uint32_t hi)
{
    if (!(hi & 0x100))
        phys_wr(c, desc_addr(c, sel) + 5, 1, (hi >> 8) | 1);
}

/* Fill a segment register's hidden part from a descriptor. */
static void seg_cache(m86 *c, int seg, uint16_t sel, uint32_t lo, uint32_t hi)
{
    m86_seg *s = &c->s.seg[seg];
    int code = (hi >> 11) & 1, bit9 = (hi >> 9) & 1, bit10 = (hi >> 10) & 1;
    s->sel = sel;
    s->base = desc_base(lo, hi);
    s->limit = desc_limit(lo, hi);
    s->d = (hi >> 22) & 1;
    s->nw = code || !bit9;
    s->nr = code && !bit9;
    s->ed = !code && bit10;
    s->cc = code && bit10;
    s->dpl = (hi >> 13) & 3;
    s->null = 0;
}

static void seg_v86(m86 *c, int seg, uint16_t sel)
{
    m86_seg *s = &c->s.seg[seg];
    memset(s, 0, sizeof *s);
    s->sel = sel;
    s->base = (uint32_t)sel << 4;
    s->limit = 0xFFFF;
    s->dpl = 3;
}

/* A segment register other than CS is loaded. In real mode and in
 * virtual 8086 mode the base is the selector times 16 and the limit
 * stays what it was. In protected mode the descriptor is fetched and
 * checked against the privilege rules, and base, limit and rights
 * come from it. */
static void set_seg(m86 *c, int seg, uint16_t sel)
{
    if (!PMODE) {
        m86_set_seg_real(c, seg, sel);
        return;
    }
    uint32_t lo, hi;
    int cpl = c->s.cpl, rpl = sel & 3;
    if ((sel & 0xFFFCu) == 0) {
        if (seg == M86_SS)
            fault_e(c, EXC_GP, 0);
        c->s.seg[seg].sel = sel;
        c->s.seg[seg].null = 1;
        return;
    }
    if (!descriptor(c, sel, &lo, &hi))
        fault_e(c, EXC_GP, SELX(sel));
    int S = (hi >> 12) & 1, code = (hi >> 11) & 1, rw = (hi >> 9) & 1;
    int conf = (hi >> 10) & 1, dpl = (hi >> 13) & 3, p = (hi >> 15) & 1;
    if (seg == M86_SS) {
        if (rpl != cpl || !S || code || !rw || dpl != cpl)
            fault_e(c, EXC_GP, SELX(sel));
        if (!p)
            fault_e(c, EXC_SS, SELX(sel));
    } else {
        if (!S || (code && !rw))
            fault_e(c, EXC_GP, SELX(sel));
        if (!(code && conf) && (dpl < cpl || dpl < rpl))
            fault_e(c, EXC_GP, SELX(sel));
        if (!p)
            fault_e(c, EXC_NP, SELX(sel));
    }
    mark_accessed(c, sel, hi);
    seg_cache(c, seg, sel, lo, hi);
}

/* CS is loaded from a descriptor already checked. */
static void load_cs(m86 *c, uint16_t sel, uint32_t lo, uint32_t hi, int cpl, uint32_t eip)
{
    if (eip > desc_limit(lo, hi))
        fault_e(c, EXC_GP, 0);
    mark_accessed(c, sel, hi);
    seg_cache(c, M86_CS, (uint16_t)((sel & 0xFFFCu) | (unsigned)cpl), lo, hi);
    c->s.cpl = (uint8_t)cpl;
    c->s.eip = eip;
}

/* The stack an inner level starts on, from the task state segment. */
static void tss_stack(m86 *c, int dpl, uint16_t *ss, uint32_t *esp)
{
    uint32_t a;
    if (c->tr.t32) {
        a = 4 + 8 * (uint32_t)dpl;
        if (a + 5 > c->tr.limit)
            fault_e(c, EXC_TS, SELX(c->tr.sel));
        *esp = phys_rd(c, c->tr.base + a, 4);
        *ss = (uint16_t)phys_rd(c, c->tr.base + a + 4, 2);
    } else {
        a = 2 + 4 * (uint32_t)dpl;
        if (a + 3 > c->tr.limit)
            fault_e(c, EXC_TS, SELX(c->tr.sel));
        *esp = phys_rd(c, c->tr.base + a, 2);
        *ss = (uint16_t)phys_rd(c, c->tr.base + a + 2, 2);
    }
}

/* Check a selector as the stack segment of level `cpl`; `vec` is the
 * fault a bad one raises (invalid TSS when it came from the TSS). */
static void check_ss(m86 *c, uint16_t sel, int cpl, int vec, uint32_t *lo, uint32_t *hi)
{
    if ((sel & 0xFFFCu) == 0)
        fault_e(c, vec, 0);
    if (!descriptor(c, sel, lo, hi))
        fault_e(c, vec, SELX(sel));
    if ((sel & 3) != cpl || (int)((*hi >> 13) & 3) != cpl ||
        !(*hi & 0x1000) || (*hi & 0x800) || !(*hi & 0x200))
        fault_e(c, vec, SELX(sel));
    if (!(*hi & 0x8000))
        fault_e(c, EXC_SS, SELX(sel));
}

static void set_esp(m86 *c, uint32_t v)
{
    R(M86_ESP) = (R(M86_ESP) & ~SP_MASK) | (v & SP_MASK);
}

/* ---- task switches ---------------------------------------------- */

enum { TS_JMP, TS_CALL, TS_IRET };

static void task_switch(m86 *c, uint16_t sel, int kind)
{
    uint32_t lo, hi;
    if ((sel & 4) || !descriptor(c, sel, &lo, &hi))
        fault_e(c, kind == TS_IRET ? EXC_TS : EXC_GP, SELX(sel));
    int type = (hi >> 8) & 0x1F;
    int want_busy = kind == TS_IRET;
    if ((type & ~8) != (want_busy ? 3 : 1))
        fault_e(c, kind == TS_IRET ? EXC_TS : EXC_GP, SELX(sel));
    if (!(hi & 0x8000))
        fault_e(c, EXC_NP, SELX(sel));
    int n32 = (type >> 3) & 1;
    uint32_t nbase = desc_base(lo, hi), nlim = desc_limit(lo, hi);
    if (nlim < (n32 ? 0x67u : 0x2Bu))
        fault_e(c, EXC_TS, SELX(sel));

    /* Save the outgoing task. */
    uint32_t ob = c->tr.base;
    uint32_t fl = FLAGS;
    if (kind == TS_IRET)
        fl &= ~M86_NT;
    if (c->tr.t32) {
        phys_wr(c, ob + 0x20, 4, c->s.eip);
        phys_wr(c, ob + 0x24, 4, fl);
        for (int i = 0; i < 8; i++)
            phys_wr(c, ob + 0x28 + 4 * (uint32_t)i, 4, R(i));
        for (int i = 0; i < 6; i++)
            phys_wr(c, ob + 0x48 + 4 * (uint32_t)i, 2, c->s.seg[i].sel);
    } else {
        phys_wr(c, ob + 0x0E, 2, c->s.eip);
        phys_wr(c, ob + 0x10, 2, fl);
        for (int i = 0; i < 8; i++)
            phys_wr(c, ob + 0x12 + 2 * (uint32_t)i, 2, R(i));
        for (int i = 0; i < 4; i++)
            phys_wr(c, ob + 0x22 + 2 * (uint32_t)i, 2, c->s.seg[i].sel);
    }
    if (kind != TS_CALL) {
        uint32_t a = c->gdtr.base + (c->tr.sel & 0xFFF8u) + 5;
        phys_wr(c, a, 1, phys_rd(c, a, 1) & ~2u);
    }
    if (kind == TS_CALL)
        phys_wr(c, nbase, 2, c->tr.sel);
    if (kind != TS_IRET)
        phys_wr(c, desc_addr(c, sel) + 5, 1, (hi >> 8) | 2);

    c->tr.sel = sel;
    c->tr.base = nbase;
    c->tr.limit = nlim;
    c->tr.t32 = (uint8_t)n32;
    c->cr0 |= 8;

    /* Load the incoming one. */
    uint32_t nfl, neip, ldt;
    uint16_t sg[6] = { 0, 0, 0, 0, 0, 0 };
    if (n32) {
        if (c->cr0 & 0x80000000u)
            c->cr3 = phys_rd(c, nbase + 0x1C, 4);
        neip = phys_rd(c, nbase + 0x20, 4);
        nfl = phys_rd(c, nbase + 0x24, 4);
        for (int i = 0; i < 8; i++)
            R(i) = phys_rd(c, nbase + 0x28 + 4 * (uint32_t)i, 4);
        for (int i = 0; i < 6; i++)
            sg[i] = (uint16_t)phys_rd(c, nbase + 0x48 + 4 * (uint32_t)i, 2);
        ldt = phys_rd(c, nbase + 0x60, 2);
    } else {
        neip = phys_rd(c, nbase + 0x0E, 2);
        nfl = phys_rd(c, nbase + 0x10, 2);
        for (int i = 0; i < 8; i++)
            R(i) = 0xFFFF0000u | phys_rd(c, nbase + 0x12 + 2 * (uint32_t)i, 2);
        for (int i = 0; i < 4; i++)
            sg[i] = (uint16_t)phys_rd(c, nbase + 0x22 + 2 * (uint32_t)i, 2);
        ldt = phys_rd(c, nbase + 0x2A, 2);
    }
    if (kind == TS_CALL)
        nfl |= M86_NT;
    FLAGS = (nfl & EFLAGS_MASK) | 2;

    c->ldtr.sel = (uint16_t)ldt;
    c->ldtr.base = 0;
    c->ldtr.limit = 0;
    if (ldt & 0xFFFCu) {
        uint32_t a = c->gdtr.base + (ldt & 0xFFF8u);
        uint32_t llo = phys_rd(c, a, 4), lhi = phys_rd(c, a + 4, 4);
        if ((ldt & 4) || ((lhi >> 8) & 0x1F) != 2 || !(lhi & 0x8000))
            fault_e(c, EXC_TS, SELX(ldt));
        c->ldtr.base = desc_base(llo, lhi);
        c->ldtr.limit = desc_limit(llo, lhi);
    }

    if (FLAGS & M86_VM) {
        for (int i = 0; i < 6; i++)
            seg_v86(c, i, sg[i]);
        c->s.cpl = 3;
        c->s.eip = neip & 0xFFFF;
        return;
    }
    uint32_t clo, chi;
    if (!descriptor(c, sg[M86_CS], &clo, &chi) || !(chi & 0x1000) || !(chi & 0x800))
        fault_e(c, EXC_TS, SELX(sg[M86_CS]));
    if (!(chi & 0x8000))
        fault_e(c, EXC_NP, SELX(sg[M86_CS]));
    seg_cache(c, M86_CS, sg[M86_CS], clo, chi);
    c->s.cpl = sg[M86_CS] & 3;
    c->s.eip = neip;
    for (int i = 0; i < 6; i++) {
        if (i == M86_CS)
            continue;
        c->s.seg[i].null = 1;       /* so that a fault leaves it unusable */
        c->s.seg[i].sel = sg[i];
    }
    uint32_t slo, shi;
    check_ss(c, sg[M86_SS], c->s.cpl, EXC_TS, &slo, &shi);
    seg_cache(c, M86_SS, sg[M86_SS], slo, shi);
    set_seg(c, M86_ES, sg[M86_ES]);
    set_seg(c, M86_DS, sg[M86_DS]);
    set_seg(c, M86_FS, sg[M86_FS]);
    set_seg(c, M86_GS, sg[M86_GS]);
    if (neip > c->s.seg[M86_CS].limit)
        fault_e(c, EXC_GP, 0);
}

/* ---- control transfer ------------------------------------------ */

static void jump_near(m86 *c, uint32_t eip)
{
    if (c->os == 2)
        eip &= 0xFFFF;
    if (eip > c->s.seg[M86_CS].limit)
        fault_e(c, EXC_GP, 0);
    c->s.eip = eip;
}

/* A far jump or call. In protected mode the selector may name a code
 * segment, a call gate, a task gate or a task state segment. */
static void far_xfer(m86 *c, uint16_t sel, uint32_t off, int call)
{
    int os = c->os;
    if (os == 2)
        off &= 0xFFFF;
    if (!PMODE) {
        if (call) {
            push(c, os, c->s.seg[M86_CS].sel);
            push(c, os, c->s.eip);
        }
        if (off > c->s.seg[M86_CS].limit)
            fault_e(c, EXC_GP, 0);
        m86_set_seg_real(c, M86_CS, sel);
        c->s.eip = off;
        return;
    }
    uint32_t lo, hi;
    int cpl = c->s.cpl, rpl = sel & 3;
    if ((sel & 0xFFFCu) == 0)
        fault_e(c, EXC_GP, 0);
    if (!descriptor(c, sel, &lo, &hi))
        fault_e(c, EXC_GP, SELX(sel));
    int dpl = (hi >> 13) & 3, p = (hi >> 15) & 1;
    if (hi & 0x1000) {
        if (!(hi & 0x800))
            fault_e(c, EXC_GP, SELX(sel));
        if (hi & 0x400) {
            if (dpl > cpl)
                fault_e(c, EXC_GP, SELX(sel));
        } else if (rpl > cpl || dpl != cpl) {
            fault_e(c, EXC_GP, SELX(sel));
        }
        if (!p)
            fault_e(c, EXC_NP, SELX(sel));
        if (call) {
            push(c, os, c->s.seg[M86_CS].sel);
            push(c, os, c->s.eip);
        }
        load_cs(c, sel, lo, hi, cpl, off);
        return;
    }
    int type = (hi >> 8) & 15;
    if (dpl < cpl || dpl < rpl)
        fault_e(c, EXC_GP, SELX(sel));
    switch (type) {
    case 1: case 9:             /* a task state segment */
        task_switch(c, sel, call ? TS_CALL : TS_JMP);
        return;
    case 5:                     /* a task gate */
        if (!p)
            fault_e(c, EXC_NP, SELX(sel));
        task_switch(c, (uint16_t)(lo >> 16), call ? TS_CALL : TS_JMP);
        return;
    case 4: case 12: {          /* a call gate */
        if (!p)
            fault_e(c, EXC_NP, SELX(sel));
        int gs = type == 12 ? 4 : 2;
        uint16_t csel = (uint16_t)(lo >> 16);
        uint32_t goff = gs == 4 ? ((hi & 0xFFFF0000u) | (lo & 0xFFFFu)) : (lo & 0xFFFFu);
        int count = hi & 31;
        uint32_t clo, chi;
        if ((csel & 0xFFFCu) == 0)
            fault_e(c, EXC_GP, 0);
        if (!descriptor(c, csel, &clo, &chi))
            fault_e(c, EXC_GP, SELX(csel));
        int cdpl = (chi >> 13) & 3;
        if (!(chi & 0x1000) || !(chi & 0x800) || cdpl > cpl)
            fault_e(c, EXC_GP, SELX(csel));
        if (!call && !(chi & 0x400) && cdpl != cpl)
            fault_e(c, EXC_GP, SELX(csel));
        if (!(chi & 0x8000))
            fault_e(c, EXC_NP, SELX(csel));
        uint32_t ret_cs = c->s.seg[M86_CS].sel, ret_ip = c->s.eip;
        if (call && !(chi & 0x400) && cdpl < cpl) {
            /* To an inner level: a new stack from the TSS, the old
             * stack pointer and the parameters copied onto it. */
            uint16_t nss;
            uint32_t nesp, slo, shi, par[31];
            tss_stack(c, cdpl, &nss, &nesp);
            check_ss(c, nss, cdpl, EXC_TS, &slo, &shi);
            uint32_t oss = c->s.seg[M86_SS].sel, oesp = R(M86_ESP);
            for (int i = 0; i < count; i++)
                par[i] = rd_mem(c, M86_SS, (oesp + (uint32_t)(i * gs)) & SP_MASK, gs);
            c->s.cpl = (uint8_t)cdpl;
            seg_cache(c, M86_SS, nss, slo, shi);
            set_esp(c, nesp);
            push(c, gs, oss);
            push(c, gs, oesp);
            for (int i = count - 1; i >= 0; i--)
                push(c, gs, par[i]);
            push(c, gs, ret_cs);
            push(c, gs, ret_ip);
            load_cs(c, csel, clo, chi, cdpl, goff);
        } else {
            if (call) {
                push(c, gs, ret_cs);
                push(c, gs, ret_ip);
            }
            load_cs(c, csel, clo, chi, cpl, goff);
        }
        return;
    }
    default:
        fault_e(c, EXC_GP, SELX(sel));
    }
}

/* The flag bits a POPF or IRET at level `cpl` may change. */
static uint32_t flag_mask(m86 *c, int os, int cpl)
{
    uint32_t m = os == 2 ? 0xFFFFu : 0x00FCFFFFu;
    if (c->cr0 & 1) {
        m &= ~0x3200u;
        if (cpl <= IOPL)
            m |= M86_IF;
        if (cpl == 0)
            m |= 0x3000;
    }
    return m;
}

/* A far return (with `n` bytes of parameters to drop) or an IRET. */
static void far_return(m86 *c, uint32_t n, int iret)
{
    int os = c->os, k = iret ? 3 : 2;
    uint32_t sp = R(M86_ESP) & SP_MASK;
#define SPO(x) ((sp + (uint32_t)(x)) & SP_MASK)

    if (!PMODE) {
        if (iret && (FLAGS & M86_VM) && IOPL < 3)
            fault_e(c, EXC_GP, 0);
        uint32_t off = pop(c, os);
        uint32_t sel = pop(c, os);
        uint32_t fl = iret ? pop(c, os) : 0;
        set_esp(c, R(M86_ESP) + n);
        if (os == 2)
            off &= 0xFFFF;
        if (off > c->s.seg[M86_CS].limit)
            fault_e(c, EXC_GP, 0);
        m86_set_seg_real(c, M86_CS, (uint16_t)sel);
        c->s.eip = off;
        if (iret)
            write_flags(c, fl, flag_mask(c, os, 3));
        return;
    }
    if (iret && (FLAGS & M86_NT)) {
        task_switch(c, (uint16_t)phys_rd(c, c->tr.base, 2), TS_IRET);
        return;
    }
    uint32_t off = rd_mem(c, M86_SS, SPO(0), os);
    uint16_t sel = (uint16_t)rd_mem(c, M86_SS, SPO(os), 2);
    uint32_t fl = iret ? rd_mem(c, M86_SS, SPO(2 * os), os) : 0;
    int cpl = c->s.cpl, rpl = sel & 3;

    if (iret && os == 4 && (fl & M86_VM) && cpl == 0) {
        /* Back to a virtual 8086 task. */
        uint32_t nesp = rd_mem(c, M86_SS, SPO(12), 4);
        uint16_t sg[6];
        sg[M86_SS] = (uint16_t)rd_mem(c, M86_SS, SPO(16), 2);
        sg[M86_ES] = (uint16_t)rd_mem(c, M86_SS, SPO(20), 2);
        sg[M86_DS] = (uint16_t)rd_mem(c, M86_SS, SPO(24), 2);
        sg[M86_FS] = (uint16_t)rd_mem(c, M86_SS, SPO(28), 2);
        sg[M86_GS] = (uint16_t)rd_mem(c, M86_SS, SPO(32), 2);
        sg[M86_CS] = sel;
        FLAGS = (fl & EFLAGS_MASK) | 2;
        for (int i = 0; i < 6; i++)
            seg_v86(c, i, sg[i]);
        c->s.cpl = 3;
        c->s.eip = off & 0xFFFF;
        R(M86_ESP) = nesp;
        return;
    }

    uint32_t lo, hi;
    if ((sel & 0xFFFCu) == 0)
        fault_e(c, EXC_GP, 0);
    if (!descriptor(c, sel, &lo, &hi))
        fault_e(c, EXC_GP, SELX(sel));
    int dpl = (hi >> 13) & 3;
    if (rpl < cpl || !(hi & 0x1000) || !(hi & 0x800))
        fault_e(c, EXC_GP, SELX(sel));
    if ((hi & 0x400) ? dpl > rpl : dpl != rpl)
        fault_e(c, EXC_GP, SELX(sel));
    if (!(hi & 0x8000))
        fault_e(c, EXC_NP, SELX(sel));
    if (os == 2)
        off &= 0xFFFF;

    if (rpl == cpl) {
        set_esp(c, sp + (uint32_t)(k * os) + n);
        load_cs(c, sel, lo, hi, cpl, off);
    } else {
        /* To an outer level: its stack pointer is on this stack. */
        uint32_t nesp = rd_mem(c, M86_SS, SPO(k * os + (int)n), os);
        uint16_t nss = (uint16_t)rd_mem(c, M86_SS, SPO(k * os + (int)n + os), 2);
        uint32_t slo, shi;
        check_ss(c, nss, rpl, EXC_GP, &slo, &shi);
        load_cs(c, sel, lo, hi, rpl, off);
        seg_cache(c, M86_SS, nss, slo, shi);
        if (os == 4)
            R(M86_ESP) = nesp;
        else
            R(M86_ESP) = (R(M86_ESP) & 0xFFFF0000u) | (nesp & 0xFFFF);
        set_esp(c, R(M86_ESP) + n);
        /* Data segments the outer level may not have are emptied. */
        static const int ds[4] = { M86_ES, M86_DS, M86_FS, M86_GS };
        for (int i = 0; i < 4; i++) {
            m86_seg *s = &c->s.seg[ds[i]];
            if (!s->null && !s->cc && s->dpl < rpl) {
                s->sel = 0;
                s->null = 1;
            }
        }
    }
    if (iret)
        write_flags(c, fl, flag_mask(c, os, cpl));
#undef SPO
}

/* I/O from a level the I/O privilege level does not cover, or from a
 * virtual 8086 task, is allowed port by port by the bitmap in the TSS. */
static void io_check(m86 *c, uint32_t port, int size)
{
    if (!(c->cr0 & 1))
        return;
    if (!(FLAGS & M86_VM) && c->s.cpl <= IOPL)
        return;
    if (!c->tr.t32 || c->tr.limit < 0x67)
        fault_e(c, EXC_GP, 0);
    uint32_t base = phys_rd(c, c->tr.base + 0x66, 2);
    if (base + (port + (uint32_t)size - 1) / 8 > c->tr.limit)
        fault_e(c, EXC_GP, 0);
    uint32_t bits = phys_rd(c, c->tr.base + base + port / 8, 1);
    if (base + port / 8 + 1 <= c->tr.limit)
        bits |= phys_rd(c, c->tr.base + base + port / 8 + 1, 1) << 8;
    if ((bits >> (port & 7)) & ((1u << size) - 1))
        fault_e(c, EXC_GP, 0);
}

/* Only level 0 may. */
static void privileged(m86 *c)
{
    if ((c->cr0 & 1) && c->s.cpl != 0)
        fault_e(c, EXC_GP, 0);
}

/* Deliver an interrupt or an exception. kind: INT_SOFT for INT n,
 * INT3 and INTO; INT_EXT for a hardware interrupt; INT_FAULT for a
 * fault, which may push an error code. */
enum { INT_SOFT, INT_EXT, INT_FAULT };

static int has_error_code(int vec)
{
    return vec == 8 || (vec >= 10 && vec <= 14) || vec == 17;
}

static void interrupt(m86 *c, int vec, uint32_t ret_eip, int kind)
{
    if (!(c->cr0 & 1)) {
        uint32_t a = (uint32_t)vec * 4;
        if (a + 3 > c->idtr.limit)
            fault(c, EXC_GP);
        uint32_t ip = phys_rd(c, c->idtr.base + a, 2);
        uint32_t cs = phys_rd(c, c->idtr.base + a + 2, 2);
        push(c, 2, FLAGS);
        push(c, 2, c->s.seg[M86_CS].sel);
        push(c, 2, ret_eip);
        FLAGS &= ~(M86_IF | M86_TF);
        m86_set_seg_real(c, M86_CS, (uint16_t)cs);
        c->s.eip = ip;
        return;
    }

    uint32_t ext = kind != INT_SOFT;
    uint32_t idx = (uint32_t)vec * 8 + 2;
    uint32_t err = c->err;
    int ec = kind == INT_FAULT && has_error_code(vec);
    if ((uint32_t)vec * 8 + 7 > c->idtr.limit)
        fault_e(c, EXC_GP, idx + ext);
    uint32_t g = c->idtr.base + (uint32_t)vec * 8;
    uint32_t lo = phys_rd(c, g, 4), hi = phys_rd(c, g + 4, 4);
    int type = (hi >> 8) & 0x1F, gdpl = (hi >> 13) & 3;
    int cpl = c->s.cpl;
    if (type != 5 && type != 6 && type != 7 && type != 14 && type != 15)
        fault_e(c, EXC_GP, idx + ext);
    if (kind == INT_SOFT && gdpl < cpl)
        fault_e(c, EXC_GP, idx);
    if (!(hi & 0x8000))
        fault_e(c, EXC_NP, idx + ext);
    uint32_t oflags = FLAGS;

    if (type == 5) {            /* a task gate */
        c->s.eip = ret_eip;
        task_switch(c, (uint16_t)(lo >> 16), TS_CALL);
        if (ec)
            push(c, c->tr.t32 ? 4 : 2, err);
        return;
    }

    int size = (type & 8) ? 4 : 2;
    uint16_t sel = (uint16_t)(lo >> 16);
    uint32_t off = size == 4 ? ((hi & 0xFFFF0000u) | (lo & 0xFFFFu)) : (lo & 0xFFFFu);
    uint32_t clo, chi;
    if ((sel & 0xFFFCu) == 0)
        fault_e(c, EXC_GP, ext);
    if (!descriptor(c, sel, &clo, &chi))
        fault_e(c, EXC_GP, SELX(sel) + ext);
    int dpl = (chi >> 13) & 3;
    if (!(chi & 0x1000) || !(chi & 0x800) || dpl > cpl)
        fault_e(c, EXC_GP, SELX(sel) + ext);
    if (!(chi & 0x8000))
        fault_e(c, EXC_NP, SELX(sel) + ext);
    uint32_t ocs = c->s.seg[M86_CS].sel;

    if (!(chi & 0x400) && dpl < cpl) {
        /* To an inner level, on the stack the TSS gives for it. */
        uint16_t nss;
        uint32_t nesp, slo, shi;
        int vm = (FLAGS & M86_VM) != 0;
        if (vm && dpl != 0)
            fault_e(c, EXC_GP, SELX(sel) + ext);
        tss_stack(c, dpl, &nss, &nesp);
        check_ss(c, nss, dpl, EXC_TS, &slo, &shi);
        uint32_t oss = c->s.seg[M86_SS].sel, oesp = R(M86_ESP);
        uint16_t og[4] = { c->s.seg[M86_ES].sel, c->s.seg[M86_DS].sel,
                           c->s.seg[M86_FS].sel, c->s.seg[M86_GS].sel };
        FLAGS &= ~M86_VM;
        c->s.cpl = (uint8_t)dpl;
        seg_cache(c, M86_SS, nss, slo, shi);
        set_esp(c, nesp);
        if (vm) {
            static const int ds[4] = { M86_ES, M86_DS, M86_FS, M86_GS };
            for (int i = 3; i >= 0; i--) {
                push(c, size, og[i]);
                c->s.seg[ds[i]].sel = 0;
                c->s.seg[ds[i]].null = 1;
            }
        }
        push(c, size, oss);
        push(c, size, oesp);
        cpl = dpl;
    } else {
        if (FLAGS & M86_VM)
            fault_e(c, EXC_GP, SELX(sel) + ext);
        if (!(chi & 0x400) && dpl != cpl)
            fault_e(c, EXC_GP, SELX(sel) + ext);
    }
    push(c, size, oflags);
    push(c, size, ocs);
    push(c, size, ret_eip);
    if (ec)
        push(c, size, err);
    if (!(type & 1))
        FLAGS &= ~M86_IF;
    FLAGS &= ~(M86_TF | M86_NT | M86_VM | 0x10000u);
    load_cs(c, sel, clo, chi, cpl, off);
}

/* ---- arithmetic helpers ---------------------------------------- */

static int32_t sext(uint32_t v, int size)
{
    return size == 1 ? (int8_t)v : size == 2 ? (int16_t)v : (int32_t)v;
}

static void mul_flags(m86 *c, int overflow)
{
    set_flag(c, M86_CF, overflow);
    set_flag(c, M86_OF, overflow);
}

static void group3(m86 *c, int size)
{
    uint32_t m = MASK(size);
    uint32_t v;
    switch (c->reg) {
    case 0: case 1:
        v = rd_rm(c, size);
        alu(c, 4, v, fetch(c, size), size);
        break;
    case 2:
        wr_rm(c, size, ~rd_rm(c, size));
        break;
    case 3:
        v = rd_rm(c, size);
        wr_rm(c, size, alu(c, 5, 0, v, size));
        break;
    case 4: {
        v = rd_rm(c, size);
        uint64_t p = (uint64_t)(R(M86_EAX) & m) * v;
        if (size == 1) {
            wr_reg(c, 2, M86_EAX, (uint32_t)p);
            mul_flags(c, (p >> 8) != 0);
        } else {
            wr_reg(c, size, M86_EAX, (uint32_t)p);
            wr_reg(c, size, M86_EDX, (uint32_t)(p >> (8 * size)));
            mul_flags(c, (p >> (8 * size)) != 0);
        }
        break;
    }
    case 5: {
        v = rd_rm(c, size);
        int64_t p = (int64_t)sext(R(M86_EAX) & m, size) * sext(v, size);
        if (size == 1) {
            wr_reg(c, 2, M86_EAX, (uint32_t)p);
        } else {
            wr_reg(c, size, M86_EAX, (uint32_t)p);
            wr_reg(c, size, M86_EDX, (uint32_t)((uint64_t)p >> (8 * size)));
        }
        mul_flags(c, p != (int64_t)sext((uint32_t)p & m, size));
        break;
    }
    case 6: {
        v = rd_rm(c, size);
        if (v == 0)
            fault(c, EXC_DE);
        uint64_t n = size == 1 ? (R(M86_EAX) & 0xFFFF)
                   : size == 2 ? ((R(M86_EDX) & 0xFFFF) << 16) | (R(M86_EAX) & 0xFFFF)
                   : ((uint64_t)R(M86_EDX) << 32) | R(M86_EAX);
        uint64_t q = n / v, rem = n % v;
        if (q > m)
            fault(c, EXC_DE);
        if (size == 1) {
            wr_reg(c, 1, 0, (uint32_t)q);
            wr_reg(c, 1, 4, (uint32_t)rem);
        } else {
            wr_reg(c, size, M86_EAX, (uint32_t)q);
            wr_reg(c, size, M86_EDX, (uint32_t)rem);
        }
        break;
    }
    default: {
        v = rd_rm(c, size);
        int64_t d = sext(v, size);
        if (d == 0)
            fault(c, EXC_DE);
        int64_t n = size == 1 ? (int16_t)R(M86_EAX)
                  : size == 2 ? (int32_t)(((R(M86_EDX) & 0xFFFF) << 16) | (R(M86_EAX) & 0xFFFF))
                  : (int64_t)(((uint64_t)R(M86_EDX) << 32) | R(M86_EAX));
        if (n == INT64_MIN && d == -1)
            fault(c, EXC_DE);
        int64_t q = n / d, rem = n % d;
        int64_t lim = (int64_t)(MSB(size));
        if (q >= lim || q < -lim)
            fault(c, EXC_DE);
        if (size == 1) {
            wr_reg(c, 1, 0, (uint32_t)q);
            wr_reg(c, 1, 4, (uint32_t)rem);
        } else {
            wr_reg(c, size, M86_EAX, (uint32_t)q);
            wr_reg(c, size, M86_EDX, (uint32_t)rem);
        }
        break;
    }
    }
}

static uint32_t imul_trunc(m86 *c, uint32_t a, uint32_t b, int size)
{
    int64_t p = (int64_t)sext(a, size) * sext(b, size);
    uint32_t r = (uint32_t)p & MASK(size);
    mul_flags(c, p != (int64_t)sext(r, size));
    return r;
}

/* SHLD (right == 0) and SHRD. */
static uint32_t shift_double(m86 *c, uint32_t dst, uint32_t src, uint32_t cnt,
                             int size, int right)
{
    int bits = 8 * size;
    uint32_t m = MASK(size), s = MSB(size), r;
    cnt &= 31;
    dst &= m;
    src &= m;
    if (cnt == 0)
        return dst;
    /* A count above 16 on 16-bit operands is undefined in the manual.
     * The hardware keeps shifting, and the source supplies the bits a
     * second time. */
    if (size == 2) {
        if (!right) {
            uint64_t w = ((uint64_t)dst << 32) | ((uint64_t)src << 16) | src;
            w <<= cnt;
            r = (uint32_t)(w >> 32) & m;
            set_flag(c, M86_CF, (w >> 48) & 1);
        } else {
            uint64_t w = ((uint64_t)src << 32) | ((uint64_t)src << 16) | dst;
            set_flag(c, M86_CF, (w >> (cnt - 1)) & 1);
            r = (uint32_t)(w >> cnt) & m;
        }
    } else if (!right) {
        r = (dst << cnt) | (src >> (bits - (int)cnt));
        set_flag(c, M86_CF, (dst >> (bits - (int)cnt)) & 1);
    } else {
        uint64_t w = ((uint64_t)src << bits) | dst;
        set_flag(c, M86_CF, (w >> (cnt - 1)) & 1);
        r = (uint32_t)(w >> cnt) & m;
    }
    set_flag(c, M86_OF, ((r ^ dst) & s) != 0);
    set_szp(c, r, size);
    FLAGS &= ~M86_AF;
    return r;
}

/* ---- strings --------------------------------------------------- */

static void string_op(m86 *c, int op, int size)
{
    uint32_t am = c->as32 ? 0xFFFFFFFFu : 0xFFFFu;
    int sseg = c->seg_ovr >= 0 ? c->seg_ovr : M86_DS;
    int rep = c->rep;
    /* REP only gives a termination condition to CMPS and SCAS. */
    int cmp = (op == 0xA6 || op == 0xA7 || op == 0xAE || op == 0xAF);

    for (;;) {
        if (rep && (R(M86_ECX) & am) == 0)
            break;
        uint32_t d = (FLAGS & M86_DF) ? (uint32_t)-size : (uint32_t)size;
        uint32_t si = R(M86_ESI) & am, di = R(M86_EDI) & am;
        int use_si = 0, use_di = 0;
        uint32_t a, b;

        switch (op) {
        case 0x6C: case 0x6D:       /* INS */
            /* Check the destination before the port is read. */
            io_check(c, R(M86_EDX) & 0xFFFF, size);
            {
                /* ... and with paging, that its pages can be written. */
                uint32_t la = linear(c, M86_ES, di, size, 1);
                if (c->cr0 & 0x80000000u) {
                    translate(c, la, 1, c->s.cpl == 3);
                    translate(c, la + (uint32_t)size - 1, 1, c->s.cpl == 3);
                }
            }
            wr_mem(c, M86_ES, di, size,
                   c->io_read(c->bus, (uint16_t)R(M86_EDX), size));
            use_di = 1;
            break;
        case 0x6E: case 0x6F:       /* OUTS */
            io_check(c, R(M86_EDX) & 0xFFFF, size);
            c->io_write(c->bus, (uint16_t)R(M86_EDX), size,
                        rd_mem(c, sseg, si, size));
            use_si = 1;
            break;
        case 0xA4: case 0xA5:       /* MOVS */
            wr_mem(c, M86_ES, di, size, rd_mem(c, sseg, si, size));
            use_si = use_di = 1;
            break;
        case 0xA6: case 0xA7:       /* CMPS */
            a = rd_mem(c, sseg, si, size);
            b = rd_mem(c, M86_ES, di, size);
            alu(c, 7, a, b, size);
            use_si = use_di = 1;
            break;
        case 0xAA: case 0xAB:       /* STOS */
            wr_mem(c, M86_ES, di, size, R(M86_EAX));
            use_di = 1;
            break;
        case 0xAC: case 0xAD:       /* LODS */
            wr_reg(c, size, M86_EAX, rd_mem(c, sseg, si, size));
            use_si = 1;
            break;
        default:                    /* SCAS */
            b = rd_mem(c, M86_ES, di, size);
            alu(c, 7, R(M86_EAX), b, size);
            use_di = 1;
            break;
        }
        if (use_si)
            R(M86_ESI) = (R(M86_ESI) & ~am) | ((si + d) & am);
        if (use_di)
            R(M86_EDI) = (R(M86_EDI) & ~am) | ((di + d) & am);
        if (!rep)
            break;
        R(M86_ECX) = (R(M86_ECX) & ~am) | ((R(M86_ECX) - 1) & am);

        /* One iteration is done: a fault in the next one resumes here. */
        memcpy(c->snap.r, c->s.r, sizeof c->s.r);
        c->snap.eflags = c->s.eflags;

        if (cmp) {
            int zf = (FLAGS & M86_ZF) != 0;
            if ((rep == 0xF3 && !zf) || (rep == 0xF2 && zf))
                break;
        }
    }
}

/* ---- the 0F map ------------------------------------------------ */

static void load_far_pointer(m86 *c, int seg)
{
    if (c->mod == 3)
        fault(c, EXC_UD);
    uint32_t off = rd_mem(c, c->ea_seg, c->ea_off, c->os);
    uint32_t sel = rd_mem(c, c->ea_seg, ea_plus(c, c->os), 2);
    set_seg(c, seg, (uint16_t)sel);
    wr_reg(c, c->os, c->reg, off);
    if (seg == M86_SS)
        c->irq_inhibit = 1;
}

static void bit_op(m86 *c, int kind, int imm)
{
    int size = c->os, bits = 8 * size;
    uint32_t bit, v;
    if (imm) {
        bit = fetch8(c) & (uint32_t)(bits - 1);
    } else {
        int32_t sb = sext(rd_reg(c, size, c->reg), size);
        if (c->mod != 3) {
            /* The bit offset reaches outside the operand. */
            int32_t words = sb >> (size == 2 ? 4 : 5);
            c->ea_off += (uint32_t)(words * size);
            if (!c->as32)
                c->ea_off &= 0xFFFF;
        }
        bit = (uint32_t)sb & (uint32_t)(bits - 1);
    }
    v = rd_rm(c, size);
    set_flag(c, M86_CF, (v >> bit) & 1);
    switch (kind) {
    case 1: wr_rm(c, size, v | (1u << bit)); break;     /* BTS */
    case 2: wr_rm(c, size, v & ~(1u << bit)); break;    /* BTR */
    case 3: wr_rm(c, size, v ^ (1u << bit)); break;     /* BTC */
    default: break;                                     /* BT */
    }
}

static void exec_0f(m86 *c)
{
    int op = fetch8(c);
    int os = c->os;
    uint32_t v;
    c->op = 0x100 | op;

    switch (op) {
    case 0x00:                  /* the local table and the task register */
        if (!PMODE)
            fault(c, EXC_UD);
        decode_modrm(c);
        switch (c->reg) {
        case 0: case 1:         /* SLDT, STR */
            v = c->reg == 0 ? c->ldtr.sel : c->tr.sel;
            if (c->mod == 3)
                wr_reg(c, os, c->rm, v);
            else
                wr_mem(c, c->ea_seg, c->ea_off, 2, v);
            break;
        case 2: {               /* LLDT: the table's base from its descriptor in the GDT */
            uint32_t lo, hi;
            privileged(c);
            v = rd_rm(c, 2);
            if ((v & 0xFFFCu) == 0) {
                c->ldtr.sel = (uint16_t)v;
                c->ldtr.base = c->ldtr.limit = 0;
                break;
            }
            if ((v & 4) || !descriptor(c, (uint16_t)v, &lo, &hi) || ((hi >> 8) & 0x1F) != 2)
                fault_e(c, EXC_GP, SELX(v));
            if (!(hi & 0x8000))
                fault_e(c, EXC_NP, SELX(v));
            c->ldtr.sel = (uint16_t)v;
            c->ldtr.base = desc_base(lo, hi);
            c->ldtr.limit = desc_limit(lo, hi);
            break;
        }
        case 3: {               /* LTR: an available TSS, which becomes busy */
            uint32_t lo, hi;
            privileged(c);
            v = rd_rm(c, 2);
            if ((v & 0xFFFCu) == 0)
                fault_e(c, EXC_GP, 0);
            if ((v & 4) || !descriptor(c, (uint16_t)v, &lo, &hi) || ((hi >> 8) & 0x17) != 1)
                fault_e(c, EXC_GP, SELX(v));
            if (!(hi & 0x8000))
                fault_e(c, EXC_NP, SELX(v));
            phys_wr(c, desc_addr(c, (uint16_t)v) + 5, 1, (hi >> 8) | 2);
            c->tr.sel = (uint16_t)v;
            c->tr.base = desc_base(lo, hi);
            c->tr.limit = desc_limit(lo, hi);
            c->tr.t32 = (hi >> 11) & 1;
            break;
        }
        case 4: case 5: {       /* VERR, VERW */
            uint32_t lo, hi;
            v = rd_rm(c, 2);
            if (!descriptor(c, (uint16_t)v, &lo, &hi)) {
                FLAGS &= ~M86_ZF;
                break;
            }
            int code = (hi >> 11) & 1, bit9 = (hi >> 9) & 1, seg = (hi >> 12) & 1;
            int dpl = (hi >> 13) & 3, conf = code && ((hi >> 10) & 1);
            int ok = seg && (c->reg == 4 ? (!code || bit9) : (!code && bit9));
            if (!conf && (dpl < c->s.cpl || dpl < (int)(v & 3)))
                ok = 0;
            set_flag(c, M86_ZF, ok);
            break;
        }
        default:
            fault(c, EXC_UD);
        }
        break;
    case 0x02: case 0x03: {     /* LAR, LSL */
        uint32_t lo, hi;
        if (!PMODE)
            fault(c, EXC_UD);
        decode_modrm(c);
        v = rd_rm(c, 2);
        if (!descriptor(c, (uint16_t)v, &lo, &hi)) {
            FLAGS &= ~M86_ZF;
            break;
        }
        int type = (hi >> 8) & 0x1F, dpl = (hi >> 13) & 3;
        int conf = (type & 0x1C) == 0x1C, ok;
        if (type & 0x10)
            ok = 1;
        else if (op == 0x02)    /* TSS, LDT, call gate, task gate */
            ok = (0x1A3E >> type) & 1;
        else                    /* what has a limit: TSS, LDT */
            ok = (0x0A0E >> type) & 1;
        if (!conf && (dpl < c->s.cpl || dpl < (int)(v & 3)))
            ok = 0;
        if (!ok) {
            FLAGS &= ~M86_ZF;
            break;
        }
        if (op == 0x02)
            v = hi & 0x00F0FF00u;
        else
            v = desc_limit(lo, hi);
        wr_reg(c, os, c->reg, v);
        FLAGS |= M86_ZF;
        break;
    }
    case 0x01:
        decode_modrm(c);
        switch (c->reg) {
        case 0: case 1: {       /* SGDT, SIDT */
            if (c->mod == 3)
                fault(c, EXC_UD);
            uint32_t base = c->reg == 0 ? c->gdtr.base : c->idtr.base;
            uint16_t lim = c->reg == 0 ? c->gdtr.limit : c->idtr.limit;
            wr_mem(c, c->ea_seg, c->ea_off, 2, lim);
            wr_mem(c, c->ea_seg, ea_plus(c, 2), 4, base);
            break;
        }
        case 2: case 3: {       /* LGDT, LIDT */
            if (c->mod == 3)
                fault(c, EXC_UD);
            privileged(c);
            uint16_t lim = (uint16_t)rd_mem(c, c->ea_seg, c->ea_off, 2);
            uint32_t base = rd_mem(c, c->ea_seg, ea_plus(c, 2), 4);
            if (os == 2)
                base &= 0x00FFFFFF;
            if (c->reg == 2) {
                c->gdtr.base = base;
                c->gdtr.limit = lim;
            } else {
                c->idtr.base = base;
                c->idtr.limit = lim;
            }
            break;
        }
        case 4:                 /* SMSW */
            if (c->mod == 3)
                wr_reg(c, os, c->rm, c->cr0);
            else
                wr_mem(c, c->ea_seg, c->ea_off, 2, c->cr0);
            break;
        case 6:                 /* LMSW: cannot clear PE */
            privileged(c);
            v = rd_rm(c, 2);
            c->cr0 = (c->cr0 & ~0xEu) | (v & 0xF) | (c->cr0 & 1);
            break;
        case 7:                 /* INVLPG (a 486's): the model keeps no translations */
            if (c->mod == 3)
                fault(c, EXC_UD);
            privileged(c);
            break;
        default:
            fault(c, EXC_UD);
        }
        break;
    case 0x06:                  /* CLTS */
        privileged(c);
        c->cr0 &= ~8u;
        break;
    case 0x20:                  /* MOV r32, CRn */
        decode_modrm(c);
        privileged(c);
        if (c->reg == 0)
            R(c->rm) = c->cr0;
        else if (c->reg == 2)
            R(c->rm) = c->cr2;
        else if (c->reg == 3)
            R(c->rm) = c->cr3;
        else
            fault(c, EXC_UD);
        break;
    case 0x22:                  /* MOV CRn, r32 */
        decode_modrm(c);
        privileged(c);
        if (c->reg == 0) {
            c->cr0 = R(c->rm);
            if (!(c->cr0 & 1))
                c->s.cpl = 0;
        } else if (c->reg == 2) {
            c->cr2 = R(c->rm);
        } else if (c->reg == 3) {
            c->cr3 = R(c->rm);
        } else {
            fault(c, EXC_UD);
        }
        break;
    case 0x21:                  /* MOV r32, DRn */
        decode_modrm(c);
        privileged(c);
        R(c->rm) = c->dr[c->reg];
        break;
    case 0x23:                  /* MOV DRn, r32 */
        decode_modrm(c);
        privileged(c);
        c->dr[c->reg] = R(c->rm);
        break;
    case 0x80 ... 0x8F: {       /* Jcc rel16/32 */
        int32_t rel = fetch_s(c, os);
        c->taken = cond(c, op & 15);
        if (c->taken)
            jump_near(c, c->s.eip + (uint32_t)rel);
        break;
    }
    case 0x90 ... 0x9F:         /* SETcc */
        decode_modrm(c);
        wr_rm(c, 1, (uint32_t)cond(c, op & 15));
        break;
    case 0xA0: push_seg(c, M86_FS); break;
    case 0xA8: push_seg(c, M86_GS); break;
    case 0xA1: set_seg(c, M86_FS, pop_seg(c)); break;
    case 0xA9: set_seg(c, M86_GS, pop_seg(c)); break;
    case 0xA3: decode_modrm(c); bit_op(c, 0, 0); break;
    case 0xAB: decode_modrm(c); bit_op(c, 1, 0); break;
    case 0xB3: decode_modrm(c); bit_op(c, 2, 0); break;
    case 0xBB: decode_modrm(c); bit_op(c, 3, 0); break;
    case 0xBA:
        decode_modrm(c);
        if (c->reg < 4)
            fault(c, EXC_UD);
        bit_op(c, c->reg - 4, 1);
        break;
    case 0xA4: case 0xAC:       /* SHLD/SHRD imm8 */
        decode_modrm(c);
        v = rd_rm(c, os);
        wr_rm(c, os, shift_double(c, v, rd_reg(c, os, c->reg), fetch8(c),
                                  os, op == 0xAC));
        break;
    case 0xA5: case 0xAD:       /* SHLD/SHRD CL */
        decode_modrm(c);
        v = rd_rm(c, os);
        wr_rm(c, os, shift_double(c, v, rd_reg(c, os, c->reg), R(M86_ECX),
                                  os, op == 0xAD));
        break;
    case 0xAF:                  /* IMUL r, r/m */
        decode_modrm(c);
        wr_reg(c, os, c->reg,
               imul_trunc(c, rd_reg(c, os, c->reg), rd_rm(c, os), os));
        break;
    case 0xB2: decode_modrm(c); load_far_pointer(c, M86_SS); break;
    case 0xB4: decode_modrm(c); load_far_pointer(c, M86_FS); break;
    case 0xB5: decode_modrm(c); load_far_pointer(c, M86_GS); break;
    case 0xB6: decode_modrm(c); wr_reg(c, os, c->reg, rd_rm(c, 1)); break;
    case 0xB7: decode_modrm(c); wr_reg(c, os, c->reg, rd_rm(c, 2)); break;
    case 0xBE:
        decode_modrm(c);
        wr_reg(c, os, c->reg, (uint32_t)sext(rd_rm(c, 1), 1));
        break;
    case 0xBF:
        decode_modrm(c);
        wr_reg(c, os, c->reg, (uint32_t)sext(rd_rm(c, 2), 2));
        break;
    case 0xBC: case 0xBD:       /* BSF, BSR */
        decode_modrm(c);
        v = rd_rm(c, os);
        if (v == 0) {
            FLAGS |= M86_ZF;
        } else {
            int i;
            if (op == 0xBC)
                for (i = 0; !((v >> i) & 1); i++)
                    ;
            else
                for (i = 8 * os - 1; !((v >> i) & 1); i--)
                    ;
            FLAGS &= ~M86_ZF;
            wr_reg(c, os, c->reg, (uint32_t)i);
        }
        break;
    /* ---- a 486's ---- */
    case 0x08: case 0x09:       /* INVD, WBINVD: there is no cache to empty */
        privileged(c);
        break;
    case 0xC8 ... 0xCF:         /* BSWAP */
        v = R(op & 7);
        R(op & 7) = (v >> 24) | ((v >> 8) & 0xFF00u) | ((v << 8) & 0xFF0000u) | (v << 24);
        break;
    case 0xC0: case 0xC1: {     /* XADD */
        int size = (op & 1) ? os : 1;
        decode_modrm(c);
        uint32_t d = rd_rm(c, size), s2 = rd_reg(c, size, c->reg);
        uint32_t sum = alu(c, 0, d, s2, size);
        wr_reg(c, size, c->reg, d);
        wr_rm(c, size, sum);
        break;
    }
    case 0xB0: case 0xB1: {     /* CMPXCHG */
        int size = (op & 1) ? os : 1;
        decode_modrm(c);
        uint32_t d = rd_rm(c, size);
        alu(c, 7, rd_reg(c, size, M86_EAX), d, size);
        if (FLAGS & M86_ZF)
            wr_rm(c, size, rd_reg(c, size, c->reg));
        else
            wr_reg(c, size, M86_EAX, d);
        break;
    }
    default:
        /* Includes the protected-mode-only instructions (0F 00, LAR,
         * LSL), which real mode does not recognise. */
        fault(c, EXC_UD);
    }
}

/* ---- one instruction ------------------------------------------- */

/* LOCK is accepted only on these, and only with a memory destination. */
static int lockable(int op, int reg)
{
    if (op < 0x40 && (op & 7) < 2)
        return (op >> 3) != 7;                  /* not CMP */
    switch (op) {
    case 0x80: case 0x81: case 0x82: case 0x83: return reg != 7;
    case 0x86: case 0x87: return 1;
    case 0xF6: case 0xF7: return reg == 2 || reg == 3;
    case 0xFE: case 0xFF: return reg < 2;
    case 0x1AB: case 0x1B3: case 0x1BB: return 1;
    case 0x1B0: case 0x1B1: case 0x1C0: case 0x1C1: return 1;   /* CMPXCHG, XADD */
    case 0x1BA: return reg >= 5;
    default: return 0;
    }
}

static void exec(m86 *c)
{
    int op, os, size;
    uint32_t v, a;

    /* Prefixes. */
    for (;;) {
        op = fetch8(c);
        switch (op) {
        case 0x26: c->seg_ovr = M86_ES; continue;
        case 0x2E: c->seg_ovr = M86_CS; continue;
        case 0x36: c->seg_ovr = M86_SS; continue;
        case 0x3E: c->seg_ovr = M86_DS; continue;
        case 0x64: c->seg_ovr = M86_FS; continue;
        case 0x65: c->seg_ovr = M86_GS; continue;
        case 0x66: c->os = c->s.seg[M86_CS].d ? 2 : 4; continue;
        case 0x67: c->as32 = !c->s.seg[M86_CS].d; continue;
        case 0xF0: c->lock = 1; continue;
        case 0xF2: case 0xF3: c->rep = op; continue;
        }
        break;
    }
    c->op = op;
    os = c->os;
    size = (op & 1) ? os : 1;       /* for the many w-bit encodings */

    if (c->lock) {
        /* Look ahead at the opcode and ModRM without consuming them. */
        m86_regs here = c->s;
        int len = c->len;
        int o = op == 0x0F ? (0x100 | fetch8(c)) : op;
        uint8_t modrm = fetch8(c);
        c->s = here;
        c->len = len;
        if (!lockable(o, (modrm >> 3) & 7) || (modrm >> 6) == 3)
            fault(c, EXC_UD);
    }

    switch (op) {
    /* ALU r/m,r  r,r/m  acc,imm */
    case 0x00 ... 0x05: case 0x08 ... 0x0D: case 0x10 ... 0x15:
    case 0x18 ... 0x1D: case 0x20 ... 0x25: case 0x28 ... 0x2D:
    case 0x30 ... 0x35: case 0x38 ... 0x3D: {
        int aop = op >> 3;
        switch (op & 7) {
        case 0: case 1:
            decode_modrm(c);
            v = alu(c, aop, rd_rm(c, size), rd_reg(c, size, c->reg), size);
            if (aop != 7)
                wr_rm(c, size, v);
            break;
        case 2: case 3:
            decode_modrm(c);
            v = alu(c, aop, rd_reg(c, size, c->reg), rd_rm(c, size), size);
            if (aop != 7)
                wr_reg(c, size, c->reg, v);
            break;
        default:
            v = alu(c, aop, rd_reg(c, size, M86_EAX), fetch(c, size), size);
            if (aop != 7)
                wr_reg(c, size, M86_EAX, v);
            break;
        }
        break;
    }
    case 0x06: push_seg(c, M86_ES); break;
    case 0x0E: push_seg(c, M86_CS); break;
    case 0x16: push_seg(c, M86_SS); break;
    case 0x1E: push_seg(c, M86_DS); break;
    case 0x07: set_seg(c, M86_ES, pop_seg(c)); break;
    case 0x17:
        set_seg(c, M86_SS, pop_seg(c));
        c->irq_inhibit = 1;
        break;
    case 0x1F: set_seg(c, M86_DS, pop_seg(c)); break;
    case 0x0F: exec_0f(c); break;

    case 0x27: case 0x2F: {     /* DAA, DAS */
        uint32_t al = R(M86_EAX) & 0xFF, old = al;
        int cf = FLAGS & M86_CF, af = (FLAGS & M86_AF) != 0, ncf = 0;
        if ((al & 0x0F) > 9 || af) {
            if (op == 0x2F && al < 6)
                ncf = 1;
            al = op == 0x27 ? al + 6 : al - 6;
            af = 1;
        }
        if (old > 0x99 || cf) {
            al = op == 0x27 ? al + 0x60 : al - 0x60;
            ncf = 1;
        }
        wr_reg(c, 1, 0, al);
        set_flag(c, M86_CF, ncf);
        set_flag(c, M86_AF, af);
        set_szp(c, al, 1);
        break;
    }
    case 0x37: case 0x3F: {     /* AAA, AAS */
        uint32_t ax = R(M86_EAX) & 0xFFFF;
        if ((ax & 0x0F) > 9 || (FLAGS & M86_AF)) {
            ax = op == 0x37 ? ax + 0x106 : ax - 0x106;
            FLAGS |= M86_AF | M86_CF;
        } else {
            FLAGS &= ~(M86_AF | M86_CF);
        }
        wr_reg(c, 2, M86_EAX, ax & 0xFF0F);
        break;
    }

    case 0x40 ... 0x47:
        wr_reg(c, os, op & 7, incdec(c, rd_reg(c, os, op & 7), 0, os));
        break;
    case 0x48 ... 0x4F:
        wr_reg(c, os, op & 7, incdec(c, rd_reg(c, os, op & 7), 1, os));
        break;
    case 0x50 ... 0x57: push(c, os, rd_reg(c, os, op & 7)); break;
    case 0x58 ... 0x5F:
        v = pop(c, os);
        wr_reg(c, os, op & 7, v);
        break;

    case 0x60: {                /* PUSHA */
        /* The frame is written from its lowest address upwards, so a
         * fault part-way leaves the registers stored so far. */
        uint32_t sp = R(M86_ESP);
        uint32_t base = (sp - 8u * (uint32_t)os) & SP_MASK;
        for (int i = 7; i >= 0; i--)
            wr_mem(c, M86_SS, (base + (uint32_t)((7 - i) * os)) & SP_MASK, os,
                   i == M86_ESP ? sp : R(i));
        R(M86_ESP) = (sp & ~SP_MASK) | base;
        break;
    }
    case 0x61: {                /* POPA */
        uint32_t esp_image = R(M86_ESP);
        for (int i = 7; i >= 0; i--) {
            v = pop(c, os);
            if (i != M86_ESP) {
                wr_reg(c, os, i, v);
                /* A register already popped stays popped if a later
                 * pop faults. */
                c->snap.r[i] = R(i);
            } else {
                esp_image = v;
            }
        }
        /* The stack pointer itself is not restored, but with a 32-bit
         * operand the half of ESP above SP takes the stored value. */
        if (os == 4)
            R(M86_ESP) = (esp_image & ~SP_MASK) | (R(M86_ESP) & SP_MASK);
        break;
    }
    case 0x62: {                /* BOUND */
        decode_modrm(c);
        if (c->mod == 3)
            fault(c, EXC_UD);
        int32_t idx = sext(rd_reg(c, os, c->reg), os);
        int32_t lo = sext(rd_mem(c, c->ea_seg, c->ea_off, os), os);
        int32_t hi = sext(rd_mem(c, c->ea_seg, ea_plus(c, os), os), os);
        if (idx < lo || idx > hi)
            fault(c, EXC_BR);
        break;
    }
    case 0x68: push(c, os, fetch(c, os)); break;
    case 0x6A: push(c, os, (uint32_t)fetch_s(c, 1)); break;
    case 0x69:
        decode_modrm(c);
        v = rd_rm(c, os);
        wr_reg(c, os, c->reg, imul_trunc(c, v, fetch(c, os), os));
        break;
    case 0x6B:
        decode_modrm(c);
        v = rd_rm(c, os);
        wr_reg(c, os, c->reg, imul_trunc(c, v, (uint32_t)fetch_s(c, 1), os));
        break;
    case 0x6C ... 0x6F: case 0xA4 ... 0xA7: case 0xAA ... 0xAF:
        string_op(c, op, size);
        break;

    case 0x70 ... 0x7F: {
        int32_t rel = fetch_s(c, 1);
        c->taken = cond(c, op & 15);
        if (c->taken)
            jump_near(c, c->s.eip + (uint32_t)rel);
        break;
    }
    case 0x80: case 0x81: case 0x82: case 0x83:
        decode_modrm(c);
        a = rd_rm(c, size);
        v = op == 0x83 ? (uint32_t)fetch_s(c, 1) : fetch(c, size);
        v = alu(c, c->reg, a, v, size);
        if (c->reg != 7)
            wr_rm(c, size, v);
        break;
    case 0x84: case 0x85:
        decode_modrm(c);
        alu(c, 4, rd_rm(c, size), rd_reg(c, size, c->reg), size);
        break;
    case 0x86: case 0x87:
        decode_modrm(c);
        v = rd_rm(c, size);
        wr_rm(c, size, rd_reg(c, size, c->reg));
        wr_reg(c, size, c->reg, v);
        break;
    case 0x88: case 0x89:
        decode_modrm(c);
        wr_rm(c, size, rd_reg(c, size, c->reg));
        break;
    case 0x8A: case 0x8B:
        decode_modrm(c);
        wr_reg(c, size, c->reg, rd_rm(c, size));
        break;
    case 0x8C:
        decode_modrm(c);
        if (c->reg > 5)
            fault(c, EXC_UD);
        if (c->mod == 3)
            wr_reg(c, os, c->rm, c->s.seg[c->reg].sel);
        else
            wr_mem(c, c->ea_seg, c->ea_off, 2, c->s.seg[c->reg].sel);
        break;
    case 0x8D:
        decode_modrm(c);
        if (c->mod == 3)
            fault(c, EXC_UD);
        wr_reg(c, os, c->reg, c->ea_off);
        break;
    case 0x8E:
        decode_modrm(c);
        if (c->reg > 5 || c->reg == M86_CS)
            fault(c, EXC_UD);
        set_seg(c, c->reg, (uint16_t)rd_rm(c, 2));
        if (c->reg == M86_SS)
            c->irq_inhibit = 1;
        break;
    case 0x8F:
        /* The address is formed after ESP has moved. */
        v = pop(c, os);
        decode_modrm(c);
        if (c->reg != 0)
            fault(c, EXC_UD);
        wr_rm(c, os, v);
        break;

    case 0x90: break;
    case 0x91 ... 0x97:
        v = rd_reg(c, os, op & 7);
        wr_reg(c, os, op & 7, rd_reg(c, os, M86_EAX));
        wr_reg(c, os, M86_EAX, v);
        break;
    case 0x98:
        if (os == 2)
            wr_reg(c, 2, M86_EAX, (uint32_t)(int8_t)R(M86_EAX));
        else
            R(M86_EAX) = (uint32_t)(int16_t)R(M86_EAX);
        break;
    case 0x99:
        if (os == 2)
            wr_reg(c, 2, M86_EDX, (R(M86_EAX) & 0x8000) ? 0xFFFF : 0);
        else
            R(M86_EDX) = (R(M86_EAX) & 0x80000000u) ? 0xFFFFFFFFu : 0;
        break;
    case 0x9A: {                /* CALL far */
        uint32_t off = fetch(c, os);
        uint16_t sel = (uint16_t)fetch(c, 2);
        far_xfer(c, sel, off, 1);
        break;
    }
    case 0x9B:                  /* WAIT */
        if ((c->cr0 & 0xA) == 0xA)
            fault(c, EXC_NM);
        break;
    case 0x9C:
        if ((FLAGS & M86_VM) && IOPL < 3)
            fault_e(c, EXC_GP, 0);
        push(c, os, FLAGS & 0x00FCFFFFu);
        break;
    case 0x9D:
        if ((FLAGS & M86_VM) && IOPL < 3)
            fault_e(c, EXC_GP, 0);
        v = pop(c, os);
        write_flags(c, v, flag_mask(c, os, c->s.cpl));
        break;
    case 0x9E:
        write_flags(c, R(M86_EAX) >> 8, 0xD5);
        break;
    case 0x9F:
        wr_reg(c, 1, 4, FLAGS & 0xFF);
        break;

    case 0xA0: case 0xA1: case 0xA2: case 0xA3: {
        uint32_t off = fetch(c, c->as32 ? 4 : 2);
        int seg = c->seg_ovr >= 0 ? c->seg_ovr : M86_DS;
        if (op < 0xA2)
            wr_reg(c, size, M86_EAX, rd_mem(c, seg, off, size));
        else
            wr_mem(c, seg, off, size, rd_reg(c, size, M86_EAX));
        break;
    }
    case 0xA8: case 0xA9:
        alu(c, 4, rd_reg(c, size, M86_EAX), fetch(c, size), size);
        break;

    case 0xB0 ... 0xB7: wr_reg(c, 1, op & 7, fetch8(c)); break;
    case 0xB8 ... 0xBF: wr_reg(c, os, op & 7, fetch(c, os)); break;

    case 0xC0: case 0xC1:
        decode_modrm(c);
        v = rd_rm(c, size);
        a = fetch8(c);
        wr_rm(c, size, shift(c, c->reg, v, a, size));
        break;
    case 0xD0: case 0xD1:
        decode_modrm(c);
        wr_rm(c, size, shift(c, c->reg, rd_rm(c, size), 1, size));
        break;
    case 0xD2: case 0xD3:
        decode_modrm(c);
        wr_rm(c, size, shift(c, c->reg, rd_rm(c, size), R(M86_ECX), size));
        break;

    case 0xC2: {                /* RET imm16 */
        uint32_t n = fetch(c, 2);
        v = pop(c, os);
        R(M86_ESP) = (R(M86_ESP) & ~SP_MASK) | ((R(M86_ESP) + n) & SP_MASK);
        jump_near(c, v);
        break;
    }
    case 0xC3:
        v = pop(c, os);
        jump_near(c, v);
        break;
    case 0xC4: decode_modrm(c); load_far_pointer(c, M86_ES); break;
    case 0xC5: decode_modrm(c); load_far_pointer(c, M86_DS); break;
    case 0xC6: case 0xC7:
        decode_modrm(c);
        if (c->reg != 0)
            fault(c, EXC_UD);
        wr_rm(c, size, fetch(c, size));
        break;
    case 0xC8: {                /* ENTER */
        uint32_t alloc = fetch(c, 2);
        int level = fetch8(c) & 31;
        push(c, os, R(M86_EBP));
        uint32_t frame = R(M86_ESP);
        if (level > 0) {
            uint32_t bp = R(M86_EBP);
            for (int i = 1; i < level; i++) {
                bp = (bp & ~SP_MASK) | ((bp - (uint32_t)os) & SP_MASK);
                push(c, os, rd_mem(c, M86_SS, bp & SP_MASK, os));
            }
            push(c, os, frame);
        }
        /* With paging on, the page the final stack pointer is in must
         * be writable. */
        if (c->cr0 & 0x80000000u)
            translate(c, c->s.seg[M86_SS].base + ((R(M86_ESP) - alloc) & SP_MASK), 1, c->s.cpl == 3);
        wr_reg(c, os, M86_EBP, frame);
        R(M86_ESP) = (R(M86_ESP) & ~SP_MASK) | ((R(M86_ESP) - alloc) & SP_MASK);
        break;
    }
    case 0xC9:                  /* LEAVE */
        R(M86_ESP) = (R(M86_ESP) & ~SP_MASK) | (R(M86_EBP) & SP_MASK);
        v = pop(c, os);
        wr_reg(c, os, M86_EBP, v);
        break;
    case 0xCA: case 0xCB: {     /* RET far */
        uint32_t n = op == 0xCA ? fetch(c, 2) : 0;
        far_return(c, n, 0);
        break;
    }
    case 0xCC: interrupt(c, EXC_BP, c->s.eip, INT_SOFT); break;
    case 0xCD:
        v = fetch8(c);
        if ((FLAGS & M86_VM) && IOPL < 3)
            fault_e(c, EXC_GP, 0);
        interrupt(c, (int)v, c->s.eip, INT_SOFT);
        break;
    case 0xCE:
        if (FLAGS & M86_OF)
            interrupt(c, EXC_OF, c->s.eip, INT_SOFT);
        break;
    case 0xCF: {                /* IRET */
        far_return(c, 0, 1);
        break;
    }

    case 0xD4: {                /* AAM */
        uint32_t base = fetch8(c);
        if (base == 0)
            fault(c, EXC_DE);
        uint32_t al = R(M86_EAX) & 0xFF;
        wr_reg(c, 2, M86_EAX, ((al / base) << 8) | (al % base));
        set_szp(c, al % base, 1);
        break;
    }
    case 0xD5: {                /* AAD */
        uint32_t base = fetch8(c);
        uint32_t al = R(M86_EAX) & 0xFF, ah = (R(M86_EAX) >> 8) & 0xFF;
        v = alu(c, 0, al, (ah * base) & 0xFF, 1);
        wr_reg(c, 2, M86_EAX, v);
        break;
    }
    case 0xD6:                  /* SALC */
        wr_reg(c, 1, 0, (FLAGS & M86_CF) ? 0xFF : 0);
        break;
    case 0xD7: {                /* XLAT */
        uint32_t off = R(M86_EBX) + (R(M86_EAX) & 0xFF);
        if (!c->as32)
            off &= 0xFFFF;
        wr_reg(c, 1, 0,
               rd_mem(c, c->seg_ovr >= 0 ? c->seg_ovr : M86_DS, off, 1));
        break;
    }
    case 0xD8 ... 0xDF:         /* coprocessor escape: there is none */
        decode_modrm(c);
        if (c->cr0 & 0xC)       /* EM or TS */
            fault(c, EXC_NM);
        break;

    case 0xE0: case 0xE1: case 0xE2: case 0xE3: {
        int32_t rel = fetch_s(c, 1);
        uint32_t am = c->as32 ? 0xFFFFFFFFu : 0xFFFFu;
        if (op == 0xE3) {
            c->taken = (R(M86_ECX) & am) == 0;
        } else {
            uint32_t cx = (R(M86_ECX) - 1) & am;
            R(M86_ECX) = (R(M86_ECX) & ~am) | cx;
            c->taken = cx != 0;
            if (op == 0xE0)
                c->taken = c->taken && !(FLAGS & M86_ZF);
            else if (op == 0xE1)
                c->taken = c->taken && (FLAGS & M86_ZF);
        }
        if (c->taken)
            jump_near(c, c->s.eip + (uint32_t)rel);
        break;
    }
    case 0xE4: case 0xE5:
        v = fetch8(c);
        io_check(c, v, size);
        wr_reg(c, size, M86_EAX, c->io_read(c->bus, (uint16_t)v, size));
        break;
    case 0xE6: case 0xE7:
        v = fetch8(c);
        io_check(c, v, size);
        c->io_write(c->bus, (uint16_t)v, size, rd_reg(c, size, M86_EAX));
        break;
    case 0xEC: case 0xED:
        io_check(c, R(M86_EDX) & 0xFFFF, size);
        wr_reg(c, size, M86_EAX,
               c->io_read(c->bus, (uint16_t)R(M86_EDX), size));
        break;
    case 0xEE: case 0xEF:
        io_check(c, R(M86_EDX) & 0xFFFF, size);
        c->io_write(c->bus, (uint16_t)R(M86_EDX), size,
                    rd_reg(c, size, M86_EAX));
        break;
    case 0xE8: {
        int32_t rel = fetch_s(c, os);
        push(c, os, c->s.eip);
        jump_near(c, c->s.eip + (uint32_t)rel);
        break;
    }
    case 0xE9: {
        int32_t rel = fetch_s(c, os);
        jump_near(c, c->s.eip + (uint32_t)rel);
        break;
    }
    case 0xEA: {
        uint32_t off = fetch(c, os);
        uint16_t sel = (uint16_t)fetch(c, 2);
        far_xfer(c, sel, off, 0);
        break;
    }
    case 0xEB: {
        int32_t rel = fetch_s(c, 1);
        jump_near(c, c->s.eip + (uint32_t)rel);
        break;
    }

    case 0xF1: interrupt(c, EXC_DB, c->s.eip, INT_SOFT); break;
    case 0xF4: privileged(c); c->halted = 1; break;
    case 0xF5: FLAGS ^= M86_CF; break;
    case 0xF6: case 0xF7: decode_modrm(c); group3(c, size); break;
    case 0xF8: FLAGS &= ~M86_CF; break;
    case 0xF9: FLAGS |= M86_CF; break;
    case 0xFA:
        if ((c->cr0 & 1) && c->s.cpl > IOPL)
            fault_e(c, EXC_GP, 0);
        FLAGS &= ~M86_IF;
        break;
    case 0xFB:
        if ((c->cr0 & 1) && c->s.cpl > IOPL)
            fault_e(c, EXC_GP, 0);
        if (!(FLAGS & M86_IF))
            c->irq_inhibit = 1;
        FLAGS |= M86_IF;
        break;
    case 0xFC: FLAGS &= ~M86_DF; break;
    case 0xFD: FLAGS |= M86_DF; break;

    case 0xFE:
        decode_modrm(c);
        if (c->reg > 1)
            fault(c, EXC_UD);
        wr_rm(c, 1, incdec(c, rd_rm(c, 1), c->reg, 1));
        break;
    case 0xFF:
        decode_modrm(c);
        switch (c->reg) {
        case 0: case 1:
            wr_rm(c, os, incdec(c, rd_rm(c, os), c->reg, os));
            break;
        case 2:
            v = rd_rm(c, os);
            push(c, os, c->s.eip);
            jump_near(c, v);
            break;
        case 4:
            jump_near(c, rd_rm(c, os));
            break;
        case 3: case 5: {
            if (c->mod == 3)
                fault(c, EXC_UD);
            uint32_t off = rd_mem(c, c->ea_seg, c->ea_off, os);
            uint32_t sel = rd_mem(c, c->ea_seg, ea_plus(c, os), 2);
            far_xfer(c, (uint16_t)sel, off, c->reg == 3);
            break;
        }
        case 6:
            push(c, os, rd_rm(c, os));
            break;
        default:
            fault(c, EXC_UD);
        }
        break;

    case 0x63: {                /* ARPL: not recognised outside protected mode */
        if (!PMODE)
            fault(c, EXC_UD);
        decode_modrm(c);
        uint32_t d = rd_rm(c, 2), r = rd_reg(c, 2, c->reg);
        if ((d & 3) < (r & 3)) {
            wr_rm(c, 2, (d & ~3u) | (r & 3));
            FLAGS |= M86_ZF;
        } else {
            FLAGS &= ~M86_ZF;
        }
        break;
    }
    default:
        fault(c, EXC_UD);
    }
}

/* ---- classification for the profile ----------------------------- */

static int classify(const m86 *c)
{
    int op = c->op, mem = c->mod != 3, reg = c->reg;

    if (op >= 0x100) {
        op &= 0xFF;
        if (op >= 0x80 && op <= 0x8F)
            return c->taken ? M86_CL_JCC_TAKEN : M86_CL_JCC_NOT;
        if (op >= 0x90 && op <= 0x9F)
            return mem ? M86_CL_STORE : M86_CL_REGREG;
        if (op == 0xB6 || op == 0xB7 || op == 0xBE || op == 0xBF)
            return mem ? M86_CL_LOAD : M86_CL_REGREG;
        if (op == 0xA0 || op == 0xA1 || op == 0xA8 || op == 0xA9)
            return M86_CL_PUSHPOP;
        return M86_CL_SLOW;
    }
    if (op < 0x40) {
        switch (op & 7) {
        case 0: case 1:
            if (!mem) return M86_CL_REGREG;
            return (op >> 3) == 7 ? M86_CL_ALUMEM : M86_CL_RMW;
        case 2: case 3: return mem ? M86_CL_ALUMEM : M86_CL_REGREG;
        case 4: case 5: return M86_CL_REGREG;
        default:
            return op >= 0x26 ? M86_CL_SLOW : M86_CL_PUSHPOP;
        }
    }
    switch (op) {
    case 0x40 ... 0x4F: return M86_CL_REGREG;
    case 0x50 ... 0x5F: case 0x68: case 0x6A: case 0x8F: case 0x9C:
    case 0xC9:
        return M86_CL_PUSHPOP;
    case 0x70 ... 0x7F: case 0xE0 ... 0xE3:
        return c->taken ? M86_CL_JCC_TAKEN : M86_CL_JCC_NOT;
    case 0x80 ... 0x83:
        if (!mem) return M86_CL_REGREG;
        return reg == 7 ? M86_CL_ALUMEM : M86_CL_RMW;
    case 0x84: case 0x85: return mem ? M86_CL_ALUMEM : M86_CL_REGREG;
    case 0x86: case 0x87: return mem ? M86_CL_RMW : M86_CL_REGREG;
    case 0x88: case 0x89: case 0x8C: case 0xC6: case 0xC7:
        return mem ? M86_CL_STORE : M86_CL_REGREG;
    case 0x8A: case 0x8B: return mem ? M86_CL_LOAD : M86_CL_REGREG;
    case 0x8D: case 0x90 ... 0x99: case 0x9B: case 0x9E: case 0x9F:
    case 0xA8: case 0xA9: case 0xB0 ... 0xBF: case 0xD6: case 0xF5:
    case 0xF8 ... 0xFD:
        return M86_CL_REGREG;
    case 0xA0: case 0xA1: case 0xD7: return M86_CL_LOAD;
    case 0xA2: case 0xA3: return M86_CL_STORE;
    case 0xD0: case 0xD1: return mem ? M86_CL_RMW : M86_CL_REGREG;
    case 0xC2: case 0xC3: case 0xE8: case 0xE9: case 0xEB:
        return M86_CL_CALLRET;
    case 0xF6: case 0xF7:
        if (reg < 2) return mem ? M86_CL_ALUMEM : M86_CL_REGREG;
        if (reg < 4) return mem ? M86_CL_RMW : M86_CL_REGREG;
        return M86_CL_SLOW;
    case 0xFE: case 0xFF:
        if (reg < 2) return mem ? M86_CL_RMW : M86_CL_REGREG;
        if (reg == 2 || reg == 4) return M86_CL_CALLRET;
        if (reg == 6) return M86_CL_PUSHPOP;
        return M86_CL_SLOW;
    default:
        return M86_CL_SLOW;
    }
}

/* ---- public ---------------------------------------------------- */

void m86_reset(m86 *c)
{
    memset(&c->s, 0, sizeof c->s);
    for (int i = 0; i < 6; i++)
        c->s.seg[i].limit = 0xFFFF;
    /* I386-DS: execution starts at F000:FFF0, DH holds the family. */
    c->s.seg[M86_CS].sel = 0xF000;
    c->s.seg[M86_CS].base = 0x000F0000;
    c->s.eip = 0xFFF0;
    c->s.eflags = 2;
    c->s.r[M86_EDX] = 0x0420;           /* a 486SX */
    c->cr0 = 0;
    c->cr2 = c->cr3 = 0;
    memset(c->dr, 0, sizeof c->dr);
    c->gdtr.base = c->idtr.base = 0;
    c->gdtr.limit = c->idtr.limit = 0xFFFF;
    c->halted = c->shutdown = c->unsupported = 0;
    c->irq_inhibit = 0;
    c->last_exception = -1;
}

void m86_init(m86 *c)
{
    memset(c, 0, sizeof *c);
    m86_reset(c);
}

/* A fault: put the state back and enter the handler. A fault while
 * doing that is a double fault, and one more stops the CPU. */
static void deliver_fault(m86 *c, volatile int vec)
{
    /* M86_FAULTS=n in the environment: say where the first n faults
     * taken with PE set were, for finding what a program wanted. */
    static int flog = -1;
    if (flog < 0)
        flog = getenv("M86_FAULTS") ? atoi(getenv("M86_FAULTS")) : 0;
    if (flog > 0 && (c->cr0 & 1)) {
        uint32_t la = c->snap.seg[M86_CS].base + c->snap.eip;
        flog--;
        fprintf(stderr, "fault %d (code %x, level %d) at %04x:%08x (D=%d):", vec, c->err,
                c->snap.cpl, c->snap.seg[M86_CS].sel, c->snap.eip, c->snap.seg[M86_CS].d);
        for (int k = 0; k < 12; k++)
            fprintf(stderr, " %02x", c->mem_read(c->bus, la + (uint32_t)k));
        fprintf(stderr, "\n");
    }
    for (;;) {
        c->s = c->snap;
        c->last_exception = vec;
        volatile int first = vec;
        int again = setjmp(c->fault_jmp);
        if (!again) {
            interrupt(c, vec, c->snap.eip, INT_FAULT);
            return;
        }
        /* A fault while delivering one. Two of the contributory kind,
         * or anything of those after a page fault, make a double
         * fault; a fault delivering that stops the CPU. Otherwise the
         * new fault is simply the one delivered. */
        int second = again - 1;
        int c1 = first == 0 || (first >= 10 && first <= 13);
        int c2 = second == 0 || (second >= 10 && second <= 13);
        if (first == EXC_DF || ++c->fault_depth >= 4) {
            c->shutdown = 1;
            return;
        }
        if ((c1 && c2) || (first == EXC_PF && (c2 || second == EXC_PF))) {
            vec = EXC_DF;
            c->err = 0;
        } else {
            vec = second;
        }
    }
}

void m86_step(m86 *c)
{
    if (c->shutdown || c->unsupported)
        return;

    c->snap = c->s;
    c->fault_depth = 0;

    int inhibit = c->irq_inhibit;
    c->irq_inhibit = 0;

    if (!inhibit && (c->nmi || (c->irq && (FLAGS & M86_IF)))) {
        volatile int vec = 2;
        if (c->nmi)
            c->nmi = 0;
        else
            vec = c->irq_ack(c->bus);
        c->halted = 0;
        int f = setjmp(c->fault_jmp);
        if (f)
            deliver_fault(c, f - 1);
        else
            interrupt(c, vec, c->s.eip, INT_EXT);
        return;
    }
    if (c->halted)
        return;

    c->os = c->s.seg[M86_CS].d ? 4 : 2;
    c->as32 = c->s.seg[M86_CS].d;
    c->seg_ovr = -1;
    c->rep = 0;
    c->lock = 0;
    c->len = 0;
    c->mod = 3;
    c->reg = 0;
    c->taken = 0;

    /* M86_BREAK=offset (hex) in the environment: when execution first
     * reaches that offset, say where the last instructions were. */
    {
        static uint32_t brk, ring[16][3];
        static int init, at;
        if (!init) {
            init = 1;
            brk = getenv("M86_BREAK") ? (uint32_t)strtoul(getenv("M86_BREAK"), 0, 16) : 0xFFFFFFFFu;
            if (brk == 0xFFFFFFFFu)
                init = 2;
        }
        if (init == 1) {
            ring[at][0] = c->s.seg[M86_CS].sel;
            ring[at][1] = c->s.eip;
            ring[at][2] = R(M86_ESP);
            at = (at + 1) & 15;
            if (c->s.eip == brk) {
                for (int i = 0; i < 16; i++)
                    fprintf(stderr, "before: %04x:%08x esp=%08x\n", ring[(at + i) & 15][0],
                            ring[(at + i) & 15][1], ring[(at + i) & 15][2]);
                fprintf(stderr, "eax=%08x ecx=%08x edx=%08x ebx=%08x ebp=%08x esi=%08x edi=%08x\n",
                        R(0), R(1), R(2), R(3), R(5), R(6), R(7));
                init = 2;
            }
        }
    }
    int trap = (FLAGS & M86_TF) != 0;
    int f = setjmp(c->fault_jmp);
    if (f) {
        deliver_fault(c, f - 1);
        return;
    }
    exec(c);
    c->icount++;
    int cls = classify(c);
    c->class_count[cls]++;
    if (cls == M86_CL_SLOW)
        c->slow_count[c->op & 0x1FF]++;

    if (trap && !c->shutdown) {
        c->snap = c->s;
        f = setjmp(c->fault_jmp);
        if (f)
            deliver_fault(c, f - 1);
        else
            interrupt(c, EXC_DB, c->s.eip, INT_FAULT);
    }
}
