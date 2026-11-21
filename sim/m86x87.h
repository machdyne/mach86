/*
 * m86x87.h: the x87 instructions of the model's processor (a 486DX's
 * floating-point unit), on the arithmetic of m86fpu.c. Part of
 * m86cpu.c; see docs/fpu.md.
 */

#define FP          (c->fp)
#define FP_TOP      ((FP.sw >> 11) & 7)
#define FP_PHYS(i)  ((FP_TOP + (i)) & 7)
#define FP_ST(i)    (FP.st[FP_PHYS(i)])
#define FP_EMPTY(i) ((FP.empty >> FP_PHYS(i)) & 1)
#define FP_SF       0x40u
#define FP_C0       0x0100u
#define FP_C1       0x0200u
#define FP_C2       0x0400u
#define FP_C3       0x4000u
#define FP_CC       (FP_C0 | FP_C1 | FP_C2 | FP_C3)

static const m86f80 fp_indef = { 0xC000000000000000ull, 0xFFFF };

/* The summary bits follow the flags and their masks; an exception that
 * is not masked is also the FERR line (for interrupt 13 of a PC, when
 * CR0's NE is clear). */
static void fp_summary(m86 *c)
{
    if (FP.sw & ~FP.cw & 0x3F)
        FP.sw |= 0x8080;
    else
        FP.sw &= 0x7F7F;
    c->ferr = (FP.sw & 0x80) != 0;
    if (!c->ferr)
        c->ignne = 0;
}

static void m86_fpu_reset(m86 *c)
{
    memset(&c->fp, 0, sizeof c->fp);
    FP.cw = 0x037F;
    FP.empty = 0xFF;
    c->ferr = c->ignne = 0;
    c->fp_stop = 0;
}

static void fp_set_top(m86 *c, int t)
{
    FP.sw = (uint16_t)((FP.sw & ~0x3800) | ((t & 7) << 11));
}

static void fp_pop(m86 *c)
{
    FP.empty |= (uint8_t)(1 << FP_TOP);
    fp_set_top(c, FP_TOP + 1);
}

static void fp_c1(m86 *c, int v)
{
    FP.sw = (uint16_t)(v ? FP.sw | FP_C1 : FP.sw & ~FP_C1);
}

/* A stack fault: an empty register read (under: 0) or a full one
 * pushed onto (over: 1). Nonzero if the instruction goes on, with the
 * indefinite number for a result (the invalid exception is masked). */
static int fp_stack_fault(m86 *c, int over)
{
    FP.sw |= FX_I | FP_SF;
    fp_c1(c, over);
    return (FP.cw & FX_I) != 0;
}

/* The flags of an operation go to the status word. Nonzero if it is
 * stopped before it does anything: an invalid operation, a denormal
 * operand or a division by zero that is not masked (and, for a store
 * to memory, overflow and underflow). */
static int fp_post(m86 *c, unsigned fl, int store)
{
    unsigned stop = fl & ~FP.cw & (FX_I | FX_D | FX_Z);
    if (stop) {
        FP.sw |= fl & (FX_I | FX_D | FX_Z);
        return 1;
    }
    if (store && (fl & ~FP.cw & (FX_O | FX_U))) {
        FP.sw |= fl & (FX_O | FX_U);
        return 1;
    }
    FP.sw |= fl & 0x3F;
    fp_c1(c, (fl & FX_C1) != 0);
    return 0;
}

static m86fctx fp_ctx(m86 *c)
{
    m86fctx x = { (FP.cw >> 10) & 3, (FP.cw >> 8) & 3, 0, ~FP.cw & (FX_O | FX_U) };
    return x;
}

/* Push: nonzero if done. */
static int fp_push(m86 *c, m86f80 v)
{
    int n = (FP_TOP - 1) & 7;
    if (!((FP.empty >> n) & 1)) {
        if (!fp_stack_fault(c, 1))
            return 0;
        v = fp_indef;
    } else
        fp_c1(c, 0);
    fp_set_top(c, n);
    FP.st[n] = v;
    FP.empty &= (uint8_t)~(1 << n);
    return 1;
}

