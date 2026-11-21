/*
 * Mach86 on Sergei with the Sechzig ML2 module (LFE5U-45F).
 *
 * The SoC of rtl/soc/m86_soc.v at 31.5 MHz, with its memory in the
 * module's DDR3: 64 MB of it, behind a 64 KB cache. The display is
 * DDMI (DVI on an HDMI connector): 80 x 25 text in 640 x 480 at 60 Hz.
 * The console is also on the board's UART at 115200 baud, 8N1, which
 * is a second keyboard; the disk is the microSD card. A low-speed
 * USB keyboard on the first USB host port is the PC's keyboard
 * (rtl/ext/usb_hid_host, the HID host Zeitlos carries, then
 * rtl/soc/m86_usbkbd.v). The second USB port and Ethernet are not
 * used yet and their pins are left alone.
 *
 * The DDR3 controller, its PHY and its clocks are Zeitlos's
 * (rtl/ext/zeitlos, see the README there), wired the way Zeitlos
 * wires them on this board, and the BIOS trains the read path with
 * Zeitlos's algorithm (sw/train). The controller runs on its own 48
 * MHz clock, made from the memory's 96 MHz; the machine reaches it
 * through rtl/soc/m86_xclk.v.
 *
 * Clocks: one PLL on the 48 MHz oscillator for the machine and the
 * display (the settings are Zeitlos's rtl/clk/pll1.v for 640 x 480,
 * with a third output): 126 MHz for the DVI bits, 25.2 MHz for the
 * pixels, 31.5 MHz for the machine. A second one, inside ddr3_clk,
 * for the memory.
 *
 * LED: a slow blink says the clocks run and the design is configured.
 * A fast blink says the CPU has taken a fault at some point since
 * reset, which a healthy DOS boot does not do.
 *
 * PROGRAMN is wired back to a user pin on this module (see Zeitlos,
 * boards/sergei_ml2.lpf). It is an input with a pull-up here: an
 * unused pin would be pulled down, and that would reconfigure the
 * FPGA for ever.
 *
 * Mozart ML2 is the same module in another carrier and is built from
 * this file with defines (the Makefile's): M86_TOP names the module;
 * M86_PT8211 sends the sound to a PT8211 DAC and not to the optical
 * output; M86_NO_SDDAT leaves out the card's two unused data lines.
 * It has not run on a board.
 */
