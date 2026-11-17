/*
 * Mach86 reference model -- the PC around the CPU.
 *
 * Sources: I8259, I8254, I8042, MC146818 (docs/cleanroom.md); the map
 * is docs/hwmap.md.
 */
#include <stdlib.h>
#include <string.h>
#include "pc.h"

/* ---- memory ---------------------------------------------------- */

static uint32_t a20_mask(const pc *p, uint32_t a)
{
    return p->a20 ? a : (a & ~0x100000u);
}

static uint8_t mem_read(void *bus, uint32_t a)
{
    pc *p = bus;
    a = a20_mask(p, a);
    if (a >= 0xF0000 && a < 0x100000)
        return p->rom[a - 0xF0000];
    if (a >= 0xA0000 && a < 0x100000)
        return a < 0xC0000 ? vga_mem_read(&p->vga, a) : 0xFF;
    if (a < 0xA0000)
        return a < p->conv_size ? p->ram[a] : 0xFF;
    if (a < PC_RAM_SIZE)
        return p->ram[a];
    return 0xFF;
}

static void mem_write(void *bus, uint32_t a, uint8_t v)
{
    pc *p = bus;
    a = a20_mask(p, a);
    if (a >= 0xA0000 && a < 0x100000) {
        if (a < 0xC0000)
            vga_mem_write(&p->vga, a, v);
        return;
    }
    if (a < 0xA0000) {
        if (a < p->conv_size)
            p->ram[a] = v;
        return;
    }
    if (a < PC_RAM_SIZE)
        p->ram[a] = v;
}

/* ---- interrupt controllers (8259) ------------------------------- */

static int pic_pending(const pc_pic *q)
{
    uint8_t req = q->irr & ~q->imr;
    for (int n = 0; n < 8; n++) {
        if (q->isr & (1u << n))
            return -1;              /* this or a higher one is in service */
        if (req & (1u << n))
            return n;
    }
    return -1;
}

static void pic_update(pc *p)
{
    if (pic_pending(&p->pic[1]) >= 0)
        p->pic[0].irr |= 4;
    else
        p->pic[0].irr &= ~4;
    p->cpu.irq = pic_pending(&p->pic[0]) >= 0;
}

static void raise_irq(pc *p, int n)
{
    if (n < 8)
        p->pic[0].irr |= (uint8_t)(1u << n);
    else
        p->pic[1].irr |= (uint8_t)(1u << (n - 8));
    pic_update(p);
}

static int irq_ack(void *bus)
{
    pc *p = bus;
    int n = pic_pending(&p->pic[0]);
    int vec;
    if (n < 0)
        return p->pic[0].base + 7;  /* spurious */
    p->pic[0].isr |= (uint8_t)(1u << n);
    if (n == 2) {
        int m = pic_pending(&p->pic[1]);
        if (m < 0)
            m = 7;
        p->pic[1].isr |= (uint8_t)(1u << m);
        p->pic[1].irr &= (uint8_t)~(1u << m);
        vec = p->pic[1].base + m;
    } else {
        p->pic[0].irr &= (uint8_t)~(1u << n);
        vec = p->pic[0].base + n;
    }
    pic_update(p);
    return vec;
}

static void pic_write(pc *p, int which, int a0, uint8_t v)
{
    pc_pic *q = &p->pic[which];
    if (!a0) {
        if (v & 0x10) {                         /* ICW1 */
            q->icw_step = 1;
            q->icw4 = v & 1;
            q->imr = q->isr = q->irr = 0;
            q->read_isr = 0;
        } else if ((v & 0x18) == 0x08) {        /* OCW3 */
            if (v & 2)
                q->read_isr = v & 1;
        } else if (v & 0x20) {                  /* OCW2: end of interrupt */
            if (v & 0x40) {
                q->isr &= (uint8_t)~(1u << (v & 7));
            } else {
                for (int n = 0; n < 8; n++)
                    if (q->isr & (1u << n)) {
                        q->isr &= (uint8_t)~(1u << n);
                        break;
                    }
            }
        }
    } else {
        switch (q->icw_step) {
        case 1: q->base = v & 0xF8; q->icw_step = 2; break;
        case 2: q->icw_step = q->icw4 ? 3 : 0; break;
        case 3: q->icw_step = 0; break;
        default: q->imr = v; break;
        }
    }
    pic_update(p);
}