static uint64_t fp_rd64(m86 *c)
{
    uint64_t lo = rd_mem(c, c->ea_seg, c->ea_off, 4);
    return lo | ((uint64_t)rd_mem(c, c->ea_seg, ea_plus(c, 4), 4) << 32);
}

static void fp_wr64(m86 *c, uint64_t v)
{
    wr_mem(c, c->ea_seg, c->ea_off, 4, (uint32_t)v);
    wr_mem(c, c->ea_seg, ea_plus(c, 4), 4, (uint32_t)(v >> 32));
}

static m86f80 fp_rd80(m86 *c, int at)
{
    m86f80 v;
    v.m = rd_mem(c, c->ea_seg, ea_plus(c, at), 4);
    v.m |= (uint64_t)rd_mem(c, c->ea_seg, ea_plus(c, at + 4), 4) << 32;
    v.se = (uint16_t)rd_mem(c, c->ea_seg, ea_plus(c, at + 8), 2);
    return v;
}

static void fp_wr80(m86 *c, int at, m86f80 v)
{
    wr_mem(c, c->ea_seg, ea_plus(c, at), 4, (uint32_t)v.m);
    wr_mem(c, c->ea_seg, ea_plus(c, at + 4), 4, (uint32_t)(v.m >> 32));
    wr_mem(c, c->ea_seg, ea_plus(c, at + 8), 2, v.se);
}

static unsigned fp_tags(m86 *c)
{
    unsigned t = 0;
    for (int i = 0; i < 8; i++) {
        unsigned k = 3;
        if (!((FP.empty >> i) & 1)) {
            int cl = m86f_class(FP.st[i]);
            k = cl == FC_ZERO ? 1 : cl == FC_NORMAL ? 0 : 2;
        }
        t |= k << (2 * i);
    }
    return t;
}

/* The environment: 14 or 28 bytes, in the layout of real or protected
 * mode. */
static int fp_env_size(m86 *c) { return c->os == 4 ? 28 : 14; }

static void fp_store_env(m86 *c)
{
    int prot = PMODE;
    uint32_t w[7];
    w[0] = FP.cw; w[1] = FP.sw; w[2] = fp_tags(c);
    if (prot) {
        w[3] = FP.fip; w[4] = FP.fcs; w[5] = FP.fdp; w[6] = FP.fds;
        if (c->os == 4)
            w[4] |= (uint32_t)FP.fop << 16;
    } else {
        uint32_t ip = ((uint32_t)FP.fcs << 4) + FP.fip, dp = ((uint32_t)FP.fds << 4) + FP.fdp;
        w[3] = ip & 0xFFFF; w[5] = dp & 0xFFFF;
        if (c->os == 4) {
            w[4] = ((ip >> 16) << 12 & 0x0FFFF000u) | FP.fop;
            w[6] = (dp >> 16) << 12 & 0x0FFFF000u;
        } else {
            w[4] = ((ip >> 16) << 12 & 0xF000) | FP.fop;
            w[6] = (dp >> 16) << 12 & 0xF000;
        }
    }
    for (int i = 0; i < 7; i++) {
        if (c->os == 4) {
            if (i < 3 || (prot && i == 6))
                w[i] |= 0xFFFF0000u;    /* (the unused halves read as ones) */
            wr_mem(c, c->ea_seg, ea_plus(c, 4 * i), 4, w[i]);
        } else
            wr_mem(c, c->ea_seg, ea_plus(c, 2 * i), 2, w[i] & 0xFFFF);
    }
}

