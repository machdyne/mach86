/*
 * Mach86 SoC -- the display's way out, with sound: DVI as m86_dvi.v
 * sends it, and, when `hdmi` is set, data islands between the pixels
 * that carry the machine's sound and say what the picture is. A
 * monitor or capture device with an HDMI input then has picture and
 * sound on the one cable; one that only knows DVI should be left with
 * `hdmi` clear.
 *
 * The islands are Zeitlos's (rtl/ext/zeitlos/ddmi_island.v, with its
 * encoder tmds_encoder.v, both unchanged): audio sample packets, clock
 * regeneration, general control and the AVI, SPD and audio InfoFrames,
 * one island a line, placed by position in the line. This module
 * gives that scheduler what it wants -- line and character counters
 * that start at the front porch, where ours start at the picture --
 * by rebuilding them from the display's own signals, and serialises
 * the characters as m86_dvi.v does: two bits a cycle of a clock five
 * times the pixel clock.
 *
 * The picture must be 640 x 480 with the standard timing (800 by 525,
 * 16 + 96 + 48 and 10 + 2 + 33), and vsync must change where the
 * front porch begins, 160 characters before a line's first pixel.
 * m86_vga.v's does.
 *
 * Sound: 48,000 frames a second written on aud_clk. The pixel clock
 * is 25.2 MHz from the same oscillator, so N = 6144 and CTS = 25200
 * exactly.
 *
 * `hdmi` may come from any clock; it takes effect at the start of a
 * picture.
 */
module m86_hdmi (
    input  wire       pclk,
    input  wire       bclk,         // five times pclk, from the same PLL
    input  wire [7:0] r,
    input  wire [7:0] g,
    input  wire [7:0] b,
    input  wire       de,
    input  wire       hsync,        // low during the pulse
    input  wire       vsync,
    input  wire       hdmi,
    input  wire        aud_clk,
    input  wire        aud_we,      // a frame, for one cycle
    input  wire [15:0] aud_l,
    input  wire [15:0] aud_r,
    output wire [1:0] tmds_r,       // bit 0 goes out first
    output wire [1:0] tmds_g,
    output wire [1:0] tmds_b,
    output wire [1:0] tmds_c
);
    // Where we are, counted from the front porch: character 0 is the
    // first after a line's last pixel, line 0 the first after the
    // picture's last line; vsync's leading edge is the start of line
    // 10. Lines without pixels are counted off by length.
    reg        de_d = 1'b0, vs_d = 1'b1;
    reg [9:0]  hc_r = 10'd0;
    reg [9:0]  vc_r = 10'd0;
    wire       line0 = (de_d && !de) || (hc_r == 10'd800);
    wire [9:0] hc = line0 ? 10'd0 : hc_r;
    wire [9:0] vc = (vs_d && !vsync) ? 10'd10 :
                    !line0 ? vc_r : (vc_r == 10'd524) ? 10'd0 : vc_r + 10'd1;
    always @(posedge pclk) begin
        de_d <= de;
        vs_d <= vsync;
        hc_r <= hc + 10'd1;
        vc_r <= vc;
    end

    // The switch, taken at the start of a picture.
    reg [1:0] hd_s = 2'b00;
    reg       en = 1'b0;
    always @(posedge pclk) begin
        hd_s <= {hd_s[0], hdmi};
        if (hc == 10'd0 && vc == 10'd0)
            en <= hd_s[1];
    end

    wire [1:0] m0, m1, m2, ctl1, ctl2;
    wire [3:0] t0, t1, t2;
    ddmi_island island (
        .pclk(pclk), .ce(1'b1), .en(en),
        .hc({2'b00, hc}), .vc({1'b0, vc}), .hsync(hsync), .vsync(vsync),
        // 640 x 480: the island at character 12, the video preamble
        // ten before the picture, the picture from line 45, vsync
        // from line 10; the AVI InfoFrame says format 1.
        .ioff(12'd0), .vpre0(12'd150), .vact0(11'd45), .vgcp(11'd10), .avi_sel(3'd0),
        .mode0(m0), .t0(t0), .mode1(m1), .t1(t1), .ctl1(ctl1),
        .mode2(m2), .t2(t2), .ctl2(ctl2),
        .sound_en(1'b1), .fs_code(4'd2), .acr_n(20'd6144), .acr_cts(20'd25200),
        .aud_clk(aud_clk), .aud_we(aud_we), .aud_wdata({aud_l, aud_r}));

    // Channel 0 is blue and carries the syncs; 1 is green, 2 is red.
    wire [9:0] q0, q1, q2;
    tmds_encoder #(.CH(2)) e2 (pclk, de, r, ctl2[1], ctl2[0], m2, t2, q2);
    tmds_encoder #(.CH(1)) e1 (pclk, de, g, ctl1[1], ctl1[0], m1, t1, q1);
    tmds_encoder #(.CH(0)) e0 (pclk, de, b, vsync,   hsync,   m0, t0, q0);

    reg [2:0] phase = 3'd0;
    reg       load = 1'b0;
    reg [9:0] sr = 10'd0, sg = 10'd0, sb = 10'd0, sc = 10'd0;
    always @(posedge bclk) begin
        phase <= (phase == 3'd4) ? 3'd0 : phase + 3'd1;
        load  <= (phase == 3'd4);
        sr <= load ? q2 : {2'b00, sr[9:2]};
        sg <= load ? q1 : {2'b00, sg[9:2]};
        sb <= load ? q0 : {2'b00, sb[9:2]};
        sc <= load ? 10'b0000011111 : {2'b00, sc[9:2]};
    end
    assign tmds_r = sr[1:0];
    assign tmds_g = sg[1:0];
    assign tmds_b = sb[1:0];
    assign tmds_c = sc[1:0];
endmodule
