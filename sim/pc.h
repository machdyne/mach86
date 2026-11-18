/*
 * Mach86 reference model -- the PC around the CPU.
 *
 * Sources: I8259, I8254, I8042, MC146818, SD-PHY (docs/cleanroom.md);
 * port and memory assignments from docs/hwmap.md.
 *
 * Level of detail: what the BIOS and DOS-era software can observe
 * through ports and memory. Time is counted in instructions, so a run
 * is reproducible.
 */
#ifndef PC_H
#define PC_H

#include <stdint.h>
#include "vga.h"
#include <stdio.h>
#include "m86.h"

#define PC_RAM_SIZE     (16u << 20)
#define PC_TEXT_BASE    0xB8000u
#define PC_COLS         80
#define PC_ROWS         25

typedef struct {
    uint8_t irr, isr, imr, base;
    int icw_step, icw4, read_isr;
} pc_pic;

typedef struct {
    uint32_t reload;        /* 1..65536 */
    uint32_t remain;        /* ticks until the count wraps */
    uint16_t latch;
    int latched, latch_hi;
    int mode, rw;
    int wr_hi, rd_hi;
    uint8_t wr_lo;
    int loaded, gate, out, fired;
} pc_pit_ch;

typedef struct {
    FILE    *image;
    uint32_t sectors;
    int      idle;          /* in idle state (before ACMD41 completes) */
    int      acmd, acmd41_calls;
    uint8_t  cmd[6];
    int      cmd_len;
    uint8_t  resp[600];
    int      resp_len, resp_pos;
    int      writing;       /* 0 no, 1 waiting for token, 2 data */
    uint32_t wr_lba;
    uint8_t  wr_buf[514];
    int      wr_len;
} pc_sd;

typedef struct pc {
    m86      cpu;
    uint8_t *ram;
    uint8_t  rom[0x20000];              /* the BIOS, ending at FFFFFh */
    uint32_t rom_size;                  /* 64 KB; a test ROM may be 128 KB (model only) */
    int      a20;

    pc_pic   pic[2];
    pc_pit_ch pit[3];
    uint8_t hdmi;                       /* port 1E1h bit 0 */
    uint8_t post;                       /* the last code written to port 190h */
    uint8_t slow;                       /* the speed control's register (port 1E0h) */
    /* The mouse port (E3h, interrupt 12). */
    struct {
        int ax, ay;                     /* movement waiting */
        uint8_t btn, seen, seq;
        int8_t tx, ty;
    } mouse;
    /* The AdLib's bus side: index, timers, status (no sound here). */
    struct {
        uint8_t index, t1_load, t2_load, t1, t2, ctrl, f1, f2, div4;
        uint32_t frac;                  /* timer ticks * 1000, towards 80 us */
        uint32_t writes;                /* register writes seen */
    } opl;
    /* The Sound Blaster (a 2.0: DSP at 220h, 8-bit DMA on channel 1,
     * interrupt 7) and the one DMA channel it uses. */
    struct {
        uint8_t  rst, cmd, need, have, arg[2];
        uint8_t  out[4], out_n, last;
        uint8_t  tc, speaker, active, autoinit, paused, irq, dac, test;
        uint16_t block;
        uint32_t left;
        uint64_t frac;                  /* timer ticks * 1,000,000 towards a sample */
        uint32_t samples;               /* played, for the tests */
        void    *wav;                   /* M86_WAV: what was played, as a file */
    } sb;
    struct {
        uint16_t addr, count, base_addr, base_count;
        uint8_t  page, mode, mask, ff, tc;
    } dma;
    uint32_t pit_frac;          /* instructions not yet turned into ticks */
    uint32_t insn_per_tick;

    /* Keyboard controller. */
    uint8_t  kb_queue[64];
    int      kb_head, kb_count;
    uint8_t  kb_out;
    int      kb_obf;
    uint8_t  kb_cmdbyte;
    int      kb_pending_cmd;    /* controller command awaiting its data byte */
    int      kb_wait;           /* instructions before the next byte appears */

    uint8_t  port61;
    uint8_t  cmos_index;
    uint8_t  cmos[128];
    uint32_t conv_size;         /* conventional memory, bytes (640 KB) */
    vga      vga;               /* A0000h-BFFFFh and ports 3C0h-3DAh */

    /* SPI to the SD card: ports E1h (data) and E2h (control). */
    uint8_t  spi_rx;
    int      spi_cs;            /* 1 = card selected */
    pc_sd    sd;

    FILE    *debug_out;         /* port E0h */
    char     dbg_log[1 << 16];  /* ... and the last of what went there */
    uint32_t dbg_count;         /* characters written to it, ever */
    int      reset_request;
} pc;

void pc_init(pc *p);
int  pc_load_bios(pc *p, const char *path);
int  pc_attach_disk(pc *p, const char *path);
void pc_reset(pc *p);

/* Advance the devices alone, for a CPU that is stepped elsewhere
 * (the RTL core in lockstep.cpp). The CPU's bus is reached through
 * p->cpu's callbacks with `p` as the bus. */
void pc_devices(pc *p, uint32_t steps);

/* Run about n instructions (fewer if the machine stops). */
void pc_run(pc *p, uint64_t n);
int  pc_stopped(const pc *p);

/* Type one character on the keyboard (ASCII; '\r' is Enter). */
void pc_key_ascii(pc *p, int ch);
void pc_mouse(pc *p, int dx, int dy, int buttons);  /* a mouse report */
int  pc_keys_pending(const pc *p);

/* Character and attribute at a screen position. */
uint8_t pc_screen_char(const pc *p, int row, int col);
void pc_cursor(const pc *p, int *row, int *col);

/* The SD card (sdcard.c). */
uint8_t sd_exchange(pc_sd *sd, uint8_t mosi);
void sd_deselect(pc_sd *sd);

#endif
