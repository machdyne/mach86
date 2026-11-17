/*
 * Mach86 -- instruction vector runner, back end: the RTL core
 * (rtl/cpu/m86_core.v) under Verilator.
 *
 * Registers are loaded and read through the core's internal signals,
 * which the RTL marks public for this purpose. Memory is answered in
 * the same cycle it is asked for.
 */
#include "Vm86_core.h"
#include "Vm86_core___024root.h"
#include "vectest.h"

static Vm86_core *top;
static unsigned long long cycles_total;

#define R(sig) top->rootp->m86_core__DOT__##sig

static uint32_t mem_read(uint32_t a, int size)
{
    uint32_t v = 0;
    for (int i = 0; i < size; i++)
        v |= (uint32_t)vt_mem_read(a + i) << (8 * i);
    return v;
}

/* One clock. Bus requests are served before the rising edge. */
static void cycle(void)
{
    top->clk = 0;
    top->eval();
    top->mem_ack = 1;
    top->io_ack = 1;
    top->io_rdata = 0xFFFFFFFF;
    if (top->mem_req) {
        if (top->mem_wr) {
            for (int i = 0; i < top->mem_size; i++)
                vt_mem_write(top->mem_addr + i,
                             (uint8_t)(top->mem_wdata >> (8 * i)));
        } else {
            top->mem_rdata = mem_read(top->mem_addr, top->mem_size);
        }
    }
    top->eval();
    top->clk = 1;
    top->eval();
    cycles_total++;
}

void backend_init(void)
{
    top = new Vm86_core;
    top->irq = 0;
    top->nmi = 0;
    top->irq_vec = 0;
    top->rst = 1;
    cycle();
    cycle();
    top->rst = 0;
}

void backend_set(const uint32_t v[RG_COUNT])
{
    static const int gpr[8] = { RG_EAX, RG_ECX, RG_EDX, RG_EBX,
                                RG_ESP, RG_EBP, RG_ESI, RG_EDI };
    static const int seg[6] = { RG_ES, RG_CS, RG_SS, RG_DS, RG_FS, RG_GS };

    top->rst = 1;
    cycle();
    top->rst = 0;
    top->eval();

    for (int i = 0; i < 8; i++)
        R(gprs)[i] = v[gpr[i]];
    R(eip) = v[RG_EIP];
    R(fl) = (v[RG_EFLAGS] & 0x37FD5) | 2;
    R(ssel)[0] = R(ssel)[1] = R(ssel)[2] = 0;
    for (int i = 0; i < 6; i++) {
        uint32_t sel = v[seg[i]] & 0xFFFF;
        R(ssel)[i / 2] |= sel << (16 * (i % 2));
        R(sbase)[i] = sel << 4;
    }
    R(cr0) = v[RG_CR0];
    R(idtr_base) = 0;
    R(idtr_lim) = 0x3FF;
    top->eval();
}

int backend_run(void)
{
    for (int i = 0; i < 200000; i++) {
        cycle();
        if (top->halted)
            return 0;
        if (top->shutdown)
            return 2;
        if (top->unsupported)
            return 3;
    }
    return 1;
}

void backend_get(uint32_t v[RG_COUNT])
{
    static const int gpr[8] = { RG_EAX, RG_ECX, RG_EDX, RG_EBX,
                                RG_ESP, RG_EBP, RG_ESI, RG_EDI };
    static const int seg[6] = { RG_ES, RG_CS, RG_SS, RG_DS, RG_FS, RG_GS };

    for (int i = 0; i < RG_COUNT; i++)
        v[i] = 0;
    for (int i = 0; i < 8; i++)
        v[gpr[i]] = R(gprs)[i];
    v[RG_EIP] = R(eip);
    v[RG_EFLAGS] = R(fl);
    for (int i = 0; i < 6; i++)
        v[seg[i]] = (R(ssel)[i / 2] >> (16 * (i % 2))) & 0xFFFF;
    v[RG_CR0] = R(cr0);
}

int backend_last_exception(void)
{
    return top->last_exc == 0xFF ? -1 : top->last_exc;
}

double sc_time_stamp(void)
{
    return 0;
}