static uint8_t pic_read(pc *p, int which, int a0)
{
    pc_pic *q = &p->pic[which];
    if (a0)
        return q->imr;
    return q->read_isr ? q->isr : q->irr;
}

/* ---- timer (8254) ------------------------------------------------ */

static void pit_advance(pc *p, uint32_t ticks)
{
    for (int i = 0; i < 3; i++) {
        pc_pit_ch *ch = &p->pit[i];
        uint32_t n = ticks;
        if (!ch->loaded || (i == 2 && !ch->gate))
            continue;
        while (n >= ch->remain) {
            n -= ch->remain;
            ch->remain = ch->reload;
            if (ch->mode == 0) {
                if (!ch->fired) {
                    ch->fired = 1;
                    ch->out = 1;
                    if (i == 0)
                        raise_irq(p, 0);
                }
            } else if (i == 0) {
                raise_irq(p, 0);
            }
        }
        ch->remain -= n;
        if (ch->mode == 3)
            ch->out = ch->remain > ch->reload / 2;
        else if (ch->mode != 0)
            ch->out = ch->remain != 1;
    }
}

/* The AdLib's timers: `ticks` of the 1,193,182 Hz clock have passed;
 * 80 microseconds is 95.455 of them. */
static void opl_advance(pc *p, uint32_t ticks)
{
    p->opl.frac += ticks * 1000;
    while (p->opl.frac >= 95455) {
        p->opl.frac -= 95455;
        if (p->opl.ctrl & 1) {
            if (p->opl.t1 == 0xFF) {
                p->opl.t1 = p->opl.t1_load;
                if (!(p->opl.ctrl & 0x40)) p->opl.f1 = 1;
            } else
                p->opl.t1++;
        }
        if ((++p->opl.div4 & 3) == 0 && (p->opl.ctrl & 2)) {
            if (p->opl.t2 == 0xFF) {
                p->opl.t2 = p->opl.t2_load;
                if (!(p->opl.ctrl & 0x20)) p->opl.f2 = 1;
            } else
                p->opl.t2++;
        }
    }
}

static void opl_write(pc *p, uint8_t v)
{
    p->opl.writes++;
    switch (p->opl.index) {
    case 0x02: p->opl.t1_load = v; break;
    case 0x03: p->opl.t2_load = v; break;
    case 0x04:
        if (v & 0x80)
            p->opl.f1 = p->opl.f2 = 0;
        else {
            if ((v & 1) && !(p->opl.ctrl & 1)) p->opl.t1 = p->opl.t1_load;
            if ((v & 2) && !(p->opl.ctrl & 2)) p->opl.t2 = p->opl.t2_load;
            p->opl.ctrl = v;
        }
        break;
    default: break;
    }
}

static uint16_t pit_count(const pc_pit_ch *ch)
{
    return (uint16_t)(ch->remain & 0xFFFF);
}

static void pit_write(pc *p, int port, uint8_t v)
{
    if (port == 3) {
        int n = v >> 6;
        if (n == 3)
            return;                             /* read-back: not modelled */
        pc_pit_ch *ch = &p->pit[n];
        int rw = (v >> 4) & 3;
        if (rw == 0) {                          /* latch the count */
            ch->latch = pit_count(ch);
            ch->latched = 1;
            ch->latch_hi = 0;
            return;
        }
        ch->rw = rw;
        ch->mode = (v >> 1) & 7;
        if (ch->mode > 5)
            ch->mode -= 4;
        ch->wr_hi = ch->rd_hi = 0;
        ch->loaded = 0;
        ch->out = ch->mode != 0;
        return;
    }
    pc_pit_ch *ch = &p->pit[port];
    uint32_t value;
    if (ch->rw == 3) {
        if (!ch->wr_hi) {
            ch->wr_lo = v;
            ch->wr_hi = 1;
            return;
        }
        ch->wr_hi = 0;
        value = ((uint32_t)v << 8) | ch->wr_lo;
    } else if (ch->rw == 2) {
        value = (uint32_t)v << 8;
    } else {
        value = v;
    }
    ch->reload = value ? value : 0x10000;
    ch->remain = ch->reload;
    ch->loaded = 1;
    ch->fired = 0;
    if (ch->mode == 0)
        ch->out = 0;
}

