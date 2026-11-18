/*
 * Mach86 reference model -- CPU.
 *
 * Sources: I386-PRM (instruction set, real-mode behaviour, exceptions),
 * I86-UM (16-bit instruction set). See docs/cleanroom.md.
 *
 * This is the reference the RTL core is held against (docs/verification.md).
 * It models what software can observe, not bus cycles or timing.
 *
 * Level implemented: the 486SX instruction set, with 16- and 32-bit
 * operands and addresses, in real mode and in as much of protected
 * mode as docs/pmode.md lists. Paging and V86 are not here: asking
 * for them stops the model (m86.unsupported).
 */
#ifndef M86_H
#define M86_H

#include <stdint.h>
#include <setjmp.h>

enum { M86_EAX, M86_ECX, M86_EDX, M86_EBX, M86_ESP, M86_EBP, M86_ESI, M86_EDI };
enum { M86_ES, M86_CS, M86_SS, M86_DS, M86_FS, M86_GS };

#define M86_CF 0x0001u
#define M86_PF 0x0004u
#define M86_AF 0x0010u
#define M86_ZF 0x0040u
#define M86_SF 0x0080u
#define M86_TF 0x0100u
#define M86_IF 0x0200u
#define M86_DF 0x0400u
#define M86_OF 0x0800u
#define M86_NT 0x4000u
#define M86_VM 0x20000u

/* Instruction classes, for the profile (docs/model.md). */
enum {
    M86_CL_REGREG,      /* register to register */
    M86_CL_LOAD,        /* load into a register */
    M86_CL_ALUMEM,      /* arithmetic or logic with a memory source */
    M86_CL_STORE,       /* store */
    M86_CL_RMW,         /* read-modify-write on memory */
    M86_CL_JCC_TAKEN,
    M86_CL_JCC_NOT,
    M86_CL_PUSHPOP,
    M86_CL_CALLRET,     /* call, return, unconditional jump */
    M86_CL_SLOW,        /* multiply, divide, shifts by a count, strings, the rest */
    M86_CL_COUNT
};

typedef struct {
    uint16_t sel;
    uint32_t base;
    uint32_t limit;
    uint8_t  d;         /* the descriptor's D/B bit: 32-bit code, 32-bit stack */
    /* Rights from the descriptor, looked at in protected mode only.
     * All zero means anything goes, which is what real mode loads. */
    uint8_t  nw;        /* not writable */
    uint8_t  nr;        /* not readable (execute-only code) */
    uint8_t  ed;        /* expand-down data: valid offsets lie above the limit */
    uint8_t  cc;        /* conforming code */
    uint8_t  dpl;       /* the descriptor's privilege level */
    uint8_t  null;      /* loaded with a null selector: unusable */
} m86_seg;

typedef struct {
    uint32_t r[8];
    uint32_t eip;
    uint32_t eflags;
    m86_seg  seg[6];
    uint8_t  cpl;       /* current privilege level, 0 to 3 */
} m86_regs;

typedef struct m86 m86;

struct m86 {
    /* Architectural state. */
    m86_regs s;
    uint32_t cr0, cr2, cr3;
    uint32_t dr[8];
    struct { uint32_t base; uint16_t limit; } gdtr, idtr;
    struct { uint16_t sel; uint32_t base; uint32_t limit; uint8_t t32; } ldtr, tr;   /* t32: a 386 task state segment */
    uint32_t err;       /* the error code of the fault being raised */

    int halted;         /* HLT executed; an interrupt wakes it */
    int shutdown;       /* fault while delivering a fault: the CPU has stopped */
    int unsupported;    /* software asked for something this level lacks */
    int irq_inhibit;    /* one instruction after MOV SS / POP SS / STI */

    /* The bus. Addresses are physical; `bus` is passed back. */
    void    *bus;
    uint8_t  (*mem_read)(void *bus, uint32_t addr);
    void     (*mem_write)(void *bus, uint32_t addr, uint8_t val);
    uint32_t (*io_read)(void *bus, uint16_t port, int size);
    void     (*io_write)(void *bus, uint16_t port, int size, uint32_t val);
    int      (*irq_ack)(void *bus);     /* returns the vector */

    int irq;            /* level of the maskable interrupt line */
    int nmi;            /* set to request an NMI; cleared when taken */

    /* Statistics. */
    uint64_t icount;
    uint64_t class_count[M86_CL_COUNT];
    uint64_t slow_count[512];   /* slow-path instructions, by opcode */
    int      last_exception;    /* vector of the last fault taken, or -1 */

    /* Decode state of the instruction in progress. Not architectural. */
    m86_regs snap;      /* state to return to if the instruction faults */
    jmp_buf  fault_jmp;
    int      fault_depth;
    int      os;        /* operand size in bytes: 2 or 4 */
    int      as32;      /* 32-bit addressing */
    int      seg_ovr;   /* segment override, or -1 */
    int      rep;       /* 0, 0xF2 or 0xF3 */
    int      lock;
    int      len;       /* bytes fetched so far */
    int      op;        /* opcode; 0x100 | op for the 0F map */
    int      mod, reg, rm;
    int      ea_seg;
    uint32_t ea_off;
    int      taken;     /* conditional jump taken */
};

void m86_init(m86 *c);
void m86_reset(m86 *c);

/* Execute one instruction, or take one pending interrupt. */
void m86_step(m86 *c);

/* Load a segment register the real-mode way. */
void m86_set_seg_real(m86 *c, int seg, uint16_t sel);

extern const char *const m86_class_name[M86_CL_COUNT];
extern const double m86_class_cycles[M86_CL_COUNT];

#endif
