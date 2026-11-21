/*
 * Mach86 on Lakritz (ECP5 LFE5U-25F, 32 MB SDRAM): the minimum board.
 *
 * The SoC of rtl/soc/m86_soc.v at 33.16 MHz with everything a program
 * can see as on Sergei ML2, and three differences underneath:
 *
 *   - the memory is SDRAM, on the CPU's own clock (Zeitlos's
 *     controller, rtl/ext/zeitlos/sdram_kianv.v): no second clock, no
 *     bridge, no training;
 *   - there is no block RAM to spare for video memory (56 blocks, 96
 *     used on Sergei), so all of it is in the SDRAM: the VGA is built
 *     with VGA_BRAM = 0, every line comes through the line buffer, and
 *     the display has first call on the memory in every mode;
 *   - sound is a one-bit sigma-delta signal on AUDIO_L and AUDIO_R,
 *     for the board's resistor and capacitor.
 *
 * Memory: 32 MB. The top 256 KB is the video memory; the machine has
 * 640 KB and 31,488 KB above 1 MB. The data cache is 16 KB.
 *
 * NOT RUN ON A BOARD. Pins are Zeitlos's (boards/lakritz.lpf). The
 * memory path is simulated against Zeitlos's model of the SDRAM
 * (sim/m86_lakritz_tb.v). docs/boards.md says what is known and not.
 *
 * LED_B: slow blink, the machine runs; fast, the CPU has faulted.
 *
 * The other SDRAM boards are built from this file too, with defines
 * (the Makefile's): M86_TOP names the module; M86_UART gives the
 * BIOS's console a serial port; M86_PT8211 sends the sound to a
 * PT8211 DAC and not to the sigma-delta pins; M86_NO_SDDAT leaves
 * out the card's two unused data lines, where the board's constraint
 * file does not name them. Konfekt is M86_NO_SDDAT; Mozart ML0 and
 * ML1 are all three. None of those has run on a board.
 */
`ifndef M86_TOP
`define M86_TOP lakritz
`endif
// What of the processor this board builds (rtl/cpu/m86b_core.v): the
// decoder's window; paging, virtual 8086 mode and the I/O permission
// bitmap (left out: about 2,500 LUTs that DOS and DOOM do not use);
// loads that let the next instruction start. -DM86_VMEM=1 builds a
// Lakritz with all of protected mode.
`ifndef M86_VMEM
`define M86_VMEM 0
`endif
`ifndef M86_WIN
`define M86_WIN 1
`endif
`ifndef M86_OVL
`define M86_OVL 1
`endif
module `M86_TOP (
    input  wire CLK_48,
    output wire LED_B,
    output wire SD_SCK,
    output wire SD_MOSI,
    input  wire SD_MISO,
    output wire SD_SS,
`ifndef M86_NO_SDDAT
    input  wire SD_DAT1,
    input  wire SD_DAT2,
`endif
`ifdef M86_UART
    output wire UART0_TX,
    input  wire UART0_RX,
`endif
    output wire DDMI_CK_P,
    output wire DDMI_D0_P,
    output wire DDMI_D1_P,
    output wire DDMI_D2_P,
`ifdef M86_PT8211
    output wire AUD_BCK,
    output wire AUD_WS,
    output wire AUD_DIN,