static uint8_t pit_read(pc *p, int port)
{
    if (port == 3)
        return 0xFF;
    pc_pit_ch *ch = &p->pit[port];
    uint16_t value = ch->latched ? ch->latch : pit_count(ch);
    int *hi = ch->latched ? &ch->latch_hi : &ch->rd_hi;
    uint8_t v;
    if (ch->rw == 3) {
        v = *hi ? (uint8_t)(value >> 8) : (uint8_t)value;
        if (*hi && ch->latched)
            ch->latched = 0;
        *hi = !*hi;
    } else {
        v = ch->rw == 2 ? (uint8_t)(value >> 8) : (uint8_t)value;
        ch->latched = 0;
    }
    return v;
}

/* ---- keyboard controller (8042) ---------------------------------- */

static void kb_queue(pc *p, uint8_t v)
{
    if (p->kb_count < (int)sizeof p->kb_queue) {
        p->kb_queue[(p->kb_head + p->kb_count) % (int)sizeof p->kb_queue] = v;
        p->kb_count++;
    }
}

static void kb_poll(pc *p)
{
    if (p->kb_obf || p->kb_count == 0)
        return;
    p->kb_out = p->kb_queue[p->kb_head];
    p->kb_head = (p->kb_head + 1) % (int)sizeof p->kb_queue;
    p->kb_count--;
    p->kb_obf = 1;
    if (p->kb_cmdbyte & 1)
        raise_irq(p, 1);
}

static void kb_write_data(pc *p, uint8_t v)
{
    int cmd = p->kb_pending_cmd;
    p->kb_pending_cmd = 0;
    if (cmd == 0x60) {                  /* write command byte */
        p->kb_cmdbyte = v;
    } else if (cmd == 0xD1) {           /* write output port */
        p->a20 = (v >> 1) & 1;
        if (!(v & 1))
            p->reset_request = 1;
    } else if (cmd == 0xED || cmd == 0xF3) {
        kb_queue(p, 0xFA);              /* argument of a keyboard command */
    } else {
        /* A command to the keyboard itself. */
        kb_queue(p, 0xFA);
        if (v == 0xFF)
            kb_queue(p, 0xAA);
        else if (v == 0xF2) {
            kb_queue(p, 0xAB);
            kb_queue(p, 0x41);
        } else if (v == 0xED || v == 0xF3)
            p->kb_pending_cmd = v;
    }
}

static void kb_write_cmd(pc *p, uint8_t v)
{
    switch (v) {
    case 0x20: kb_queue(p, p->kb_cmdbyte); break;
    case 0x60: case 0xD1: p->kb_pending_cmd = v; break;
    case 0xAA: kb_queue(p, 0x55); break;
    case 0xAB: kb_queue(p, 0x00); break;
    case 0xAD: p->kb_cmdbyte |= 0x10; break;
    case 0xAE: p->kb_cmdbyte &= (uint8_t)~0x10; break;
    case 0xD0: kb_queue(p, (uint8_t)(0xDD | (p->a20 << 1))); break;
    case 0xFE: p->reset_request = 1; break;
    default: break;
    }
}