static void fp_load_env(m86 *c)
{
    int prot = PMODE;
    uint32_t w[7];
    for (int i = 0; i < 7; i++)
        w[i] = c->os == 4 ? rd_mem(c, c->ea_seg, ea_plus(c, 4 * i), 4)
                          : rd_mem(c, c->ea_seg, ea_plus(c, 2 * i), 2);
    FP.cw = (uint16_t)(w[0] | 0x40);
    FP.sw = (uint16_t)w[1];
    FP.empty = 0;
    for (int i = 0; i < 8; i++)
        if (((w[2] >> (2 * i)) & 3) == 3)
            FP.empty |= (uint8_t)(1 << i);
    if (prot) {
        FP.fip = c->os == 4 ? w[3] : (w[3] & 0xFFFF);
        FP.fcs = (uint16_t)w[4];
        FP.fop = c->os == 4 ? (uint16_t)((w[4] >> 16) & 0x7FF) : 0;
        FP.fdp = c->os == 4 ? w[5] : (w[5] & 0xFFFF);
        FP.fds = (uint16_t)w[6];
    } else {
        /* (Linear addresses: kept as offsets from segment 0.) */
        FP.fop = (uint16_t)(w[4] & 0x7FF);
        FP.fcs = FP.fds = 0;
        if (c->os == 4) {
            FP.fip = (w[3] & 0xFFFF) | ((w[4] >> 12 & 0xFFFF) << 16);
            FP.fdp = (w[5] & 0xFFFF) | ((w[6] >> 12 & 0xFFFF) << 16);
        } else {
            FP.fip = (w[3] & 0xFFFF) | ((w[4] >> 12 & 0xF) << 16);
            FP.fdp = (w[5] & 0xFFFF) | ((w[6] >> 12 & 0xF) << 16);
        }
    }
    fp_summary(c);
}

/* The eight arithmetic operations of D8/DA/DC/DE by the reg field, on
 * ST and another operand: the result, or a comparison's condition bits. */
static m86f80 fp_arith(m86fctx *x, int reg, m86f80 st, m86f80 o)
{
    switch (reg) {
    case 0: return m86f_add(x, st, o);
    case 1: return m86f_mul(x, st, o);
    case 4: return m86f_sub(x, st, o);
    case 5: return m86f_sub(x, o, st);
    case 6: return m86f_div(x, st, o);
    default: return m86f_div(x, o, st);
    }
}

static void fp_setcc(m86 *c, unsigned cc)
{
    FP.sw = (uint16_t)((FP.sw & ~(FP_C0 | FP_C2 | FP_C3)) | cc);
}

/* Compare ST with o (o_empty: it is an empty register), and pop. */
static void fp_compare(m86 *c, m86f80 o, int o_empty, int quiet, int pops)
{
    if (FP_EMPTY(0) || o_empty) {
        if (!fp_stack_fault(c, 0))
            return;
        fp_setcc(c, FP_C0 | FP_C2 | FP_C3);
    } else {
        m86fctx x = fp_ctx(c);
        unsigned cc = m86f_cmp(&x, FP_ST(0), o, quiet);
        if (fp_post(c, x.fl, 0))
            return;
        fp_c1(c, 0);
        fp_setcc(c, cc);
    }
    while (pops--)
        fp_pop(c);
}

/* ST(dst) = ST op o, and pop. */
static void fp_binary(m86 *c, int reg, int dst, m86f80 o, int o_empty, unsigned pre, int pop)
{
    m86f80 r;
    if (FP_EMPTY(0) || o_empty) {
        if (!fp_stack_fault(c, 0))
            return;
        r = fp_indef;
    } else {
        m86fctx x = fp_ctx(c);
        x.fl = pre;
        r = fp_arith(&x, reg, FP_ST(0), o);
        if (fp_post(c, x.fl, 0))
            return;
    }
    FP_ST(dst) = r;
    if (pop)
        fp_pop(c);
}

/* A function of ST alone, the result in ST. */
static void fp_unary(m86 *c, m86f80 (*fn)(m86fctx *, m86f80))
{
    m86f80 r = fp_indef;
    if (FP_EMPTY(0)) {
        if (!fp_stack_fault(c, 0))
            return;
    } else {
        m86fctx x = fp_ctx(c);
        r = fn(&x, FP_ST(0));
        if (fp_post(c, x.fl, 0))
            return;
    }
    FP_ST(0) = r;
}

static void fp_fninit(m86 *c)
{
    FP.cw = 0x037F;
    FP.sw = 0;
    FP.empty = 0xFF;
    FP.fip = FP.fdp = 0;
    FP.fcs = FP.fds = FP.fop = 0;
    fp_summary(c);
}