`else
    output wire AUDIO_L,
    output wire AUDIO_R,
`endif
    input  wire PROGRAMN,
    inout  wire [1:0] usb_host_dp,
    inout  wire [1:0] usb_host_dm,
    output wire [12:0] sdram_a,
    output wire [1:0]  sdram_ba,
    output wire        sdram_cs_n,
    output wire        sdram_cke,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire [1:0]  sdram_dm,
    inout  wire [15:0] sdram_dq,
    output wire        sdram_clock
);
    wire clk, pclk, bclk, locked;
    pll_lakritz pll (.clkin(CLK_48), .bclk(bclk), .pclk(pclk), .sysclk(clk),
                     .locked(locked));

    // Reset: held for 65,536 cycles after the PLL locks (2 ms: the
    // SDRAM wants 200 microseconds, which its controller counts).
    reg [16:0] por = 17'd0;
    wire       rst = !por[16];
    always @(posedge clk)
        if (!locked)
            por <= 17'd0;
        else if (rst)
            por <= por + 17'd1;
    // The memory's reset ends early, so that it is ready when the
    // machine starts.
    wire       mrst = !por[9] && rst;

    // USB: keyboard and mouse, either port for either (as Sergei).
    reg [1:0] div12 = 2'd0;
    always @(posedge CLK_48) div12 <= div12 + 2'd1;
    wire      clk12 = div12[1];
    reg [7:0] upor = 8'd0;
    always @(posedge clk12)
        if (!upor[7])
            upor <= upor + 8'd1;
    wire [1:0] typ_a, typ_b;
    wire       rep_a, rep_b;
    wire [7:0] mod_a, k1_a, k2_a, k3_a, k4_a, mod_b, k1_b, k2_b, k3_b, k4_b;
    wire [7:0] mb_a, mx_a, my_a, mb_b, mx_b, my_b;
    usb_hid_host hid (
        .usbclk(clk12), .usbrst_n(upor[7]),
        .usb_dm(usb_host_dm[0]), .usb_dp(usb_host_dp[0]),
        .typ(typ_a), .report(rep_a), .conerr(),
        .key_modifiers(mod_a), .key1(k1_a), .key2(k2_a),
        .key3(k3_a), .key4(k4_a),
        .mouse_btn(mb_a), .mouse_dx(mx_a), .mouse_dy(my_a),
        .game_l(), .game_r(), .game_u(), .game_d(),
        .game_a(), .game_b(), .game_x(), .game_y(), .game_sel(), .game_sta(),
        .dbg_hid_report());
    usb_hid_host hid2 (
        .usbclk(clk12), .usbrst_n(upor[7]),
        .usb_dm(usb_host_dm[1]), .usb_dp(usb_host_dp[1]),
        .typ(typ_b), .report(rep_b), .conerr(),
        .key_modifiers(mod_b), .key1(k1_b), .key2(k2_b),
        .key3(k3_b), .key4(k4_b),
        .mouse_btn(mb_b), .mouse_dx(mx_b), .mouse_dy(my_b),
        .game_l(), .game_r(), .game_u(), .game_d(),
        .game_a(), .game_b(), .game_x(), .game_y(), .game_sel(), .game_sta(),
        .dbg_hid_report());
    wire       kb_b = (typ_a != 2'd1) && (typ_b == 2'd1);
    wire [1:0] hid_typ    = kb_b ? typ_b : typ_a;
    wire       hid_report = kb_b ? rep_b : rep_a;
    wire [7:0] hid_mod = kb_b ? mod_b : mod_a;
    wire [7:0] hid_k1  = kb_b ? k1_b : k1_a;
    wire [7:0] hid_k2  = kb_b ? k2_b : k2_a;
    wire [7:0] hid_k3  = kb_b ? k3_b : k3_a;
    wire [7:0] hid_k4  = kb_b ? k4_b : k4_a;
    wire       ms_b = (typ_a != 2'd2) && (typ_b == 2'd2);
    wire       ms_report = ms_b ? rep_b : (rep_a && typ_a == 2'd2);
    wire [2:0] ms_btn = ms_b ? mb_b[2:0] : mb_a[2:0];
    wire [7:0] ms_dx  = ms_b ? mx_b : mx_a;
    wire [7:0] ms_dy  = ms_b ? my_b : my_a;

    // The machine.
    wire [7:0]  v_r, v_g, v_b, last_exc;
    wire        v_hs, v_vs, v_de, halted, tick18;
    wire        m_req, m_we, m_ack, x_req;
    wire [22:0] m_addr;
    wire [31:0] m_wdata, mem_q;
    wire        xv_req, xv_we, xv_ack, vf_t, vf_par;
    wire [3:0]  xv_sel;
    wire [15:0] xv_addr, vf_addr;
    wire [31:0] xv_wdata, lb_q;
    wire [7:0]  lb_addr;
    wire        spk, opl_we;
    wire [7:0]  opl_a, opl_d, sb_sample;
    m86_soc #(.CLK_HZ(33157895), .BAUD(1000000),
              .MAIN_MEM(1), .MEM_AW(25), .MEM_TRAIN(0),
              .CACHE_LINE_BITS(10), .EXT_KB(31488),
              .VGA_EXT(1), .VGA_BRAM(0), .CPU_WIN(`M86_WIN), .CPU_VMEM(`M86_VMEM),
              .CPU_OVL(`M86_OVL)) soc (
        .clk(clk), .rst(rst), .vclk(pclk),
        .v_r(v_r), .v_g(v_g), .v_b(v_b),
        .v_hsync(v_hs), .v_vsync(v_vs), .v_de(v_de),
`ifdef M86_UART
        .uart_tx(UART0_TX), .uart_rx(UART0_RX),
`else
        .uart_tx(), .uart_rx(1'b1),
`endif
        .sd_sck(SD_SCK), .sd_mosi(SD_MOSI), .sd_miso(SD_MISO), .sd_ss_n(SD_SS),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_rdata(mem_q), .m_ack(m_ack),
        .x_req(x_req), .x_we(), .x_addr(), .x_wdata(), .x_rdata(32'd0), .x_ack(x_req),
        .xv_req(xv_req), .xv_we(xv_we), .xv_sel(xv_sel), .xv_addr(xv_addr),
        .xv_wdata(xv_wdata), .xv_rdata(mem_q), .xv_ack(xv_ack),
        .vf_t(vf_t), .vf_addr(vf_addr), .vf_par(vf_par),
        .lb_addr(lb_addr), .lb_q(lb_q),
        .ms_report(ms_report), .ms_btn(ms_btn), .ms_dx(ms_dx), .ms_dy(ms_dy),
        .hid_clk(clk12), .hid_report(hid_report), .hid_typ(hid_typ),
        .hid_mod(hid_mod), .hid_k1(hid_k1), .hid_k2(hid_k2),
        .hid_k3(hid_k3), .hid_k4(hid_k4),
        .hdmi(hdmi), .spk(spk), .sb_sample(sb_sample), .opl_we(opl_we), .opl_a(opl_a), .opl_d(opl_d),
        .halted(halted), .last_exc(last_exc), .tick18(tick18));

    // The memory: the display's line reads, the VGA's CPU side and
    // the cache, one at a time, on the SDRAM (m86_vfetch.v).
    wire        vfe_stb, vfe_lock, vfe_ack, mem_stb, mem_we, mem_ack;
    wire [15:0] vfe_adr;
    wire [3:0]  mem_sel;
    wire [26:0] mem_adr;
    wire [31:0] mem_d;
    wire [2:0]  vfe_cti, mem_cti;
    m86_vfetch #(.BURST(1)) vfetch (
        .vclk(pclk), .vf_t(vf_t), .vf_addr(vf_addr), .vf_par(vf_par),
        .lb_addr(lb_addr), .lb_q(lb_q),
        .mclk(clk), .mrst(rst), .wb_stb(vfe_stb), .wb_lock(vfe_lock), .wb_cti(vfe_cti),
        .wb_adr(vfe_adr), .wb_dat(mem_q), .wb_ack(vfe_ack));
    m86_wbarb arb (
        .clk(clk), .rst(rst),
        .s0_stb(vfe_stb), .s0_lock(vfe_lock), .s0_cti(vfe_cti),
        .s0_adr({4'd0, 7'h7F, vfe_adr}),
        .s0_ack(vfe_ack),
        .s1_stb(xv_req), .s1_we(xv_we), .s1_sel(xv_sel),
        .s1_adr({4'd0, 7'h7F, xv_addr}), .s1_dat(xv_wdata), .s1_ack(xv_ack),
        .s2_stb(m_req), .s2_we(m_we), .s2_adr({4'd0, m_addr}),
        .s2_dat(m_wdata), .s2_ack(m_ack),
        .m_stb(mem_stb), .m_we(mem_we), .m_sel(mem_sel), .m_cti(mem_cti),
        .m_adr(mem_adr), .m_dat(mem_d), .m_ack(mem_ack));
    sdram_wb #(.SDRAM_CLK_FREQ(34), .TREFI_NS(7500), .BURST(1)) sdram (
        .wb_clk_i(clk), .wb_rst_i(mrst),
        .wb_adr_i({mem_adr[22:0], 2'b00}), .wb_dat_i(mem_d), .wb_dat_o(mem_q),
        .wb_we_i(mem_we), .wb_sel_i(mem_sel), .wb_stb_i(mem_stb),
        .wb_ack_o(mem_ack), .wb_cyc_i(mem_stb), .wb_cti_i(mem_cti),
        .sdram_clk(sdram_clock), .sdram_cke(sdram_cke), .sdram_dqm(sdram_dm),
        .sdram_addr(sdram_a), .sdram_ba(sdram_ba), .sdram_csn(sdram_cs_n),
        .sdram_wen(sdram_we_n), .sdram_rasn(sdram_ras_n), .sdram_casn(sdram_cas_n),
        .sdram_dq(sdram_dq));

    // Sound: speaker and AdLib as a one-bit signal on both channels.
    wire a_sd;
    reg  [7:0] apor = 8'd0;
    always @(posedge CLK_48)
        if (!apor[7])
            apor <= apor + 8'd1;
    wire a_frame, hdmi;
    wire signed [15:0] a_sample;
    m86_audio audio (
        .clk(clk), .opl_we(opl_we), .opl_a(opl_a), .opl_d(opl_d), .spk(spk), .sb(sb_sample),
        .aclk(CLK_48), .arst(!apor[7]),
        .tick(), .frame_req(a_frame), .sample(a_sample), .sd_l(a_sd), .sd_r());
`ifdef M86_PT8211
    m86_pt8211 dac (.aclk(CLK_48), .arst(!apor[7]), .sample(a_sample),
                    .bck(AUD_BCK), .ws(AUD_WS), .din(AUD_DIN));
`else
    assign AUDIO_L = a_sd;
    assign AUDIO_R = a_sd;
`endif

    // The display.
    wire [1:0] t_r, t_g, t_b, t_c;
    // DVI, or with port 1E1h bit 0 set HDMI with the sound in data
    // islands (rtl/soc/m86_hdmi.v).
    reg [1:0] a_fr = 2'b00;
    always @(posedge CLK_48) a_fr <= {a_fr[0], a_frame};
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

// 48 MHz to 126 MHz (DVI bits), 25.2 MHz (pixels) and 33.16 MHz (the
// machine): a 630 MHz VCO divided by 5, 25 and 19. As Sergei ML2.
module pll_lakritz (
    input  wire clkin,
    output wire bclk,
    output wire pclk,
    output wire sysclk,
    output wire locked
);
    (* FREQUENCY_PIN_CLKI="48" *)
    (* FREQUENCY_PIN_CLKOP="126" *)
    (* FREQUENCY_PIN_CLKOS="25.2" *)
    (* FREQUENCY_PIN_CLKOS2="33.158" *)
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
        .CLKOS2_DIV(19),
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