/* Set-1 scancodes for the characters a test script can type. */
static int ascii_to_scan(int ch, int *shift)
{
    static const char plain[] =
        "\0\0331234567890-=\b\tqwertyuiop[]\r\0asdfghjkl;'`\0\\zxcvbnm,./\0*\0 ";
    static const char shifted[] =
        "\0\033!@#$%^&*()_+\b\tQWERTYUIOP{}\r\0ASDFGHJKL:\"~\0|ZXCVBNM<>?\0*\0 ";
    if (ch == '\n')
        ch = '\r';
    for (int i = 1; i < (int)sizeof plain - 1; i++) {
        if (plain[i] && plain[i] == ch) {
            *shift = 0;
            return i;
        }
        if (shifted[i] && shifted[i] == ch) {
            *shift = 1;
            return i;
        }
    }
    return 0;
}

static int clamp8(int v)
{
    return v > 127 ? 127 : v < -128 ? -128 : v;
}

void pc_mouse(pc *p, int dx, int dy, int buttons)
{
    p->mouse.ax += dx;
    p->mouse.ay += dy;
    p->mouse.btn = (uint8_t)(buttons & 7);
    p->mouse.seen = 1;
    raise_irq(p, 12);
}

static uint8_t mouse_read(pc *p)
{
    uint8_t v;
    if (p->mouse.seq == 0) {
        p->mouse.tx = (int8_t)clamp8(p->mouse.ax);
        p->mouse.ty = (int8_t)clamp8(p->mouse.ay);
        p->mouse.ax -= p->mouse.tx;
        p->mouse.ay -= p->mouse.ty;
        v = (uint8_t)((p->mouse.seen << 7) | p->mouse.btn |
                      ((p->mouse.ax || p->mouse.ay) ? 0x40 : 0));
    } else
        v = (uint8_t)(p->mouse.seq == 1 ? p->mouse.tx : p->mouse.ty);
    p->mouse.seq = (uint8_t)((p->mouse.seq + 1) % 3);
    return v;
}

void pc_key_ascii(pc *p, int ch)
{
    int shift = 0, ctrl = 0;
    if (ch >= 1 && ch <= 26 && ch != '\r' && ch != '\n' && ch != '\t'
        && ch != '\b') {
        ctrl = 1;
        ch += 'a' - 1;
    }
    int sc = ascii_to_scan(ch, &shift);
    if (!sc)
        return;
    if (ctrl)
        kb_queue(p, 0x1D);
    if (shift)
        kb_queue(p, 0x2A);
    kb_queue(p, (uint8_t)sc);
    kb_queue(p, (uint8_t)(sc | 0x80));
    if (shift)
        kb_queue(p, 0xAA);
    if (ctrl)
        kb_queue(p, 0x9D);
}

int pc_keys_pending(const pc *p)
{
    return p->kb_count + p->kb_obf;
}

/* ---- ports ------------------------------------------------------- */

static uint8_t port_read8(pc *p, uint16_t port)
{
    switch (port) {
    case 0x20: case 0x21: return pic_read(p, 0, port & 1);
    case 0xA0: case 0xA1: return pic_read(p, 1, port & 1);
    case 0x40: case 0x41: case 0x42: case 0x43:
        return pit_read(p, port & 3);
    case 0x60: {
        uint8_t v = p->kb_out;
        p->kb_obf = 0;
        p->kb_wait = 2000;
        return v;
    }
    case 0x61:
        p->port61 ^= 0x10;              /* refresh toggle */
        return (uint8_t)((p->port61 & 0x1F) | (p->pit[2].out ? 0x20 : 0));
    case 0x64:
        return (uint8_t)(0x14 | (p->kb_obf ? 1 : 0));
    case 0x70: return p->cmos_index;
    case 0x71: return p->cmos[p->cmos_index & 0x7F];
    case 0x92: return (uint8_t)(p->a20 << 1);
    case 0x388:
        return (uint8_t)(((p->opl.f1 || p->opl.f2) << 7) | (p->opl.f1 << 6) |
                         (p->opl.f2 << 5) | 0x06);
    case 0xE3: return mouse_read(p);
    case 0x1E0: return p->slow;
    case 0x1E1: return p->hdmi;
    case 0xE0: return 0;                /* the debug console always has room */
    case 0xE4: return 0;                /* no memory port: plain RAM, no training */
    case 0xE1: return p->spi_rx;
    case 0xE2: return (uint8_t)(p->spi_cs ? 1 : 0);     /* never busy here */
    default:
        return vga_port(port) ? vga_in(&p->vga, port) : 0xFF;
    }
}

