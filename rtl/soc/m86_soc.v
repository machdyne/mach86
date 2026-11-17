/*
 * Mach86 SoC -- the first one: the CPU (design B), memory in block
 * RAM, and the PC devices the BIOS and DOS need, with a serial
 * console in place of the screen and keyboard and an SD card on SPI.
 * The map is docs/hwmap.md; the machine is the one the reference
 * model implements (sim/pc.c), which is what the BIOS and DOS have
 * been run against.
 *
 *   memory    00000h up        RAM, RAM_KB kilobytes
 *             A0000h-BFFFFh    the VGA's memory (m86_vga.v)
 *             F0000h-FFFFFh    the BIOS, a 16 KB ROM repeated
 *             anywhere else    reads FFh
 *   ports     20h 21h A0h A1h  interrupt controllers
 *             40h-43h          timer
 *             60h 64h 92h      keyboard controller, A20, reset
 *             61h              speaker gate and switch, refresh toggle
 *             70h 71h          clock and configuration memory
 *             3C0h-3DFh        the VGA's registers
 *             388h 389h        the AdLib (m86_opl2.v)
 *             1E0h             the speed control: cycles to wait after each
 *                              instruction (ours; docs/speed.md)
 *             E3h              the mouse (m86_usbmouse.v), interrupt 12
 *             E0h              console: write a character; bit 7 read: no room
 *             E1h E2h          SD card SPI
 *
 * The bus: the CPU holds a read request until it is acknowledged, and
 * everything here but the main memory and the VGA's answers in the
 * cycle after the request, as block RAM does. A write takes the one
 * cycle it is asked in. Ports are a byte wide: a wider port access
 * reads FFh in its upper bytes and writes only its lowest; but a word
 * written to one of the VGA's index ports writes the index and the
 * register, which is how programs set them.
 *
 * What the console shows is what the BIOS's teletype call writes.
 * What it receives is turned into key presses (m86_kbd.v).
 */
