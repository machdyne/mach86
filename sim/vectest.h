/*
 * Mach86 -- instruction vector runner: the interface between the
 * runner (vectest.c) and the CPU being tested.
 */
#ifndef VECTEST_H
#define VECTEST_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Register order of the test suite's 32-bit register chunks. */
enum { RG_CR0, RG_CR3, RG_EAX, RG_EBX, RG_ECX, RG_EDX, RG_ESI, RG_EDI,
       RG_EBP, RG_ESP, RG_CS, RG_DS, RG_ES, RG_FS, RG_GS, RG_SS, RG_EIP,
       RG_EFLAGS, RG_DR6, RG_DR7, RG_COUNT };

static const char *const rg_name[RG_COUNT] = {
    "cr0", "cr3", "eax", "ebx", "ecx", "edx", "esi", "edi", "ebp", "esp",
    "cs", "ds", "es", "fs", "gs", "ss", "eip", "eflags", "dr6", "dr7"
};

/* The test memory: 16 MB, as the captures have 24 address lines. */
uint8_t vt_mem_read(uint32_t addr);
void    vt_mem_write(uint32_t addr, uint8_t value);

/* The CPU under test. */
void backend_init(void);
void backend_set(const uint32_t regs[RG_COUNT]);
/* Run to HLT. Returns 0 at HLT, 1 if it never came, 2 on shutdown,
 * 3 if the CPU was asked for something it does not implement. */
int  backend_run(void);
void backend_get(uint32_t regs[RG_COUNT]);
int  backend_last_exception(void);

#ifdef __cplusplus
}
#endif

#endif
