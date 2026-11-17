/*
 * Mach86 -- test bench for the display's line buffer and the share of
 * the memory (rtl/soc/m86_vfetch.v), against a memory that answers
 * after a few cycles, more for every fourth word, as a DDR3
 * controller with a block register does.
 *
 *   - lines are asked for one after another, 800 pixel clocks apart,
 *     while two other masters read and write as fast as they are
 *     answered; every line must be whole in the buffer, in its half,
 *     before the next is asked for;
 *   - what the other two read must be what was written, their writes
 *     must land with their byte selects, and none may be answered
 *     with another's data.
 */
`timescale 1ns / 1ps
module m86_vfetch_tb;
    reg mclk = 0, vclk = 0, rst = 1;
    always #10.416 mclk = ~mclk;            // 48 MHz
    always #19.841 vclk = ~vclk;            // 25.2 MHz

    reg         vf_t = 0, vf_par = 0;
    reg  [15:0] vf_addr = 0;
    reg  [7:0]  lb_addr = 0;
    wire [31:0] lb_q;
    wire        f_stb, f_lock, f_ack, m_stb, m_we, m_ackw;
    wire [15:0] f_adr;
    wire [3:0]  m_sel;
    wire [26:0] m_adr;
    wire [31:0] m_dat;
    reg         s1_stb = 0, s1_we = 0, s2_stb = 0, s2_we = 0;
    reg  [3:0]  s1_sel = 0;
    reg  [26:0] s1_adr = 0, s2_adr = 0;
    reg  [31:0] s1_dat = 0, s2_dat = 0;
    wire        s1_ack, s2_ack;

    // The memory: 2^17 words; video is the upper half.
    reg [31:0] mem [0:131071];
    reg [31:0] m_q;
    reg        m_ack = 0;
    integer    wait_n = 0, i;
    wire [16:0] ma = {m_adr[24], m_adr[15:0]};
    always @(posedge mclk) begin
        m_ack <= 0;
        if (m_stb && !m_ack) begin
            wait_n = wait_n + 1;
            if (wait_n >= ((m_adr[1:0] == 0) ? 12 : 2)) begin
                wait_n = 0;
                m_ack <= 1;
                if (m_we) begin
                    if (m_sel[0]) mem[ma][7:0]   <= m_dat[7:0];
                    if (m_sel[1]) mem[ma][15:8]  <= m_dat[15:8];
                    if (m_sel[2]) mem[ma][23:16] <= m_dat[23:16];
                    if (m_sel[3]) mem[ma][31:24] <= m_dat[31:24];
                end else
                    m_q <= mem[ma];
            end
        end else
            wait_n = 0;
    end
    assign m_ackw = m_ack;

    m86_vfetch fetch (
        .vclk(vclk), .vf_t(vf_t), .vf_addr(vf_addr), .vf_par(vf_par),
        .lb_addr(lb_addr), .lb_q(lb_q),
        .mclk(mclk), .mrst(rst), .wb_stb(f_stb), .wb_lock(f_lock), .wb_cti(), .wb_adr(f_adr),
        .wb_dat(m_q), .wb_ack(f_ack));
    m86_wbarb arb (
        .clk(mclk), .rst(rst),
        .s0_stb(f_stb), .s0_lock(f_lock), .s0_cti(3'b000), .s0_adr({3'b001, 8'd0, f_adr}), .s0_ack(f_ack),
        .s1_stb(s1_stb), .s1_we(s1_we), .s1_sel(s1_sel), .s1_adr(s1_adr),
        .s1_dat(s1_dat), .s1_ack(s1_ack),
        .s2_stb(s2_stb), .s2_we(s2_we), .s2_adr(s2_adr), .s2_dat(s2_dat),
        .s2_ack(s2_ack),
        .m_stb(m_stb), .m_we(m_we), .m_sel(m_sel), .m_cti(), .m_adr(m_adr),
        .m_dat(m_dat), .m_ack(m_ackw));

    integer errors = 0, n1 = 0, n2 = 0, lines = 0;

    // Master 2, the cache: writes a word, reads it back, on and on, in
    // the lower half.
    reg [31:0] v2;
    initial begin
        @(negedge rst);
        forever begin
            @(posedge mclk); s2_adr <= $random & 27'h000FFFF; s2_dat <= $random;
            s2_we <= 1; s2_stb <= 1;
            @(posedge mclk); while (!s2_ack) @(posedge mclk);
            s2_stb <= 0; v2 = s2_dat;
            @(posedge mclk); s2_we <= 0; s2_stb <= 1;
            @(posedge mclk); while (!s2_ack) @(posedge mclk);
            s2_stb <= 0;
            if (m_q !== v2) begin
                errors = errors + 1;
                if (errors < 5) $display("cache read %x, wrote %x", m_q, v2);
            end
            n2 = n2 + 1;
        end
    end

    // Master 1, the VGA's CPU side: writes two planes of a word in the
    // video half beyond what the lines show, and reads it back.
    reg [31:0] v1, old1;
    initial begin
        @(negedge rst);
        forever begin
            @(posedge mclk); s1_adr <= {3'b001, 8'd0, 16'hC000 | ($random & 16'h0FFF)};
            s1_we <= 0; s1_sel <= 4'b1111; s1_stb <= 1;
            @(posedge mclk); while (!s1_ack) @(posedge mclk);
            s1_stb <= 0; @(posedge mclk); old1 = m_q;
            s1_dat <= $random; s1_sel <= 4'b0101; s1_we <= 1; s1_stb <= 1;
            @(posedge mclk); while (!s1_ack) @(posedge mclk);
            s1_stb <= 0; v1 = {old1[31:24], s1_dat[23:16], old1[15:8], s1_dat[7:0]};
            @(posedge mclk); s1_we <= 0; s1_stb <= 1;
            @(posedge mclk); while (!s1_ack) @(posedge mclk);
            s1_stb <= 0; @(posedge mclk);
            if (m_q !== v1) begin
                errors = errors + 1;
                if (errors < 5) $display("video read %x, expected %x", m_q, v1);
            end
            n1 = n1 + 1;
        end
    end

    // The display: a line every 800 clocks; the line before is checked
    // in the buffer just before the next is asked for.
    integer l, c;
    reg [15:0] prev_addr;
    reg        prev_par;
    initial begin
        for (i = 0; i < 131072; i = i + 1) mem[i] = i * 32'h01010101 + 32'h12345678;
        repeat (8) @(posedge mclk);
        rst = 0;
        repeat (8) @(posedge vclk);
        for (l = 0; l < 60; l = l + 1) begin
            prev_addr = vf_addr; prev_par = vf_par;
            @(posedge vclk);
            vf_addr <= 16'h4000 + l * 80; vf_par <= l[0]; vf_t <= !vf_t;
            repeat (790) @(posedge vclk);
            // the line just asked for must be whole by now
            for (c = 0; c < 80; c = c + 1) begin
                lb_addr <= {l[0], c[6:0]};
                @(posedge vclk); @(posedge vclk);
                if (lb_q !== mem[17'h10000 + 16'h4000 + l * 80 + c]) begin
                    errors = errors + 1;
                    if (errors < 5) $display("line %0d word %0d: %x", l, c, lb_q);
                end
            end
            lines = lines + 1;
        end
        $display("vfetch: %0d lines, %0d video and %0d cache accesses beside them, %0d errors",
                 lines, n1, n2, errors);
        if (errors == 0 && n1 > 100 && n2 > 100) $display("vfetch: pass");
        else $display("vfetch: FAIL");
        $finish;
    end
endmodule
