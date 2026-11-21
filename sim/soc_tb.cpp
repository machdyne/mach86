/*
 * Mach86 -- the SoC (rtl/soc/m86_soc.v) in simulation.
 *
 * Unlike lockstep.cpp, nothing here is compared with the model: time
 * in the SoC is real time (a timer at 1.19 MHz, a serial line at its
 * rate), so the two would not stay in step. This is the whole machine
 * as it goes on a board, seen through its pins: a serial console and
 * an SD card. The card is the model's (sdcard.c), a bit at a time.
 *
 * usage: soc_tb -disk IMAGE [-card MB] [-max CYCLES] [-quiet] [script...]
 *   -card MB        the card's size, if larger than the image
 *   -frame FILE     at the end, write the picture on the display as a PPM
 *   -snap FILE      (a step of the script) the same, there and then
 *   -tone HZ        (a step) the speaker bit over the next tenth of a
 *                   second must be a tone of HZ, within 3%; 0: silent
 *   -expect TEXT    run until TEXT appears on the console
 *   -type TEXT      type TEXT on the console (\r for Enter)
 *   -usb TEXT       type TEXT on a USB keyboard: HID reports, as a HID
 *                   host hands them over
 *   In TEXT, \r is Enter, \n a line feed and \\ a backslash; any other
 *   backslash stands for itself, as in a DOS path -- but write a
 *   path's \r, \n as \\r, \\n.
 *   -run CYCLES     run that many clock cycles
 * With -trace N before the script, the CPU's first N bus cycles are
 * printed to stderr: for setting the RTL beside a synthesised netlist.
 * Exit status 0 if the script ran to its end.
 */
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include "Vm86_soc.h"
#ifdef SOC_RTL
#include "Vm86_soc___024root.h"
#endif
#include "verilated.h"
extern "C" {
#include "pc.h"
}

#ifndef CLK_HZ
#define CLK_HZ 24000000
#endif
#define BIT_CYCLES (CLK_HZ / 115200)

static Vm86_soc *top;
static pc_sd card;
static unsigned long long cycles, budget = 3000000000ull;
static std::string console;
static int quiet;
static unsigned long card_mb;
static long trace_left;
static unsigned long long dbg_ring[16];       /* the last cycles: pipeline state, bus */

/* ---- the card on the SPI pins ---- */
static int spi_prev_sck, spi_bits;
static uint8_t spi_in, spi_out = 0xFF;
static int spi_selected;

static uint8_t spi_next_out(void)
{
    return card.resp_pos < card.resp_len ? card.resp[card.resp_pos] : 0xFF;
}

static void spi_step(void)
{
    int sel = !top->sd_ss_n;
    if (spi_selected && !sel) {
        sd_deselect(&card);
        spi_bits = 0;
    }
    if (!spi_selected && sel) {
        spi_bits = 0;
        spi_out = spi_next_out();
    }
    spi_selected = sel;
    if (top->sd_sck && !spi_prev_sck && sel) {         /* rising: sample */
        spi_in = (uint8_t)((spi_in << 1) | (top->sd_mosi & 1));
        if (++spi_bits == 8) {
            sd_exchange(&card, spi_in);
            spi_bits = 0;
        }
    }
    if (!top->sd_sck && spi_prev_sck && sel) {         /* falling: next bit */
        if (spi_bits == 0)
            spi_out = spi_next_out();
        else
            spi_out = (uint8_t)(spi_out << 1);
    }
    spi_prev_sck = top->sd_sck;
    /* Without -disk there is no card: the line stays high. */
    top->sd_miso = (sel && card.image) ? (spi_out >> 7) & 1 : 1;
}

/* ---- the main memory, for a SoC built with MAIN_MEM = 1 ----
 * A word at a time, answered after a few cycles, as a memory
 * controller on another clock would. The controller's registers are
 * four words that read back what was written. */
#include <vector>
static std::vector<uint32_t> main_mem;
static uint32_t ctl_reg[4];
static int mem_wait, ctl_wait;
static unsigned long long mem_reads, mem_writes;

#ifdef SOC_TRAIN
/* A stand-in for a DDR3 read path that needs training, for the BIOS's
 * trainer (sw/train): the controller's three registers, and data that
 * only comes back right at the right settings. It is NOT a model of
 * the PHY -- only something with one right answer for the trainer to
 * find, shaped like what the hardware showed (Zeitlos, docs/ddr3.md):
 * writes land at one write delay; each byte lane reads at one offset,
 * over a few read phases, and the phase wraps into the next gate. */
