/*
 * Mach86 -- test bench for Lakritz's memory path: the display's line
 * reads, the VGA's CPU side and the cache sharing one SDRAM
 * (rtl/soc/m86_vfetch.v), through Zeitlos's controller
 * (rtl/ext/zeitlos/sdram_kianv.v) to Zeitlos's model of the part
 * (sdram_model.v), at the board's clocks: 33.16 MHz and 25.2 MHz.
 *
 *   - 4,800 words of video memory are written, two planes at a time;
 *   - then 60 lines are asked for, one every 800 pixel clocks, while
 *     a "cache" writes and reads back as fast as it is answered and a
 *     "VGA" does the same in video memory;
 *   - every line must be whole in the buffer when the next is asked
 *     for, and how long the slowest took is printed: it has 31.7
 *     microseconds;
 *   - the model counts every protocol error it sees.
 *
 * Video memory is put low here (words 10000h up) because the model
 * backs only the first megabyte or two; the board has it at the top.
 */
`timescale 1ns / 1ps
module m86_lakritz_tb;
    reg clk = 0, vclk = 0, rst = 1;
    always #15.079 clk = ~clk;              // 33.16 MHz
    always #19.841 vclk = ~vclk;            // 25.2 MHz

    reg         vf_t = 0, vf_par = 0;
    reg  [15:0] vf_addr = 0;
    reg  [7:0]  lb_addr = 0;
    wire [31:0] lb_q, mem_q, mem_d;
    wire        f_stb, f_lock, f_ack, mem_stb, mem_we, mem_ack;
    wire [15:0] f_adr;
    wire [3:0]  mem_sel;
    wire [26:0] mem_adr;
    reg         s1_stb = 0, s1_we = 0, s2_stb = 0, s2_we = 0;
    reg  [3:0]  s1_sel = 0;
    reg  [26:0] s1_adr = 0, s2_adr = 0;
    reg  [31:0] s1_dat = 0, s2_dat = 0;
    wire        s1_ack, s2_ack;

    wire [2:0]  f_cti, mem_cti;
    m86_vfetch #(.BURST(1)) fetch (
        .vclk(vclk), .vf_t(vf_t), .vf_addr(vf_addr), .vf_par(vf_par),
        .lb_addr(lb_addr), .lb_q(lb_q),
        .mclk(clk), .mrst(rst), .wb_stb(f_stb), .wb_lock(f_lock), .wb_cti(f_cti), .wb_adr(f_adr),
        .wb_dat(mem_q), .wb_ack(f_ack));
    m86_wbarb arb (
        .clk(clk), .rst(rst),
        .s0_stb(f_stb), .s0_lock(f_lock), .s0_cti(f_cti), .s0_adr({10'd0, 1'b1, f_adr}), .s0_ack(f_ack),
        .s1_stb(s1_stb), .s1_we(s1_we), .s1_sel(s1_sel), .s1_adr(s1_adr),
        .s1_dat(s1_dat), .s1_ack(s1_ack),
        .s2_stb(s2_stb), .s2_we(s2_we), .s2_adr(s2_adr), .s2_dat(s2_dat),
        .s2_ack(s2_ack),
        .m_stb(mem_stb), .m_we(mem_we), .m_sel(mem_sel), .m_cti(mem_cti), .m_adr(mem_adr),
        .m_dat(mem_d), .m_ack(mem_ack));

    wire        sd_clk, sd_cke, sd_csn, sd_wen, sd_rasn, sd_casn;
    wire [1:0]  sd_dqm, sd_ba;
    wire [12:0] sd_addr;
    wire [15:0] sd_dq;
    sdram_wb #(.SDRAM_CLK_FREQ(34), .TREFI_NS(7500), .BURST(1)) ctrl (
        .wb_clk_i(clk), .wb_rst_i(rst),
        .wb_adr_i({mem_adr[22:0], 2'b00}), .wb_dat_i(mem_d), .wb_dat_o(mem_q),
        .wb_we_i(mem_we), .wb_sel_i(mem_sel), .wb_stb_i(mem_stb),
        .wb_ack_o(mem_ack), .wb_cyc_i(mem_stb), .wb_cti_i(mem_cti),
        .sdram_clk(sd_clk), .sdram_cke(sd_cke), .sdram_dqm(sd_dqm),
        .sdram_addr(sd_addr), .sdram_ba(sd_ba), .sdram_csn(sd_csn),
        .sdram_wen(sd_wen), .sdram_rasn(sd_rasn), .sdram_casn(sd_casn),
        .sdram_dq(sd_dq));
    sdram_model #(.MEM_WORDS(1048576)) mem (
        .clk(sd_clk), .cke(sd_cke), .csn(sd_csn), .rasn(sd_rasn), .casn(sd_casn),
        .wen(sd_wen), .dqm(sd_dqm), .ba(sd_ba), .addr(sd_addr), .dq(sd_dq));

    integer errors = 0, n1 = 0, n2 = 0, lines = 0, i;
    reg     go = 0;
    reg [31:0] vid [0:65535];               // what video memory should hold

    task vga(input we, input [3:0] sel, input [15:0] a, input [31:0] d);
        begin
            @(posedge clk); s1_adr <= {10'd0, 1'b1, a}; s1_dat <= d; s1_sel <= sel;
            s1_we <= we; s1_stb <= 1;
            @(posedge clk); while (!s1_ack) @(posedge clk);
            s1_stb <= 0;
        end
    endtask

    // The "cache": writes a word, reads it back.
    reg [31:0] v2;
    initial begin
        wait (go);
        forever begin
            @(posedge clk); s2_adr <= $random & 27'h000FFFF; s2_dat <= $random;
            s2_we <= 1; s2_stb <= 1;
            @(posedge clk); while (!s2_ack) @(posedge clk);
            s2_stb <= 0; v2 = s2_dat;
            @(posedge clk); s2_we <= 0; s2_stb <= 1;
            @(posedge clk); while (!s2_ack) @(posedge clk);
            if (mem_q !== v2) begin
                errors = errors + 1;
                if (errors < 5) $display("cache read %x, wrote %x", mem_q, v2);
            end
            s2_stb <= 0;
            n2 = n2 + 1;
        end
    end

    // The "VGA": first fills the lines' words, then goes on writing
    // two planes and reading back beyond them.
    reg [15:0] a1;
    reg [31:0] d1;
    initial begin
        for (i = 0; i < 65536; i = i + 1) vid[i] = 32'h0;
        repeat (10) @(posedge clk);
        rst = 0;
        for (i = 16'h4000; i < 16'h4000 + 4800; i = i + 1) begin
            d1 = $random;
            vga(1, 4'b0101, i[15:0], d1);
            vga(1, 4'b1010, i[15:0], ~d1);
            vid[i] = {~d1[31:24], d1[23:16], ~d1[15:8], d1[7:0]};
        end
        go = 1;
        forever begin
            a1 = 16'hC000 | ($random & 16'h0FFF);
            d1 = $random;
            vga(1, 4'b0101, a1, d1);
            vid[a1] = {vid[a1][31:24], d1[23:16], vid[a1][15:8], d1[7:0]};
            vga(0, 4'b1111, a1, 0);
            if (mem_q !== vid[a1]) begin
                errors = errors + 1;
                if (errors < 5) $display("video read %x, expected %x", mem_q, vid[a1]);
            end
            n1 = n1 + 1;
        end
    end

    // How long a line takes: from the request to the buffer's last word.
    time    t_req, worst = 0;
    always @(vf_t) t_req = $time;
    always @(negedge f_lock) if (go && $time - t_req > worst) worst = $time - t_req;

    integer l, c;
    initial begin
        wait (go);
        repeat (8) @(posedge vclk);
        for (l = 0; l < 60; l = l + 1) begin
            @(posedge vclk);
            // (every seventh line from an address that is not a multiple
            // of four, as a program's start address may be)
            vf_addr <= 16'h4000 + l * 80 + ((l % 7 == 6) ? 16'd1 : 16'd0); vf_par <= l[0]; vf_t <= !vf_t;
            repeat (795) @(posedge vclk);
            if (f_lock) begin
                errors = errors + 1;
                $display("line %0d is not in after a line's time", l);
            end
            for (c = 0; c < 80; c = c + 1) begin
                lb_addr <= {l[0], c[6:0]};
                @(posedge vclk); @(posedge vclk);
                if (lb_q !== vid[16'h4000 + l * 80 + c + ((l % 7 == 6) ? 1 : 0)]) begin
                    errors = errors + 1;
                    if (errors < 5) $display("line %0d word %0d: %x", l, c, lb_q);
                end
            end
            lines = lines + 1;
        end
        errors = errors + mem.errors;
        $display("lakritz: %0d lines, the slowest in %0d ns of 31,746; %0d video and %0d cache accesses beside them; %0d errors (the model's: %0d)",
                 lines, worst, n1, n2, errors, mem.errors);
        if (errors == 0 && n1 > 100 && n2 > 100) $display("lakritz: pass");
        else $display("lakritz: FAIL");
        $finish;
    end
endmodule