/* An exception is waiting and not masked: the next instruction that
 * looks is interrupted. With CR0's NE, by exception 16. Without (as DOS
 * has it), the FERR line has been asking for interrupt 13 since the
 * exception; the instruction waits for an interrupt, unless the PC has
 * said to go on (IGNNE: a write to port F0h). */
static int fp_check(m86 *c)
{
    if (!(FP.sw & 0x80))
        return 0;
    if (c->cr0 & 0x20)
        fault(c, EXC_MF);
    if (c->ignne)
        return 0;
    c->s = c->snap;             /* (the instruction has not begun) */
    c->fp_stop = 1;
    return 1;
}

static void x87(m86 *c, int op)
{
    int esc = op & 7, mem = c->mod != 3, reg = c->reg, i = c->rm;
    int code = (esc << 3) | reg;        /* for memory forms */
    int rcode = (esc << 8) | (0xC0 | (reg << 3) | i);   /* register forms: Dx yy */

    if (c->cr0 & 0xC)                   /* EM or TS */
        fault(c, EXC_NM);

    /* The control instructions that do not look for a waiting exception. */
    int nowait = mem ? (code == 016 || code == 017 || code == 056 || code == 057)
                     : (rcode >= 0x3E0 && rcode <= 0x3E4) || rcode == 0x7E0;
    if (!nowait && fp_check(c))
        return;

    /* Where the last instruction and its operand were. */
    int control = nowait || (mem && (code == 014 || code == 015 || code == 054));
    uint16_t n_fop = (uint16_t)((esc << 8) | (c->mod << 6) | (reg << 3) | i);
    #define FP_POINTERS() do { if (!control) { \
            FP.fip = c->snap.eip; FP.fcs = c->snap.seg[M86_CS].sel; FP.fop = n_fop; \
            if (mem) { FP.fdp = c->ea_off; FP.fds = c->s.seg[c->ea_seg].sel; } } } while (0)

    m86fctx x = fp_ctx(c);

    if (mem) {
        switch (code) {
        /* ---- arithmetic with a memory operand ---- */
        case 000: case 001: case 002: case 003: case 004: case 005: case 006: case 007:     /* m32 real */
        case 020: case 021: case 022: case 023: case 024: case 025: case 026: case 027:     /* m32 integer */
        case 040: case 041: case 042: case 043: case 044: case 045: case 046: case 047:     /* m64 real */
        case 060: case 061: case 062: case 063: case 064: case 065: case 066: case 067: {   /* m16 integer */
            m86f80 o;
            m86fctx y = fp_ctx(c);
            switch (esc) {
            case 0: o = m86f_from_f32(&y, rd_mem(c, c->ea_seg, c->ea_off, 4)); break;
            case 2: o = m86f_from_i64((int32_t)rd_mem(c, c->ea_seg, c->ea_off, 4)); break;
            case 4: o = m86f_from_f64(&y, fp_rd64(c)); break;
            default: o = m86f_from_i64((int16_t)rd_mem(c, c->ea_seg, c->ea_off, 2)); break;
            }
            FP_POINTERS();
            if (reg == 2 || reg == 3) {
                /* (Any NaN is invalid in the comparison itself.) */
                if (y.fl & ~FP.cw & FX_D) {
                    FP.sw |= FX_D;
                    break;
                }
                FP.sw |= y.fl & FX_D;
                fp_compare(c, o, 0, 0, reg == 3);
            } else
                fp_binary(c, reg, 0, o, 0, y.fl, 0);
            break;
        }
        /* ---- loads ---- */
        case 010: {                     /* FLD m32 */
            m86f80 v = m86f_from_f32(&x, rd_mem(c, c->ea_seg, c->ea_off, 4));
            FP_POINTERS();
            if ((x.fl & ~FP.cw & FX_I)) { FP.sw |= FX_I; break; }
            if (fp_push(c, v)) FP.sw |= x.fl & 0x3F;
            break;
        }
        case 050: {                     /* FLD m64 */
            m86f80 v = m86f_from_f64(&x, fp_rd64(c));
            FP_POINTERS();
            if ((x.fl & ~FP.cw & FX_I)) { FP.sw |= FX_I; break; }
            if (fp_push(c, v)) FP.sw |= x.fl & 0x3F;
            break;
        }
        case 035: {                     /* FLD m80 */
            m86f80 v = fp_rd80(c, 0);
            FP_POINTERS();
            fp_push(c, v);
            break;
        }
        case 030: case 070: case 075: { /* FILD m32, m16, m64 */
            int64_t v = code == 030 ? (int32_t)rd_mem(c, c->ea_seg, c->ea_off, 4)
                      : code == 070 ? (int16_t)rd_mem(c, c->ea_seg, c->ea_off, 2)
                      : (int64_t)fp_rd64(c);
            FP_POINTERS();
            fp_push(c, m86f_from_i64(v));
            break;
        }
        case 074: {                     /* FBLD */
            uint8_t b[10];
            for (int k = 0; k < 10; k++)
                b[k] = (uint8_t)rd_mem(c, c->ea_seg, ea_plus(c, k), 1);
            FP_POINTERS();
            fp_push(c, m86f_from_bcd(b));
            break;
        }
        /* ---- stores ---- */
        case 012: case 013: case 052: case 053:         /* FST, FSTP m32, m64 */
        case 032: case 033: case 072: case 073: case 077: {     /* FIST, FISTP m32, m16; FISTP m64 */
            int real = (esc == 1 || esc == 5), pop = (reg != 2);
            int bits = code == 077 ? 64 : esc == 3 || esc == 1 ? 32 : esc == 5 ? 64 : 16;
            uint64_t v;
            FP_POINTERS();
            if (FP_EMPTY(0)) {
                if (!fp_stack_fault(c, 0))
                    break;
                x.fl = 0;
                v = real ? (bits == 32 ? 0xFFC00000ull : 0xFFF8000000000000ull)
                         : (uint64_t)1 << (bits - 1);
            } else {
                v = real ? (bits == 32 ? m86f_to_f32(&x, FP_ST(0)) : m86f_to_f64(&x, FP_ST(0)))
                         : (uint64_t)m86f_to_int(&x, FP_ST(0), bits);
                if (x.fl & ~FP.cw & (FX_I | FX_O | FX_U)) {
                    fp_post(c, x.fl & (FX_I | FX_O | FX_U), 1);
                    break;
                }
            }
            if (bits == 64)
                fp_wr64(c, v);
            else
                wr_mem(c, c->ea_seg, c->ea_off, bits / 8, (uint32_t)v);
            FP.sw |= x.fl & 0x3F;
            fp_c1(c, (x.fl & FX_C1) != 0);
            if (pop)
                fp_pop(c);
            break;
        }
        case 037: {                     /* FSTP m80 */
            m86f80 v = fp_indef;
            FP_POINTERS();
            if (FP_EMPTY(0) && !fp_stack_fault(c, 0))
                break;
            if (!FP_EMPTY(0)) { v = FP_ST(0); fp_c1(c, 0); }
            fp_wr80(c, 0, v);
            fp_pop(c);
            break;
        }
        case 076: {                     /* FBSTP */
            uint8_t b[10] = { 0, 0, 0, 0, 0, 0, 0, 0xC0, 0xFF, 0xFF };
            FP_POINTERS();
            if (FP_EMPTY(0)) {
                if (!fp_stack_fault(c, 0))
                    break;
                x.fl = 0;
            } else {
                m86f_to_bcd(&x, FP_ST(0), b);
                if (x.fl & ~FP.cw & FX_I) { FP.sw |= FX_I; break; }
            }
            for (int k = 0; k < 10; k++)
                wr_mem(c, c->ea_seg, ea_plus(c, k), 1, b[k]);
            FP.sw |= x.fl & 0x3F;
            fp_c1(c, (x.fl & FX_C1) != 0);
            fp_pop(c);
            break;
        }
        /* ---- control ---- */
        case 014: fp_load_env(c); break;                                /* FLDENV */
        case 015:                                                       /* FLDCW */
            FP.cw = (uint16_t)(rd_mem(c, c->ea_seg, c->ea_off, 2) | 0x40);
            fp_summary(c);
            break;
        case 016:                                                       /* FNSTENV */
            fp_store_env(c);
            FP.cw |= 0x3F;
            fp_summary(c);
            break;
        case 017: wr_mem(c, c->ea_seg, c->ea_off, 2, FP.cw); break;     /* FNSTCW */
        case 057: wr_mem(c, c->ea_seg, c->ea_off, 2, FP.sw); break;     /* FNSTSW */
        case 054: {                                                     /* FRSTOR */
            m86f80 r[8];
            int n = fp_env_size(c);
            for (int k = 0; k < 8; k++)
                r[k] = fp_rd80(c, n + 10 * k);
            fp_load_env(c);
            for (int k = 0; k < 8; k++)
                FP_ST(k) = r[k];
            break;
        }
        case 056: {                                                     /* FNSAVE */
            int n = fp_env_size(c);
            fp_store_env(c);
            for (int k = 0; k < 8; k++)
                fp_wr80(c, n + 10 * k, FP_ST(k));
            fp_fninit(c);
            break;
        }
        default:
            fault(c, EXC_UD);
        }
        fp_summary(c);
        return;
    }

    /* ---- register forms ---- */
    FP_POINTERS();
    switch (rcode & 0x7F8) {
    case 0x0C0: case 0x0C8: case 0x0E0: case 0x0E8: case 0x0F0: case 0x0F8:     /* D8: ST = ST op ST(i) */
        fp_binary(c, reg, 0, FP_ST(i), FP_EMPTY(i), 0, 0);
        break;
    case 0x4C0: case 0x4C8: case 0x4E0: case 0x4E8: case 0x4F0: case 0x4F8:     /* DC: ST(i) = ... */
    case 0x6C0: case 0x6C8: case 0x6E0: case 0x6E8: case 0x6F0: case 0x6F8:     /* DE: and pop */
        fp_binary(c, reg, i, FP_ST(i), FP_EMPTY(i), 0, esc == 6);
        break;
    case 0x0D0: case 0x4D0: fp_compare(c, FP_ST(i), FP_EMPTY(i), 0, 0); break;  /* FCOM */
    case 0x0D8: case 0x4D8: case 0x6D0:                                         /* FCOMP */
        fp_compare(c, FP_ST(i), FP_EMPTY(i), 0, 1);
        break;
    case 0x6D8:                                                                 /* FCOMPP (DE D9) */
        if (i != 1) fault(c, EXC_UD);
        fp_compare(c, FP_ST(1), FP_EMPTY(1), 0, 2);
        break;
    case 0x5E0: fp_compare(c, FP_ST(i), FP_EMPTY(i), 1, 0); break;              /* FUCOM */
    case 0x5E8: fp_compare(c, FP_ST(i), FP_EMPTY(i), 1, 1); break;              /* FUCOMP */
    case 0x2E8:                                                                 /* FUCOMPP (DA E9) */
        if (i != 1) fault(c, EXC_UD);
        fp_compare(c, FP_ST(1), FP_EMPTY(1), 1, 2);
        break;
    case 0x1C0: {                                                               /* FLD ST(i) */
        m86f80 v = FP_ST(i);
        if (FP_EMPTY(i)) {
            if (!fp_stack_fault(c, 0))
                break;
            v = fp_indef;
        }
        fp_push(c, v);
        break;
    }
    case 0x1C8: case 0x5C8: case 0x7C8: {                                       /* FXCH */
        if (FP_EMPTY(0) || FP_EMPTY(i)) {
            if (!fp_stack_fault(c, 0))
                break;
            if (FP_EMPTY(0)) { FP_ST(0) = fp_indef; FP.empty &= (uint8_t)~(1 << FP_PHYS(0)); }
            if (FP_EMPTY(i)) { FP_ST(i) = fp_indef; FP.empty &= (uint8_t)~(1 << FP_PHYS(i)); }
        }
        m86f80 t = FP_ST(0);
        FP_ST(0) = FP_ST(i);
        FP_ST(i) = t;
        fp_c1(c, 0);
        break;
    }
    case 0x1D0:                                                                 /* FNOP (D9 D0) */
        if (i != 0) fault(c, EXC_UD);
        break;
    case 0x5C0: FP.empty |= (uint8_t)(1 << FP_PHYS(i)); break;                  /* FFREE */
    case 0x7C0: FP.empty |= (uint8_t)(1 << FP_PHYS(i)); fp_pop(c); break;       /* (FFREEP) */
    case 0x5D0: case 0x5D8: case 0x1D8: case 0x7D0: case 0x7D8: {               /* FST, FSTP ST(i) */
        m86f80 v = FP_ST(0);
        if (FP_EMPTY(0)) {
            if (!fp_stack_fault(c, 0))
                break;
            v = fp_indef;
        } else
            fp_c1(c, 0);
        FP_ST(i) = v;
        FP.empty &= (uint8_t)~(1 << FP_PHYS(i));
        if ((rcode & 0x7F8) != 0x5D0)
            fp_pop(c);
        break;
    }
    case 0x1E0:
        switch (i) {
        case 0: case 1:                                                         /* FCHS, FABS */
            if (FP_EMPTY(0)) {
                if (fp_stack_fault(c, 0)) FP_ST(0) = fp_indef;
                break;
            }
            if (i == 0) FP_ST(0).se ^= 0x8000; else FP_ST(0).se &= 0x7FFF;
            fp_c1(c, 0);
            break;
        case 4: {                                                               /* FTST */
            m86f80 z = { 0, 0 };
            fp_compare(c, z, 0, 0, 0);
            break;
        }
        case 5: {                                                               /* FXAM */
            unsigned cc;
            if (FP_EMPTY(0))
                cc = FP_C3 | FP_C0;
            else switch (m86f_class(FP_ST(0))) {
                case FC_ZERO: cc = FP_C3; break;
                case FC_DENORMAL: cc = FP_C3 | FP_C2; break;
                case FC_NORMAL: cc = FP_C2; break;
                case FC_INF: cc = FP_C2 | FP_C0; break;
                case FC_UNSUPPORTED: cc = 0; break;
                default: cc = FP_C0; break;
            }
            fp_setcc(c, cc);
            fp_c1(c, (FP_ST(0).se & 0x8000) != 0);
            break;
        }
        default: fault(c, EXC_UD);
        }
        break;
    case 0x1E8:                                                                 /* FLD1 ... FLDZ */
        if (i == 7) fault(c, EXC_UD);
        fp_push(c, m86f_const(&x, i));
        break;
    case 0x1F0:
        switch (i) {
        case 0: fp_unary(c, m86f_2xm1); break;                                  /* F2XM1 */
        case 1: case 3: {                                                       /* FYL2X, FPATAN */
            m86f80 r = fp_indef;
            if (FP_EMPTY(0) || FP_EMPTY(1)) {
                if (!fp_stack_fault(c, 0))
                    break;
            } else {
                r = i == 1 ? m86f_yl2x(&x, FP_ST(0), FP_ST(1)) : m86f_atan2(&x, FP_ST(1), FP_ST(0));
                if (fp_post(c, x.fl, 0))
                    break;
            }
            FP_ST(1) = r;
            fp_pop(c);
            break;
        }
        case 2: {                                                               /* FPTAN */
            m86f80 s, co, one = { 0x8000000000000000ull, 0x3FFF };
            if (FP_EMPTY(0)) {
                if (fp_stack_fault(c, 0)) { FP_ST(0) = fp_indef; fp_push(c, fp_indef); }
                break;
            }
            if (m86f_sincos(&x, FP_ST(0), &s, &co)) {
                FP.sw |= FP_C2;
                break;
            }
            if (fp_post(c, x.fl, 0))
                break;
            FP.sw &= (uint16_t)~FP_C2;
            if (m86f_class(co) != FC_ZERO || m86f_class(s) != FC_ZERO) {
                m86fctx y = fp_ctx(c);
                int k = m86f_class(s);
                if (k == FC_NORMAL || k == FC_DENORMAL)
                    s = m86f_div(&y, s, co);
            }
            FP_ST(0) = s;
            {
                int k = m86f_class(s);
                fp_push(c, k == FC_QNAN ? s : one);
            }
            break;
        }
        case 4: {                                                               /* FXTRACT */
            m86f80 sig, e;
            if (FP_EMPTY(0)) {
                if (fp_stack_fault(c, 0)) { FP_ST(0) = fp_indef; fp_push(c, fp_indef); }
                break;
            }
            e = m86f_xtract(&x, FP_ST(0), &sig);
            if (fp_post(c, x.fl, 0))
                break;
            FP_ST(0) = e;
            fp_push(c, sig);
            break;
        }
        case 5: {                                                               /* FPREM1 */
            unsigned cc = 0;
            m86f80 r = fp_indef;
            if (FP_EMPTY(0) || FP_EMPTY(1)) {
                if (!fp_stack_fault(c, 0))
                    break;
            } else {
                r = m86f_prem(&x, FP_ST(0), FP_ST(1), 1, &cc);
                if (fp_post(c, x.fl, 0))
                    break;
            }
            FP_ST(0) = r;
            FP.sw = (uint16_t)((FP.sw & ~FP_CC) | cc);
            break;
        }
        case 6: fp_set_top(c, FP_TOP - 1); fp_c1(c, 0); break;                  /* FDECSTP */
        default: fp_set_top(c, FP_TOP + 1); fp_c1(c, 0); break;                 /* FINCSTP */
        }
        break;
    case 0x1F8:
        switch (i) {
        case 0: {                                                               /* FPREM */
            unsigned cc = 0;
            m86f80 r = fp_indef;
            if (FP_EMPTY(0) || FP_EMPTY(1)) {
                if (!fp_stack_fault(c, 0))
                    break;
            } else {
                r = m86f_prem(&x, FP_ST(0), FP_ST(1), 0, &cc);
                if (fp_post(c, x.fl, 0))
                    break;
            }
            FP_ST(0) = r;
            FP.sw = (uint16_t)((FP.sw & ~FP_CC) | cc);
            break;
        }
        case 1: {                                                               /* FYL2XP1 */
            m86f80 r = fp_indef;
            if (FP_EMPTY(0) || FP_EMPTY(1)) {
                if (!fp_stack_fault(c, 0))
                    break;
            } else {
                r = m86f_yl2xp1(&x, FP_ST(0), FP_ST(1));
                if (fp_post(c, x.fl, 0))
                    break;
            }
            FP_ST(1) = r;
            fp_pop(c);
            break;
        }
        case 2: fp_unary(c, m86f_sqrt); break;                                  /* FSQRT */
        case 3: case 6: case 7: {                                               /* FSINCOS, FSIN, FCOS */
            m86f80 s, co;
            if (FP_EMPTY(0)) {
                if (fp_stack_fault(c, 0)) {
                    FP_ST(0) = fp_indef;
                    if (i == 3) fp_push(c, fp_indef);
                }
                break;
            }
            if (m86f_sincos(&x, FP_ST(0), &s, &co)) {
                FP.sw |= FP_C2;
                break;
            }
            if (fp_post(c, x.fl, 0))
                break;
            FP.sw &= (uint16_t)~FP_C2;
            FP_ST(0) = i == 7 ? co : s;
            if (i == 3)
                fp_push(c, co);
            break;
        }
        case 4: fp_unary(c, m86f_rndint); break;                                /* FRNDINT */
        default: {                                                              /* FSCALE */
            m86f80 r = fp_indef;
            if (FP_EMPTY(0) || FP_EMPTY(1)) {
                if (!fp_stack_fault(c, 0))
                    break;
            } else {
                r = m86f_scale(&x, FP_ST(0), FP_ST(1));
                if (fp_post(c, x.fl, 0))
                    break;
            }
            FP_ST(0) = r;
            break;
        }
        }
        break;
    case 0x3E0:
        switch (i) {
        case 0: case 1: case 4: break;                          /* FNENI, FNDISI, FNSETPM: nothing */
        case 2: FP.sw &= 0x7F00; break;                         /* FNCLEX */
        case 3: fp_fninit(c); break;                            /* FNINIT */
        default: fault(c, EXC_UD);
        }
        break;
    case 0x7E0:                                                 /* FNSTSW AX */
        if (i != 0) fault(c, EXC_UD);
        wr_reg(c, 2, 0, FP.sw);
        break;
    default:
        fault(c, EXC_UD);
    }
    fp_summary(c);
    #undef FP_POINTERS
}