/* The write delay that works: 1, or what TRAIN_WD says (8 or more:
 * none, to see the trainer fail). */
static uint32_t tr_wd(void)
{
    static int wd = -1;
    if (wd < 0) {
        const char *e = getenv("TRAIN_WD");
        wd = e ? atoi(e) : 1;
    }
    return (uint32_t)wd;
}
static bool lane_ok(int lane, uint32_t tune)
{
    uint32_t g  = (tune >> (lane ? 8 : 4)) & 7;
    uint32_t rs = (tune >> (lane ? 16 : 12)) & 7;
    uint32_t o  = (tune >> (lane ? 24 : 20)) & 15;
    if (lane == 0)
        return o == 5 && g == 3 && rs >= 2 && rs <= 4;
    return o == 9 && ((g == 2 && rs >= 6) || (g == 3 && rs == 0));
}
static bool lane_burst(int lane, uint32_t tune)
{
    uint32_t g = (tune >> (lane ? 8 : 4)) & 7;
    return lane ? (g == 2 || g == 3) : (g == 3 || g == 4);
}
static uint32_t tr_status(void)
{
    return 0xdd300083u | (lane_burst(0, ctl_reg[1]) ? 0x10 : 0)
                       | (lane_burst(1, ctl_reg[1]) ? 0x20 : 0);
}
static uint32_t tr_read(uint32_t v)
{
    if (!lane_ok(0, ctl_reg[1])) v ^= 0x00ff0055u;
    if (!lane_ok(1, ctl_reg[1])) v ^= 0x5500ff00u;
    return v;
}
static uint32_t tr_write(uint32_t v)
{
    return (ctl_reg[1] & 7) == tr_wd() ? v : ~v;
}
#else
static uint32_t tr_status(void) { return ctl_reg[0]; }
static uint32_t tr_read(uint32_t v) { return v; }
static uint32_t tr_write(uint32_t v) { return v; }
#endif

/* Video memory past 64 KB (the SoC's xv_ port, when it is built with
 * VGA_EXT) and the display's line buffer, as a board gives them. The
 * line is copied when it is asked for; a board takes most of a line's
 * time over it. */
static uint32_t vid_mem[65536], line_buf[256], lb_next;
static int vid_wait, vf_seen;

static void vid_step(void)
{
    top->xv_ack = 0;
    if (top->xv_req) {
        if (++vid_wait >= 6) {
            vid_wait = 0;
            top->xv_ack = 1;
            uint32_t a = top->xv_addr;
            if (top->xv_we) {
                uint32_t m = 0;
                for (int k = 0; k < 4; k++)
                    if (top->xv_sel >> k & 1) m |= 0xFFu << (8 * k);
                vid_mem[a] = (vid_mem[a] & ~m) | (top->xv_wdata & m);
            } else
                top->xv_rdata = vid_mem[a];
        }
    } else
        vid_wait = 0;
    if (top->vf_t != vf_seen) {
        vf_seen = top->vf_t;
        for (int k = 0; k < 80; k++)
            line_buf[(top->vf_par << 7) | k] = vid_mem[(top->vf_addr + k) & 0xFFFF];
    }
    lb_next = line_buf[top->lb_addr];       /* read at the clock's edge */
}

static void mem_step(void)
{
    top->m_ack = 0;
    top->x_ack = 0;
    if (top->m_req) {
        if (main_mem.empty())
            main_mem.assign(1u << 24, 0xA5A5A5A5u);     /* 64 MB of rubbish */
        if (++mem_wait >= 4) {
            mem_wait = 0;
            top->m_ack = 1;
            uint32_t a = top->m_addr & ((1u << 24) - 1);
            if (top->m_we) {
                main_mem[a] = tr_write(top->m_wdata);
                mem_writes++;
            } else {
                top->m_rdata = tr_read(main_mem[a]);
                mem_reads++;
            }
        }
    } else
        mem_wait = 0;
    if (top->x_req) {
        if (++ctl_wait >= 3) {
            ctl_wait = 0;
            top->x_ack = 1;
            if (top->x_we)
                ctl_reg[top->x_addr & 3] = top->x_wdata;
            else
                top->x_rdata = (top->x_addr & 3) ? ctl_reg[top->x_addr & 3]
                                                 : tr_status();
        }
    } else
        ctl_wait = 0;
}

/* ---- the terminal on the serial pins ---- */
static int rx_state, rx_count, rx_bit;      /* reading the SoC's output */
static uint8_t rx_byte;
static std::string tx_queue;                /* typing into the SoC */
static int tx_state, tx_count;
static uint8_t tx_byte;

