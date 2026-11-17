/*
 * Mach86 -- instruction vector runner, back end: the C reference model.
 */
#include "m86.h"
#include "vectest.h"

static m86 cpu;

static uint8_t bus_read(void *bus, uint32_t a)
{
    (void)bus;
    return vt_mem_read(a);
}

static void bus_write(void *bus, uint32_t a, uint8_t v)
{
    (void)bus;
    vt_mem_write(a, v);
}

static uint32_t bus_in(void *bus, uint16_t port, int size)
{
    (void)bus; (void)port;
    return size == 1 ? 0xFF : size == 2 ? 0xFFFF : 0xFFFFFFFF;
}

static void bus_out(void *bus, uint16_t port, int size, uint32_t v)
{
    (void)bus; (void)port; (void)size; (void)v;
}

void backend_init(void)
{
    m86_init(&cpu);
    cpu.mem_read = bus_read;
    cpu.mem_write = bus_write;
    cpu.io_read = bus_in;
    cpu.io_write = bus_out;
}

void backend_get(uint32_t v[RG_COUNT])
{
    const m86 *c = &cpu;
    v[RG_CR0] = c->cr0;
    v[RG_CR3] = c->cr3;
    v[RG_EAX] = c->s.r[M86_EAX];
    v[RG_EBX] = c->s.r[M86_EBX];
    v[RG_ECX] = c->s.r[M86_ECX];
    v[RG_EDX] = c->s.r[M86_EDX];
    v[RG_ESI] = c->s.r[M86_ESI];
    v[RG_EDI] = c->s.r[M86_EDI];
    v[RG_EBP] = c->s.r[M86_EBP];
    v[RG_ESP] = c->s.r[M86_ESP];
    v[RG_CS] = c->s.seg[M86_CS].sel;
    v[RG_DS] = c->s.seg[M86_DS].sel;
    v[RG_ES] = c->s.seg[M86_ES].sel;
    v[RG_FS] = c->s.seg[M86_FS].sel;
    v[RG_GS] = c->s.seg[M86_GS].sel;
    v[RG_SS] = c->s.seg[M86_SS].sel;
    v[RG_EIP] = c->s.eip;
    v[RG_EFLAGS] = c->s.eflags;
    v[RG_DR6] = c->dr[6];
    v[RG_DR7] = c->dr[7];
}

void backend_set(const uint32_t v[RG_COUNT])
{
    m86 *c = &cpu;
    static const int segmap[6][2] = {
        { RG_CS, M86_CS }, { RG_DS, M86_DS }, { RG_ES, M86_ES },
        { RG_FS, M86_FS }, { RG_GS, M86_GS }, { RG_SS, M86_SS }
    };
    m86_reset(c);
    c->cr0 = v[RG_CR0];
    c->cr3 = v[RG_CR3];
    c->s.r[M86_EAX] = v[RG_EAX];
    c->s.r[M86_EBX] = v[RG_EBX];
    c->s.r[M86_ECX] = v[RG_ECX];
    c->s.r[M86_EDX] = v[RG_EDX];
    c->s.r[M86_ESI] = v[RG_ESI];
    c->s.r[M86_EDI] = v[RG_EDI];
    c->s.r[M86_EBP] = v[RG_EBP];
    c->s.r[M86_ESP] = v[RG_ESP];
    for (int i = 0; i < 6; i++) {
        c->s.seg[segmap[i][1]].limit = 0xFFFF;
        m86_set_seg_real(c, segmap[i][1], (uint16_t)v[segmap[i][0]]);
    }
    c->s.eip = v[RG_EIP];
    c->s.eflags = (v[RG_EFLAGS] & 0x00037FD5u) | 2;
    c->dr[6] = v[RG_DR6];
    c->dr[7] = v[RG_DR7];
    c->idtr.base = 0;
    c->idtr.limit = 0x3FF;
}

int backend_run(void)
{
    for (int i = 0; i < 4096 && !cpu.halted && !cpu.shutdown
                    && !cpu.unsupported; i++)
        m86_step(&cpu);
    if (cpu.halted)
        return 0;
    return cpu.shutdown ? 2 : cpu.unsupported ? 3 : 1;
}

int backend_last_exception(void)
{
    return cpu.last_exception;
}
