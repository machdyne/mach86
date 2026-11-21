/*
 * Mach86 -- instruction vector runner, back end: CPU design B
 * (rtl/cpu/m86b_core.v) under Verilator.
 */
#include <stdlib.h>
#include <cstring>
#ifdef CORE_C
/* Design C: the same ports and signals. */
#include "Vm86c_core.h"
#include "Vm86c_core___024root.h"
#define Vm86b_core Vm86c_core
#else
#include "Vm86b_core.h"
#include "Vm86b_core___024root.h"
#endif
#include "vectest.h"

static Vm86b_core *top;
#ifdef CORE_C
#define R(sig) top->rootp->m86c_core__DOT__##sig
#else
#define R(sig) top->rootp->m86b_core__DOT__##sig
#endif

static void cycle(void)
{
    top->clk = 0;
    top->eval();
    top->d_ack = 1;
    top->d_st_rdy = 1;
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
            top->eval();
            top->clk = 1;
            top->eval();
            
            return;
        }
        waited = 0;
    }
    if (top->d_req && top->d_io) {
        // No device answers: reads float high, as in the model's backend.
        top->d_rdata = 0xFFFFFFFFu;
    } else if (top->d_req) {
        int n = 1 << top->d_size;
        if (top->d_wr) {
            for (int i = 0; i < n; i++)
                vt_mem_write(top->d_addr + i, (uint8_t)(top->d_wdata >> (8 * i)));
        } else {
            uint32_t v = 0;
            for (int i = 0; i < n; i++)
                v |= (uint32_t)vt_mem_read(top->d_addr + i) << (8 * i);
            top->d_rdata = v;
        }
    }
    top->eval();
    top->clk = 1;
    top->eval();
}

void backend_init(void)
{
    top = new Vm86b_core;
    top->rst = 1;
    cycle();
    cycle();
    top->rst = 0;
}

static const int gpr[8] = { RG_EAX, RG_ECX, RG_EDX, RG_EBX,
                            RG_ESP, RG_EBP, RG_ESI, RG_EDI };
static const int seg[6] = { RG_ES, RG_CS, RG_SS, RG_DS, RG_FS, RG_GS };

void backend_set(const uint32_t v[RG_COUNT])
{
    /* Memory has changed: nothing decoded earlier may be reused. */
    memset(&R(dc), 0, sizeof R(dc));
    top->rst = 1;
    cycle();
    top->rst = 0;
    /* Reset continues in microcode; let it finish before setting state. */
    for (int i = 0; i < 200 && R(rst_seq); i++)
        cycle();
    top->eval();

    for (int i = 0; i < 16; i++) {
        uint32_t x = i < 8 ? v[gpr[i]] : 0;
        R(rf0)[i] = x & 0xFF;
        R(rf1)[i] = (x >> 8) & 0xFF;
        R(rf2)[i] = (x >> 16) & 0xFF;
        R(rf3)[i] = (x >> 24) & 0xFF;
    }
    R(esp_now) = v[RG_ESP];
    for (int i = 0; i < 6; i++) {
        R(seg_sel)[i] = v[seg[i]] & 0xFFFF;
        R(seg_base)[i] = (v[seg[i]] & 0xFFFF) << 4;
        R(seg_hi1)[i] = (((v[seg[i]] & 0xFFFF) << 4) >> 16) + 1;
        R(seg_lim)[i] = 0xFFFF;
    }
    R(cs_base) = (v[RG_CS] & 0xFFFF) << 4;
    R(fl) = (v[RG_EFLAGS] & 0x37FD5) | 2;
    R(lk_eip) = v[RG_EIP];
    R(lk_lin) = R(cs_base) + v[RG_EIP];
    R(lk_pend) = 1;
    R(gen) = 1;
    top->eval();
}

int backend_run(void)
{
    for (int i = 0; i < 3000; i++) {
        cycle();
        if (top->halted)
            return 0;
    }
    return 1;
}

void backend_get(uint32_t v[RG_COUNT])
{
    for (int i = 0; i < RG_COUNT; i++)
        v[i] = 0;
    for (int i = 0; i < 8; i++)
        v[gpr[i]] = R(rf0)[i] | R(rf1)[i] << 8 | R(rf2)[i] << 16
                    | (uint32_t)R(rf3)[i] << 24;
    v[RG_EIP] = R(lk_eip);
    v[RG_EFLAGS] = R(fl);
    for (int i = 0; i < 6; i++)
        v[seg[i]] = R(seg_sel)[i];
}

int backend_last_exception(void)
{
    return top->last_exc == 0xFF ? -1 : top->last_exc;
}

double sc_time_stamp(void)
{
    return 0;
}