`ifndef M86_TOP
`define M86_TOP sergei_ml2
`endif
// The processor's options (rtl/cpu/m86b_core.v): paging, virtual 8086
// mode and the I/O permission bitmap; loads that let the next
// instruction start.
`ifndef M86_VMEM
`define M86_VMEM 1
`endif
`ifndef M86_OVL
`define M86_OVL 1
`endif
// The main memory's bridge: 1 a cache line at a time (m86_xline.v), 0 a
// word at a time (m86_xclk.v, as before round 40).
`ifndef M86_XLINE
`define M86_XLINE 1
`endif
`ifndef M86_WCOMBINE
`define M86_WCOMBINE 0
`endif
module `M86_TOP (
    input  wire CLK_48,
    output wire LED_B,
    output wire UART0_TX,
    input  wire UART0_RX,
    output wire SD_SCK,
    output wire SD_MOSI,
    input  wire SD_MISO,
    output wire SD_SS,
`ifndef M86_NO_SDDAT
    input  wire SD_D1,
    input  wire SD_D2,
`endif
    output wire DDMI_CK_P,          // one port a pair: the tool drives the N ball
    output wire DDMI_D0_P,
    output wire DDMI_D1_P,
    output wire DDMI_D2_P,
`ifdef M86_PT8211
    output wire AUD_BCK,
    output wire AUD_WS,
    output wire AUD_DIN,
`else
    output wire AUD_OPTICAL,        // S/PDIF, optical
`endif
    input  wire PROGRAMN,
    inout  wire usb_host_dp,        // the first USB host port
    inout  wire usb_host_dm,
    inout  wire usb_host2_dp,       // the second
    inout  wire usb_host2_dm,
    output wire [15:0] ddr3_a,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire        ddr3_cs_n,
    output wire        ddr3_cke,
    output wire        ddr3_odt,
    output wire        ddr3_reset_n,
    output wire [1:0]  ddr3_dm,
    inout  wire [15:0] ddr3_dq,
    inout  wire [1:0]  ddr3_dqs_p,
    output wire        ddr3_clk_p
);
    wire clk, pclk, bclk, pll_locked;
    pll_video pll (.clkin(CLK_48), .bclk(bclk), .pclk(pclk), .sysclk(clk),
                   .locked(pll_locked));

    // The memory's clocks (Zeitlos).
    wire mclk, eclk, ddrdel, ddr_pause, phy_rst, phy_ready, mem_locked;
    ddr3_clk ddr3_clk_i (
        .clk48_i(CLK_48), .rst_i(1'b0),
        .sys_clk_o(mclk), .eclk_o(eclk), .ddrdel_o(ddrdel),
        .pause_o(ddr_pause), .phy_rst_o(phy_rst), .ready_o(phy_ready),
        .locked_o(mem_locked));

    // The machine waits for both. (mem_locked comes from the other
    // clock: two flip-flops first.)
    reg [1:0] ml_s = 2'b00;
    always @(posedge clk) ml_s <= {ml_s[0], mem_locked};
    wire locked = pll_locked && ml_s[1];

    // The controller's reset, on its own clock: 256 cycles after that
    // clock starts.
    reg [8:0] mpor = 9'd0;
    wire      mrst = !mpor[8];
    always @(posedge mclk)
        if (mrst)
            mpor <= mpor + 9'd1;

    // Reset: held for 65,536 cycles after the PLL locks.
    reg [16:0] por = 17'd0;
    wire       rst = !por[16];
    always @(posedge clk)
        if (!locked)
            por <= 17'd0;
        else if (rst)
            por <= por + 17'd1;

    // The USB keyboard. The HID host wants 12 MHz: the oscillator
    // divided by four. It is reset for a while after configuration.
    reg [1:0] div12 = 2'd0;
    always @(posedge CLK_48) div12 <= div12 + 2'd1;
    wire      clk12 = div12[1];
    reg [7:0] upor = 8'd0;
    always @(posedge clk12)
        if (!upor[7])
            upor <= upor + 8'd1;
    // Two host ports, either for the keyboard and either for the
    // mouse: each says what is plugged into it.
    wire [1:0] typ_a, typ_b;
    wire       rep_a, rep_b;
    wire [7:0] mod_a, k1_a, k2_a, k3_a, k4_a, mod_b, k1_b, k2_b, k3_b, k4_b;
    wire [7:0] mb_a, mx_a, my_a, mb_b, mx_b, my_b;
    usb_hid_host hid (
        .usbclk(clk12), .usbrst_n(upor[7]),
        .usb_dm(usb_host_dm), .usb_dp(usb_host_dp),
        .typ(typ_a), .report(rep_a), .conerr(),
        .key_modifiers(mod_a), .key1(k1_a), .key2(k2_a),
        .key3(k3_a), .key4(k4_a),
        .mouse_btn(mb_a), .mouse_dx(mx_a), .mouse_dy(my_a),
        .game_l(), .game_r(), .game_u(), .game_d(),
        .game_a(), .game_b(), .game_x(), .game_y(), .game_sel(), .game_sta(),
        .dbg_hid_report());
    usb_hid_host hid2 (
        .usbclk(clk12), .usbrst_n(upor[7]),
        .usb_dm(usb_host2_dm), .usb_dp(usb_host2_dp),
        .typ(typ_b), .report(rep_b), .conerr(),
        .key_modifiers(mod_b), .key1(k1_b), .key2(k2_b),
        .key3(k3_b), .key4(k4_b),
        .mouse_btn(mb_b), .mouse_dx(mx_b), .mouse_dy(my_b),
        .game_l(), .game_r(), .game_u(), .game_d(),
        .game_a(), .game_b(), .game_x(), .game_y(), .game_sel(), .game_sta(),
        .dbg_hid_report());
    // The keyboard is the first port's if it has one, else the second's.
    wire       kb_b = (typ_a != 2'd1) && (typ_b == 2'd1);
    wire [1:0] hid_typ    = kb_b ? typ_b : typ_a;
    wire       hid_report = kb_b ? rep_b : rep_a;
    wire [7:0] hid_mod = kb_b ? mod_b : mod_a;
    wire [7:0] hid_k1  = kb_b ? k1_b : k1_a;
    wire [7:0] hid_k2  = kb_b ? k2_b : k2_a;
    wire [7:0] hid_k3  = kb_b ? k3_b : k3_a;
    wire [7:0] hid_k4  = kb_b ? k4_b : k4_a;
    // The mouse likewise.
    wire       ms_b = (typ_a != 2'd2) && (typ_b == 2'd2);
    wire       ms_report = ms_b ? rep_b : (rep_a && typ_a == 2'd2);
    wire [2:0] ms_btn = ms_b ? mb_b[2:0] : mb_a[2:0];
    wire [7:0] ms_dx  = ms_b ? mx_b : mx_a;
    wire [7:0] ms_dy  = ms_b ? my_b : my_a;

    wire [7:0] last_exc;
    wire       halted, tick18;
    wire [7:0] v_r, v_g, v_b;
    wire       v_hs, v_vs, v_de;
    wire        xv_req, xv_we, xv_ack, vf_t, vf_par;
    wire [3:0]  xv_sel;
    wire [15:0] xv_addr, vf_addr;
    wire [31:0] xv_wdata, xv_rdata, lb_q;
    wire [7:0]  lb_addr;
    wire        m_req, m_we, m_ack, x_req, x_we, x_ack;
    wire        m_raw;
    wire [23:0] m_addr;
    wire [1:0]  x_addr;
    wire [31:0] m_wdata, m_rdata, x_wdata, x_rdata;
`ifdef M86_CPU_C
    // Design C (docs/cpu_c.md). Its clock is 630 MHz / M86_C_DIV: 16
    // gives 39.4 MHz, 13 gives 48.5. M86_C_PH is the core's PH. With
    // M86_CPU_FPU the core has its floating-point unit (docs/fpu.md).
`ifndef M86_C_DIV
`define M86_C_DIV 16
`endif
`ifndef M86_C_PH
`define M86_C_PH 3
`endif
`ifdef M86_CPU_FPU
    m86_soc #(.CLK_HZ(630000000 / `M86_C_DIV), .CPU_C(1), .CPU_PH(`M86_C_PH), .CPU_FPU(1), .BAUD(1000000),
`else
    m86_soc #(.CLK_HZ(630000000 / `M86_C_DIV), .CPU_C(1), .CPU_PH(`M86_C_PH), .BAUD(1000000),
`endif
`else
    m86_soc #(.CLK_HZ(33157895), .BAUD(1000000),
`endif
              .MAIN_MEM(1), .MEM_AW(26), .MEM_TRAIN(1),
              .CACHE_LINE_BITS(11), .EXT_KB(64512), .VGA_EXT(1),
              .CPU_VMEM(`M86_VMEM), .CPU_OVL(`M86_OVL)) soc (
        .clk(clk), .rst(rst),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_rdata(m_rdata), .m_ack(m_ack), .m_raw(m_raw),
        .x_req(x_req), .x_we(x_we), .x_addr(x_addr), .x_wdata(x_wdata),
        .x_rdata(x_rdata), .x_ack(x_ack),
        .xv_req(xv_req), .xv_we(xv_we), .xv_sel(xv_sel), .xv_addr(xv_addr),
        .xv_wdata(xv_wdata), .xv_rdata(xv_rdata), .xv_ack(xv_ack),
        .vf_t(vf_t), .vf_addr(vf_addr), .vf_par(vf_par),
        .lb_addr(lb_addr), .lb_q(lb_q),
        .hdmi(hdmi),
        .ms_report(ms_report), .ms_btn(ms_btn), .ms_dx(ms_dx), .ms_dy(ms_dy),
        .hid_clk(clk12), .hid_report(hid_report), .hid_typ(hid_typ),
        .hid_mod(hid_mod), .hid_k1(hid_k1), .hid_k2(hid_k2),
        .hid_k3(hid_k3), .hid_k4(hid_k4),
        .vclk(pclk), .v_r(v_r), .v_g(v_g), .v_b(v_b),
        .v_hsync(v_hs), .v_vsync(v_vs), .v_de(v_de),
        .uart_tx(UART0_TX), .uart_rx(UART0_RX),
        .sd_sck(SD_SCK), .sd_mosi(SD_MOSI), .sd_miso(SD_MISO), .sd_ss_n(SD_SS),
        .spk(spk), .sb_sample(sb_sample), .opl_we(opl_we), .opl_a(opl_a), .opl_d(opl_d),
        .halted(halted), .last_exc(last_exc), .tick18(tick18));

    // Sound: the PC speaker and the AdLib as 48,000 samples a second
    // on the optical output, by Zeitlos's S/PDIF transmitter, on the
    // 48 MHz oscillator (m86_spk.v says why that clock).
    wire        spk, opl_we, a_tick, a_frame;
    wire [7:0]  opl_a, opl_d, sb_sample;
    wire signed [15:0] a_sample;
    wire hdmi;
    reg  [7:0]  apor = 8'd0;
    always @(posedge CLK_48)
        if (!apor[7])
            apor <= apor + 8'd1;
    m86_audio audio (
        .clk(clk), .opl_we(opl_we), .opl_a(opl_a), .opl_d(opl_d), .spk(spk), .sb(sb_sample),
        .aclk(CLK_48), .arst(!apor[7]),
        .tick(a_tick), .frame_req(a_frame), .sample(a_sample),
        .sd_l(), .sd_r());
`ifdef M86_PT8211
    m86_pt8211 dac (.aclk(CLK_48), .arst(!apor[7]), .sample(a_sample),
                    .bck(AUD_BCK), .ws(AUD_WS), .din(AUD_DIN));
`else
    audio_spdif spdif (
        .clk(CLK_48), .rst(!apor[7]), .enable(1'b1),
        .tick(a_tick), .frame_req(a_frame),
        .sample_l(a_sample), .sample_r(a_sample),
        .fs_code(4'd2), .spdif(AUD_OPTICAL));
`endif

    // The memory and the controller's registers, across the clocks.
    wire        wb_stb, wb_we, wb_ack, rg_stb, rg_we, rg_ack;
    wire [23:0] wb_adr;
    wire [1:0]  rg_adr;
    wire [31:0] wb_dat_w, rg_dat_w, rg_dat_r;
    wire        mem_stb, mem_we, mem_ack;
    wire [3:0]  mem_sel;
    wire [26:0] mem_adr;
    wire [31:0] mem_dat_w, mem_dat_r;
    // (A cache line at a time, and the controller's block register
    // read whole: rtl/soc/m86_xline.v. With -DM86_XLINE=0 the bridge
    // of before round 40, a word at a time.)
    wire [127:0] mem_blk;
    wire         mem_blk_ok;
    generate if (`M86_XLINE != 0) begin : gxl
        m86_xline #(.AW(24)) xm (
            .a_clk(clk), .a_rst(rst), .a_req(m_req), .a_we(m_we), .a_raw(m_raw),
            .a_addr(m_addr), .a_wdata(m_wdata), .a_rdata(m_rdata), .a_ack(m_ack),
            .b_clk(mclk), .b_rst(mrst), .b_stb(wb_stb), .b_we(wb_we),
            .b_addr(wb_adr), .b_wdata(wb_dat_w), .b_rdata(mem_dat_r), .b_ack(wb_ack),
            .b_blk(mem_blk), .b_blk_ok(mem_blk_ok));
    end else begin : gxw
        m86_xclk #(.AW(24)) xm (
            .a_clk(clk), .a_rst(rst), .a_req(m_req), .a_we(m_we),
            .a_addr(m_addr), .a_wdata(m_wdata), .a_rdata(m_rdata), .a_ack(m_ack),
            .b_clk(mclk), .b_rst(mrst), .b_stb(wb_stb), .b_we(wb_we),
            .b_addr(wb_adr), .b_wdata(wb_dat_w), .b_rdata(mem_dat_r), .b_ack(wb_ack));
    end endgenerate

    // Video memory past the VGA's own 64 KB is in the DDR3 too, above
    // the 64 MB the machine uses: the VGA's CPU side through a bridge
    // of its own (the planes a write changes ride with the address),
    // the display through its line buffer; and the three share the
    // memory (m86_vfetch.v).
    wire        vb_stb, vb_we, vb_ack, vfe_stb, vfe_lock, vfe_ack;
    wire [19:0] vb_adr;
    wire [31:0] vb_dat_w;
    wire [15:0] vfe_adr;
    m86_xclk #(.AW(20)) xvid (
        .a_clk(clk), .a_rst(rst), .a_req(xv_req), .a_we(xv_we),
        .a_addr({xv_sel, xv_addr}), .a_wdata(xv_wdata), .a_rdata(xv_rdata),
        .a_ack(xv_ack),
        .b_clk(mclk), .b_rst(mrst), .b_stb(vb_stb), .b_we(vb_we),
        .b_addr(vb_adr), .b_wdata(vb_dat_w), .b_rdata(mem_dat_r), .b_ack(vb_ack));
    m86_vfetch vfetch (
        .vclk(pclk), .vf_t(vf_t), .vf_addr(vf_addr), .vf_par(vf_par),
        .lb_addr(lb_addr), .lb_q(lb_q),
        .mclk(mclk), .mrst(mrst), .wb_stb(vfe_stb), .wb_lock(vfe_lock), .wb_cti(),
        .wb_adr(vfe_adr), .wb_dat(mem_dat_r), .wb_ack(vfe_ack));
    m86_wbarb arb (
        .clk(mclk), .rst(mrst),
        .s0_stb(vfe_stb), .s0_lock(vfe_lock), .s0_cti(3'b000),
        .s0_adr({3'b001, 8'd0, vfe_adr}),
        .s0_ack(vfe_ack),
        .s1_stb(vb_stb), .s1_we(vb_we), .s1_sel(vb_adr[19:16]),
        .s1_adr({3'b001, 8'd0, vb_adr[15:0]}), .s1_dat(vb_dat_w), .s1_ack(vb_ack),
        .s2_stb(wb_stb), .s2_we(wb_we), .s2_adr({3'b000, wb_adr}),
        .s2_dat(wb_dat_w), .s2_ack(wb_ack),
        .m_stb(mem_stb), .m_we(mem_we), .m_sel(mem_sel), .m_cti(), .m_adr(mem_adr),
        .m_dat(mem_dat_w), .m_ack(mem_ack));
    m86_xclk #(.AW(2)) xr (
        .a_clk(clk), .a_rst(rst), .a_req(x_req), .a_we(x_we),
        .a_addr(x_addr), .a_wdata(x_wdata), .a_rdata(x_rdata), .a_ack(x_ack),
        .b_clk(mclk), .b_rst(mrst), .b_stb(rg_stb), .b_we(rg_we),
        .b_addr(rg_adr), .b_wdata(rg_dat_w), .b_rdata(rg_dat_r), .b_ack(rg_ack));

    // Zeitlos's DDR3 memory: the 4 Gb part (MT41K256M16), of which
    // the machine uses the first 64 MB. Parameters as in Zeitlos's
    // rtl/boards.vh for this board.
    // (With the controller's write combining, -DM86_WCOMBINE=1, the
    // four words of a line that the bridge writes one after the other
    // are one DRAM write and not four. It is off: its logic is the
    // longest path on the controller's 48 MHz clock, which it then
    // meets on some placements and misses on others, and it saves
    // little: docs/soc.md.)
    ddr3 #(.ROW_BITS(15), .TRFC_NS(260), .WCOMBINE(`M86_WCOMBINE)) mem (
        .clk_i(mclk), .rst_i(mrst),
        .eclk_i(eclk), .ddrdel_i(ddrdel), .pause_i(ddr_pause),
        .phy_rst_i(phy_rst), .phy_ready_i(phy_ready), .pll_locked_i(mem_locked),
        .wb_adr_i(mem_adr), .wb_dat_i(mem_dat_w), .wb_dat_o(mem_dat_r),
        .wb_we_i(mem_we), .wb_sel_i(mem_sel), .wb_stb_i(mem_stb),
        .wb_cyc_i(mem_stb), .wb_ack_o(mem_ack),
        .blk_dat_o(mem_blk), .blk_ok_o(mem_blk_ok),
        .reg_adr_i(rg_adr), .reg_dat_i(rg_dat_w), .reg_dat_o(rg_dat_r),
        .reg_we_i(rg_we), .reg_stb_i(rg_stb), .reg_cyc_i(rg_stb),
        .reg_ack_o(rg_ack),
        .ddr3_a(ddr3_a), .ddr3_ba(ddr3_ba), .ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n), .ddr3_cs_n(ddr3_cs_n),
        .ddr3_cke(ddr3_cke), .ddr3_odt(ddr3_odt), .ddr3_reset_n(ddr3_reset_n),
        .ddr3_dm(ddr3_dm), .ddr3_dq(ddr3_dq), .ddr3_dqs_p(ddr3_dqs_p),
        .ddr3_clk_p(ddr3_clk_p));

    // The display: DVI, or with port 1E1h bit 0 set HDMI with the
    // sound in data islands (rtl/soc/m86_hdmi.v, docs/sound.md).
    // Channel 0 is blue and carries the syncs, 1 green, 2 red.
    reg [1:0] a_fr = 2'b00;
    always @(posedge CLK_48) a_fr <= {a_fr[0], a_frame};
    wire [1:0] t_r, t_g, t_b, t_c;
    m86_hdmi dvi (.pclk(pclk), .bclk(bclk), .r(v_r), .g(v_g), .b(v_b),
                  .de(v_de), .hsync(v_hs), .vsync(v_vs), .hdmi(hdmi),
                  .aud_clk(CLK_48), .aud_we(a_fr[1]),
                  .aud_l(a_sample), .aud_r(a_sample),
                  .tmds_r(t_r), .tmds_g(t_g), .tmds_b(t_b), .tmds_c(t_c));
    ODDRX1F o_c (.D0(t_c[0]), .D1(t_c[1]), .SCLK(bclk), .RST(1'b0), .Q(DDMI_CK_P));
    ODDRX1F o_0 (.D0(t_b[0]), .D1(t_b[1]), .SCLK(bclk), .RST(1'b0), .Q(DDMI_D0_P));
    ODDRX1F o_1 (.D0(t_g[0]), .D1(t_g[1]), .SCLK(bclk), .RST(1'b0), .Q(DDMI_D1_P));
    ODDRX1F o_2 (.D0(t_r[0]), .D1(t_r[1]), .SCLK(bclk), .RST(1'b0), .Q(DDMI_D2_P));

    reg [24:0] beat = 25'd0;
    reg        faulted = 1'b0;
    always @(posedge clk) begin
        beat <= beat + 25'd1;
        if (rst)
            faulted <= 1'b0;
        else if (last_exc != 8'hFF)
            faulted <= 1'b1;
    end
    assign LED_B = faulted ? beat[21] : beat[24];
endmodule

// 48 MHz to 126 MHz (DVI bits), 25.2 MHz (pixels) and 31.5 MHz (the
// machine): a 630 MHz VCO divided by 5, 25 and 20.
module pll_video (
    input  wire clkin,
    output wire bclk,
    output wire pclk,
    output wire sysclk,
    output wire locked
);
    (* FREQUENCY_PIN_CLKI="48" *)
    (* FREQUENCY_PIN_CLKOP="126" *)
    (* FREQUENCY_PIN_CLKOS="25.2" *)
    (* FREQUENCY_PIN_CLKOS2="31.5" *)
    (* ICP_CURRENT="12" *) (* LPF_RESISTOR="8" *)
    (* MFG_ENABLE_FILTEROPAMP="1" *) (* MFG_GMCREF_SEL="2" *)
    EHXPLLL #(
        .PLLRST_ENA("DISABLED"),
        .INTFB_WAKE("DISABLED"),
        .STDBY_ENABLE("DISABLED"),
        .DPHASE_SOURCE("DISABLED"),
        .OUTDIVIDER_MUXA("DIVA"),
        .OUTDIVIDER_MUXB("DIVB"),
        .OUTDIVIDER_MUXC("DIVC"),
        .OUTDIVIDER_MUXD("DIVD"),
        .CLKI_DIV(8),
        .CLKOP_ENABLE("ENABLED"),
        .CLKOP_DIV(5),
        .CLKOP_CPHASE(2),
        .CLKOP_FPHASE(0),
        .CLKOS_ENABLE("ENABLED"),
        .CLKOS_DIV(25),
        .CLKOS_CPHASE(2),
        .CLKOS_FPHASE(0),
        .CLKOS2_ENABLE("ENABLED"),
`ifdef M86_CPU_C
        .CLKOS2_DIV(`M86_C_DIV),
`else
        .CLKOS2_DIV(19),            // 630 / 19 = 33.16 MHz
`endif
        .CLKOS2_CPHASE(2),
        .CLKOS2_FPHASE(0),
        .FEEDBK_PATH("CLKOP"),
        .CLKFB_DIV(21)
    ) pll_i (
        .RST(1'b0),
        .STDBY(1'b0),
        .CLKI(clkin),
        .CLKOP(bclk),
        .CLKOS(pclk),
        .CLKOS2(sysclk),
        .CLKFB(bclk),
        .CLKINTFB(),
        .PHASESEL0(1'b0),
        .PHASESEL1(1'b0),
        .PHASEDIR(1'b1),
        .PHASESTEP(1'b1),
        .PHASELOADREG(1'b1),
        .PLLWAKESYNC(1'b0),
        .ENCLKOP(1'b0),
        .LOCK(locked)
    );
endmodule