static void port_write8(pc *p, uint16_t port, uint8_t v)
{
    switch (port) {
    case 0x20: case 0x21: pic_write(p, 0, port & 1, v); break;
    case 0xA0: case 0xA1: pic_write(p, 1, port & 1, v); break;
    case 0x40: case 0x41: case 0x42: case 0x43:
        pit_write(p, port & 3, v);
        break;
    case 0x60: kb_write_data(p, v); break;
    case 0x61:
        p->port61 = (uint8_t)((p->port61 & 0x10) | (v & 0x0F));
        p->pit[2].gate = v & 1;
        if (!(v & 1) && (p->pit[2].mode == 2 || p->pit[2].mode == 3))
            p->pit[2].out = 1;          /* stopped: the output is high */
        break;
    case 0x64: kb_write_cmd(p, v); break;
    case 0x70: p->cmos_index = v; break;
    case 0x71: p->cmos[p->cmos_index & 0x7F] = v; break;
    case 0x92:
        p->a20 = (v >> 1) & 1;
        if (v & 1)
            p->reset_request = 1;
        break;
    case 0xE0:
        p->dbg_log[p->dbg_count++ & 0xFFFF] = (char)v;
        if (p->debug_out) {
            fputc(v, p->debug_out);
            if (v == '\n')
                fflush(p->debug_out);
        }
        break;
    case 0xE1:
        p->spi_rx = p->spi_cs ? sd_exchange(&p->sd, v) : 0xFF;
        break;
    case 0xE2:
        if (p->spi_cs && !(v & 1))
            sd_deselect(&p->sd);
        p->spi_cs = v & 1;
        break;
    case 0xE3: p->mouse.seq = 0; break;
    case 0x1E1: p->hdmi = v & 1; break;     /* sound on the display's cable: no cable here */
    case 0x1E0: p->slow = v; break;         /* the speed control: nothing to slow here */
    case 0x388: p->opl.index = v; break;
    case 0x389: opl_write(p, v); break;
    default:
        if (vga_port(port))
            vga_out(&p->vga, port, v);
        break;
    }
}

static uint32_t io_read(void *bus, uint16_t port, int size)
{
    uint32_t v = 0;
    for (int i = 0; i < size; i++)
        v |= (uint32_t)port_read8(bus, (uint16_t)(port + i)) << (8 * i);
    return v;
}

static void io_write(void *bus, uint16_t port, int size, uint32_t v)
{
    for (int i = 0; i < size; i++)
        port_write8(bus, (uint16_t)(port + i), (uint8_t)(v >> (8 * i)));
}

/* ---- machine ----------------------------------------------------- */

static uint8_t bcd(int v)
{
    return (uint8_t)(((v / 10) << 4) | (v % 10));
}

void pc_reset(pc *p)
{
    m86_reset(&p->cpu);
    p->a20 = 0;
    memset(p->pic, 0, sizeof p->pic);
    p->pic[0].base = 0x08;
    p->pic[1].base = 0x70;
    memset(p->pit, 0, sizeof p->pit);
    for (int i = 0; i < 3; i++) {
        p->pit[i].reload = p->pit[i].remain = 0x10000;
        p->pit[i].rw = 3;
        p->pit[i].mode = 3;
    }
    p->pit[0].gate = p->pit[1].gate = 1;
    p->kb_head = p->kb_count = p->kb_obf = 0;
    p->kb_cmdbyte = 0x45;
    p->kb_pending_cmd = 0;
    p->spi_cs = 0;
    p->spi_rx = 0xFF;
    sd_deselect(&p->sd);
    p->reset_request = 0;
    vga_reset(&p->vga);
}