static void uart_step(void)
{
    /* From the SoC. */
    if (rx_state == 0) {
        if (!top->uart_tx) {
            rx_state = 1;
            rx_count = BIT_CYCLES + BIT_CYCLES / 2;
            rx_bit = 0;
        }
    } else if (--rx_count == 0) {
        rx_count = BIT_CYCLES;
        if (rx_bit < 8) {
            rx_byte = (uint8_t)((rx_byte >> 1) | (top->uart_tx ? 0x80 : 0));
            rx_bit++;
        } else {
            rx_state = 0;
            console.push_back((char)rx_byte);
            if (!quiet) {
                fputc(rx_byte, stdout);
                fflush(stdout);
            }
        }
    }
    /* To the SoC: start bit, eight data bits, stop bit, then a gap. */
    if (tx_state == 0) {
        top->uart_rx = 1;
        if (!tx_queue.empty()) {
            tx_byte = (uint8_t)tx_queue[0];
            tx_queue.erase(0, 1);
            tx_state = 1;
            tx_count = BIT_CYCLES;
        }
    } else {
        if (tx_state == 1)
            top->uart_rx = 0;
        else if (tx_state <= 9)
            top->uart_rx = (tx_byte >> (tx_state - 2)) & 1;
        else
            top->uart_rx = 1;
        if (--tx_count == 0) {
            tx_count = BIT_CYCLES;
            if (++tx_state == 40)           /* 30 bit times between characters */
                tx_state = 0;
        }
    }
}

static unsigned long long busy_cycles;      /* cycles in which the CPU is not halted */

static void cycle(void)
{
    top->clk = 0;
    top->vclk = 0;
    top->eval();
    spi_step();
    uart_step();
    mem_step();
    vid_step();
    top->eval();
    if (trace_left > 0 && top->dbg_req && top->dbg_ack) {
        fprintf(stderr, "%s %s%d %08x %08x\n", top->dbg_io ? "io " : "mem",
                top->dbg_wr ? "w" : "r", 1 << top->dbg_size, top->dbg_addr,
                top->dbg_wr ? top->dbg_wdata : top->dbg_rdata);
        trace_left--;
    }
    dbg_ring[cycles & 15] = ((unsigned long long)top->rootp->m86_soc__DOT__cpu_dbg << 40) |
                            ((unsigned long long)top->dbg_req << 36) | ((unsigned long long)top->dbg_wr << 35) |
                            ((unsigned long long)top->dbg_ack << 34) |
                            top->dbg_addr;
    if (!top->halted) busy_cycles++;
    top->clk = 1;
    top->vclk = 1;                      /* the pixel clock: any rate will do */
    top->hid_clk = (cycles & 3) < 2;    /* the HID host's: a quarter of ours */
    top->eval();
    top->lb_q = lb_next;
    cycles++;
}

/* ---- a USB keyboard, as the HID host reports it ---- */
static void hid_report(uint8_t mod, uint8_t key)
{
    while (top->hid_clk) cycle();           /* change while its clock is low */
    top->hid_typ = 1;
    top->hid_mod = mod;
    top->hid_k1 = key;
    top->hid_k2 = top->hid_k3 = top->hid_k4 = 0;
    top->hid_report = 1;
    for (int k = 0; k < 4; k++) cycle();    /* one of its cycles */
    top->hid_report = 0;
    for (int k = 0; k < 200000; k++) cycle();   /* 8 ms: a keyboard's pace */
}

/* The key that types a character on a US keyboard: usage, and Shift. */
static int hid_key(int ch, int *shift)
{
    static const char plain[] = "\r\x1b\b\t -=[]\\#;'`,./";    /* usages 28h up */
    static const char digits[] = ")!@#$%^&*(";                 /* Shift 0 to 9 */
    static const char shpunct[] = "_+{}|:\"~<>?";
    static const char unpunct[] = "-=[]\\;'`,./";
    const char *p;
    *shift = 0;
    if (ch == 0) return 0;
    if (ch >= 'a' && ch <= 'z') return 0x04 + ch - 'a';
    if (ch >= 'A' && ch <= 'Z') { *shift = 1; return 0x04 + ch - 'A'; }
    if (ch >= '1' && ch <= '9') return 0x1E + ch - '1';
    if (ch == '0') return 0x27;
    if (ch == 0x11) return 0x52;            /* up */
    if (ch == 0x12) return 0x51;            /* down */
    if (ch == 0x13) return 0x50;            /* left */
    if (ch == 0x14) return 0x4F;            /* right */
    if ((p = strchr(digits, ch)) != NULL) {
        *shift = 1;
        return p == digits ? 0x27 : 0x1E + (int)(p - digits) - 1;
    }
    if ((p = strchr(shpunct, ch)) != NULL) {
        *shift = 1;
        ch = unpunct[p - shpunct];
    }
    if ((p = strchr(plain, ch)) != NULL) return 0x28 + (int)(p - plain);
    return 0;
}