module m86_soc #(
    parameter CLK_HZ = 24000000,
    parameter BAUD   = 115200,
    parameter RAM_KB = 160,
    // 1: the main memory is outside (SDRAM, DDR3), behind a cache, on
    // the m_ ports; RAM_KB is not used. 640 KB below A0000h and
    // everything from 1 MB up to 2**MEM_AW bytes go there.
    parameter MAIN_MEM = 0,
    parameter MEM_AW = 26,
    parameter CACHE_LINE_BITS = 12, // the cache: 2**this lines of 16 bytes
    parameter MEM_TRAIN = 0,        // 1: the memory needs training (the x_ ports)
    parameter EXT_KB = 0,           // memory above 1 MB, for the configuration memory
    parameter VGA_EXT = 0,          // 1: video memory past 64 KB is outside (xv_, vf_, lb_)
    parameter VGA_BRAM = 1,         // 0: and the first 64 KB too
    parameter ROM0 = "rom0.hex",
    parameter ROM1 = "rom1.hex",
    parameter ROM2 = "rom2.hex",
    parameter ROM3 = "rom3.hex",
    parameter UCODE = "ucode.hex",
    parameter ATTR  = "attr.hex",
    parameter KBD_WAIT = 8192,
    parameter FONT = "font.hex",
    parameter HDMI_DEF = 1'b0          // port 1E1h bit 0 at power-on
) (
    input  wire clk,
    input  wire rst,
    // The display, on its own clock (25.2 MHz for 640 x 480).
    input  wire       vclk,
    output wire [7:0] v_r,
    output wire [7:0] v_g,
    output wire [7:0] v_b,
    output wire       v_hsync,
    output wire       v_vsync,
    output wire       v_de,
    output wire uart_tx,
    input  wire uart_rx,
    output wire sd_sck,
    output wire sd_mosi,
    input  wire sd_miso,
    output wire sd_ss_n,
    // A USB keyboard, from a HID host on its own clock (m86_usbkbd.v).
    // Without one: hid_typ 0 and the rest anything.
    input  wire       hid_clk,
    input  wire       ms_report,    // a USB mouse's report, on hid_clk (m86_usbmouse.v)
    input  wire [2:0] ms_btn,
    input  wire [7:0] ms_dx,
    input  wire [7:0] ms_dy,
    input  wire       hid_report,
    input  wire [1:0] hid_typ,
    input  wire [7:0] hid_mod,
    input  wire [7:0] hid_k1,
    input  wire [7:0] hid_k2,
    input  wire [7:0] hid_k3,
    input  wire [7:0] hid_k4,
    // Video memory past 64 KB, when VGA_EXT (m86_vga.v): word
    // requests as m_'s, with the planes a write changes; and the
    // display's line buffer, on vclk.
    output wire        xv_req,
    output wire        xv_we,
    output wire [3:0]  xv_sel,
    output wire [15:0] xv_addr,
    output wire [31:0] xv_wdata,
    input  wire [31:0] xv_rdata,
    input  wire        xv_ack,
    output wire        vf_t,
    output wire [15:0] vf_addr,
    output wire        vf_par,
    output wire [7:0]  lb_addr,
    input  wire [31:0] lb_q,
    output wire hdmi,               // port 1E1h bit 0: sound on the display's cable, please
    output wire spk,                // the PC speaker: timer channel 2 and port 61h bit 1
    output wire       opl_we,       // the AdLib's register writes, for m86_opl2
    output wire [7:0] opl_a,
    output wire [7:0] opl_d,
    output wire halted,             // for a light: the CPU is waiting for an interrupt
    output wire [7:0] last_exc,     // the CPU's last fault (FFh: none), for a probe
    output reg  tick18,             // toggles on each timer interrupt, for a light
    // The main memory, a word at a time (MAIN_MEM = 1): held until m_ack.
    output wire              m_req,
    output wire              m_we,
    output wire [MEM_AW-3:0] m_addr,
    output wire [31:0]       m_wdata,
    input  wire [31:0]       m_rdata,
    input  wire              m_ack,
    // The memory controller's own registers, the same way.
    output wire        x_req,
    output wire        x_we,
    output wire [1:0]  x_addr,
    output wire [31:0] x_wdata,
    input  wire [31:0] x_rdata,
    input  wire        x_ack,
    // The CPU's bus, for a trace in simulation; not connected on a board.
    output wire        dbg_req,
    output wire        dbg_wr,
    output wire        dbg_io,
    output wire        dbg_ack,
    output wire [1:0]  dbg_size,
    output wire [31:0] dbg_addr,
    output wire [31:0] dbg_wdata,
    output wire [31:0] dbg_rdata
);
    assign dbg_req = d_req;   assign dbg_wr = d_wr;     assign dbg_io = d_io;
    assign dbg_ack = d_ack;   assign dbg_size = d_size; assign dbg_addr = d_addr;
    assign dbg_wdata = d_wdata; assign dbg_rdata = d_rdata;

    localparam RAM_BYTES = RAM_KB * 1024;

    // ---- reset: the board's, or the machine's own request ----
    wire       reset_req;
    reg [3:0]  rst_cnt;
    wire       sys_rst = (rst_cnt != 4'd0);
    always @(posedge clk)
        if (rst || reset_req)
            rst_cnt <= 4'd15;
        else if (sys_rst)
            rst_cnt <= rst_cnt - 4'd1;

    // ---- the CPU ----
    wire        d_req, d_wr, d_io;
    wire [31:0] d_addr, d_wdata;
    wire [1:0]  d_size;
    reg  [31:0] d_rdata;
    reg         ack_r;
    wire        c_ack, c_ack_any, c_st_rdy, v_ack, v_st_rdy;
    wire        d_st_rdy = c_st_rdy && v_st_rdy;
    wire [31:0] v_rdata;
    wire [31:0] c_rdata;
    wire        d_ack = ack_r || c_ack || v_ack || (d_req && d_wr);
    // What the CPU is told: the cache's answer without waiting to see
    // whether the CPU's request stood (it knows that itself, and its
    // request arrives late, behind the limit check); and nothing for
    // a write, which it does not wait for.
    wire        d_ack_cpu = ack_r || c_ack_any || v_ack;
    wire        irq, inta;
    wire [7:0]  irq_vec;

    m86b_core #(.UCODE(UCODE), .ATTR(ATTR)) cpu (
        .clk(clk), .rst(sys_rst),
        .d_req(d_req), .d_wr(d_wr), .d_addr(d_addr), .d_size(d_size),
        .d_wdata(d_wdata), .d_rdata(d_rdata), .d_ack(d_ack_cpu), .d_st_rdy(d_st_rdy),
        .e_req(e_req), .e_addr(e_addr), .e_size(e_size),
        .d_io(d_io),
        .slow(slow), .irq(irq), .irq_vec(irq_vec), .inta(inta),
        .halted(halted), .step_done(), .last_exc(last_exc), .dbg_insns());

    always @(posedge clk)
        ack_r <= d_req && !d_wr && !ack_r && !sys_rst && !(MAIN_MEM != 0 && is_main) &&
                 !is_vid && !(d_io && cs_vga && !v_idle);

    // ---- memory ----
    wire        a20;
    wire [20:0] ma     = {d_addr[20] & a20, d_addr[19:0]};
    wire        in_1m  = (d_addr[31:21] == 11'd0) && !ma[20];
    wire        is_ram = (MAIN_MEM == 0) && in_1m && (ma[19:0] < RAM_BYTES);
    // The main memory: all but the hole from A0000h to FFFFFh.
    wire [31:0] fa      = {d_addr[31:21], ma};
    wire        is_main = !d_io && (fa[31:MEM_AW] == 0) &&
                          !(fa[MEM_AW-1:20] == 0 && fa[19:16] >= 4'hA);
    // The same for a read the CPU announces a cycle early.
    wire        e_req;
    wire [31:0] e_addr;
    wire [1:0]  e_size;
    wire [31:0] e_fa   = {e_addr[31:21], e_addr[20] & a20, e_addr[19:0]};
    wire        e_main = (e_fa[31:MEM_AW] == 0) &&
                         !(e_fa[MEM_AW-1:20] == 0 && e_fa[19:16] >= 4'hA);
    wire        is_vid = !d_io && in_1m && (ma[19:17] == 3'b101);
    wire        is_rom = in_1m && (ma[19:16] == 4'hF);
    wire        mem_wr = d_req && d_wr && !d_io;
    wire [31:0] ram_q, rom_q;

    wire              cm_req, cm_we;
    wire [MEM_AW-3:0] cm_addr;
    wire [31:0]       cm_wdata;
    wire              mp_mem;       // the memory port is in use by the BIOS
    generate
        if (MAIN_MEM == 0) begin : g_bram
            m86_mem #(.AW(18), .BYTES(RAM_BYTES)) ram (
                .clk(clk), .addr(ma[17:0]), .we(mem_wr && is_ram), .wsize(d_size),
                .wdata(d_wdata), .rdata(ram_q));
            assign c_ack = 1'b0;
            assign c_ack_any = 1'b0;
            assign c_rdata = 32'd0;
            assign c_st_rdy = 1'b1;
            assign cm_req = 1'b0;
            assign cm_we = 1'b0;
            assign cm_addr = {(MEM_AW-2){1'b0}};
            assign cm_wdata = 32'd0;
        end else begin : g_main
            assign ram_q = 32'd0;
            m86_dcache #(.AW(MEM_AW), .LINE_BITS(CACHE_LINE_BITS)) cache (
                .clk(clk), .rst(sys_rst),
                .req(d_req && is_main), .wr(d_wr), .addr(fa[MEM_AW-1:0]),
                .size(d_size), .wdata(d_wdata),
                .e_req(e_req), .e_ok(e_main), .e_addr(e_fa[MEM_AW-1:0]),
                .e_size(e_size),
                .rdata(c_rdata), .ack(c_ack), .ack_any(c_ack_any),
                .st_rdy(c_st_rdy),
                .m_req(cm_req), .m_we(cm_we), .m_addr(cm_addr), .m_wdata(cm_wdata),
                .m_rdata(m_rdata), .m_ack(m_ack && !mp_mem));
        end
    endgenerate

    // The memory port: ports E4h, E8h, ECh. Through it the BIOS reaches
    // a word of the main memory past the cache, or one of the memory
    // controller's registers, which is what training a DDR3 memory
    // needs. E8h holds the address (a word address, or a register
    // number), ECh the data, both 32 bits. Writing E4h starts a
    // transfer: bit 0 write, bit 1 a register. Reading E4h: bit 7 busy,
    // bit 1 the memory needs training, bit 0 there is a main memory.
    // The BIOS does not touch the main memory any other way meanwhile.
    reg [31:0] mp_addr, mp_data;
    reg        mp_busy, mp_wr, mp_reg;
    assign mp_mem = mp_busy && !mp_reg;
    assign m_req   = mp_mem ? 1'b1 : cm_req;
    assign m_we    = mp_mem ? mp_wr : cm_we;
    assign m_addr  = mp_mem ? mp_addr[MEM_AW-3:0] : cm_addr;
    assign m_wdata = mp_mem ? mp_data : cm_wdata;
    assign x_req   = mp_busy && mp_reg;
    assign x_we    = mp_wr;
    assign x_addr  = mp_addr[1:0];
    assign x_wdata = mp_data;
    // The VGA: its memory at A0000h-BFFFFh, its ports at 3C0h-3DFh.
    wire [7:0] vga_q;
    wire       v_idle;
    m86_vga #(.FONT(FONT), .VGA_EXT(VGA_EXT), .VGA_BRAM(VGA_BRAM)) vga (
        .clk(clk), .rst(sys_rst),
        .req(d_req && is_vid), .wr(d_wr), .addr(ma[16:0]), .size(d_size),
        .wdata(d_wdata), .rdata(v_rdata), .ack(v_ack), .st_rdy(v_st_rdy),
        .idle(v_idle),
        .io_rd(io_rd && cs_vga && v_idle), .io_wr(io_wr && cs_vga), .io_a(port[4:0]),
        .io_wd(d_wdata[15:0]), .io_word(d_size != 2'd0), .io_q(vga_q),
        .x_req(xv_req), .x_we(xv_we), .x_sel(xv_sel), .x_addr(xv_addr),
        .x_wdata(xv_wdata), .x_rdata(xv_rdata), .x_ack(xv_ack),
        .vf_t(vf_t), .vf_addr(vf_addr), .vf_par(vf_par),
        .lb_addr(lb_addr), .lb_q(lb_q),
        .vclk(vclk), .r(v_r), .g(v_g), .b(v_b),
        .hsync(v_hsync), .vsync(v_vsync), .de(v_de));
    m86_mem #(.AW(14), .INIT0(ROM0), .INIT1(ROM1), .INIT2(ROM2), .INIT3(ROM3)) rom (
        .clk(clk), .addr(ma[13:0]), .we(1'b0), .wsize(2'd0),
        .wdata(32'd0), .rdata(rom_q));

    // ---- ports ----
    wire [15:0] port  = d_addr[15:0];
    wire        io_rd = d_req && d_io && !d_wr && !ack_r;   // once per read
    wire        io_wr = d_req && d_io && d_wr;
    wire [7:0]  io_wd = d_wdata[7:0];

    wire cs_pic_m = (port[15:1] == 15'h0010);       // 20h, 21h
    wire cs_pic_s = (port[15:1] == 15'h0050);       // A0h, A1h
    wire cs_pit   = (port[15:2] == 14'h0010);       // 40h-43h
    wire cs_60    = (port == 16'h0060);
    wire cs_61    = (port == 16'h0061);
    wire cs_64    = (port == 16'h0064);
    wire cs_92    = (port == 16'h0092);
    wire cs_70    = (port == 16'h0070);
    wire cs_71    = (port == 16'h0071);
    wire cs_e0    = (port == 16'h00E0);
    wire cs_e1    = (port == 16'h00E1);
    wire cs_e2    = (port == 16'h00E2);
    wire cs_e4    = (port == 16'h00E4);
    wire cs_e8    = (port == 16'h00E8);
    wire cs_ec    = (port == 16'h00EC);
    wire cs_vga   = (port[15:5] == 11'h01E);        // 3C0h-3DFh
    wire cs_opl   = (port[15:1] == 15'h01C4);       // 388h, 389h
    wire cs_e3    = (port == 16'h00E3);
    wire cs_slow  = (port == 16'h01E0);
    wire cs_hdmi  = (port == 16'h01E1);

    // Interrupt controllers.
    wire [7:0] pic_q;
    wire       irq0, irq1;
    m86_pic pic (
        .clk(clk), .rst(sys_rst), .cs_m(cs_pic_m), .cs_s(cs_pic_s), .a0(port[0]),
        .wr(io_wr), .wdata(io_wd), .rdata(pic_q),
        .req({3'd0, irq12, 10'd0, irq1, irq0}), .irq(irq), .inta(inta), .vec(irq_vec));

    // Timer: 1,193,182 ticks a second, made from the system clock.
    reg [31:0] pit_acc;
    reg        pit_tick;
    always @(posedge clk) begin
        pit_tick <= 1'b0;
        if (pit_acc + 32'd1193182 >= CLK_HZ) begin
            pit_acc  <= pit_acc + 32'd1193182 - CLK_HZ;
            pit_tick <= 1'b1;
        end else
            pit_acc <= pit_acc + 32'd1193182;
        if (sys_rst)
            pit_acc <= 32'd0;
    end

    // The AdLib: what programs talk to is here; the sound is the
    // board's (m86_opl2), fed by the register writes.
    wire [7:0] opl_status;
    m86_opl2_bus #(.CLK_HZ(CLK_HZ)) oplbus (
        .clk(clk), .rst(sys_rst), .wr(io_wr && cs_opl), .a(port[0]),
        .wd(io_wd), .status(opl_status),
        .reg_we(opl_we), .reg_a(opl_a), .reg_d(opl_d));

    // The speed control: port 1E0h is how many cycles the CPU waits
    // after every instruction (docs/speed.md). Reset: none.
    reg [7:0] slow;
    always @(posedge clk)
        if (sys_rst) slow <= 8'd0;
        else if (io_wr && cs_slow) slow <= io_wd;

    // The display's sound: port 1E1h bit 0 asks the board to send
    // HDMI data islands with the sound in them, where it can
    // (docs/sound.md). A reset leaves it as it is, so the picture does
    // not blink on Ctrl-Alt-Del.
    reg hdmi_r = HDMI_DEF;
    always @(posedge clk)
        if (io_wr && cs_hdmi) hdmi_r <= io_wd[0];
    assign hdmi = hdmi_r;

    // The mouse: port E3h, interrupt 12.
    wire [7:0] mouse_q;
    wire       irq12;
    m86_usbmouse mouse (
        .clk(clk), .rst(sys_rst), .hid_clk(hid_clk), .ms_report(ms_report),
        .ms_btn(ms_btn), .ms_dx(ms_dx), .ms_dy(ms_dy),
        .rd(io_rd && cs_e3), .wr(io_wr && cs_e3), .q(mouse_q), .irq(irq12));

    wire [7:0] pit_q;
    assign spk = pit_out2 && p61[1];
    wire       pit_out2;
    reg  [4:0] p61;                 // bits 3:0 as written, bit 4 toggles
    m86_pit pit (
        .clk(clk), .rst(sys_rst), .tick(pit_tick), .cs(cs_pit), .a(port[1:0]),
        .rd(io_rd), .wr(io_wr), .wdata(io_wd), .rdata(pit_q),
        .gate2(p61[0]), .out2(pit_out2), .irq0(irq0));

    always @(posedge clk)
        if (sys_rst)
            tick18 <= 1'b0;
        else if (irq0)
            tick18 <= !tick18;

    // Keyboard controller, fed from the console's receiver.
    wire [7:0] kbd_q, rx_data;
    wire       rx_valid;
    wire       sc_valid, sc_ready;
    wire [7:0] sc_data;
    m86_usbkbd #(.CLK_HZ(CLK_HZ)) usbkbd (
        .clk(clk), .rst(sys_rst),
        .hid_clk(hid_clk), .hid_report(hid_report), .hid_typ(hid_typ),
        .hid_mod(hid_mod), .hid_k1(hid_k1), .hid_k2(hid_k2),
        .hid_k3(hid_k3), .hid_k4(hid_k4),
        .sc_valid(sc_valid), .sc_data(sc_data), .sc_ready(sc_ready),
        .present());
    m86_kbd #(.WAIT(KBD_WAIT)) kbd (
        .clk(clk), .rst(sys_rst), .cs60(cs_60), .cs64(cs_64), .cs92(cs_92),
        .rd(io_rd), .wr(io_wr), .wdata(io_wd), .rdata(kbd_q),
        .key_valid(rx_valid), .key(rx_data),
        .sc_valid(sc_valid), .sc_data(sc_data), .sc_ready(sc_ready),
        .irq1(irq1), .a20(a20), .reset_req(reset_req));

    // Console.
    wire tx_full;
    m86_uart #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) uart (
        .clk(clk), .rst(rst),
        .tx_valid(io_wr && cs_e0), .tx_data(io_wd), .tx_full(tx_full),
        .rx_valid(rx_valid), .rx_data(rx_data),
        .txd(uart_tx), .rxd(uart_rx));

    // SD card.
    wire [7:0] spi_q;
    m86_spi #(.CLK_HZ(CLK_HZ)) spi (
        .clk(clk), .rst(sys_rst), .cs_data(cs_e1), .cs_ctrl(cs_e2),
        .wr(io_wr), .wdata(io_wd), .rdata(spi_q),
        .sck(sd_sck), .mosi(sd_mosi), .miso(sd_miso), .ss_n(sd_ss_n));

    // Clock and configuration memory: a fixed date, 1990-01-01 12:00,
    // and the memory sizes. It does not count.
    reg [7:0] nvram [0:127];
    reg [7:0] nv_idx;
    integer k;
    initial begin
        for (k = 0; k < 128; k = k + 1)
            nvram[k] = 8'h00;
        nvram[8'h04] = 8'h12;        // hours, BCD
        nvram[8'h06] = 8'h02;        // day of the week
        nvram[8'h07] = 8'h01;        // day
        nvram[8'h08] = 8'h01;        // month
        nvram[8'h09] = 8'h90;        // year
        nvram[8'h32] = 8'h19;        // century
        nvram[8'h0A] = 8'h26;
        nvram[8'h0B] = 8'h02;        // 24-hour, BCD
        nvram[8'h0D] = 8'h80;
        nvram[8'h15] = 8'h80;        // base memory: 640 KB (the BIOS measures it)
        nvram[8'h16] = 8'h02;
        nvram[8'h17] = EXT_KB & 255; nvram[8'h18] = EXT_KB >> 8;
        nvram[8'h30] = EXT_KB & 255; nvram[8'h31] = EXT_KB >> 8;
    end
    always @(posedge clk) begin
        if (io_wr && cs_70) nv_idx <= io_wd;
        if (io_wr && cs_71) nvram[nv_idx[6:0]] <= io_wd;
    end

    always @(posedge clk) begin
        if (io_rd && cs_61) p61[4] <= !p61[4];
        if (io_wr && cs_61) p61[3:0] <= io_wd[3:0];
        if (sys_rst) begin
            p61 <= 5'd0;
        end
    end

    // What a port reads, taken in the first cycle of the request.
    always @(posedge clk) begin
        if (io_wr && cs_e8) mp_addr <= d_wdata;
        if (io_wr && cs_ec) mp_data <= d_wdata;
        if (io_wr && cs_e4 && MAIN_MEM != 0) begin
            mp_busy <= 1'b1;
            mp_wr   <= io_wd[0];
            mp_reg  <= io_wd[1];
        end
        if (mp_busy && (mp_reg ? x_ack : m_ack)) begin
            mp_busy <= 1'b0;
            if (!mp_wr)
                mp_data <= mp_reg ? x_rdata : m_rdata;
        end
        if (sys_rst)
            mp_busy <= 1'b0;
    end

    reg [31:0] io_q;
    always @(posedge clk)
        io_q <= cs_e8 ? mp_addr :
                cs_ec ? mp_data :
                {24'hFFFFFF,
                (cs_pic_m || cs_pic_s) ? pic_q :
                cs_pit ? pit_q :
                (cs_60 || cs_64 || cs_92) ? kbd_q :
                cs_61 ? {2'b00, pit_out2, !p61[4], p61[3:0]} :
                cs_70 ? nv_idx :
                cs_71 ? nvram[nv_idx[6:0]] :
                cs_e0 ? {tx_full, 7'd0} :
                (cs_e1 || cs_e2) ? spi_q :
                cs_vga ? vga_q :
                cs_opl ? opl_status :
                cs_e3 ? mouse_q :
                cs_slow ? slow :
                cs_hdmi ? {7'd0, hdmi_r} :
                cs_e4 ? {mp_busy, 5'd0, MEM_TRAIN != 0, MAIN_MEM != 0} :
                8'hFF};

    // ---- what the CPU reads ----
    reg [3:0] sel_q;
    always @(posedge clk)
        sel_q <= {d_io, is_rom, 1'b0, is_ram};
    always @(*) begin
        if (c_ack_any)
            d_rdata = c_rdata;
        else if (v_ack)
            d_rdata = v_rdata;
        else if (sel_q[3])
            d_rdata = io_q;
        else if (sel_q[0])
            d_rdata = ram_q;
        else if (sel_q[2])
            d_rdata = rom_q;
        else
            d_rdata = 32'hFFFFFFFF;
    end
endmodule
