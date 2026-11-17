/*
 * Mach86 SoC -- DVI output: three colour channels and a clock, each a
 * serial stream of ten bits a pixel.
 *
 * Sources: the Digital Visual Interface specification, revision 1.0
 * (the TMDS encoding of section 3). The serialising follows Zeitlos's
 * rtl/gpu/gpu_ddmi.v, which is proven on these boards: a bit clock of
 * five times the pixel clock, two bits a cycle, least significant
 * first, into a double-data-rate output cell (in the board's file).
 * No audio or other HDMI data: plain DVI, which an HDMI input accepts.
 */
module m86_dvi (
    input  wire       pclk,
    input  wire       bclk,         // five times pclk, from the same PLL
    input  wire [7:0] r,
    input  wire [7:0] g,
    input  wire [7:0] b,
    input  wire       de,
    input  wire       hsync,
    input  wire       vsync,
    output wire [1:0] tmds_r,       // bit 0 goes out first
    output wire [1:0] tmds_g,
    output wire [1:0] tmds_b,
    output wire [1:0] tmds_c
);
    wire [9:0] qr, qg, qb;
    m86_tmds er (.clk(pclk), .d(r), .de(de), .c(2'b00), .q(qr));
    m86_tmds eg (.clk(pclk), .d(g), .de(de), .c(2'b00), .q(qg));
    m86_tmds eb (.clk(pclk), .d(b), .de(de), .c({vsync, hsync}), .q(qb));

    reg [2:0] phase = 3'd0;
    reg       load = 1'b0;
    reg [9:0] sr = 10'd0, sg = 10'd0, sb = 10'd0, sc = 10'd0;
    always @(posedge bclk) begin
        phase <= (phase == 3'd4) ? 3'd0 : phase + 3'd1;
        load  <= (phase == 3'd4);
        sr <= load ? qr : {2'b00, sr[9:2]};
        sg <= load ? qg : {2'b00, sg[9:2]};
        sb <= load ? qb : {2'b00, sb[9:2]};
        sc <= load ? 10'b0000011111 : {2'b00, sc[9:2]};
    end
    assign tmds_r = sr[1:0];
    assign tmds_g = sg[1:0];
    assign tmds_b = sb[1:0];
    assign tmds_c = sc[1:0];
endmodule

// One channel's encoder: eight bits to ten with few transitions and no
// net DC, or one of four control characters outside the picture.
module m86_tmds (
    input  wire       clk,
    input  wire [7:0] d,
    input  wire       de,
    input  wire [1:0] c,
    output reg  [9:0] q = 10'd0
);
    wire [3:0] n1d = d[0] + d[1] + d[2] + d[3] + d[4] + d[5] + d[6] + d[7];
    wire       xn  = (n1d > 4'd4) || (n1d == 4'd4 && !d[0]);
    wire [8:0] qm;
    assign qm[0] = d[0];
    assign qm[1] = qm[0] ^ d[1] ^ xn;
    assign qm[2] = qm[1] ^ d[2] ^ xn;
    assign qm[3] = qm[2] ^ d[3] ^ xn;
    assign qm[4] = qm[3] ^ d[4] ^ xn;
    assign qm[5] = qm[4] ^ d[5] ^ xn;
    assign qm[6] = qm[5] ^ d[6] ^ xn;
    assign qm[7] = qm[6] ^ d[7] ^ xn;
    assign qm[8] = !xn;

    wire [3:0] n1 = qm[0] + qm[1] + qm[2] + qm[3] + qm[4] + qm[5] + qm[6] + qm[7];
    // Ones minus zeros in the eight data bits, -8 to 8.
    wire signed [4:0] bal = {n1, 1'b0} - 5'sd8;
    reg  signed [4:0] cnt = 5'sd0;      // the running disparity

    always @(posedge clk) begin
        if (!de) begin
            case (c)
                2'b00: q <= 10'b1101010100;
                2'b01: q <= 10'b0010101011;
                2'b10: q <= 10'b0101010100;
                default: q <= 10'b1010101011;
            endcase
            cnt <= 5'sd0;
        end else if (cnt == 5'sd0 || bal == 5'sd0) begin
            q   <= {!qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
            cnt <= qm[8] ? cnt + bal : cnt - bal;
        end else if ((cnt > 5'sd0) == (bal > 5'sd0)) begin
            q   <= {1'b1, qm[8], ~qm[7:0]};
            cnt <= cnt + {3'd0, qm[8], 1'b0} - bal;
        end else begin
            q   <= {1'b0, qm[8], qm[7:0]};
            cnt <= cnt - {3'd0, !qm[8], 1'b0} + bal;
        end
    end
endmodule