static void hid_type(const std::string &text)
{
    for (size_t k = 0; k < text.size() && cycles < budget; k++) {
        int shift, key = hid_key((unsigned char)text[k], &shift);
        if (!key) continue;
        if (shift) hid_report(0x02, 0);
        hid_report(shift ? 0x02 : 0x00, (uint8_t)key);
        hid_report(shift ? 0x02 : 0x00, 0);
        if (shift) hid_report(0x00, 0);
    }
}

/* One picture off the display's pins, as a PPM file: wait for a vertical
 * sync, then take every pixel that has "data enable" up to the next. */
static const char *frame_file;

#define CURSOR ((top->rootp->m86_soc__DOT__vga__DOT__crtc0e << 8) | \
                top->rootp->m86_soc__DOT__vga__DOT__crtc0f)

static void write_frame(const char *name)
{
    FILE *f = fopen(name, "wb");
    if (!f)
        return;
    fprintf(f, "P6\n640 480\n255\n");
    long n = 0;
#ifdef SOC_RTL
    /* A picture in which the text cursor is in the dark half of its
     * blink, so that pictures can be compared. */
    for (long guard = 0; guard < 40000000 &&
         (top->rootp->m86_soc__DOT__vga__DOT__frame & 0x10); guard++)
        cycle();
#endif
    int prev = top->v_vsync;
    for (long guard = 0; guard < 2000000; guard++) {     /* to the end of a sync */
        cycle();
        if (top->v_vsync && !prev)
            break;
        prev = top->v_vsync;
    }
    while (n < 640 * 480) {
        cycle();
        if (top->v_de) {
            fputc(top->v_r, f);
            fputc(top->v_g, f);
            fputc(top->v_b, f);
            n++;
        }
    }
    fclose(f);
}

static std::string unescape(const char *s)
{
    std::string r;
    for (; *s; s++) {
        if (s[0] == '\\' && s[1] == 'r') { r.push_back('\r'); s++; }
        else if (s[0] == '\\' && s[1] == 'n') { r.push_back('\n'); s++; }
        else if (s[0] == '\\' && s[1] == '\\') { r.push_back('\\'); s++; }
        else r.push_back(*s);
    }
    return r;
}