void pc_init(pc *p)
{
    memset(p, 0, sizeof *p);
    p->ram = calloc(PC_RAM_SIZE, 1);
    memset(p->rom, 0xFF, sizeof p->rom);
    m86_init(&p->cpu);
    p->cpu.bus = p;
    p->cpu.mem_read = mem_read;
    p->cpu.mem_write = mem_write;
    p->cpu.io_read = io_read;
    p->cpu.io_write = io_write;
    p->cpu.irq_ack = irq_ack;
    p->conv_size = 0xA0000;
    p->insn_per_tick = 16;      /* about 19 MIPS against a 1.193 MHz timer */

    /* A fixed clock, so that runs are reproducible: 1990-01-01 12:00. */
    p->cmos[0x00] = bcd(0);
    p->cmos[0x02] = bcd(0);
    p->cmos[0x04] = bcd(12);
    p->cmos[0x06] = 2;
    p->cmos[0x07] = bcd(1);
    p->cmos[0x08] = bcd(1);
    p->cmos[0x09] = bcd(90);
    p->cmos[0x32] = bcd(19);
    p->cmos[0x0A] = 0x26;
    p->cmos[0x0B] = 0x02;       /* 24-hour, BCD */
    p->cmos[0x0D] = 0x80;
    p->cmos[0x15] = 0x80;       /* base memory: 640 KB */
    p->cmos[0x16] = 0x02;
    uint32_t ext_kb = (PC_RAM_SIZE >> 10) - 1024;
    p->cmos[0x17] = p->cmos[0x30] = (uint8_t)ext_kb;
    p->cmos[0x18] = p->cmos[0x31] = (uint8_t)(ext_kb >> 8);
    pc_reset(p);
}

int pc_load_bios(pc *p, const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f)
        return -1;
    uint8_t buf[0x10001];
    size_t n = fread(buf, 1, sizeof buf, f);
    fclose(f);
    if (n == 0 || n > 0x10000)
        return -1;
    memcpy(p->rom + 0x10000 - n, buf, n);
    return 0;
}

int pc_attach_disk(pc *p, const char *path)
{
    FILE *f = fopen(path, "r+b");
    if (!f)
        return -1;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    p->sd.image = f;
    p->sd.sectors = (uint32_t)(size / 512);
    return 0;
}

int pc_stopped(const pc *p)
{
    return p->cpu.shutdown || p->cpu.unsupported;
}

/* Advance the devices by `steps` instructions' worth of time. */
void pc_devices(pc *p, uint32_t steps)
{
    p->pit_frac += steps;
    if (p->pit_frac >= p->insn_per_tick) {
        pit_advance(p, p->pit_frac / p->insn_per_tick);
        opl_advance(p, p->pit_frac / p->insn_per_tick);
        p->pit_frac %= p->insn_per_tick;
    }
    if (p->kb_wait > 0)
        p->kb_wait -= (int)steps;
    else
        kb_poll(p);
}

void pc_run(pc *p, uint64_t n)
{
    m86 *c = &p->cpu;
    while (n > 0 && !pc_stopped(p)) {
        if (p->reset_request)
            pc_reset(p);

        uint32_t steps = 1;
        if (c->halted && !c->irq && !c->nmi) {
            /* Nothing can happen until the timer or keyboard speaks:
             * skip ahead a tick at a time. */
            steps = p->insn_per_tick;
            if (!(c->s.eflags & M86_IF) && p->kb_count == 0
                && !p->kb_obf) {
                /* Halted with interrupts off: only a reset ends this. */
                return;
            }
        } else {
            m86_step(c);
        }
        pc_devices(p, steps);
        n = n > steps ? n - steps : 0;
    }
}

uint8_t pc_screen_char(const pc *p, int row, int col)
{
    return (uint8_t)vga_text_cell(&p->vga, row, col);
}

void pc_cursor(const pc *p, int *row, int *col)
{
    int pos = (p->vga.crtc[0x0E] << 8) | p->vga.crtc[0x0F];
    *row = pos / PC_COLS;
    *col = pos % PC_COLS;
}