double sc_time_stamp(void) { return (double)cycles; }

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    const char *disk = NULL;
    int i = 1;
    for (; i < argc; i++) {
        if (!strcmp(argv[i], "-disk") && i + 1 < argc) disk = argv[++i];
        else if (!strcmp(argv[i], "-max") && i + 1 < argc)
            budget = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "-card") && i + 1 < argc)
            card_mb = strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "-quiet")) quiet = 1;
        else if (!strcmp(argv[i], "-frame") && i + 1 < argc)
            frame_file = argv[++i];
        else if (!strcmp(argv[i], "-trace") && i + 1 < argc)
            trace_left = strtol(argv[++i], NULL, 0);
        else break;
    }
    memset(&card, 0, sizeof card);
    if (disk) {
        card.image = fopen(disk, "r+b");
        if (!card.image) {
            fprintf(stderr, "soc_tb: cannot open %s\n", disk);
            return 2;
        }
        fseek(card.image, 0, SEEK_END);
        card.sectors = (uint32_t)(ftell(card.image) / 512);
        if (card_mb)                    /* a card larger than its image */
            card.sectors = (uint32_t)(card_mb * 2048ul);
    }
    sd_deselect(&card);

    top = new Vm86_soc;
    top->uart_rx = 1;
    top->sd_miso = 1;
    top->rst = 1;
    for (int k = 0; k < 4; k++)
        cycle();
    top->rst = 0;

    size_t seen = 0;                        /* console text already matched */
    int ok = 1;
    for (; i < argc && ok; i++) {
        const char *arg = i + 1 < argc ? argv[i + 1] : "";
        if (!strcmp(argv[i], "-expect")) {
            std::string want = unescape(arg);
            size_t at;
            while ((at = console.find(want, seen)) == std::string::npos
                   && cycles < budget)
                cycle();
            if (at == std::string::npos) {
                fprintf(stderr, "\nsoc_tb: \"%s\" did not appear in %llu cycles\n",
                        arg, cycles);
                ok = 0;
            } else
                seen = at + want.size();
            i++;
        } else if (!strcmp(argv[i], "-type")) {
            tx_queue += unescape(arg);
            while ((!tx_queue.empty() || tx_state) && cycles < budget)
                cycle();
            i++;
        } else if (!strcmp(argv[i], "-usb")) {
            hid_type(unescape(arg));
            i++;
        } else if (!strcmp(argv[i], "-mouse")) {
            /* a USB mouse's report: DX,DY,BUTTONS */
            int dx = 0, dy = 0, b = 0;
            sscanf(arg, "%d,%d,%d", &dx, &dy, &b);
            while (top->hid_clk) cycle();
            top->ms_dx = dx & 255; top->ms_dy = dy & 255; top->ms_btn = b & 7;
            top->ms_report = 1;
            for (int k = 0; k < 4; k++) cycle();
            top->ms_report = 0;
            for (int k = 0; k < 200000; k++) cycle();
            i++;
        } else if (!strcmp(argv[i], "-tone")) {
            /* Rising edges of the speaker bit in a tenth of a second
             * of the machine's time (its clock is 24 MHz here). */
            long want = strtol(arg, NULL, 0), edges = 0;
            int prev = top->spk;
            for (long n = 0; n < 2400000; n++) {
                cycle();
                if (top->spk && !prev) edges++;
                prev = top->spk;
            }
            long hz = edges * 10;
            fprintf(stderr, "soc_tb: speaker: %ld Hz\n", hz);
            if (want == 0 ? edges != 0
                          : (hz * 100 < want * 97 || hz * 100 > want * 103)) {
                fprintf(stderr, "soc_tb: the speaker should sound %ld Hz\n", want);
                ok = 0;
            }
            i++;
        } else if (!strcmp(argv[i], "-snap")) {
            write_frame(arg);
            i++;
        } else if (!strcmp(argv[i], "-run")) {
            unsigned long long n = strtoull(arg, NULL, 0);
            while (n-- && cycles < budget)
                cycle();
            i++;
        } else {
            fprintf(stderr, "soc_tb: what is %s?\n", argv[i]);
            return 2;
        }
    }
    if (frame_file)
        write_frame(frame_file);
#ifdef SOC_RTL
    fprintf(stderr, "\nsoc_tb: cursor at row %u, column %u%s",
            CURSOR / 80, CURSOR % 80,
            (top->rootp->m86_soc__DOT__vga__DOT__crtc0a & 0x20) ? " (off)" : "");
#endif
#ifdef SOC_RTL
    {
        unsigned long long n = top->rootp->m86_soc__DOT__cpu_insns;
        fprintf(stderr, "\nsoc_tb: %llu instructions in %llu cycles not halted: "
                "%.2f cycles per instruction", n, busy_cycles,
                n ? (double)busy_cycles / (double)n : 0.0);
    }
#endif
    if (mem_reads)
        fprintf(stderr, "\nsoc_tb: main memory: %llu words read, %llu written",
                mem_reads, mem_writes);
    /* The bus as it stands (when a run has stopped making progress). */
    if (!ok)
        fprintf(stderr, "soc_tb: the bus at the end: req %d wr %d io %d ack %d size %d addr %08x; pipeline %06x\n",
                top->dbg_req, top->dbg_wr, top->dbg_io, top->dbg_ack, top->dbg_size, top->dbg_addr,
                (unsigned)top->rootp->m86_soc__DOT__cpu_dbg);
    if (!ok)
        for (int k = 1; k <= 16; k++) {
            unsigned long long v = dbg_ring[(cycles + k) & 15];
            fprintf(stderr, "soc_tb:   pipeline %06llx  req %llu wr %llu ack %llu addr %08llx\n",
                    v >> 40, (v >> 36) & 1, (v >> 35) & 1, (v >> 34) & 1, v & 0xFFFFFFFFull);
        }
    fprintf(stderr, "\nsoc_tb: %llu cycles (%.2f s at %d MHz), last fault %02x%s\n",
            cycles, (double)cycles / CLK_HZ, CLK_HZ / 1000000, top->last_exc,
            ok ? "" : ": FAILED");
    if (card.image)
        fclose(card.image);
    return ok ? 0 : 1;
}
